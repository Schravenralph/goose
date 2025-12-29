# Custom Job Scheduler

A custom job scheduler for executing scripts with built-in structured logging, metrics collection, and observability.

## Features

- ✅ **Script Execution**: Execute bash, Python, Node.js, Ruby, Perl, PHP scripts and more
- ✅ **Cron-like Scheduling**: Schedule jobs using standard cron expressions
- ✅ **Structured Logging**: All job executions are logged with trace IDs, timestamps, and structured JSON format
- ✅ **Metrics Collection**: Automatic collection of execution metrics (duration, success/failure, exit codes)
- ✅ **Job Dependencies**: Define dependencies between jobs (jobs wait for dependencies to complete successfully)
- ✅ **Retry Logic**: Configurable retry with exponential backoff
- ✅ **Job History**: Complete audit trail of all job executions
- ✅ **Configuration Files**: Define jobs in YAML or JSON format
- ✅ **Job Management**: Pause, unpause, run immediately, and manage jobs programmatically

## Usage

### Basic Example

```rust
use goose::job_scheduler::{JobScheduler, ScriptJob, RetryConfig};
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Create scheduler
    let scheduler = JobScheduler::new(None).await?;

    // Create a job
    let job = ScriptJob {
        id: "my-job".to_string(),
        name: "My Job".to_string(),
        description: Some("A simple job".to_string()),
        script_path: PathBuf::from("/path/to/script.sh"),
        working_directory: None,
        environment: std::collections::HashMap::new(),
        cron_schedule: Some("0 0 * * *".to_string()), // Daily at midnight
        dependencies: vec![],
        retry_config: RetryConfig::default(),
        paused: false,
        timeout_seconds: Some(3600),
        last_run: None,
        currently_running: false,
        process_start_time: None,
    };

    // Add the job
    scheduler.add_job(job).await?;

    // Run a job immediately
    let execution_id = scheduler.run_now("my-job").await?;
    println!("Job execution ID: {}", execution_id);

    // List all jobs
    let jobs = scheduler.list_jobs().await;
    for job in jobs {
        println!("Job: {} - {}", job.id, job.name);
    }

    // Get job history
    let history = scheduler.get_job_history("my-job", Some(10)).await;
    for execution in history {
        println!("Execution: {:?}", execution);
    }

    Ok(())
}
```

### Loading Jobs from Configuration File

```rust
use goose::job_scheduler::JobScheduler;
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let scheduler = JobScheduler::new(None).await?;

    // Load jobs from YAML or JSON file
    let loaded_ids = scheduler
        .load_jobs_from_file(PathBuf::from("examples/job-config-example.yaml").as_path())
        .await?;

    println!("Loaded {} jobs: {:?}", loaded_ids.len(), loaded_ids);

    Ok(())
}
```

## Configuration Format

### YAML Format

```yaml
jobs:
  - id: daily-backup
    name: Daily Backup
    description: Runs daily backup script at midnight
    script_path: /path/to/backup.sh
    cron_schedule: "0 0 * * *"
    working_directory: /backup
    environment:
      BACKUP_DIR: /backups
      RETENTION_DAYS: "30"
    retry_config:
      max_retries: 3
      initial_delay_seconds: 300
      max_delay_seconds: 3600
      exponential_backoff: true
    timeout_seconds: 3600
    dependencies:
      - other-job-id
```

### JSON Format

```json
{
  "jobs": [
    {
      "id": "daily-backup",
      "name": "Daily Backup",
      "script_path": "/path/to/backup.sh",
      "cron_schedule": "0 0 * * *",
      "retry_config": {
        "max_retries": 3,
        "initial_delay_seconds": 300
      }
    }
  ]
}
```

## Job Configuration Fields

- **id**: Unique identifier for the job (required)
- **name**: Human-readable name (required)
- **description**: Optional description
- **script_path**: Path to the script to execute (required)
- **working_directory**: Working directory for script execution (optional)
- **environment**: Environment variables to set (optional)
- **cron_schedule**: Cron expression for scheduling (optional, e.g., "0 0 * * *" for daily at midnight)
- **dependencies**: List of job IDs that must complete successfully before this job runs (optional)
- **retry_config**: Retry configuration (optional, see RetryConfig)
- **paused**: Whether the job is paused (default: false)
- **timeout_seconds**: Maximum execution time in seconds (optional)

## Retry Configuration

```rust
RetryConfig {
    max_retries: 3,                    // Maximum retry attempts
    initial_delay_seconds: 60,         // Initial delay before first retry
    max_delay_seconds: 3600,           // Maximum delay (exponential backoff cap)
    exponential_backoff: true,        // Use exponential backoff
}
```

## Structured Logging

All job executions produce structured JSON logs with:

- **timestamp**: ISO 8601 timestamp
- **level**: Log level (INFO, ERROR, etc.)
- **trace_id**: Unique trace ID for the execution
- **job_id**: Job identifier
- **exit_code**: Script exit code
- **stdout**: Standard output
- **stderr**: Standard error

Logs are written to: `{state_dir}/logs/jobs/{date}/{job-id}-{execution-id}.jsonl`

## Metrics

Metrics are collected for each execution and written to JSON files:

- **trace_id**: Execution trace ID
- **job_id**: Job identifier
- **exit_code**: Script exit code
- **success**: Boolean indicating success
- **timestamp**: Execution timestamp

Metrics are written to: `{state_dir}/logs/jobs/{date}/{job-id}-{execution-id}-metrics.json`

## Environment Variables

Scripts receive the following environment variables:

- **TRACE_ID**: Unique trace ID for this execution
- **JOB_ID**: Job identifier
- **JOB_NAME**: Job name
- **LOG_FILE**: Path to log file
- **METRICS_FILE**: Path to metrics file
- Plus any custom environment variables defined in the job configuration

## API Reference

### JobScheduler

- `new(storage_path: Option<PathBuf>) -> Result<Arc<Self>, JobSchedulerError>`: Create a new scheduler
- `add_job(job: ScriptJob) -> Result<(), JobSchedulerError>`: Add a new job
- `list_jobs() -> Vec<ScriptJob>`: List all jobs
- `get_job(job_id: &str) -> Option<ScriptJob>`: Get a specific job
- `remove_job(job_id: &str) -> Result<(), JobSchedulerError>`: Remove a job
- `pause_job(job_id: &str) -> Result<(), JobSchedulerError>`: Pause a job
- `unpause_job(job_id: &str) -> Result<(), JobSchedulerError>`: Unpause a job
- `run_now(job_id: &str) -> Result<String, JobSchedulerError>`: Run a job immediately
- `get_job_history(job_id: &str, limit: Option<usize>) -> Vec<JobExecution>`: Get execution history
- `kill_job(job_id: &str) -> Result<(), JobSchedulerError>`: Kill a running job
- `load_jobs_from_file(config_path: &Path) -> Result<Vec<String>, JobSchedulerError>`: Load jobs from config file

## Error Handling

All methods return `Result<T, JobSchedulerError>`. Common errors:

- `JobIdExists`: Job ID already exists
- `JobNotFound`: Job not found
- `DependencyError`: Dependency check failed
- `ScriptExecutionError`: Script execution failed
- `TimeoutError`: Job execution timed out
- `CronParseError`: Invalid cron expression

## Examples

See `examples/job-config-example.yaml` and `examples/job-config-example.json` for complete configuration examples.

