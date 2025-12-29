use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex;
use tokio_cron_scheduler::{job::JobId, Job, JobScheduler as TokioJobScheduler};
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::config::paths::Paths;
use crate::logging::prepare_log_directory;

/// Job execution status
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum JobExecutionStatus {
    Pending,
    Running,
    Success,
    Failed,
    Cancelled,
    Retrying,
}

/// Job execution result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobExecution {
    pub execution_id: String,
    pub job_id: String,
    pub status: JobExecutionStatus,
    pub start_time: DateTime<Utc>,
    pub end_time: Option<DateTime<Utc>>,
    pub duration_seconds: Option<f64>,
    pub exit_code: Option<i32>,
    pub stdout: Option<String>,
    pub stderr: Option<String>,
    pub retry_count: u32,
    pub error_message: Option<String>,
    pub trace_id: String,
    pub log_file: Option<PathBuf>,
    pub metrics_file: Option<PathBuf>,
}

/// Job retry configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetryConfig {
    /// Maximum number of retry attempts
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,
    /// Initial delay in seconds before first retry
    #[serde(default = "default_retry_delay")]
    pub initial_delay_seconds: u64,
    /// Maximum delay in seconds (exponential backoff cap)
    #[serde(default = "default_max_retry_delay")]
    pub max_delay_seconds: u64,
    /// Whether to use exponential backoff
    #[serde(default = "default_true")]
    pub exponential_backoff: bool,
}

fn default_max_retries() -> u32 {
    3
}

fn default_retry_delay() -> u64 {
    60
}

fn default_max_retry_delay() -> u64 {
    3600
}

fn default_true() -> bool {
    true
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            max_retries: default_max_retries(),
            initial_delay_seconds: default_retry_delay(),
            max_delay_seconds: default_max_retry_delay(),
            exponential_backoff: default_true(),
        }
    }
}

/// Script job definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScriptJob {
    /// Unique job identifier
    pub id: String,
    /// Human-readable job name
    pub name: String,
    /// Description of what the job does
    pub description: Option<String>,
    /// Path to the script to execute
    pub script_path: PathBuf,
    /// Working directory for script execution
    pub working_directory: Option<PathBuf>,
    /// Environment variables to set
    #[serde(default)]
    pub environment: HashMap<String, String>,
    /// Cron schedule expression (e.g., "0 0 * * *" for daily at midnight)
    pub cron_schedule: Option<String>,
    /// Job dependencies (other job IDs that must complete successfully first)
    #[serde(default)]
    pub dependencies: Vec<String>,
    /// Retry configuration
    #[serde(default)]
    pub retry_config: RetryConfig,
    /// Whether the job is currently paused
    #[serde(default)]
    pub paused: bool,
    /// Timeout in seconds (None = no timeout)
    pub timeout_seconds: Option<u64>,
    /// Last execution time
    pub last_run: Option<DateTime<Utc>>,
    /// Whether the job is currently running
    #[serde(default)]
    pub currently_running: bool,
    /// Process start time if currently running
    pub process_start_time: Option<DateTime<Utc>>,
}

/// Job scheduler error types
#[derive(Debug)]
pub enum JobSchedulerError {
    JobIdExists(String),
    JobNotFound(String),
    StorageError(io::Error),
    ScriptExecutionError(String),
    CronParseError(String),
    DependencyError(String),
    TimeoutError(String),
    SchedulerInternalError(String),
    AnyhowError(anyhow::Error),
}

impl std::fmt::Display for JobSchedulerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            JobSchedulerError::JobIdExists(id) => write!(f, "Job ID '{}' already exists.", id),
            JobSchedulerError::JobNotFound(id) => write!(f, "Job ID '{}' not found.", id),
            JobSchedulerError::StorageError(e) => write!(f, "Storage error: {}", e),
            JobSchedulerError::ScriptExecutionError(e) => {
                write!(f, "Script execution error: {}", e)
            }
            JobSchedulerError::CronParseError(e) => write!(f, "Invalid cron string: {}", e),
            JobSchedulerError::DependencyError(e) => write!(f, "Dependency error: {}", e),
            JobSchedulerError::TimeoutError(e) => write!(f, "Timeout error: {}", e),
            JobSchedulerError::SchedulerInternalError(e) => {
                write!(f, "Scheduler internal error: {}", e)
            }
            JobSchedulerError::AnyhowError(e) => write!(f, "Job scheduler error: {}", e),
        }
    }
}

impl std::error::Error for JobSchedulerError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            JobSchedulerError::StorageError(e) => Some(e),
            JobSchedulerError::AnyhowError(e) => Some(e.as_ref()),
            _ => None,
        }
    }
}

