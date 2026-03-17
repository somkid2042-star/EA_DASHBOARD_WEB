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
use eframe::egui;

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
            logs.push(format!("[{}] {}", chrono::Local::now().format("%H:%M:%S"), msg));
            // Keep last 50 logs
            if logs.len() > 50 {
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
                    }
                }
            }
        }
        Err(_) => {
            if let Ok(mut l) = logs.lock() {
                l.push(format!("[{}] ⚠️ Supabase: Connection failed", chrono::Local::now().format("%H:%M:%S")));
            }
        }
    }
}

// ---------------- EGUI APPLICATION ----------------

struct ServerApp {
    state: Arc<AppState>,
    port: u16,
    local_ip: String,
    port_status: String,
}

impl eframe::App for ServerApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Refresh 2 times per second
        ctx.request_repaint_after(std::time::Duration::from_millis(500));

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("EA Smart Server Panel");
            ui.add_space(10.0);

            ui.group(|ui| {
                ui.label(egui::RichText::new("🌐 Server Status").strong().size(16.0));
                ui.add_space(5.0);
                
                ui.horizontal(|ui| {
                    ui.label("Status:");
                    if self.port_status == "OK" {
                        ui.label(egui::RichText::new("● Running").color(egui::Color32::GREEN));
                    } else {
                        ui.label(egui::RichText::new(format!("● Error: {}", self.port_status)).color(egui::Color32::RED));
                    }
                });

                ui.label(format!("Port: {}", self.port));
                ui.horizontal(|ui| {
                    ui.label("Local URL:");
                    ui.hyperlink(format!("http://localhost:{}", self.port));
                });
                ui.horizontal(|ui| {
                    ui.label("LAN URL:");
                    ui.hyperlink(format!("http://{}:{}", self.local_ip, self.port));
                    ui.label(egui::RichText::new("(Open this on your mobile)").weak());
                });
            });

            ui.add_space(20.0);
            
            ui.label(egui::RichText::new("📊 Connected MT5 Instances").strong().size(16.0));
            ui.add_space(5.0);

            // Fetch data securely and synchronously
            let data_map = if let Ok(lock) = self.state.instance_data.lock() {
                lock.clone()
            } else {
                HashMap::new()
            };
            
            if data_map.is_empty() {
                ui.label(egui::RichText::new("No MT5 EAs currently connected.").italics().weak());
            } else {
                egui::ScrollArea::vertical().max_height(150.0).show(ui, |ui| {
                    egui::Grid::new("my_grid")
                        .num_columns(5)
                        .spacing([20.0, 8.0])
                        .striped(true)
                        .show(ui, |ui| {
                            ui.label(egui::RichText::new("Account").strong());
                            ui.label(egui::RichText::new("Symbol").strong());
                            ui.label(egui::RichText::new("Equity").strong());
                            ui.label(egui::RichText::new("Profit").strong());
                            ui.label(egui::RichText::new("Orders").strong());
                            ui.end_row();

                            for (key, val) in data_map.iter() {
                                let parts: Vec<&str> = key.split(':').collect();
                                let acc = parts.get(0).unwrap_or(&"");
                                let sym = parts.get(1).unwrap_or(&"");
                                
                                let equity = val.get("equity").and_then(|v| v.as_f64()).unwrap_or(0.0);
                                let profit = val.get("total_profit").and_then(|v| v.as_f64()).unwrap_or(0.0);
                                let orders = val.get("open_orders").and_then(|v| v.as_i64()).unwrap_or(0);

                                ui.label(*acc);
                                ui.label(*sym);
                                ui.label(format!("${:.2}", equity));
                                
                                let profit_text = format!("${:.2}", profit);
                                if profit > 0.0 {
                                    ui.label(egui::RichText::new(profit_text).color(egui::Color32::from_rgb(0, 200, 0)));
                                } else if profit < 0.0 {
                                    ui.label(egui::RichText::new(profit_text).color(egui::Color32::from_rgb(200, 0, 0)));
                                } else {
                                    ui.label(profit_text);
                                }
                                
                                ui.label(orders.to_string());
                                ui.end_row();
                            }
                        });
                });
            }

            ui.add_space(20.0);

            ui.label(egui::RichText::new("📝 Activity Logs").strong().size(16.0));
            ui.add_space(5.0);
            
            let logs_copy = if let Ok(lock) = self.state.logs.lock() {
                lock.clone()
            } else {
                vec![]
            };

            egui::ScrollArea::vertical().stick_to_bottom(true).show(ui, |ui| {
                ui.style_mut().visuals.extreme_bg_color = egui::Color32::from_rgb(20, 20, 20); 
                ui.add_sized(ui.available_size(), egui::TextEdit::multiline(&mut logs_copy.join("\n")).interactive(false).font(egui::TextStyle::Monospace));
            });
        });
    }
}

fn get_local_ip() -> String {
    "127.0.0.1 (Connect via LAN IP)".to_string()
}

fn main() {
    // 1. Setup panic hook to log crashes to text file for debugging
    std::panic::set_hook(Box::new(|info| {
        let msg = format!("CRITICAL PANIC OCCURRED:\n{:?}", info);
        let _ = std::fs::write("SERVER_CRASH_LOG.txt", &msg);
        eprintln!("{}", msg);
    }));

    let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");

    let app_state = Arc::new(AppState {
        instance_data: Arc::new(Mutex::new(HashMap::new())),
        instance_commands: Arc::new(Mutex::new(HashMap::new())),
        preloaded_settings: Arc::new(Mutex::new(HashMap::new())),
        logs: Arc::new(Mutex::new(vec![])),
    });

    let port = 3000u16;
    let local_ip = get_local_ip();

    app_state.log("Starting Web Server...".to_string());

    let server_state = app_state.clone();
    
    // Check if port is available before starting Axum
    let port_status = match std::net::TcpListener::bind(format!("0.0.0.0:{}", port)) {
        Ok(std_listener) => {
            drop(std_listener); // Let tokio bind it now
            // Port is free, start Axum server
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
                axum::serve(listener, router).await.unwrap();
            });
            "OK".to_string()
        },
        Err(e) => {
            let err_msg = format!("Port {} is IN USE by another program!", port);
            app_state.log(err_msg.clone());
            err_msg
        }
    };

    if port_status == "OK" {
        app_state.log(format!("Server listening on port {}", port));
    }

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([600.0, 500.0])
            .with_min_inner_size([400.0, 300.0])
            .with_title("EA Smart Dashboard Control Panel"),
        ..Default::default()
    };

    let result = eframe::run_native(
        "EA Smart Server",
        options,
        Box::new(move |_cc| {
            _cc.egui_ctx.set_visuals(egui::Visuals::dark());
            Ok(Box::new(ServerApp {
                state: app_state,
                port,
                local_ip,
                port_status,
            }))
        }),
    );

    // 2. If GUI fails to launch (e.g. VPS with no GPU drivers), log it and wait to prevent instant close
    if let Err(e) = result {
        let error_msg = format!(
            "Failed to start GUI Windows: {:?}\n\nThis often happens on VPS / Windows Servers without graphics drivers.\nPlease check SERVER_CRASH_LOG.txt or contact support.", 
            e
        );
        let _ = std::fs::write("GUI_ERROR_LOG.txt", &error_msg);
        println!("{}", error_msg);
        
        // Pause console so user can read the error before it disappears
        println!("\nPress ENTER to exit...");
        let mut input = String::new();
        let _ = std::io::stdin().read_line(&mut input);
    }
}
