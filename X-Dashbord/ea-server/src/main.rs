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
    app, button::Button, enums::{Color, Font, FrameType, Align},
    frame::Frame, group::{Group, Pack}, prelude::*, window::DoubleWindow,
    text::{TextDisplay, TextBuffer}, image::JpegImage,
};
use std::process::Command;

// Embed the entire www/ folder content into the .exe
#[derive(RustEmbed)]
#[folder = "www/"]
struct Assets;

pub struct AppState {
    instance_data: Arc<Mutex<HashMap<String, Value>>>,
    instance_commands: Arc<Mutex<HashMap<String, Vec<Value>>>>,
    preloaded_settings: Arc<Mutex<HashMap<String, Value>>>,
    logs: Arc<Mutex<Vec<String>>>,
    pub cloudflare_url: Arc<Mutex<Option<String>>>,
}

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
async fn get_info(State(state): State<Arc<AppState>>) -> Json<Value> {
    let url = state.cloudflare_url.lock().unwrap().clone();
    Json(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "cloudflare_url": url
    }))
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
        if let Some(settings) = preload.get(&account_id) {
            current_data["ea_settings"] = settings.clone();
        }
    }
    current_data["_connected"] = json!(true);

    // DEBUG LOG
    println!("DEBUG: Received post_stats ea_settings: {:?}", payload.get("ea_settings"));

    if let (Value::Object(ref mut current_obj), Value::Object(payload_obj)) = (&mut current_data, &payload) {
        for (k, v) in payload_obj {
            current_obj.insert(k.clone(), v.clone());
        }
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
        state.instance_commands.lock().unwrap().entry(inst_key).or_default()
            .push(json!({ "action": "update_settings", "settings": settings.clone() }));

        let settings_clone = settings.clone();
        let acc_clone = account_id.clone();
        tokio::spawn(async move {
            let url = "https://xnwyrleniqxdxomjsopw.supabase.co/rest/v1/ea_settings_master";
            let key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhud3lybGVuaXF4ZHhvbWpzb3B3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMTQ3MzMsImV4cCI6MjA4ODc5MDczM30.tx5gR29FfBLsuYCWUDEJy2QqIfDrtL5xG6ZLtXEYZTA";
            let client = reqwest::Client::new();
            let mut row = settings_clone;
            row["account_id"] = json!(acc_clone);
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
                        map.insert(acc_id, row);
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
    let current_version = env!("CARGO_PKG_VERSION");
    let url = "https://api.github.com/repos/somkid2042-star/EA_DASHBOARD_WEB/releases/latest";
    let client = reqwest::Client::new();
    
    if let Ok(res) = client.get(url).header("User-Agent", "X-Server-Updater").send().await {
        if let Ok(release) = res.json::<serde_json::Value>().await {
            if let Some(tag) = release.get("tag_name").and_then(|t| t.as_str()) {
                let latest_version = tag.strip_prefix("X-Server-v").or_else(|| tag.strip_prefix("v")).unwrap_or(tag);
                if latest_version != current_version {
                    app_state.log(format!("🔄 New version {} found (Current: {}). Downloading...", latest_version, current_version));
                    ui_sender.send("UPDATE_STARTING".to_string());
                    app::awake();

                    if let Some(assets) = release.get("assets").and_then(|a| a.as_array()) {
                        let mut download_url = None;
                        for asset in assets {
                            if let Some(name) = asset.get("name").and_then(|n| n.as_str()) {
                                if name.ends_with(".exe") && name.contains("X-Server") {
                                    download_url = asset.get("browser_download_url").and_then(|u| u.as_str());
                                    break;
                                }
                            }
                        }

                        if let Some(url) = download_url {
                            if let Ok(resp) = client.get(url).header("User-Agent", "X-Server-Updater").send().await {
                                if let Ok(bytes) = resp.bytes().await {
                                    let exe_path = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("X-Server.exe"));
                                    let exe_name = exe_path.file_name().unwrap().to_str().unwrap();
                                    
                                    let exe_dir = exe_path.parent().unwrap_or(std::path::Path::new("."));
                                    let update_exe = exe_dir.join(format!("{}_update.exe", exe_name));
                                    
                                    let _ = std::fs::write(&update_exe, &bytes);

                                    let my_pid = std::process::id();
                                    let bat_content = format!(
                                        "@echo off\n\
                                        taskkill /F /PID {} > NUL 2>&1\n\
                                        timeout /t 1 /nobreak > NUL\n\
                                        del \"{}\"\n\
                                        rename \"{}\" \"{}\"\n\
                                        start \"\" \"{}\"\n\
                                        del \"%~f0\"",
                                        my_pid, exe_path.display(), update_exe.display(), exe_name, exe_path.display()
                                    );
                                    let bat_path = exe_dir.join("update.bat");
                                    let _ = std::fs::write(&bat_path, bat_content);

                                    app_state.log("✅ Update ready! Restarting automatically...".to_string());
                                    ui_sender.send("UPDATE_READY".to_string());
                                    app::awake();
                                    
                                    std::thread::sleep(std::time::Duration::from_millis(500));
                                    let _ = std::process::Command::new("cmd")
                                        .arg("/C")
                                        .arg(exe_dir.join("update.bat").to_str().unwrap())
                                        .spawn();
                                        
                                    std::process::exit(0);
                                }
                            }
                        }
                    }
                    app_state.log("❌ Update failed: Could not download the asset.".to_string());
                    ui_sender.send("UPDATE_FAILED".to_string());
                    app::awake();
                }
            }
        }
    }
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
        cloudflare_url: Arc::new(Mutex::new(None)),
    });

    let port = 3000u16;

    app_state.log("Starting Web Server...".to_string());

    let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
    let server_state = app_state.clone();
    
    let app_state_tokio = app_state.clone();
    let msg_sender_tokio = msg_sender.clone();
    
    // Check if port is available before starting Axum
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        if let Ok(output) = std::process::Command::new("netstat").args(&["-ano"]).creation_flags(0x08000000).output() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for line in stdout.lines() {
                if line.contains(":3000") && line.contains("LISTENING") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 5 {
                        let pid = parts[4];
                        let _ = std::process::Command::new("taskkill")
                            .args(&["/F", "/PID", pid])
                            .creation_flags(0x08000000)
                            .output();
                    }
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(800)); // wait for OS to free the port
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


    // Cloudflare Tunnel Panel
    let mut cf_group = Group::default().with_size(610, 90);
    cf_group.set_frame(FrameType::FlatBox);
    cf_group.set_color(PANEL_BG);

    let mut cf_label = Frame::default().with_size(150, 25).with_pos(cf_group.x() + 15, cf_group.y() + 15).with_label("Cloudflare Tunnel:");
    cf_label.set_label_font(Font::HelveticaBold);
    cf_label.set_label_size(14);
    cf_label.set_label_color(TEXT_COLOR);
    cf_label.set_align(Align::Left | Align::Inside);

    let mut cf_status = Frame::default().with_size(140, 25).with_pos(cf_group.x() + 165, cf_group.y() + 15).with_label("Auto-starting...");
    cf_status.set_label_size(14);
    cf_status.set_label_color(Color::Yellow);
    cf_status.set_align(Align::Left | Align::Inside);
    
    let mut cf_btn_copy = Button::default().with_size(80, 25).with_pos(cf_group.x() + 505, cf_group.y() + 50).with_label("Copy URL");

    let mut cf_url_lbl = Frame::default().with_size(80, 25).with_pos(cf_group.x() + 15, cf_group.y() + 50).with_label("Public URL:");
    cf_url_lbl.set_label_size(14);
    cf_url_lbl.set_label_color(TEXT_COLOR);
    cf_url_lbl.set_align(Align::Left | Align::Inside);

    let mut cf_url_input = fltk::input::Input::default().with_size(400, 25).with_pos(cf_group.x() + 100, cf_group.y() + 50);
    cf_url_input.set_color(Color::from_hex(0x1a1a1a));
    cf_url_input.set_text_color(ACCENT);
    cf_url_input.set_value("Loading...");
    cf_url_input.set_readonly(true);
    
    let mut cf_url_input_copy = cf_url_input.clone();
    cf_btn_copy.set_callback(move |_| {
        let url = cf_url_input_copy.value();
        if url.contains("trycloudflare.com") {
            fltk::app::copy(&url);
        }
    });

    let s3 = msg_sender.clone();
    let cf_port = port;
    let st_app = app_state.clone();
    
    // Auto-start Tunnel immediately
    std::thread::spawn(move || {
        let is_installed = if cfg!(target_os = "windows") {
            Command::new("cloudflared.exe").arg("--version").output().is_ok() || Command::new("cloudflared").arg("--version").output().is_ok()
        } else {
            Command::new("cloudflared").arg("--version").output().is_ok()
        };
        
        if is_installed {
            let exe_path = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("X-Server.exe"));
            let exe_dir = exe_path.parent().unwrap_or(std::path::Path::new("."));
            let cf_url_file = exe_dir.join(".cloudflare_url");
            let log_file_path = exe_dir.join("cloudflared.log");

            // Migration from legacy versions: if no log file exists but process is running, it's a zombie from old piped version
            if !log_file_path.exists() {
                #[cfg(target_os = "windows")]
                {
                    use std::os::windows::process::CommandExt;
                    let _ = std::process::Command::new("taskkill").args(&["/F", "/IM", "cloudflared.exe", "/T"]).creation_flags(0x08000000).output();
                }
            }

            let mut is_running = if cfg!(target_os = "windows") {
                use std::os::windows::process::CommandExt;
                if let Ok(out) = std::process::Command::new("tasklist").args(&["/FI", "IMAGENAME eq cloudflared.exe", "/NH"]).creation_flags(0x08000000).output() {
                    String::from_utf8_lossy(&out.stdout).contains("cloudflared.exe")
                } else { false }
            } else { false };

            if is_running {
                let mut has_valid_url = false;
                if let Ok(saved_url) = std::fs::read_to_string(&cf_url_file) {
                    let s = saved_url.trim();
                    if s.contains("trycloudflare.com") {
                        s3.send(format!("CF_URL:{}", s));
                        has_valid_url = true;
                    }
                }
                
                if !has_valid_url {
                    #[cfg(target_os = "windows")]
                    {
                        use std::os::windows::process::CommandExt;
                        let _ = std::process::Command::new("taskkill").args(&["/F", "/IM", "cloudflared.exe", "/T"]).creation_flags(0x08000000).output();
                    }
                    is_running = false;
                }
            }
            
            if !is_running {
                s3.send("CF_STARTING".to_string());
                let s3_thread = s3.clone();
                #[allow(unused_variables)]
                let _app_state_thread = st_app.clone();
                std::thread::spawn(move || {
                    use std::process::Stdio;
                    use std::io::{BufRead, BufReader};
                    #[cfg(target_os = "windows")]
                    use std::os::windows::process::CommandExt;
                    
                    let exe_path_inner = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("X-Server.exe"));
                    let exe_dir_inner = exe_path_inner.parent().unwrap_or(std::path::Path::new("."));
                    let log_file_path = exe_dir_inner.join("cloudflared.log");
                    
                    let stdout_file = std::fs::File::create(&log_file_path).unwrap();
                    let stderr_file = stdout_file.try_clone().unwrap();

                    let bin_name = if cfg!(target_os = "windows") { "cloudflared.exe" } else { "cloudflared" };
                    
                    let mut cmd = std::process::Command::new(bin_name);
                    #[cfg(target_os = "windows")]
                    cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
                    
                    let child = cmd
                        .arg("tunnel")
                        .arg("--url")
                        .arg(format!("http://localhost:{}", cf_port))
                        .stdout(Stdio::from(stdout_file))
                        .stderr(Stdio::from(stderr_file))
                        .spawn();
                        
                    if let Ok(_process) = child {
                        let mut found = false;
                        for _ in 0..120 { // Try up to 60 seconds
                            std::thread::sleep(std::time::Duration::from_millis(500));
                            if let Ok(content) = std::fs::read_to_string(&log_file_path) {
                                for line in content.lines() {
                                    if line.contains("trycloudflare.com") {
                                        if let Some(idx) = line.find("https://") {
                                            let mut ends = idx;
                                            while ends < line.len() && &line[ends..ends+1] != " " && &line[ends..ends+1] != "|" && &line[ends..ends+1] != "\"" {
                                                ends += 1;
                                            }
                                            let url = line[idx..ends].to_string();
                                            
                                            let cf_url_file_inner = exe_dir_inner.join(".cloudflare_url");
                                            let _ = std::fs::write(&cf_url_file_inner, &url);
                                            
                                            s3_thread.send(format!("CF_URL:{}", url));
                                            app::awake();
                                            found = true;
                                            break;
                                        }
                                    }
                                }
                            }
                            if found { break; }
                        }
                        if !found {
                            s3_thread.send("CF_START_ERROR".to_string());
                            app::awake();
                        }
                    } else {
                        s3_thread.send("CF_START_ERROR".to_string());
                        app::awake();
                    }
                });
            }
        } else {
            s3.send("CF_NOT_FOUND".to_string());
        }
        app::awake();
    });

    cf_group.end();

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
                "CF_INSTALLED" => {
                    cf_status.set_label("Starting...");
                    cf_status.set_label_color(Color::Yellow);
                }
                "CF_NOT_FOUND" => {
                    cf_status.set_label("Not Found - Please install cloudflared.");
                    cf_status.set_label_color(Color::Red);
                    cf_url_input.set_value("cloudflared missing.");
                }
                "CF_STARTING" => {
                    cf_status.set_label("Starting...");
                    cf_status.set_label_color(Color::Yellow);
                    cf_url_input.set_value("Waiting for Cloudflare URL...");
                }
                "CF_START_ERROR" => {
                    cf_status.set_label("Start Error");
                    cf_status.set_label_color(Color::Red);
                    cf_url_input.set_value("Failed to run cloudflared.");
                }
                msg if msg.starts_with("CF_URL:") => {
                    cf_status.set_label("Online");
                    cf_status.set_label_color(ACCENT);
                    let url = msg.strip_prefix("CF_URL:").unwrap().to_string();
                    cf_url_input.set_value(&url);
                    *app_state.cloudflare_url.lock().unwrap() = Some(url);
                }
                "UPDATE_STARTING" => {
                    win.set_label(&format!("X-Server {} (Updating...)", env!("CARGO_PKG_VERSION")));
                }
                "UPDATE_READY" => {
                    win.set_label(&format!("X-Server {} (Restarting...)", env!("CARGO_PKG_VERSION")));
                }
                "UPDATE_FAILED" => {
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
