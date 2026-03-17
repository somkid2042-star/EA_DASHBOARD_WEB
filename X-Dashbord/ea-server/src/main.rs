use axum::{
    extract::{Query, State, Json},
    routing::{get, post},
    response::{IntoResponse, Response},
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
    frame::Frame, group::{Group, Pack, Scroll}, prelude::*, window::DoubleWindow,
    text::{TextDisplay, TextBuffer},
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
}

impl AppState {
    pub fn log(&self, msg: String) {
        if let Ok(mut logs) = self.logs.lock() {
            let log_entry = format!("[{}] {}", chrono::Local::now().format("%H:%M:%S"), msg);
            logs.push(log_entry);
            // Keep last 100 logs
            if logs.len() > 100 {
                logs.remove(0);
            }
        }
    }
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
        let total_profit = v.get("total_profit").and_then(|p| p.as_f64()).unwrap_or(0.0);
        let open_orders = v.get("open_orders").and_then(|o| o.as_i64()).unwrap_or(0);
        let status = if open_orders > 0 { "Active" } else { "Standby" };
        json!({
            "account_id": acc_id,
            "symbol": symbol,
            "total_profit": total_profit,
            "status": status,
            "last_update": v.get("last_update").and_then(|l| l.as_str()).unwrap_or("")
        })
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
    let url = "https://xnwyrleniqxdxomjsopw.supabase.co/rest/v1/ea_settings_master?select=*&limit=10";
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

fn main() {
    // Setup panic hook to log crashes to text file for debugging
    std::panic::set_hook(Box::new(|info| {
        let msg = format!("CRITICAL PANIC OCCURRED:\n{:?}", info);
        let _ = std::fs::write("SERVER_CRASH_LOG.txt", &msg);
        eprintln!("{}", msg);
    }));

    let app = app::App::default().with_scheme(app::Scheme::Gtk);

    let app_state = Arc::new(AppState {
        instance_data: Arc::new(Mutex::new(HashMap::new())),
        instance_commands: Arc::new(Mutex::new(HashMap::new())),
        preloaded_settings: Arc::new(Mutex::new(HashMap::new())),
        logs: Arc::new(Mutex::new(vec![])),
    });

    let port = 3000u16;

    app_state.log("Starting Web Server...".to_string());

    let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
    let server_state = app_state.clone();
    
    let app_state_tokio = app_state.clone();
    
    // Check if port is available before starting Axum
    let port_status = match std::net::TcpListener::bind(format!("0.0.0.0:{}", port)) {
        Ok(std_listener) => {
            drop(std_listener); // Let tokio bind
            
            rt.spawn(async move {
                let preload_state = server_state.preloaded_settings.clone();
                let logs_state = server_state.logs.clone();
                tokio::spawn(async move { preload_settings(preload_state, logs_state).await; });

                let cors = CorsLayer::new().allow_origin(Any).allow_methods(Any).allow_headers(Any);
                let router = Router::new()
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
    let mut win = DoubleWindow::default().with_size(650, 550).center_screen().with_label("EA Smart Server (Native)");
    win.set_color(DARK_BG);

    let mut pack = Pack::default().with_size(610, 510).center_of_parent();
    pack.set_spacing(15);

    // Title
    let mut title = Frame::default().with_size(610, 40).with_label("EA Smart Dashboard Control Panel");
    title.set_label_font(Font::HelveticaBold);
    title.set_label_size(24);
    title.set_label_color(TEXT_COLOR);

    // Server Status Panel
    let mut status_group = Group::default().with_size(610, 100);
    status_group.set_frame(FrameType::FlatBox);
    status_group.set_color(PANEL_BG);
    
    let mut l1 = Frame::default().with_size(580, 25).with_pos(status_group.x() + 15, status_group.y() + 10).with_label("🌐 Server Status:");
    l1.set_label_font(Font::HelveticaBold);
    l1.set_label_size(16);
    l1.set_label_color(TEXT_COLOR);
    l1.set_align(Align::Left | Align::Inside);

    let mut l_status = Frame::default().with_size(580, 25).with_pos(status_group.x() + 15, status_group.y() + 35);
    l_status.set_label_size(14);
    l_status.set_align(Align::Left | Align::Inside);
    if port_status == "OK" {
        l_status.set_label(&format!("● Running | Port: {}", port));
        l_status.set_label_color(ACCENT);
    } else {
        l_status.set_label(&format!("● Error: {}", port_status));
        l_status.set_label_color(Color::Red);
    }

    let mut l_local = Frame::default().with_size(580, 25).with_pos(status_group.x() + 15, status_group.y() + 60);
    l_local.set_label(&format!("URL: http://localhost:{}  (Enter this IP in your mobile browser)", port));
    l_local.set_label_size(14);
    l_local.set_label_color(TEXT_COLOR);
    l_local.set_align(Align::Left | Align::Inside);

    status_group.end();

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
    win.make_resizable(true);
    win.end();
    win.show();

    // ---------------- Event Loop ----------------
    let mut log_line_count = 0;
    
    // The loop keeps running, and `app::awake()` from Tokio will trigger an interaction
    while app.wait() {
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
