#![windows_subsystem = "windows"]

use axum::{
    extract::{Query, State, Json},
    routing::{get, post},
    response::IntoResponse,
    Router,
    http::{StatusCode, header, Uri},
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tower_http::cors::{Any, CorsLayer};
use rust_embed::RustEmbed;
use mime_guess::from_path;

use fltk::{
    app, enums::{Color, Font, FrameType, Align},
    frame::Frame, group::{Group, Pack}, prelude::*, window::DoubleWindow,
    text::{TextDisplay, TextBuffer}, image::JpegImage,
};

// Embed the entire www/ folder content into the .exe
#[derive(RustEmbed)]
#[folder = "www/"]
struct Assets;

pub struct AppState {
    instance_data: Arc<Mutex<HashMap<String, Value>>>,
    instance_commands: Arc<Mutex<HashMap<String, Vec<Value>>>>,
    preloaded_settings: Arc<Mutex<HashMap<String, Value>>>,
    logs: Arc<Mutex<Vec<String>>>,
    push_subscriptions: Arc<Mutex<Vec<Value>>>,
}

// VAPID Keys for Web Push
const VAPID_PUBLIC_KEY: &str = "BMxbodmc2vnGuO_eeaTaszRQULgKgU2wl374ZvBpGy3ifhPebtND8u4jdGuRmjg0AIQVl9H9tuXkc6r-QTBRvwI";
const VAPID_PRIVATE_KEY: &str = "E4jFmpDWg4_rl151rtPggyrKjOhqRJK01ofSTsVXvaQ";

impl AppState {
    pub fn log(&self, msg: String) {
        if let Ok(mut logs) = self.logs.lock() {
            let log_entry = format!("[{}] {}", chrono::Local::now().format("%H:%M:%S"), msg);
            logs.push(log_entry);
            if logs.len() > 100 {
                logs.remove(0);
            }
        }
    }
}

// ---------------- AXUM HANDLERS ----------------
async fn get_info() -> Json<Value> {
    Json(json!({
        "version": env!("CARGO_PKG_VERSION")
    }))
}

async fn get_vapid_public_key() -> impl IntoResponse {
    (StatusCode::OK, [(header::CONTENT_TYPE, "text/plain")], VAPID_PUBLIC_KEY)
}

async fn post_subscribe(State(state): State<Arc<AppState>>, Json(payload): Json<Value>) -> Json<Value> {
    let mut subs = state.push_subscriptions.lock().unwrap();
    // Avoid duplicates by endpoint
    let endpoint = payload.get("endpoint").and_then(|v| v.as_str()).unwrap_or("");
    subs.retain(|s| s.get("endpoint").and_then(|v| v.as_str()).unwrap_or("") != endpoint);
    subs.push(payload);
    state.log(format!("📱 Push subscriber registered (total: {})", subs.len()));
    app::awake();
    Json(json!({ "success": true }))
}

async fn post_test_push(State(state): State<Arc<AppState>>) -> Json<Value> {
    use web_push::*;

    let subs = state.push_subscriptions.lock().unwrap().clone();
    if subs.is_empty() {
        return Json(json!({ "success": false, "error": "No subscribers" }));
    }

    let payload_text = json!({
        "title": "🔔 EA Dashboard",
        "body": "ทดสอบแจ้งเตือนสำเร็จ!"
    }).to_string();

    let mut sent = 0;
    for sub in &subs {
        let endpoint = match sub.get("endpoint").and_then(|v| v.as_str()) {
            Some(e) => e,
            None => continue,
        };
        let keys = match sub.get("keys") {
            Some(k) => k,
            None => continue,
        };
        let p256dh = keys.get("p256dh").and_then(|v| v.as_str()).unwrap_or("");
        let auth = keys.get("auth").and_then(|v| v.as_str()).unwrap_or("");

        let subscription_info = SubscriptionInfo::new(endpoint, p256dh, auth);

        let sig_builder = match VapidSignatureBuilder::from_base64(
            VAPID_PRIVATE_KEY,
            web_push::URL_SAFE_NO_PAD,
            &subscription_info,
        ) {
            Ok(b) => b.build(),
            Err(e) => {
                state.log(format!("❌ VAPID build error: {:?}", e));
                continue;
            }
        };

        let sig = match sig_builder {
            Ok(s) => s,
            Err(e) => {
                state.log(format!("❌ VAPID sign error: {:?}", e));
                continue;
            }
        };

        let mut builder = WebPushMessageBuilder::new(&subscription_info);
        builder.set_payload(ContentEncoding::Aes128Gcm, payload_text.as_bytes());
        builder.set_vapid_signature(sig);

        match builder.build() {
            Ok(message) => {
                let client = IsahcWebPushClient::new().unwrap();
                match client.send(message).await {
                    Ok(_) => sent += 1,
                    Err(e) => state.log(format!("❌ Push send error: {:?}", e)),
                }
            }
            Err(e) => state.log(format!("❌ Push build error: {:?}", e)),
        }
    }

    state.log(format!("📤 Test push sent to {}/{} subscribers", sent, subs.len()));
    app::awake();
    Json(json!({ "success": true, "sent": sent }))
}

// Handler for embedded static files
async fn serve_embedded_file(uri: Uri) -> impl IntoResponse {
    let mut path = uri.path().trim_start_matches('/').to_string();
    if path.is_empty() {
        path = "index.html".to_string();
    }

    match Assets::get(&path) {
        Some(content) => {
            let mime = from_path(&path).first_or_octet_stream();
            ([(header::CONTENT_TYPE, mime.as_ref())], content.data).into_response()
        }
        None => {
            if let Some(content) = Assets::get("index.html") {
                 let mime = "text/html; charset=utf-8";
                 ([(header::CONTENT_TYPE, mime)], content.data).into_response()
            } else {
                 (StatusCode::NOT_FOUND, "404 Not Found").into_response()
            }
        }
    }
}

async fn get_accounts(State(state): State<Arc<AppState>>) -> Json<Value> {
    let data = state.instance_data.lock().unwrap();
    let accounts: Vec<Value> = data.iter().map(|(k, v)| {
        let parts: Vec<&str> = k.split(':').collect();
        let acc_id = if !parts.is_empty() { parts[0] } else { "default" };
        let symbol = if parts.len() > 1 { parts[1] } else { "" };
        
        let mut cloned = v.clone();
        if let Some(obj) = cloned.as_object_mut() {
            obj.insert("account_id".to_string(), json!(acc_id));
            if !obj.contains_key("symbol") || obj.get("symbol").and_then(|s| s.as_str()).unwrap_or("") == "" {
                obj.insert("symbol".to_string(), json!(symbol));
            }
            let open_orders = obj.get("open_orders").and_then(|o| o.as_i64()).unwrap_or(0);
            let status = if open_orders > 0 { "Active" } else { "Standby" };
            obj.insert("status".to_string(), json!(status));
        }
        cloned
    }).collect();
    Json(json!(accounts))
}

async fn get_stats(State(state): State<Arc<AppState>>, Query(params): Query<HashMap<String, String>>) -> Json<Value> {
    let data = state.instance_data.lock().unwrap();
    if let (Some(acc_id), Some(symbol)) = (params.get("account_id"), params.get("symbol")) {
        let inst_key = format!("{}:{}", acc_id, symbol);
        if let Some(instance_data) = data.get(&inst_key) {
            return Json(instance_data.clone());
        }
    }
    let mut cloned_map = serde_json::Map::new();
    for (k, v) in data.iter() {
        cloned_map.insert(k.clone(), v.clone());
    }
    Json(Value::Object(cloned_map))
}

async fn post_stats(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<Value>,
) -> Json<Value> {
    let account_id = payload.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
    let symbol = payload.get("symbol").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let inst_key = format!("{}:{}", account_id, symbol);

    let mut data_map = state.instance_data.lock().unwrap();
    let mut current_data = data_map.get(&inst_key).cloned().unwrap_or_else(|| {
        let msg = format!("New MT5 Connected: {} - {}", account_id, symbol);
        state.log(msg);
        json!({
            "symbol": "WAITING...",
            "equity": 0,
            "balance": 0,
            "total_profit": 0,
            "open_orders": 0,
            "_connected": false,
            "ea_settings": null
        })
    });

    let connected = current_data.get("_connected").and_then(|v| v.as_bool()).unwrap_or(false);
    if !connected {
        let preload = state.preloaded_settings.lock().unwrap();
        if let Some(settings) = preload.get(&inst_key) {
            current_data["ea_settings"] = settings.clone();
            current_data["_web_saved_settings"] = settings.clone();
        }
    }
    current_data["_connected"] = json!(true);

    // DEBUG LOG
    println!("DEBUG: Received post_stats ea_settings: {:?}", payload.get("ea_settings"));

    // Preserve web-saved ea_settings — don't let EA heartbeat overwrite them
    let saved_ea_settings = current_data.get("_web_saved_settings").cloned();

    if let (Value::Object(ref mut current_obj), Value::Object(payload_obj)) = (&mut current_data, &payload) {
        for (k, v) in payload_obj {
            current_obj.insert(k.clone(), v.clone());
        }
    }

    // If web-saved settings exist, use those instead of EA's reported settings
    if let Some(web_settings) = saved_ea_settings {
        current_data["ea_settings"] = web_settings;
    }

    data_map.insert(inst_key.clone(), current_data);

    let mut cmds_map = state.instance_commands.lock().unwrap();
    let commands = cmds_map.remove(&inst_key).unwrap_or_default();

    // Wake the FLTK GUI thread so it redraws immediately
    app::awake();

    Json(json!({ "success": true, "commands": commands }))
}

async fn post_close_order(State(state): State<Arc<AppState>>, Json(payload): Json<Value>) -> Json<Value> {
    let account_id = payload.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
    let symbol = payload.get("symbol").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let inst_key = format!("{}:{}", account_id, symbol);
    
    let action_name = payload.get("action").and_then(|v| v.as_str()).unwrap_or("close");
    state.log(format!("Command sent to {}: {}", inst_key, action_name));

    let mut cmds_map = state.instance_commands.lock().unwrap();
    let entry = cmds_map.entry(inst_key).or_default();

    if let Some(action) = payload.get("action").and_then(|v| v.as_str()) {
        entry.push(json!({ "action": action }));
    } else if let Some(ticket) = payload.get("ticket").and_then(|v| v.as_f64()) {
        entry.push(json!({ "action": "close", "ticket": ticket }));
    }
    app::awake();
    Json(json!({ "success": true }))
}

async fn post_open_multiplier(State(state): State<Arc<AppState>>, Json(payload): Json<Value>) -> Json<Value> {
    let account_id = payload.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
    let symbol = payload.get("symbol").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let inst_key = format!("{}:{}", account_id, symbol);
    if let Some(ticket) = payload.get("ticket").and_then(|v| v.as_f64()) {
        state.log(format!("Command sent to {}: open_multiplier on ticket {}", inst_key, ticket));
        state.instance_commands.lock().unwrap().entry(inst_key).or_default()
            .push(json!({ "action": "open_multiplier", "ticket": ticket }));
    }
    app::awake();
    Json(json!({ "success": true }))
}

async fn post_update_settings(State(state): State<Arc<AppState>>, Json(payload): Json<Value>) -> Json<Value> {
    let account_id = payload.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
    let symbol = payload.get("symbol").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let inst_key = format!("{}:{}", account_id, symbol);
    if let Some(settings) = payload.get("settings") {
        state.log(format!("Settings updated for {}", inst_key));
        state.instance_commands.lock().unwrap().entry(inst_key.clone()).or_default()
            .push(json!({ "action": "update_settings", "settings": settings.clone() }));

        // Immediately update in-memory instance_data so the web frontend sees the change
        {
            let mut data_map = state.instance_data.lock().unwrap();
            if let Some(instance) = data_map.get_mut(&inst_key) {
                instance["ea_settings"] = settings.clone();
                instance["_web_saved_settings"] = settings.clone();
            }
        }

        let settings_clone = settings.clone();
        let acc_clone = account_id.clone();
        let sym_clone = symbol.clone();
        tokio::spawn(async move {
            let url = "https://xnwyrleniqxdxomjsopw.supabase.co/rest/v1/ea_settings_master";
            let key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhud3lybGVuaXF4ZHhvbWpzb3B3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMTQ3MzMsImV4cCI6MjA4ODc5MDczM30.tx5gR29FfBLsuYCWUDEJy2QqIfDrtL5xG6ZLtXEYZTA";
            let client = reqwest::Client::new();
            let mut row = settings_clone;
            row["account_id"] = json!(acc_clone);
            row["symbol"] = json!(sym_clone);
            let _ = client.post(url)
                .header("apikey", key)
                .header("Authorization", format!("Bearer {}", key))
                .header("Prefer", "resolution=merge-duplicates")
                .json(&row)
                .send().await;
        });
    }
    app::awake();
    Json(json!({ "success": true }))
}

async fn preload_settings(preloaded_state: Arc<Mutex<HashMap<String, Value>>>, logs: Arc<Mutex<Vec<String>>>) {
    let url = "https://xnwyrleniqxdxomjsopw.supabase.co/rest/v1/ea_settings_master?select=*&limit=1000";
    let key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhud3lybGVuaXF4ZHhvbWpzb3B3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMTQ3MzMsImV4cCI6MjA4ODc5MDczM30.tx5gR29FfBLsuYCWUDEJy2QqIfDrtL5xG6ZLtXEYZTA";
    let client = reqwest::Client::new();
    match client.get(url).header("apikey", key).header("Authorization", format!("Bearer {}", key)).send().await {
        Ok(res) => {
            if let Ok(rows) = res.json::<Vec<Value>>().await {
                if let Ok(mut map) = preloaded_state.lock() {
                    for row in rows {
                        let acc_id = row.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
                        let sym = row.get("symbol").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let key = format!("{}:{}", acc_id, sym);
                        map.insert(key, row);
                    }
                    if let Ok(mut l) = logs.lock() {
                        l.push(format!("[{}] ✅ Supabase: Loaded {} settings", chrono::Local::now().format("%H:%M:%S"), map.len()));
                        app::awake(); // Wake GUI to show new log
                    }
                }
            }
        }
        Err(_) => {
            if let Ok(mut l) = logs.lock() {
                l.push(format!("[{}] ⚠️ Supabase: Connection failed", chrono::Local::now().format("%H:%M:%S")));
                app::awake();
            }
        }
    }
}

// ---------------- FLTK APPLICATION ----------------
const DARK_BG: Color = Color::from_hex(0x1e1e1e);
const PANEL_BG: Color = Color::from_hex(0x2d2d2d);
const TEXT_COLOR: Color = Color::from_hex(0xe0e0e0);
const ACCENT: Color = Color::from_hex(0x00a86b); // Neon Green

#[cfg(target_os = "windows")]
async fn check_for_updates(app_state: Arc<AppState>, ui_sender: fltk::app::Sender<String>) {
    use futures_util::StreamExt;

    let current_version = env!("CARGO_PKG_VERSION");
    let url = "https://api.github.com/repos/somkid2042-star/EA_DASHBOARD_WEB/releases/latest";
    let client = reqwest::Client::new();

    let res = match client.get(url).header("User-Agent", "X-Server-Updater").send().await {
        Ok(r) => r,
        Err(_) => {
            app_state.log("ℹ️ Could not check for updates.".to_string());
            app::awake();
            return;
        }
    };

    let release = match res.json::<serde_json::Value>().await {
        Ok(r) => r,
        Err(_) => return,
    };

    let tag = match release.get("tag_name").and_then(|t| t.as_str()) {
        Some(t) => t,
        None => return,
    };

    let latest_version = tag.strip_prefix("X-Server-v")
        .or_else(|| tag.strip_prefix("v"))
        .unwrap_or(tag);

    if latest_version == current_version {
        app_state.log(format!("✅ Already on latest version v{}", current_version));
        app::awake();
        return;
    }

    app_state.log(format!("🔄 New version v{} found (Current: v{})", latest_version, current_version));
    ui_sender.send(format!("UPDATE_FOUND:{}", latest_version));
    app::awake();

    // Find the .exe asset
    let assets = match release.get("assets").and_then(|a| a.as_array()) {
        Some(a) => a,
        None => {
            app_state.log("❌ No release assets found.".to_string());
            ui_sender.send("UPDATE_FAILED".to_string());
            app::awake();
            return;
        }
    };

    let mut download_url = None;
    let mut total_size: u64 = 0;
    for asset in assets {
        if let Some(name) = asset.get("name").and_then(|n| n.as_str()) {
            if name.ends_with(".exe") && name.contains("X-Server") {
                download_url = asset.get("browser_download_url").and_then(|u| u.as_str());
                total_size = asset.get("size").and_then(|s| s.as_u64()).unwrap_or(0);
                break;
            }
        }
    }

    let download_url = match download_url {
        Some(u) => u,
        None => {
            app_state.log("❌ No .exe asset in release.".to_string());
            ui_sender.send("UPDATE_FAILED".to_string());
            app::awake();
            return;
        }
    };

    // Start streaming download with progress
    let resp = match client.get(download_url).header("User-Agent", "X-Server-Updater").send().await {
        Ok(r) => r,
        Err(_) => {
            app_state.log("❌ Download failed.".to_string());
            ui_sender.send("UPDATE_FAILED".to_string());
            app::awake();
            return;
        }
    };

    // Use content-length from response header, fallback to asset size
    let content_length = resp.content_length().unwrap_or(total_size);
    let mut downloaded: u64 = 0;
    let mut file_bytes: Vec<u8> = Vec::with_capacity(content_length as usize);
    let mut stream = resp.bytes_stream();
    let mut last_pct: u64 = 0;

    while let Some(chunk_result) = stream.next().await {
        match chunk_result {
            Ok(chunk) => {
                downloaded += chunk.len() as u64;
                file_bytes.extend_from_slice(&chunk);

                if content_length > 0 {
                    let pct = (downloaded * 100) / content_length;
                    if pct != last_pct {
                        last_pct = pct;
                        ui_sender.send(format!("UPDATE_PROGRESS:{}", pct));
                        app::awake();
                    }
                }
            }
            Err(_) => {
                app_state.log("❌ Download interrupted.".to_string());
                ui_sender.send("UPDATE_FAILED".to_string());
                app::awake();
                return;
            }
        }
    }

    let size_mb = downloaded as f64 / 1_048_576.0;
    app_state.log(format!("📦 Downloaded {:.1} MB", size_mb));

    // Write new exe
    let exe_path = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("X-Server.exe"));
    let exe_name = exe_path.file_name().unwrap().to_str().unwrap().to_string();
    let exe_dir = exe_path.parent().unwrap_or(std::path::Path::new("."));
    let update_exe = exe_dir.join("X-Server_update.exe");

    if std::fs::write(&update_exe, &file_bytes).is_err() {
        app_state.log("❌ Failed to write update file.".to_string());
        ui_sender.send("UPDATE_FAILED".to_string());
        app::awake();
        return;
    }

    // Create batch file for self-replacement (no indentation whitespace!)
    let my_pid = std::process::id();
    let bat_content = format!(
"@echo off\r\ntaskkill /F /PID {} >NUL 2>&1\r\ntimeout /t 2 /nobreak >NUL\r\ndel \"{}\"\r\nmove /Y \"{}\" \"{}\"\r\nstart \"\" \"{}\"\r\ndel \"%~f0\"",
        my_pid,
        exe_path.display(),
        update_exe.display(),
        exe_path.display(),
        exe_path.display()
    );
    let bat_path = exe_dir.join("update.bat");
    let _ = std::fs::write(&bat_path, bat_content);

    app_state.log("✅ Update ready! Shutting down server...".to_string());
    ui_sender.send("UPDATE_READY".to_string());
    app::awake();

    // Wait a moment for UI to update, then signal main thread to do graceful shutdown
    std::thread::sleep(std::time::Duration::from_millis(500));
    ui_sender.send(format!("UPDATE_SHUTDOWN:{}", bat_path.to_str().unwrap()));
    app::awake();
}