impl From<io::Error> for JobSchedulerError {
    fn from(err: io::Error) -> Self {
        JobSchedulerError::StorageError(err)
    }
}

impl From<anyhow::Error> for JobSchedulerError {
    fn from(err: anyhow::Error) -> Self {
        JobSchedulerError::AnyhowError(err)
    }
}

type JobsMap = HashMap<String, (JobId, ScriptJob)>;
type RunningTasksMap = HashMap<String, CancellationToken>;
type JobHistoryMap = HashMap<String, Vec<JobExecution>>;

/// Job scheduler for executing scripts with logging, metrics, and scheduling
pub struct JobScheduler {
    tokio_scheduler: TokioJobScheduler,
    jobs: Arc<Mutex<JobsMap>>,
    job_history: Arc<Mutex<JobHistoryMap>>,
    storage_path: PathBuf,
    history_storage_path: PathBuf,
    running_tasks: Arc<Mutex<RunningTasksMap>>,
    log_dir: PathBuf,
}

impl JobScheduler {
    /// Create a new job scheduler instance
    pub async fn new(storage_path: Option<PathBuf>) -> Result<Arc<Self>, JobSchedulerError> {
        let storage = storage_path.unwrap_or_else(|| {
            Paths::data_dir().join("jobs.json")
        });

        let history_storage = storage
            .parent()
            .unwrap_or_else(|| Path::new("/tmp"))
            .join("job_history.json");

        let log_dir = prepare_log_directory("jobs", true)
            .map_err(|e| JobSchedulerError::AnyhowError(e))?;

        let internal_scheduler = TokioJobScheduler::new()
            .await
            .map_err(|e| JobSchedulerError::SchedulerInternalError(e.to_string()))?;

        let jobs = Arc::new(Mutex::new(HashMap::new()));
        let job_history = Arc::new(Mutex::new(HashMap::new()));
        let running_tasks = Arc::new(Mutex::new(HashMap::new()));

        let scheduler = Arc::new(Self {
            tokio_scheduler: internal_scheduler,
            jobs,
            job_history,
            storage_path: storage.clone(),
            history_storage_path: history_storage,
            running_tasks,
            log_dir,
        });

        // Load job history first
        scheduler.load_job_history().await?;

        // Load existing jobs (this will schedule them)
        scheduler.load_jobs().await?;

        // Start the scheduler
        scheduler
            .tokio_scheduler
            .start()
            .await
            .map_err(|e| JobSchedulerError::SchedulerInternalError(e.to_string()))?;

        Ok(scheduler)
    }

    /// Load jobs from storage
    async fn load_jobs(self: &Arc<Self>) -> Result<(), JobSchedulerError> {
        if !self.storage_path.exists() {
            return Ok(());
        }

        let content = fs::read_to_string(&self.storage_path)
            .map_err(|e| JobSchedulerError::StorageError(e))?;

        let jobs: Vec<ScriptJob> = serde_json::from_str(&content)
            .map_err(|e| JobSchedulerError::StorageError(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Failed to parse jobs: {}", e),
            )))?;

        let mut jobs_guard = self.jobs.lock().await;

        for job in jobs {
            if let Some(cron) = &job.cron_schedule {
                if !job.paused {
                    // Schedule the job
                    let tokio_job_id = self.schedule_job_internal(&job, cron).await?;
                    jobs_guard.insert(job.id.clone(), (tokio_job_id, job));
                } else {
                    // Job is paused, don't schedule it
                    jobs_guard.insert(job.id.clone(), (Uuid::new_v4().into(), job));
                }
            } else {
                // No schedule, just store it
                jobs_guard.insert(job.id.clone(), (Uuid::new_v4().into(), job));
            }
        }

