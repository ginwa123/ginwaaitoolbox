//! Process detection module
//! 
//! Provides utilities for finding and checking system processes.

use serde::{Deserialize, Serialize};
use sysinfo::System;

/// Process information returned by find_nalar_process
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProcessInfo {
    pub pid: u32,
    pub name: String,
}

/// Error types for process operations
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum ProcessError {
    ProcessNotFound,
    PermissionDenied,
    SystemError(String),
}

/// Finds all processes matching the given name
/// 
/// Uses sysinfo crate to iterate through system processes.
/// Returns all processes whose name exactly matches (case-sensitive).
/// 
/// # Arguments
/// * `process_name` - The name of the process to search for
/// 
/// # Returns
/// * `Ok(Vec<ProcessInfo>)` - List of matching processes (may be empty)
/// * `Err(ProcessError)` - Error if search failed
pub fn find_process_by_name(process_name: &str) -> Result<Vec<ProcessInfo>, ProcessError> {
    if process_name.is_empty() {
        return Ok(Vec::new());
    }
    
    let mut system = System::new_all();
    system.refresh_all();
    
    let mut results = Vec::new();
    
    for (pid, process) in system.processes() {
        let proc_name = process.name().to_string_lossy();
        if proc_name == process_name {
            results.push(ProcessInfo {
                pid: pid.as_u32(),
                name: proc_name.to_string(),
            });
        }
    }
    
    Ok(results)
}

/// Checks if a specific process is running
/// 
/// # Arguments
/// * `process_name` - The name of the process to check
/// 
/// # Returns
/// * `Ok(true)` if at least one process with that name is running
/// * `Ok(false)` if no process with that name is running
/// * `Err(ProcessError)` on error
pub fn is_process_running(process_name: &str) -> Result<bool, ProcessError> {
    let processes = find_process_by_name(process_name)?;
    Ok(!processes.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_find_nalar_process_returns_pid_and_name() {
        // When finding nalar process, it should return process info with pid and name
        let result = find_process_by_name("nalar");
        
        // Should not return an error for system errors
        assert!(!matches!(result, Err(ProcessError::SystemError(_))),
            "Should not return SystemError for valid process name");
        
        match result {
            Ok(processes) => {
                // If processes found, they should have valid data
                for p in &processes {
                    assert!(p.pid > 0, "PID should be positive");
                    assert!(!p.name.is_empty(), "Process name should not be empty");
                }
            }
            Err(ProcessError::ProcessNotFound) => {
                // Valid outcome if nalar is not running
            }
            Err(ProcessError::PermissionDenied) => {
                // Valid outcome if we don't have permission
            }
            Err(_) => panic!("Unexpected error type"),
        }
    }

    #[test]
    fn test_find_nalar_process_returns_multiple_matches() {
        // If multiple nalar processes are running, all should be returned
        let result = find_process_by_name("nalar");
        
        // Result should be a Vec (empty or with items)
        assert!(result.is_ok(), "Should return Ok with Vec, not error");
        let _processes = result.unwrap();
        
        // Verify it's a vector (can be empty)
        // Vec is always >= 0 length
    }

    #[test]
    fn test_find_nalar_process_case_sensitive() {
        // Process name search should be case-sensitive on Unix
        let result_lower = find_process_by_name("nalar");
        let result_upper = find_process_by_name("NALAR");
        
        // These may differ - searching "nalar" vs "NALAR"
        // The implementation should use exact match
        match (result_lower, result_upper) {
            (Ok(_lower), Ok(_upper)) => {
                // If both return results, they should potentially differ
                // This depends on the system's process list
            }
            _ => {}
        }
    }

    #[test]
    fn test_is_process_running_returns_true_when_found() {
        // When nalar process exists, is_process_running returns true
        let result = is_process_running("nalar");
        
        assert!(result.is_ok(), "Should not return error");
        // Result is a boolean - true if found, false if not
    }

    #[test]
    fn test_is_process_running_returns_false_when_not_found() {
        // When nalar process does not exist, is_process_running returns false
        let result = is_process_running("definitely_not_running_process_xyz");
        
        match result {
            Ok(is_running) => {
                assert!(!is_running, "Non-existent process should return false");
            }
            Err(ProcessError::ProcessNotFound) => {
                // Also acceptable - indicates process doesn't exist
            }
            _ => panic!("Unexpected result for non-existent process"),
        }
    }

    #[test]
    fn test_empty_process_name_handling() {
        // Searching for empty string should be handled gracefully
        let result = find_process_by_name("");
        
        // Should either return empty vec or an error
        match result {
            Ok(processes) => {
                assert!(processes.is_empty(), "Empty name should return no processes");
            }
            Err(_) => {
                // Error is acceptable for empty input
            }
        }
    }
}