#[cfg(not(target_os = "windows"))]
async fn check_for_updates(app_state: Arc<AppState>, _ui_sender: fltk::app::Sender<String>) {
    app_state.log("ℹ️ Auto-update skipped (Not on Windows).".to_string());
    app::awake();
}

fn main() {
    // Setup panic hook to log crashes to text file for debugging
    std::panic::set_hook(Box::new(|info| {
        let msg = format!("CRITICAL PANIC OCCURRED:\n{:?}", info);
        let _ = std::fs::write("SERVER_CRASH_LOG.txt", &msg);
        eprintln!("{}", msg);
    }));

    let app = app::App::default().with_scheme(app::Scheme::Gtk);
    let (msg_sender, msg_receiver) = fltk::app::channel::<String>();

    let app_state = Arc::new(AppState {
        instance_data: Arc::new(Mutex::new(HashMap::new())),
        instance_commands: Arc::new(Mutex::new(HashMap::new())),
        preloaded_settings: Arc::new(Mutex::new(HashMap::new())),
        logs: Arc::new(Mutex::new(vec![])),
        push_subscriptions: Arc::new(Mutex::new(vec![])),
    });

    let port = 3000u16;

    app_state.log("Starting Web Server...".to_string());

    let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
    let server_state = app_state.clone();
    
    let app_state_tokio = app_state.clone();
    let msg_sender_tokio = msg_sender.clone();
    
    // Kill any old x-server processes and free port 3000
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        let my_pid = std::process::id();

        // Step 1: Kill any other x-server.exe processes (excluding ourself)
        if let Ok(output) = std::process::Command::new("tasklist")
            .args(&["/FI", "IMAGENAME eq x-server.exe", "/NH", "/FO", "CSV"])
            .creation_flags(0x08000000).output()
        {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for line in stdout.lines() {
                // CSV format: "x-server.exe","1234","Console","1","12,345 K"
                let fields: Vec<&str> = line.split(',').collect();
                if fields.len() >= 2 {
                    let pid_str = fields[1].trim().trim_matches('"');
                    if let Ok(pid) = pid_str.parse::<u32>() {
                        if pid != my_pid {
                            app_state.log(format!("Killing old process PID {}", pid));
                            let _ = std::process::Command::new("taskkill")
                                .args(&["/F", "/PID", &pid.to_string()])
                                .creation_flags(0x08000000)
                                .output();
                        }
                    }
                }
            }
        }

        // Step 2: Kill anything listening on port 3000
        for _attempt in 0..3 {
            let mut found = false;
            if let Ok(output) = std::process::Command::new("netstat")
                .args(&["-ano", "-p", "TCP"])
                .creation_flags(0x08000000).output()
            {
                let stdout = String::from_utf8_lossy(&output.stdout);
                for line in stdout.lines() {
                    // Match exact :3000 (followed by space) to avoid matching :30000
                    if (line.contains(":3000 ") || line.ends_with(":3000")) && line.contains("LISTENING") {
                        let parts: Vec<&str> = line.split_whitespace().collect();
                        if let Some(pid_str) = parts.last() {
                            if let Ok(pid) = pid_str.parse::<u32>() {
                                if pid != my_pid && pid != 0 {
                                    app_state.log(format!("Killing port 3000 holder PID {}", pid));
                                    let _ = std::process::Command::new("taskkill")
                                        .args(&["/F", "/PID", &pid.to_string()])
                                        .creation_flags(0x08000000)
                                        .output();
                                    found = true;
                                }
                            }
                        }
                    }
                }
            }
            if !found { break; }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }

        std::thread::sleep(std::time::Duration::from_millis(1000)); // wait for OS to release port
    }

    let port_status = match std::net::TcpListener::bind(format!("0.0.0.0:{}", port)) {
        Ok(std_listener) => {
            drop(std_listener); // Let tokio bind
            
            rt.spawn(async move {
                let preload_state = server_state.preloaded_settings.clone();
                let logs_state = server_state.logs.clone();
                let app_update = app_state_tokio.clone();
                let sender_update = msg_sender_tokio.clone();
                tokio::spawn(async move { check_for_updates(app_update, sender_update).await; });
                tokio::spawn(async move { preload_settings(preload_state, logs_state).await; });

                let cors = CorsLayer::new().allow_origin(Any).allow_methods(Any).allow_headers(Any);
                let router = Router::new()
                    .route("/api/info", get(get_info))
                    .route("/api/accounts", get(get_accounts))
                    .route("/api/ea-stats", get(get_stats).post(post_stats))
                    .route("/api/close-order", post(post_close_order))
                    .route("/api/open-multiplier", post(post_open_multiplier))
                    .route("/api/update-settings", post(post_update_settings))
                    .route("/api/vapid-public-key", get(get_vapid_public_key))
                    .route("/api/subscribe", post(post_subscribe))
                    .route("/api/test-push", post(post_test_push))
                    .fallback(serve_embedded_file)
                    .layer(cors)
                    .with_state(server_state);

                let addr = format!("0.0.0.0:{}", port);
                let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
                app_state_tokio.log(format!("Server listening on port {}", port));
                // Important to call this to wake UI
                app::awake();
                
                axum::serve(listener, router).await.unwrap();
            });
            "OK".to_string()
        },
        Err(_) => {
            let err_msg = format!("Port {} is IN USE by another program!", port);
            app_state.log(err_msg.clone());
            err_msg
        }
    };

    // ---------------- UI Setup ----------------
    let mut win = DoubleWindow::default().with_size(650, 550).center_screen().with_label(&format!("X-Server {}", env!("CARGO_PKG_VERSION")));
    win.set_color(DARK_BG);
    
    // Load Icon
    let icon_data = include_bytes!("icon.jpg");
    if let Ok(img) = JpegImage::from_data(icon_data) {
        win.set_icon(Some(img));
    }

    let mut pack = Pack::default().with_size(610, 500).with_pos(20, 15);
    pack.set_spacing(15);

    // MT5 Connections Area
    let mut mt5_title = Frame::default().with_size(610, 25).with_label("📊 Connected MT5 Instances");
    mt5_title.set_label_font(Font::HelveticaBold);
    mt5_title.set_label_size(16);
    mt5_title.set_label_color(TEXT_COLOR);
    mt5_title.set_align(Align::Left | Align::Inside);

    // We use TextDisplay to show lists
    let mut mt5_buf = TextBuffer::default();
    let mut mt5_list = TextDisplay::default().with_size(610, 150);
    mt5_list.set_buffer(mt5_buf.clone());
    mt5_list.set_color(DARK_BG);
    mt5_list.set_text_color(TEXT_COLOR);
    mt5_list.set_text_size(14);
    mt5_list.set_text_font(Font::Courier); // tabular spacing

    // Logs Area
    let mut log_title = Frame::default().with_size(610, 25).with_label("📝 Activity Logs");
    log_title.set_label_font(Font::HelveticaBold);
    log_title.set_label_size(16);
    log_title.set_label_color(TEXT_COLOR);
    log_title.set_align(Align::Left | Align::Inside);

    let mut log_buf = TextBuffer::default();
    let mut log_view = TextDisplay::default().with_size(610, 150);
    log_view.set_buffer(log_buf.clone());
    log_view.set_color(Color::from_hex(0x111111));
    log_view.set_text_color(Color::from_hex(0xaaaaaa));
    log_view.set_text_size(12);
    log_view.set_text_font(Font::Courier);

    pack.end();
    
    // Bottom Status Bar
    let mut status_bar = Frame::default().with_size(650, 25).with_pos(0, 525);
    status_bar.set_color(Color::from_hex(0x1a1a1a));
    status_bar.set_frame(FrameType::FlatBox);
    status_bar.set_label_size(12);
    status_bar.set_label_color(Color::from_hex(0x888888));
    status_bar.set_align(Align::Center | Align::Inside);
    
    if port_status == "OK" {
        status_bar.set_label(&format!("Server Running | Port: {} | Listening for MT5 Connections", port));
    } else {
        status_bar.set_label(&format!("Error: {}", port_status));
        status_bar.set_label_color(Color::Red);
    }

    win.end();
    win.show();

    // ---------------- Event Loop ----------------
    let mut log_line_count = 0;
    
    // The loop keeps running, and `app::awake()` from Tokio will trigger an interaction
    while app.wait() {
        if let Some(msg) = msg_receiver.recv() {
            match msg.as_str() {

                msg if msg.starts_with("UPDATE_FOUND:") => {
                    let ver = msg.strip_prefix("UPDATE_FOUND:").unwrap();
                    status_bar.set_label(&format!("🔄 กำลังดาวน์โหลด v{}...", ver));
                    status_bar.set_label_color(ACCENT);
                    win.set_label(&format!("X-Server {} → v{}", env!("CARGO_PKG_VERSION"), ver));
                }
                msg if msg.starts_with("UPDATE_PROGRESS:") => {
                    if let Ok(pct) = msg.strip_prefix("UPDATE_PROGRESS:").unwrap().parse::<f64>() {
                        let pct_int = pct as u32;
                        status_bar.set_label(&format!("⬇️ ดาวน์โหลด {}%", pct_int));
                        if pct >= 100.0 {
                            status_bar.set_label("📦 ดาวน์โหลดเสร็จ! กำลังติดตั้ง...");
                        }
                    }
                }
                "UPDATE_STARTING" => {
                    status_bar.set_label("🔄 กำลังตรวจสอบเวอร์ชั่น...");
                    status_bar.set_label_color(Color::Yellow);
                }
                "UPDATE_READY" => {
                    status_bar.set_label("✅ อัพเดทเสร็จ! กำลังปิดเซิร์ฟเวอร์...");
                    status_bar.set_label_color(Color::from_hex(0x34C759));
                    win.set_label(&format!("X-Server {} (Restarting...)", env!("CARGO_PKG_VERSION")));
                }
                msg if msg.starts_with("UPDATE_SHUTDOWN:") => {
                    let bat = msg.strip_prefix("UPDATE_SHUTDOWN:").unwrap().to_string();
                    // Drop tokio runtime to release port 3000
                    drop(rt);
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    // Spawn the update batch file
                    #[cfg(target_os = "windows")]
                    {
                        use std::os::windows::process::CommandExt;
                        let _ = std::process::Command::new("cmd")
                            .args(&["/C", &bat])
                            .creation_flags(0x08000000)
                            .spawn();
                    }
                    std::process::exit(0);
                }
                "UPDATE_FAILED" => {
                    status_bar.set_label("❌ อัพเดทล้มเหลว");
                    status_bar.set_label_color(Color::Red);
                    win.set_label(&format!("X-Server {} (Update Failed)", env!("CARGO_PKG_VERSION")));
                }
                _ => {}
            }
        }
        
        // UI Updates requested by async threads
        
        // 1. Update Logs
        if let Ok(logs) = app_state.logs.lock() {
            if logs.len() != log_line_count {
                log_buf.set_text(&logs.join("\n"));
                log_view.scroll(log_view.count_lines(0, log_buf.length(), true), 0);
                log_line_count = logs.len();
            }
        }

        // 2. Update MT5 List
        if let Ok(data) = app_state.instance_data.lock() {
            let mut list_text = format!("{:<15} | {:<10} | {:<12} | {:<10} | {:<6}\n", "Account", "Symbol", "Equity", "Profit", "Orders");
            list_text.push_str("----------------------------------------------------------------------\n");
            
            for (key, val) in data.iter() {
                let parts: Vec<&str> = key.split(':').collect();
                let acc = parts.get(0).unwrap_or(&"");
                let sym = parts.get(1).unwrap_or(&"");
                
                let equity = val.get("equity").and_then(|v| v.as_f64()).unwrap_or(0.0);
                let profit = val.get("total_profit").and_then(|v| v.as_f64()).unwrap_or(0.0);
                let orders = val.get("open_orders").and_then(|v| v.as_i64()).unwrap_or(0);

                let line = format!("{:<15} | {:<10} | ${:<11.2} | ${:<9.2} | {:<6}\n", acc, sym, equity, profit, orders);
                list_text.push_str(&line);
            }
            if data.is_empty() {
                list_text.push_str("      (No MT5 EAs Connected)\n");
            }
            mt5_buf.set_text(&list_text);
        }
        
    }
}
