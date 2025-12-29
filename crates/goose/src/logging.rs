use crate::config::paths::Paths;
use anyhow::{Context, Result};
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

/// Returns the directory where log files should be stored for a specific component.
/// Creates the directory structure if it doesn't exist.
///
/// # Arguments
///
/// * `component` - The component name (e.g., "cli", "server", "debug", "llm")
/// * `use_date_subdir` - Whether to create a date-based subdirectory
pub fn prepare_log_directory(component: &str, use_date_subdir: bool) -> Result<PathBuf> {
    let base_log_dir = Paths::in_state_dir("logs");

    let _ = cleanup_old_logs(component);

    let component_dir = base_log_dir.join(component);

    let log_dir = if use_date_subdir {
        component_dir.join(chrono::Local::now().format("%Y-%m-%d").to_string())
    } else {
        component_dir
    };

    fs::create_dir_all(&log_dir)
        .with_context(|| format!("Failed to create log directory: {:?}", log_dir))?;

    Ok(log_dir)
}

/// Cleanup old logs based on retention policy.
/// 
/// This function removes old log files and directories based on configurable retention periods.
/// Retention periods can be set via environment variables:
/// - `GOOSE_LOG_DETAILED_RETENTION_DAYS` (default: 7) - Keep detailed logs for this many days
/// - `GOOSE_LOG_SUMMARY_RETENTION_DAYS` (default: 30) - Keep summary logs for this many days
/// 
/// # Arguments
/// 
/// * `component` - The component name (e.g., "cli", "server", "debug", "llm")
pub fn cleanup_old_logs(component: &str) -> Result<()> {
    let base_log_dir = Paths::in_state_dir("logs");
    let component_dir = base_log_dir.join(component);

    if !component_dir.exists() {
        return Ok(());
    }

    // Get retention periods from environment or use defaults
    let detailed_retention_days = std::env::var("GOOSE_LOG_DETAILED_RETENTION_DAYS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(7);
    let summary_retention_days = std::env::var("GOOSE_LOG_SUMMARY_RETENTION_DAYS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(30);

    let detailed_retention = SystemTime::now() - Duration::from_secs(detailed_retention_days * 24 * 60 * 60);
    let summary_retention = SystemTime::now() - Duration::from_secs(summary_retention_days * 24 * 60 * 60);

    let entries = fs::read_dir(&component_dir)?;

    for entry in entries.flatten() {
        let path = entry.path();

        if let Ok(metadata) = entry.metadata() {
            if let Ok(modified) = metadata.modified() {
                if path.is_dir() {
                    // Remove date-based subdirectories older than summary retention
                    if modified < summary_retention {
                        let _ = fs::remove_dir_all(&path);
                    }
                } else if path.is_file() {
                    // Remove log files older than summary retention
                    // Keep files between detailed and summary retention for potential archival
                    if modified < summary_retention {
                        // Check if this might be a critical log (contains error/fatal)
                        let should_archive = modified >= detailed_retention
                            && (path.extension().and_then(|s| s.to_str()) == Some("log")
                                || path.extension().and_then(|s| s.to_str()) == Some("jsonl"));

                        if should_archive {
                            // Try to check if log contains errors (simple heuristic)
                            if let Ok(content) = fs::read_to_string(&path) {
                                let has_error = content.contains("ERROR") || content.contains("FATAL") || content.contains("error");
                                if has_error {
                                    // Archive critical logs to archive subdirectory
                                    let archive_dir = component_dir.join("archive");
                                    let _ = fs::create_dir_all(&archive_dir);
                                    if let Some(filename) = path.file_name() {
                                        let archive_path = archive_dir.join(filename);
                                        let _ = fs::copy(&path, &archive_path);
                                    }
                                }
                            }
                        }
                        
                        // Remove the old file
                        let _ = fs::remove_file(&path);
                    }
                }
            }
        }
    }

    // Clean up empty date subdirectories
    let entries = fs::read_dir(&component_dir)?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.file_name().and_then(|s| s.to_str()).map(|s| s.len() == 10 && s.chars().all(|c| c.is_ascii_digit() || c == '-')).unwrap_or(false) {
            // This looks like a date directory (YYYY-MM-DD format)
            if fs::read_dir(&path)?.next().is_none() {
                let _ = fs::remove_dir(&path);
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_get_log_directory_basic_functionality() {
        // Test basic directory creation without date subdirectory
        let result = prepare_log_directory("cli", false);
        assert!(result.is_ok());

        let log_dir = result.unwrap();

        // Verify the directory was created and has correct structure
        assert!(log_dir.exists());
        assert!(log_dir.is_dir());

        let path_str = log_dir.to_string_lossy();
        assert!(path_str.contains("cli"));
        assert!(path_str.contains("logs"));

        // Verify we can write to the directory
        let test_file = log_dir.join("test.log");
        assert!(fs::write(&test_file, "test log content").is_ok());
        let _ = fs::remove_file(&test_file);
    }

    #[test]
    fn test_get_log_directory_with_date_subdir() {
        // Test date-based subdirectory creation
        let result = prepare_log_directory("server", true);
        assert!(result.is_ok());

        let log_dir = result.unwrap();

        // Verify the directory was created
        assert!(log_dir.exists());
        assert!(log_dir.is_dir());

        let path_str = log_dir.to_string_lossy();
        assert!(path_str.contains("server"));
        assert!(path_str.contains("logs"));

        // Verify date format (YYYY-MM-DD) is present
        let now = chrono::Local::now();
        let date_str = now.format("%Y-%m-%d").to_string();
        assert!(path_str.contains(&date_str));

        // Verify path structure: logs -> component -> date
        let logs_pos = path_str.find("logs").unwrap();
        let component_pos = path_str.find("server").unwrap();
        let date_pos = path_str.find(&date_str).unwrap();
        assert!(logs_pos < component_pos);
        assert!(component_pos < date_pos);
    }

    #[test]
    fn test_get_log_directory_idempotent() {
        // Test that multiple calls return the same result and don't fail
        let component = "debug";

        let result1 = prepare_log_directory(component, false);
        assert!(result1.is_ok());
        let log_dir1 = result1.unwrap();

        let result2 = prepare_log_directory(component, false);
        assert!(result2.is_ok());
        let log_dir2 = result2.unwrap();

        // Both calls should return the same path and directory should exist
        assert_eq!(log_dir1, log_dir2);
        assert!(log_dir1.exists());
        assert!(log_dir2.exists());

        // Test same behavior with date subdirectories
        let result3 = prepare_log_directory(component, true);
        assert!(result3.is_ok());
        let log_dir3 = result3.unwrap();

        let result4 = prepare_log_directory(component, true);
        assert!(result4.is_ok());
        let log_dir4 = result4.unwrap();

        assert_eq!(log_dir3, log_dir4);
        assert!(log_dir3.exists());
    }

    #[test]
    fn test_get_log_directory_different_components() {
        // Test that different components create different directories
        let components = ["cli", "server", "debug"];
        let mut created_dirs = Vec::new();

        for component in &components {
            let result = prepare_log_directory(component, false);
            assert!(result.is_ok(), "Failed for component: {}", component);

            let log_dir = result.unwrap();
            assert!(log_dir.exists());
            assert!(log_dir.to_string_lossy().contains(component));

            created_dirs.push(log_dir);
        }

        // Verify all directories are different
        for i in 0..created_dirs.len() {
            for j in i + 1..created_dirs.len() {
                assert_ne!(created_dirs[i], created_dirs[j]);
            }
        }
    }
}
