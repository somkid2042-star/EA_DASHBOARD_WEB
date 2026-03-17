use axum::{
    extract::{State, Json},
    routing::{get, post},
    Router,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use tower_http::cors::{Any, CorsLayer};

struct AppState {
    instance_data: Arc<Mutex<HashMap<String, Value>>>,
    instance_commands: Arc<Mutex<HashMap<String, Vec<Value>>>>,
    preloaded_settings: Arc<Mutex<HashMap<String, Value>>>,
}

async fn get_accounts(State(state): State<Arc<AppState>>) -> Json<Value> {
    let data = state.instance_data.lock().await;
    let accounts: Vec<Value> = data.iter().map(|(k, v)| {
        let parts: Vec<&str> = k.split(':').collect();
        let acc_id = if parts.len() > 0 { parts[0] } else { "default" };
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

async fn get_stats(State(state): State<Arc<AppState>>) -> Json<Value> {
    let data = state.instance_data.lock().await;
    let mut cloned_map = serde_json::Map::new();
    for (k, v) in data.iter() {
        cloned_map.insert(k.clone(), v.clone());
    }
    Json(Value::Object(cloned_map))
}

async fn post_stats(
    State(state): State<Arc<AppState>>,
    Json(mut payload): Json<Value>,
) -> Json<Value> {
    let account_id = payload.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
    let symbol = payload.get("symbol").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let inst_key = format!("{}:{}", account_id, symbol);

    let mut data_map = state.instance_data.lock().await;
    let mut current_data = data_map.get(&inst_key).cloned().unwrap_or_else(|| json!({
        "symbol": "WAITING...",
        "equity": 0,
        "balance": 0,
        "total_profit": 0,
        "open_orders": 0,
        "_connected": false,
        "ea_settings": null
    }));

    let connected = current_data.get("_connected").and_then(|v| v.as_bool()).unwrap_or(false);
    if !connected {
        let preload = state.preloaded_settings.lock().await;
        if let Some(settings) = preload.get(&account_id) {
            current_data["ea_settings"] = settings.clone();
        }
    }
    current_data["_connected"] = json!(true);

    if let Value::Object(ref mut current_obj) = current_data {
        if let Value::Object(payload_obj) = payload {
            for (k, v) in payload_obj {
                current_obj.insert(k, v);
            }
        }
    }

    data_map.insert(inst_key.clone(), current_data);

    let mut cmds_map = state.instance_commands.lock().await;
    let commands = cmds_map.remove(&inst_key).unwrap_or_default();

    Json(json!({ "success": true, "commands": commands }))
}

async fn post_close_order(State(state): State<Arc<AppState>>, Json(payload): Json<Value>) -> Json<Value> {
    let account_id = payload.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
    let symbol = payload.get("symbol").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let inst_key = format!("{}:{}", account_id, symbol);
    let mut cmds_map = state.instance_commands.lock().await;
    let entry = cmds_map.entry(inst_key).or_insert_with(Vec::new);

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
        state.instance_commands.lock().await.entry(inst_key).or_insert_with(Vec::new)
            .push(json!({ "action": "open_multiplier", "ticket": ticket }));
    }
    Json(json!({ "success": true }))
}

async fn post_update_settings(State(state): State<Arc<AppState>>, Json(payload): Json<Value>) -> Json<Value> {
    let account_id = payload.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
    let symbol = payload.get("symbol").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let inst_key = format!("{}:{}", account_id, symbol);
    if let Some(settings) = payload.get("settings") {
        state.instance_commands.lock().await.entry(inst_key).or_insert_with(Vec::new)
            .push(json!({ "action": "update_settings", "settings": settings.clone() }));
        
        let url = "https://xnwyrleniqxdxomjsopw.supabase.co/rest/v1/ea_settings_master";
        let key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhud3lybGVuaXF4ZHhvbWpzb3B3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMTQ3MzMsImV4cCI6MjA4ODc5MDczM30.tx5gR29FfBLsuYCWUDEJy2QqIfDrtL5xG6ZLtXEYZTA";
        let client = reqwest::Client::new();
        let mut row = settings.clone();
        row["account_id"] = json!(account_id);
        let _ = client.post(url)
            .header("apikey", key)
            .header("Authorization", format!("Bearer {}", key))
            .header("Prefer", "resolution=merge-duplicates")
            .json(&row)
            .send().await;
    }
    Json(json!({ "success": true }))
}

async fn preload_settings(preloaded_state: Arc<Mutex<HashMap<String, Value>>>) {
    let url = "https://xnwyrleniqxdxomjsopw.supabase.co/rest/v1/ea_settings_master?select=*&limit=10";
    let key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhud3lybGVuaXF4ZHhvbWpzb3B3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMTQ3MzMsImV4cCI6MjA4ODc5MDczM30.tx5gR29FfBLsuYCWUDEJy2QqIfDrtL5xG6ZLtXEYZTA";
    let client = reqwest::Client::new();
    if let Ok(res) = client.get(url).header("apikey", key).header("Authorization", format!("Bearer {}", key)).send().await {
        if let Ok(rows) = res.json::<Vec<Value>>().await {
            let mut map = preloaded_state.lock().await;
            for row in rows {
                let acc_id = row.get("account_id").and_then(|v| v.as_str()).unwrap_or("default").to_string();
                map.insert(acc_id, row);
            }
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_log::Builder::default().build())
        .setup(|app| {
            let app_state = Arc::new(AppState {
                instance_data: Arc::new(Mutex::new(HashMap::new())),
                instance_commands: Arc::new(Mutex::new(HashMap::new())),
                preloaded_settings: Arc::new(Mutex::new(HashMap::new())),
            });

            let preload_state = app_state.preloaded_settings.clone();
            tokio::spawn(async move { preload_settings(preload_state).await; });

            let state_clone = app_state.clone();
            tauri::async_runtime::spawn(async move {
                let cors = CorsLayer::new().allow_origin(Any).allow_methods(Any).allow_headers(Any);
                let router = Router::new()
                    .route("/api/accounts", get(get_accounts))
                    .route("/api/ea-stats", get(get_stats).post(post_stats))
                    .route("/api/close-order", post(post_close_order))
                    .route("/api/open-multiplier", post(post_open_multiplier))
                    .route("/api/update-settings", post(post_update_settings))
                    .layer(cors)
                    .with_state(state_clone);

                if let Ok(listener) = tokio::net::TcpListener::bind("0.0.0.0:3000").await {
                    println!("Tauri Rust backend listening on port 3000");
                    let _ = axum::serve(listener, router).await;
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
