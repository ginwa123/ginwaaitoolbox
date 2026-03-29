// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use desktop::process::{find_process_by_name, is_process_running, ProcessInfo, ProcessError};

fn main() {
    println!("Running Tauri application...");
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_http::init())
        .invoke_handler(tauri::generate_handler![
            find_nalar_process,
            check_nalar_running
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// Tauri command to find nalar process
/// 
/// Searches for processes matching "nalar" in the system
/// and returns their process information.
#[tauri::command]
fn find_nalar_process() -> Result<Vec<ProcessInfo>, String> {
    find_process_by_name("nalar").map_err(|e| match e {
        ProcessError::SystemError(msg) => msg,
        ProcessError::ProcessNotFound => "Process not found".to_string(),
        ProcessError::PermissionDenied => "Permission denied".to_string(),
    })
}

/// Tauri command to check if nalar is running
/// 
/// Returns true if any nalar process is found running.
#[tauri::command]
fn check_nalar_running() -> Result<bool, String> {
    is_process_running("nalar").map_err(|e| match e {
        ProcessError::SystemError(msg) => msg,
        ProcessError::ProcessNotFound => "Process not found".to_string(),
        ProcessError::PermissionDenied => "Permission denied".to_string(),
    })
}