        Ok(())
    }

    /// Load job history from storage
    async fn load_job_history(&self) -> Result<(), JobSchedulerError> {
        if !self.history_storage_path.exists() {
            return Ok(());
        }

        let content = fs::read_to_string(&self.history_storage_path)
            .map_err(|e| JobSchedulerError::StorageError(e))?;

        let history: JobHistoryMap = serde_json::from_str(&content)
            .map_err(|e| JobSchedulerError::StorageError(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Failed to parse job history: {}", e),
            )))?;

        let mut history_guard = self.job_history.lock().await;
        *history_guard = history;

        Ok(())
    }

    /// Persist jobs to storage
    async fn persist_jobs(&self) -> Result<(), JobSchedulerError> {
        let jobs_guard = self.jobs.lock().await;
        let jobs: Vec<ScriptJob> = jobs_guard.values().map(|(_, j)| j.clone()).collect();
        drop(jobs_guard);

        if let Some(parent) = self.storage_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| JobSchedulerError::StorageError(e))?;
        }

        let data = serde_json::to_string_pretty(&jobs)
            .map_err(|e| JobSchedulerError::StorageError(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Failed to serialize jobs: {}", e),
            )))?;

        fs::write(&self.storage_path, data)
            .map_err(|e| JobSchedulerError::StorageError(e))?;

        Ok(())
    }

    /// Persist job history to storage
    async fn persist_job_history(&self) -> Result<(), JobSchedulerError> {
        let history_guard = self.job_history.lock().await;
        let history = history_guard.clone();
        drop(history_guard);

        if let Some(parent) = self.history_storage_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| JobSchedulerError::StorageError(e))?;
        }

        let data = serde_json::to_string_pretty(&history)
            .map_err(|e| JobSchedulerError::StorageError(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Failed to serialize job history: {}", e),
            )))?;

        fs::write(&self.history_storage_path, data)
            .map_err(|e| JobSchedulerError::StorageError(e))?;

        Ok(())
    }

    /// Add a record to job history
    async fn add_to_history(&self, execution: JobExecution) -> Result<(), JobSchedulerError> {
        let mut history_guard = self.job_history.lock().await;
        let executions = history_guard.entry(execution.job_id.clone()).or_insert_with(Vec::new);
        executions.push(execution);

        // Keep only last 1000 executions per job
        if executions.len() > 1000 {
            executions.drain(0..executions.len() - 1000);
        }

        drop(history_guard);
        self.persist_job_history().await?;

        Ok(())
    }

    /// Internal method to schedule a job in the tokio scheduler
    async fn schedule_job_internal(
        self: &Arc<Self>,
        job: &ScriptJob,
        cron: &str,
    ) -> Result<JobId, JobSchedulerError> {
        let job_id = job.id.clone();
        let scheduler_weak = Arc::downgrade(self);

        let local_tz = chrono::Local::now().timezone();
        let cron_expr = cron.to_string();

        let job_instance = Job::new_async_tz(&cron_expr, local_tz, move |_uuid, _l| {
            let job_id_clone = job_id.clone();
            let scheduler_weak = scheduler_weak.clone();

            Box::pin(async move {
                if let Some(scheduler) = scheduler_weak.upgrade() {
                    if let Err(e) = scheduler
                        .execute_job_internal(&job_id_clone, 0, None)
                        .await
                    {
                        error!("Failed to execute scheduled job {}: {}", job_id_clone, e);
                    }
                }
            })
        })
        .map_err(|e| JobSchedulerError::CronParseError(e.to_string()))?;

        let tokio_job_id = self
            .tokio_scheduler
            .add(job_instance)
            .await
            .map_err(|e| JobSchedulerError::SchedulerInternalError(e.to_string()))?;

        Ok(tokio_job_id)
    }

    /// Execute a job (internal method)
    async fn execute_job_internal(
        &self,
        job_id: &str,
        retry_count: u32,
        cancel_token: Option<CancellationToken>,
    ) -> Result<String, JobSchedulerError> {
        // Get the job definition
        let job = {
            let jobs_guard = self.jobs.lock().await;
            jobs_guard
                .get(job_id)
                .map(|(_, j)| j.clone())
                .ok_or_else(|| JobSchedulerError::JobNotFound(job_id.to_string()))?
        };

        // Check if job is paused
        if job.paused {
            return Err(JobSchedulerError::AnyhowError(anyhow::anyhow!(
                "Job {} is paused",
                job_id
            )));
        }

        // Check dependencies
        if !job.dependencies.is_empty() {
            self.check_dependencies(&job.dependencies).await?;
        }

        // Generate execution ID and trace ID
        let execution_id = format!("{}-{}", job_id, Utc::now().timestamp());
        let trace_id = Uuid::new_v4().to_string();

        // Create log file path
        let log_file = self
            .log_dir
            .join(format!("{}-{}.jsonl", job_id, execution_id));

        // Create metrics file path
        let metrics_file = self
            .log_dir
            .join(format!("{}-{}-metrics.json", job_id, execution_id));

        // Mark job as running
        {
            let mut jobs_guard = self.jobs.lock().await;
            if let Some((_, job_def)) = jobs_guard.get_mut(job_id) {
                job_def.currently_running = true;
                job_def.process_start_time = Some(Utc::now());
            }
        }
        self.persist_jobs().await?;

        // Create cancellation token if not provided
        let cancel = cancel_token.unwrap_or_else(|| CancellationToken::new());
        {
            let mut tasks = self.running_tasks.lock().await;
            tasks.insert(job_id.to_string(), cancel.clone());
        }

        let start_time = Utc::now();
        let mut execution = JobExecution {
            execution_id: execution_id.clone(),
            job_id: job_id.to_string(),
            status: JobExecutionStatus::Running,
            start_time,
            end_time: None,
            duration_seconds: None,
            exit_code: None,
            stdout: None,
            stderr: None,
            retry_count,
            error_message: None,
            trace_id: trace_id.clone(),
            log_file: Some(log_file.clone()),
            metrics_file: Some(metrics_file.clone()),
        };

        // Clone cancel token for use after execute_script
        let cancel_clone = cancel.clone();

        // Execute the script
        let result = self
            .execute_script(
                &job,
                &trace_id,
                &log_file,
                &metrics_file,
                cancel,
            )
            .await;

        let end_time = Utc::now();
        let duration = (end_time - start_time).num_milliseconds() as f64 / 1000.0;

        // Update execution record
        match result {
            Ok((exit_code, stdout, stderr)) => {
                execution.status = if exit_code == 0 {
                    JobExecutionStatus::Success
                } else {
                    JobExecutionStatus::Failed
                };
                execution.end_time = Some(end_time);
                execution.duration_seconds = Some(duration);
                execution.exit_code = Some(exit_code);
                execution.stdout = Some(stdout);
                execution.stderr = Some(stderr);

                // If failed and retries available, schedule retry
                if exit_code != 0
                    && retry_count < job.retry_config.max_retries
                    && !cancel_clone.is_cancelled()
                {
                    execution.status = JobExecutionStatus::Retrying;
                    self.add_to_history(execution.clone()).await?;

                    // Calculate delay for retry
                    let delay = self.calculate_retry_delay(&job.retry_config, retry_count);
                    info!(
                        "Job {} failed, retrying in {} seconds (attempt {}/{})",
                        job_id,
                        delay,
                        retry_count + 1,
                        job.retry_config.max_retries
                    );

                    // Schedule retry - we'll need to handle this differently
                    // For now, just log that retry would happen
                    warn!(
                        "Job {} failed, would retry in {} seconds (attempt {}/{})",
                        job_id,
                        delay,
                        retry_count + 1,
                        job.retry_config.max_retries
                    );
                } else {
                    // Final result - add to history
                    self.add_to_history(execution.clone()).await?;
                }
            }
            Err(e) => {
                execution.status = JobExecutionStatus::Failed;
                execution.end_time = Some(end_time);
                execution.duration_seconds = Some(duration);
                execution.error_message = Some(e.to_string());
                self.add_to_history(execution.clone()).await?;
            }
        }

        // Update job status
        {
            let mut jobs_guard = self.jobs.lock().await;
            if let Some((_, job_def)) = jobs_guard.get_mut(job_id) {
                job_def.currently_running = false;
                job_def.process_start_time = None;
                job_def.last_run = Some(end_time);
            }
        }
        self.persist_jobs().await?;

        // Remove from running tasks
        {
            let mut tasks = self.running_tasks.lock().await;
            tasks.remove(job_id);
        }

        Ok(execution_id)
    }

    /// Check if all dependencies have completed successfully
    async fn check_dependencies(&self, dependencies: &[String]) -> Result<(), JobSchedulerError> {
        let history_guard = self.job_history.lock().await;

        for dep_id in dependencies {
            // Check if dependency job exists
            let jobs_guard = self.jobs.lock().await;
            if !jobs_guard.contains_key(dep_id) {
                drop(jobs_guard);
                drop(history_guard);
                return Err(JobSchedulerError::DependencyError(format!(
                    "Dependency job '{}' not found",
                    dep_id
                )));
            }
            drop(jobs_guard);

            // Check if dependency has completed successfully
            if let Some(executions) = history_guard.get(dep_id) {
                if let Some(last_execution) = executions.last() {
                    if last_execution.status != JobExecutionStatus::Success {
                        drop(history_guard);
                        return Err(JobSchedulerError::DependencyError(format!(
                            "Dependency job '{}' has not completed successfully",
                            dep_id
                        )));
                    }
                } else {
                    drop(history_guard);
                    return Err(JobSchedulerError::DependencyError(format!(
                        "Dependency job '{}' has no execution history",
                        dep_id
                    )));
                }
            } else {
                drop(history_guard);
                return Err(JobSchedulerError::DependencyError(format!(
                    "Dependency job '{}' has no execution history",
                    dep_id
                )));
            }
        }

        Ok(())
    }

    /// Calculate retry delay based on retry configuration
    fn calculate_retry_delay(&self, retry_config: &RetryConfig, retry_count: u32) -> u64 {
        if retry_config.exponential_backoff {
            let delay = retry_config.initial_delay_seconds * 2_u64.pow(retry_count);
            delay.min(retry_config.max_delay_seconds)
        } else {
            retry_config.initial_delay_seconds
        }
    }

    /// Execute a script with structured logging
    async fn execute_script(
        &self,
        job: &ScriptJob,
        trace_id: &str,
        log_file: &Path,
        metrics_file: &Path,
        cancel_token: CancellationToken,
    ) -> Result<(i32, String, String), JobSchedulerError> {
        // Determine script interpreter based on file extension
        let script_path = &job.script_path;
        if !script_path.exists() {
            return Err(JobSchedulerError::ScriptExecutionError(format!(
                "Script path does not exist: {:?}",
                script_path
            )));
        }

        let (interpreter, args) = self.determine_interpreter(script_path)?;

        // Set up working directory
        let working_dir = job
            .working_directory
            .as_ref()
            .map(|p| p.as_path())
            .unwrap_or_else(|| script_path.parent().unwrap_or(Path::new(".")));

        // Build command
        let mut cmd = Command::new(&interpreter);
        if !args.is_empty() {
            cmd.args(&args);
        }
        cmd.arg(script_path);

        // Set working directory
        cmd.current_dir(working_dir);

        // Set environment variables
        cmd.env("TRACE_ID", trace_id);
        cmd.env("JOB_ID", &job.id);
        cmd.env("JOB_NAME", &job.name);
        cmd.env("LOG_FILE", log_file);
        cmd.env("METRICS_FILE", metrics_file);
        for (key, value) in &job.environment {
            cmd.env(key, value);
        }

        // Capture stdout and stderr
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());

        info!(
            trace_id = trace_id,
            job_id = job.id,
            "Executing script: {:?}",
            script_path
        );

        // Execute with timeout if configured
        let result = if let Some(timeout) = job.timeout_seconds {
            tokio::time::timeout(
                tokio::time::Duration::from_secs(timeout),
                self.run_command_with_cancel(cmd, cancel_token),
            )
            .await
            .map_err(|_| {
                JobSchedulerError::TimeoutError(format!(
                    "Job execution timed out after {} seconds",
                    timeout
                ))
            })?
        } else {
            self.run_command_with_cancel(cmd, cancel_token).await
        };

        match result {
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                let stderr = String::from_utf8_lossy(&output.stderr).to_string();
                let exit_code = output.status.code().unwrap_or(0);

                // Write structured log entry
                self.write_execution_log(log_file, trace_id, &job.id, exit_code, &stdout, &stderr)
                    .await?;

                // Write metrics
                self.write_execution_metrics(metrics_file, trace_id, &job.id, exit_code, &output)
                    .await?;

                Ok((exit_code, stdout, stderr))
            }
            Err(e) => Err(JobSchedulerError::ScriptExecutionError(format!(
                "Failed to execute script: {}",
                e
            ))),
        }
    }

    /// Determine the interpreter for a script based on its extension
    fn determine_interpreter(
        &self,
        script_path: &Path,
    ) -> Result<(String, Vec<String>), JobSchedulerError> {
        let extension = script_path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();

        match extension.as_str() {
            "sh" | "bash" => Ok(("bash".to_string(), vec![])),
            "py" | "python" => Ok(("python3".to_string(), vec![])),
            "js" => Ok(("node".to_string(), vec![])),
            "rb" => Ok(("ruby".to_string(), vec![])),
            "pl" => Ok(("perl".to_string(), vec![])),
            "php" => Ok(("php".to_string(), vec![])),
            _ => {
                // Check for shebang
                if let Ok(content) = fs::read_to_string(script_path) {
                    if let Some(first_line) = content.lines().next() {
                        if first_line.starts_with("#!") {
                            let shebang = first_line.trim_start_matches("#!");
                            let parts: Vec<&str> = shebang.split_whitespace().collect();
                            if !parts.is_empty() {
                                return Ok((parts[0].to_string(), parts[1..].iter().map(|s| s.to_string()).collect()));
                            }
                        }
                    }
                }
                // Default to bash
                Ok(("bash".to_string(), vec![]))
            }
        }
    }

    /// Run a command with cancellation support
    async fn run_command_with_cancel(
        &self,
        mut cmd: Command,
        cancel_token: CancellationToken,
    ) -> Result<std::process::Output, io::Error> {
        let mut child = cmd.spawn()?;

        // Capture stdout and stderr
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        // Spawn tasks to read stdout and stderr
        let stdout_handle = if let Some(stdout) = stdout {
            Some(tokio::task::spawn_blocking(move || {
                let mut output = Vec::new();
                use std::io::Read;
                let mut reader = std::io::BufReader::new(stdout);
                let _ = reader.read_to_end(&mut output);
                output
            }))
        } else {
            None
        };

        let stderr_handle = if let Some(stderr) = stderr {
            Some(tokio::task::spawn_blocking(move || {
                let mut output = Vec::new();
                use std::io::Read;
                let mut reader = std::io::BufReader::new(stderr);
                let _ = reader.read_to_end(&mut output);
                output
            }))
        } else {
            None
        };

        // Wrap child in Arc<StdMutex<>> to share between branches
        let child_arc = Arc::new(StdMutex::new(child));

        // Wait for either completion or cancellation
        let child_clone = child_arc.clone();
        let wait_handle = tokio::task::spawn_blocking(move || {
            let mut child_guard = child_clone.lock().unwrap();
            child_guard.wait()
        });

        tokio::select! {
            result = wait_handle => {
                match result {
                    Ok(Ok(status)) => {
                        let stdout = if let Some(handle) = stdout_handle {
                            handle.await.unwrap_or_default()
                        } else {
                            vec![]
                        };
                        let stderr = if let Some(handle) = stderr_handle {
                            handle.await.unwrap_or_default()
                        } else {
                            vec![]
                        };
                        Ok(std::process::Output {
                            status,
                            stdout,
                            stderr,
                        })
                    }
                    Ok(Err(e)) => Err(e),
                    Err(e) => Err(io::Error::new(
                        io::ErrorKind::Other,
                        format!("Task join error: {}", e)
                    )),
                }
            }
            _ = cancel_token.cancelled() => {
                let mut child_guard = child_arc.lock().unwrap();
                let _ = child_guard.kill();
                let _ = child_guard.wait();
                Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Job execution cancelled"
                ))
            }
        }
    }

    /// Write structured execution log
    async fn write_execution_log(
        &self,
        log_file: &Path,
        trace_id: &str,
        job_id: &str,
        exit_code: i32,
        stdout: &str,
        stderr: &str,
    ) -> Result<(), JobSchedulerError> {
        let log_entry = serde_json::json!({
            "timestamp": Utc::now().to_rfc3339(),
            "level": if exit_code == 0 { "INFO" } else { "ERROR" },
            "trace_id": trace_id,
            "job_id": job_id,
            "exit_code": exit_code,
            "stdout": stdout,
            "stderr": stderr,
        });

        let log_line = serde_json::to_string(&log_entry)
            .map_err(|e| JobSchedulerError::StorageError(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Failed to serialize log entry: {}", e),
            )))?;

        tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log_file)
            .await
            .map_err(|e| JobSchedulerError::StorageError(e))?
            .write_all(format!("{}\n", log_line).as_bytes())
            .await
            .map_err(|e| JobSchedulerError::StorageError(e))?;

        Ok(())
    }

    /// Write execution metrics
    async fn write_execution_metrics(
        &self,
        metrics_file: &Path,
        trace_id: &str,
        job_id: &str,
        exit_code: i32,
        _output: &std::process::Output,
    ) -> Result<(), JobSchedulerError> {
        let metrics = serde_json::json!({
            "trace_id": trace_id,
            "job_id": job_id,
            "exit_code": exit_code,
            "success": exit_code == 0,
            "timestamp": Utc::now().to_rfc3339(),
        });

        let metrics_json = serde_json::to_string_pretty(&metrics)
            .map_err(|e| JobSchedulerError::StorageError(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Failed to serialize metrics: {}", e),
            )))?;

        tokio::fs::write(metrics_file, metrics_json)
            .await
            .map_err(|e| JobSchedulerError::StorageError(e))?;

        Ok(())
    }

    /// Load jobs from a configuration file (YAML or JSON)
    /// Supports both formats:
    /// - Array of jobs: [job1, job2, ...]
    /// - Object with jobs array: { jobs: [job1, job2, ...] }
    pub async fn load_jobs_from_file(
        self: &Arc<Self>,
        config_path: &Path,
    ) -> Result<Vec<String>, JobSchedulerError> {
        let content = fs::read_to_string(config_path)
            .map_err(|e| JobSchedulerError::StorageError(e))?;

        let extension = config_path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();

        let jobs: Vec<ScriptJob> = match extension.as_str() {
            "yaml" | "yml" => {
                // Try parsing as object with jobs array first
                #[derive(Deserialize)]
                struct JobConfig {
                    jobs: Option<Vec<ScriptJob>>,
                }

                let config: serde_yaml::Value = serde_yaml::from_str(&content)
                    .map_err(|e| JobSchedulerError::StorageError(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("Failed to parse YAML: {}", e),
                    )))?;

                if let Ok(job_config) = serde_yaml::from_value::<JobConfig>(config.clone()) {
                    job_config.jobs.unwrap_or_default()
                } else if let Ok(jobs_array) = serde_yaml::from_value::<Vec<ScriptJob>>(config) {
                    jobs_array
                } else {
                    return Err(JobSchedulerError::StorageError(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "YAML must contain either an array of jobs or an object with a 'jobs' array",
                    )));
                }
            }
            "json" => {
                // Try parsing as object with jobs array first
                #[derive(Deserialize)]
                struct JobConfig {
                    jobs: Option<Vec<ScriptJob>>,
                }

                if let Ok(job_config) = serde_json::from_str::<JobConfig>(&content) {
                    job_config.jobs.unwrap_or_default()
                } else if let Ok(jobs_array) = serde_json::from_str::<Vec<ScriptJob>>(&content) {
                    jobs_array
                } else {
                    return Err(JobSchedulerError::StorageError(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "JSON must contain either an array of jobs or an object with a 'jobs' array",
                    )));
                }
            }
            _ => {
                return Err(JobSchedulerError::StorageError(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Configuration file must be YAML (.yaml, .yml) or JSON (.json)",
                )));
            }
        };

        let mut loaded_ids = Vec::new();
        for job in jobs {
            let job_id = job.id.clone();
            self.add_job(job).await?;
            loaded_ids.push(job_id);
        }

        Ok(loaded_ids)
    }

    // ========== Public API Methods ==========

    /// Add a new job to the scheduler
    pub async fn add_job(self: &Arc<Self>, job: ScriptJob) -> Result<(), JobSchedulerError> {
        let job_id = job.id.clone();

        // Check if job already exists
        {
            let jobs_guard = self.jobs.lock().await;
            if jobs_guard.contains_key(&job_id) {
                return Err(JobSchedulerError::JobIdExists(job_id));
            }
        }

        // Schedule the job if it has a cron schedule and is not paused
        let tokio_job_id = if let Some(cron) = &job.cron_schedule {
            if !job.paused {
                self.schedule_job_internal(&job, cron).await?
            } else {
                Uuid::new_v4().into()
            }
        } else {
            Uuid::new_v4().into()
        };

        // Store the job
        {
            let mut jobs_guard = self.jobs.lock().await;
            jobs_guard.insert(job_id.clone(), (tokio_job_id, job));
        }

        self.persist_jobs().await?;

        info!("Added job: {}", job_id);
        Ok(())
    }

    /// List all jobs
    pub async fn list_jobs(&self) -> Vec<ScriptJob> {
        let jobs_guard = self.jobs.lock().await;
        jobs_guard.values().map(|(_, j)| j.clone()).collect()
    }

    /// Get a specific job by ID
    pub async fn get_job(&self, job_id: &str) -> Option<ScriptJob> {
        let jobs_guard = self.jobs.lock().await;
        jobs_guard.get(job_id).map(|(_, j)| j.clone())
    }

    /// Remove a job from the scheduler
    pub async fn remove_job(self: &Arc<Self>, job_id: &str) -> Result<(), JobSchedulerError> {
        // Remove from tokio scheduler if scheduled
        {
            let jobs_guard = self.jobs.lock().await;
            if let Some((tokio_job_id, _)) = jobs_guard.get(job_id) {
                if let Err(e) = self.tokio_scheduler.remove(tokio_job_id).await {
                    warn!("Failed to remove job from scheduler: {}", e);
                }
            }
        }

        // Remove from jobs map
        {
            let mut jobs_guard = self.jobs.lock().await;
            jobs_guard.remove(job_id);
        }

        // Cancel if running
        {
            let mut tasks = self.running_tasks.lock().await;
            if let Some(cancel_token) = tasks.remove(job_id) {
                cancel_token.cancel();
            }
        }

        self.persist_jobs().await?;

        info!("Removed job: {}", job_id);
        Ok(())
    }

    /// Pause a job (prevents it from running)
    pub async fn pause_job(self: &Arc<Self>, job_id: &str) -> Result<(), JobSchedulerError> {
        let (cron, tokio_job_id) = {
            let mut jobs_guard = self.jobs.lock().await;
            let job = jobs_guard
                .get_mut(job_id)
                .ok_or_else(|| JobSchedulerError::JobNotFound(job_id.to_string()))?;

            if job.1.paused {
                return Ok(()); // Already paused
            }

            job.1.paused = true;
            let cron = job.1.cron_schedule.clone();
            let tokio_job_id = job.0.clone();
            (cron, tokio_job_id)
        };

        // Remove from scheduler if it was scheduled
        if cron.is_some() {
            if let Err(e) = self.tokio_scheduler.remove(&tokio_job_id).await {
                warn!("Failed to remove paused job from scheduler: {}", e);
            }
        }

        self.persist_jobs().await?;

        info!("Paused job: {}", job_id);
        Ok(())
    }

    /// Unpause a job (allows it to run again)
    pub async fn unpause_job(self: &Arc<Self>, job_id: &str) -> Result<(), JobSchedulerError> {
        let (cron, job) = {
            let mut jobs_guard = self.jobs.lock().await;
            let job_entry = jobs_guard
                .get_mut(job_id)
                .ok_or_else(|| JobSchedulerError::JobNotFound(job_id.to_string()))?;

            if !job_entry.1.paused {
                return Ok(()); // Already unpaused
            }

            job_entry.1.paused = false;
            let cron = job_entry.1.cron_schedule.clone();
            let job = job_entry.1.clone();
            (cron, job)
        };

        // Re-schedule if it has a cron schedule
        if let Some(cron_expr) = &cron {
            let tokio_job_id = self.schedule_job_internal(&job, cron_expr).await?;
            let mut jobs_guard = self.jobs.lock().await;
            if let Some(job_entry) = jobs_guard.get_mut(job_id) {
                job_entry.0 = tokio_job_id;
            }
        }

        self.persist_jobs().await?;

        info!("Unpaused job: {}", job_id);
        Ok(())
    }

    /// Run a job immediately (regardless of schedule)
    pub async fn run_now(self: &Arc<Self>, job_id: &str) -> Result<String, JobSchedulerError> {
        // Check if job is already running
        {
            let jobs_guard = self.jobs.lock().await;
            if let Some((_, job)) = jobs_guard.get(job_id) {
                if job.currently_running {
                    return Err(JobSchedulerError::AnyhowError(anyhow::anyhow!(
                        "Job '{}' is already running",
                        job_id
                    )));
                }
            } else {
                return Err(JobSchedulerError::JobNotFound(job_id.to_string()));
            }
        }

        self.execute_job_internal(job_id, 0, None).await
    }

    /// Get execution history for a job
    pub async fn get_job_history(&self, job_id: &str, limit: Option<usize>) -> Vec<JobExecution> {
        let history_guard = self.job_history.lock().await;
        if let Some(executions) = history_guard.get(job_id) {
            let mut result = executions.clone();
            if let Some(limit) = limit {
                result.truncate(limit);
            }
            result
        } else {
            Vec::new()
        }
    }

    /// Get all job execution history
    pub async fn get_all_history(&self) -> JobHistoryMap {
        let history_guard = self.job_history.lock().await;
        history_guard.clone()
    }

    /// Kill a currently running job
    pub async fn kill_job(self: &Arc<Self>, job_id: &str) -> Result<(), JobSchedulerError> {
        let cancel_token = {
            let mut tasks = self.running_tasks.lock().await;
            tasks.remove(job_id)
        };

        if let Some(token) = cancel_token {
            token.cancel();
            info!("Cancelled running job: {}", job_id);
            Ok(())
        } else {
            Err(JobSchedulerError::JobNotFound(job_id.to_string()))
        }
    }

    /// Get information about a running job
    pub async fn get_running_job_info(
        &self,
        job_id: &str,
    ) -> Option<(String, DateTime<Utc>)> {
        let jobs_guard = self.jobs.lock().await;
        if let Some((_, job)) = jobs_guard.get(job_id) {
            if job.currently_running {
                if let Some(start_time) = job.process_start_time {
                    return Some((job_id.to_string(), start_time));
                }
            }
        }
        None
    }

    /// Update a job's schedule
    pub async fn update_schedule(
        self: &Arc<Self>,
        job_id: &str,
        new_cron: String,
    ) -> Result<(), JobSchedulerError> {
        let (_old_tokio_job_id, job) = {
            let mut jobs_guard = self.jobs.lock().await;
            let job_entry = jobs_guard
                .get_mut(job_id)
                .ok_or_else(|| JobSchedulerError::JobNotFound(job_id.to_string()))?;

            // Remove old schedule if it exists
            if job_entry.1.cron_schedule.is_some() {
                if let Err(e) = self.tokio_scheduler.remove(&job_entry.0).await {
                    warn!("Failed to remove old schedule: {}", e);
                }
            }

            job_entry.1.cron_schedule = Some(new_cron.clone());
            let old_tokio_job_id = job_entry.0.clone();
            let job = job_entry.1.clone();
            (old_tokio_job_id, job)
        };

        // Schedule with new cron if not paused
        if !job.paused {
            let new_tokio_job_id = self.schedule_job_internal(&job, &new_cron).await?;
            let mut jobs_guard = self.jobs.lock().await;
            if let Some(job_entry) = jobs_guard.get_mut(job_id) {
                job_entry.0 = new_tokio_job_id;
            }
        }

        self.persist_jobs().await?;

        info!("Updated schedule for job: {}", job_id);
        Ok(())
    }
}

