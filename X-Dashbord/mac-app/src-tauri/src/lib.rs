use tauri::Manager;

#[tauri::command]
fn get_version() -> String {
    "1.4.0".to_string()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![get_version])
        .setup(|app| {
            // Set up the main window
            let window = app.get_webview_window("main").unwrap();
            window.set_title("X-Dashboard — EA Monitor").unwrap();
            
            #[cfg(debug_assertions)]
            {
                window.open_devtools();
            }
            
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
