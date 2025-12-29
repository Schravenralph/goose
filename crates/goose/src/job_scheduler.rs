use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_cron_scheduler::{job::JobId, Job, JobScheduler as TokioJobScheduler};
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};

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
            Paths::data_dir()
                .unwrap_or_else(|_| PathBuf::from("/tmp/goose-jobs"))
                .join("jobs.json")
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

        // Load existing jobs
        scheduler.load_jobs().await?;
        scheduler.load_job_history().await?;

        // Start the scheduler
        scheduler
            .tokio_scheduler
            .start()
            .await
            .map_err(|e| JobSchedulerError::SchedulerInternalError(e.to_string()))?;

        Ok(scheduler)
    }

    /// Load jobs from storage
    async fn load_jobs(&self) -> Result<(), JobSchedulerError> {
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
                    let job_id = self.schedule_job_internal(&job, cron).await?;
                    jobs_guard.insert(job.id.clone(), (job_id, job));
                } else {
                    // Job is paused, don't schedule it
                    jobs_guard.insert(job.id.clone(), (JobId::new(), job));
                }
            } else {
                // No schedule, just store it
                jobs_guard.insert(job.id.clone(), (JobId::new(), job));
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
        &self,
        job: &ScriptJob,
        cron: &str,
    ) -> Result<JobId, JobSchedulerError> {
        let job_id = job.id.clone();
        let jobs_arc = self.jobs.clone();
        let running_tasks_arc = self.running_tasks.clone();
        let scheduler_arc = Arc::downgrade(&Arc::new(self.clone()));

        let local_tz = chrono::Local::now().timezone();

        let job_for_task = job.clone();
        let cron_expr = cron.to_string();

        let job_instance = Job::new_async_tz(&cron_expr, local_tz, move |_uuid, _l| {
            let job_id_clone = job_id.clone();
            let jobs_arc_clone = jobs_arc.clone();
            let running_tasks_clone = running_tasks_arc.clone();
            let scheduler_weak = scheduler_arc.clone();

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

        let job_id = self
            .tokio_scheduler
            .add(job_instance)
            .await
            .map_err(|e| JobSchedulerError::SchedulerInternalError(e.to_string()))?;

        Ok(job_id)
    }

    /// Clone implementation for JobScheduler (needed for async closures)
    fn clone(&self) -> Self {
        Self {
            tokio_scheduler: self.tokio_scheduler.clone(),
            jobs: self.jobs.clone(),
            job_history: self.job_history.clone(),
            storage_path: self.storage_path.clone(),
            history_storage_path: self.history_storage_path.clone(),
            running_tasks: self.running_tasks.clone(),
            log_dir: self.log_dir.clone(),
        }
    }
}

// This is a placeholder - we'll implement the actual execution logic next
impl JobScheduler {
    async fn execute_job_internal(
        &self,
        job_id: &str,
        retry_count: u32,
        cancel_token: Option<CancellationToken>,
    ) -> Result<String, JobSchedulerError> {
        // This will be implemented in the next step
        Err(JobSchedulerError::AnyhowError(anyhow::anyhow!(
            "Not implemented yet"
        )))
    }
}

