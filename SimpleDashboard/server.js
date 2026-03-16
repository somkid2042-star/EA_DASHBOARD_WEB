const http = require('http');
const fs = require('fs');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');

const webpush = require('web-push');

const supabaseUrl = 'https://xnwyrleniqxdxomjsopw.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhud3lybGVuaXF4ZHhvbWpzb3B3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMTQ3MzMsImV4cCI6MjA4ODc5MDczM30.tx5gR29FfBLsuYCWUDEJy2QqIfDrtL5xG6ZLtXEYZTA';
const supabase = createClient(supabaseUrl, supabaseKey);

// --- Web Push Setup ---
const vapidPublicKey = 'BL-LaApM83wwMjRMg1-Xvy36sNI_XTfgYzWBfELjbhLn1qPW-pK2qeHHLaTzoXzIBM5_MLFG9funkmQLrVmpjAA';
const vapidPrivateKey = 'I567Kb2sbltpJjGhp16htnruuFlYhPHlxCF-Ww8nuRY';
webpush.setVapidDetails(
    'mailto:your_email@example.com',
    vapidPublicKey,
    vapidPrivateKey
);

let pushSubscriptions = [];
// In a real app, save pushSubscriptions to Supabase/DB so they persist across server restarts.
// For now, storing in memory.
// -----------------------

// --- Per-Instance Data Maps (keyed by "account_id:symbol") ---
const instanceDataMap = new Map();     // Map<instanceKey, latestData>
const instanceCommandsMap = new Map(); // Map<instanceKey, commands[]>
const previousStateMap = new Map();    // Map<instanceKey, previousState>
const preloadedSettings = new Map();   // Map<account_id, ea_settings> (from DB at startup)

function makeInstanceKey(accountId, symbol) {
    return `${accountId}:${symbol}`;
}

function getDefaultData() {
    return {
        symbol: "WAITING...",
        equity: 0,
        balance: 0,
        total_profit: 0,
        open_orders: 0,
        trend_direction: "WAITING",
        active_orders: [],
        is_hedged: false
    };
}

function getInstanceData(key) {
    if (!instanceDataMap.has(key)) {
        instanceDataMap.set(key, getDefaultData());
    }
    return instanceDataMap.get(key);
}

function getInstanceCommands(key) {
    if (!instanceCommandsMap.has(key)) {
        instanceCommandsMap.set(key, []);
    }
    return instanceCommandsMap.get(key);
}

function parseInstanceFromUrl(url) {
    const accMatch = url.match(/[?&]account_id=([^&]+)/);
    const symMatch = url.match(/[?&]symbol=([^&]+)/);
    const accountId = accMatch ? accMatch[1] : 'default';
    const symbol = symMatch ? symMatch[1] : '';
    return { accountId, symbol, key: makeInstanceKey(accountId, symbol) };
}

// Helper to send push notifications to all subscribers
function sendPushNotification(payload) {
    if (pushSubscriptions.length === 0) return;
    const stringPayload = JSON.stringify(payload);
    console.log(`[Push] Sending notification to ${pushSubscriptions.length} subscribers...`);

    pushSubscriptions.forEach((sub, index) => {
        webpush.sendNotification(sub, stringPayload).catch(error => {
            console.error('[Push] Payload send error:', error);
            // If subscription is invalid/expired (410, 404), you'd normally remove it here.
            if (error.statusCode === 410 || error.statusCode === 404) {
                pushSubscriptions.splice(index, 1);
            }
        });
    });
}

const server = http.createServer(async (req, res) => {
    // Enable CORS for MT5
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    // Endpoint for MT5 to push data to
    if (req.method === 'POST' && req.url === '/api/ea-stats') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', async () => {
            try {
                const data = JSON.parse(body);
                const accountId = data.account_id || 'default';
                const symbol = data.symbol || '';
                const instKey = makeInstanceKey(accountId, symbol);

                // Get or create per-instance data
                let latestData = getInstanceData(instKey);

                // Apply preloaded settings from DB if this is first connection
                if (!latestData._connected && preloadedSettings.has(accountId)) {
                    latestData.ea_settings = preloadedSettings.get(accountId);
                }
                latestData._connected = true;

                Object.assign(latestData, data);
                instanceDataMap.set(instKey, latestData);

                // Save History to Supabase if exists
                if (data.history && data.history.length > 0) {
                    const upserts = data.history.map(item => ({
                        ticket: item.ticket,
                        symbol: item.symbol,
                        type: item.type,
                        volume: item.volume,
                        open_price: item.open_price,
                        profit: item.profit,
                        date: item.date,
                        account_id: accountId
                    }));

                    const { error } = await supabase
                        .from('ea_history')
                        .upsert(upserts, { onConflict: 'ticket,account_id' });

                    if (error) {
                        console.error("[Supabase] Error upserting history:", error.message);
                    }
                }

                // Check for state changes to trigger push notifications (per-instance)
                const previousDataState = previousStateMap.get(instKey);
                if (previousDataState) {
                    // Hedge notifications (Grid strategy)
                    if (data.is_hedged === true && previousDataState.is_hedged === false) {
                        sendPushNotification({
                            title: `🔒 HEDGE [${symbol}]`,
                            body: `เทรนด์เปลี่ยน สลับ Hedge แล้ว กำไรรวม: $${data.total_profit.toFixed(2)}`,
                            icon: '/icon.png'
                        });
                    } else if (data.is_hedged === false && previousDataState.is_hedged === true) {
                        sendPushNotification({
                            title: `🔓 ปลด Hedge [${symbol}]`,
                            body: 'ระบบกลับมาทำงานแบบ Grid ปกติ',
                            icon: '/icon.png'
                        });
                    }

                    // All orders closed (position closed)
                    if (data.open_orders === 0 && previousDataState.open_orders > 0) {
                        sendPushNotification({
                            title: `✅ ปิดออเดอร์ [${symbol}]`,
                            body: `ปิดรอบสำเร็จ กำไรรวม: $${previousDataState.total_profit.toFixed(2)}`,
                            icon: '/icon.png'
                        });
                    }

                    // New order opened
                    if (data.open_orders > 0 && previousDataState.open_orders === 0) {
                        const strategy = data.strategy || 'GRID';
                        const stLabel = strategy === 'XAU_TREND' ? '🟡 XAU' : strategy === 'BTC_MOMENTUM' ? '🟠 BTC' : '📊 Grid';
                        sendPushNotification({
                            title: `📈 เปิดออเดอร์ [${symbol}]`,
                            body: `${stLabel} เข้า Position ใหม่ | Trend: ${data.trend_direction || '-'}`,
                            icon: '/icon.png'
                        });
                    }

                    // High drawdown alert (> 5%)
                    if (data.max_dd && data.max_dd > 5.0 && (!previousDataState.max_dd || previousDataState.max_dd <= 5.0)) {
                        sendPushNotification({
                            title: `⚠️ Drawdown สูง [${symbol}]`,
                            body: `DD: ${data.max_dd.toFixed(1)}% | กำไรรวม: $${data.total_profit.toFixed(2)}`,
                            icon: '/icon.png'
                        });
                    }

                    // Profit milestone (every $10 gained)
                    if (data.total_profit > 0) {
                        const prevMilestone = Math.floor((previousDataState.total_profit || 0) / 10);
                        const currMilestone = Math.floor(data.total_profit / 10);
                        if (currMilestone > prevMilestone && currMilestone > 0) {
                            sendPushNotification({
                                title: `💰 กำไร $${(currMilestone * 10)} [${symbol}]`,
                                body: `กำไรรวม: $${data.total_profit.toFixed(2)} | ออเดอร์: ${data.open_orders}`,
                                icon: '/icon.png'
                            });
                        }
                    }
                }
                previousStateMap.set(instKey, JSON.parse(JSON.stringify(latestData)));

                console.log(`[${instKey}] Profit: $${latestData.total_profit}`);
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true }));
            } catch (e) {
                res.writeHead(400);
                res.end("Bad Request");
            }
        });
    }
    // Endpoint for frontend to send close combinations
    else if (req.method === 'POST' && req.url === '/api/close-order') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                const accountId = data.account_id || 'default';
                const symbol = data.symbol || '';
                const instKey = makeInstanceKey(accountId, symbol);
                const cmds = getInstanceCommands(instKey);
                if (data.action === 'close_all') {
                    cmds.push({ action: "close_all" });
                    console.log(`[WebCmd][${instKey}] close ALL orders`);
                } else if (data.action === 'close_profitable') {
                    cmds.push({ action: "close_profitable" });
                    console.log(`[WebCmd][${instKey}] close PROFITABLE`);
                } else if (data.action === 'hedge_now') {
                    cmds.push({ action: "hedge_now" });
                    console.log(`[WebCmd][${instKey}] HEDGE NOW`);
                } else if (data.action === 'close_hedge') {
                    cmds.push({ action: "close_hedge" });
                    console.log(`[WebCmd][${instKey}] CLOSE HEDGE`);
                } else if (data.ticket) {
                    cmds.push({ action: "close", ticket: data.ticket });
                    console.log(`[WebCmd][${instKey}] close #${data.ticket}`);
                } else {
                    res.writeHead(400);
                    res.end("Invalid request");
                    return;
                }
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true }));
            } catch (e) {
                res.writeHead(400);
                res.end("Bad Request");
            }
        });
    }
    // Endpoint for frontend to send manual multiplier combinations
    else if (req.method === 'POST' && req.url === '/api/open-multiplier') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                const accountId = data.account_id || 'default';
                const symbol = data.symbol || '';
                const instKey = makeInstanceKey(accountId, symbol);
                if (data.ticket) {
                    getInstanceCommands(instKey).push({ action: "open_multiplier", ticket: data.ticket });
                    console.log(`[WebCmd][${instKey}] open multiplier #${data.ticket}`);
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ success: true }));
                } else {
                    res.writeHead(400);
                    res.end("Invalid ticket");
                }
            } catch (e) {
                res.writeHead(400);
                res.end("Bad Request");
            }
        });
    }
    // Endpoint for frontend to send updated EA settings
    else if (req.method === 'POST' && req.url === '/api/update-settings') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', async () => {
            try {
                const data = JSON.parse(body);
                const accountId = data.account_id || 'default';
                const symbol = data.symbol || '';
                const instKey = makeInstanceKey(accountId, symbol);
                if (data.settings) {
                    getInstanceCommands(instKey).push({ action: "update_settings", settings: data.settings });

                    // Supabase UPSERT with account_id
                    const { error } = await supabase.from('ea_settings_master').upsert({
                        id: 1,
                        account_id: accountId,
                        start_lot: data.settings.start_lot,
                        lot_multiplier: data.settings.lot_multiplier,
                        max_levels: data.settings.max_levels,
                        tp_mode: data.settings.tp_mode,
                        take_profit_usd: data.settings.tp_usd,
                        use_dynamic_step: data.settings.use_dynamic_step,
                        fixed_grid_step: data.settings.grid_step,
                        atr_period: data.settings.atr_period,
                        atr_multiplier: data.settings.atr_multiplier,
                        use_trend_filter: data.settings.use_trend_filter,
                        ema_fast: data.settings.ema_fast,
                        ema_slow: data.settings.ema_slow,
                        rsi_period: data.settings.rsi_period,
                        rsi_tf: data.settings.rsi_tf,
                        rsi_buy_level: data.settings.rsi_buy,
                        rsi_sell_level: data.settings.rsi_sell,
                        use_basket_trail: data.settings.use_basket_trail,
                        basket_trail_start_usd: data.settings.trail_start,
                        basket_trail_step_usd: data.settings.trail_step,
                        updated_at: new Date()
                    });

                    if (error) {
                        console.error("[Supabase] Error updating database:", error);
                    } else {
                        console.log(`[Supabase][${instKey}] Settings saved to DB`);
                    }

                    console.log(`[WebCmd][${instKey}] update EA settings`);
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ success: true }));
                } else {
                    res.writeHead(400);
                    res.end("Invalid settings data");
                }
            } catch (e) {
                res.writeHead(400);
                res.end("Bad Request");
            }
        });
    }
    // Endpoint for EA to poll for commands (per-account)
    else if (req.method === 'GET' && req.url.startsWith('/api/ea-commands')) {
        const { accountId, symbol, key: instKey } = parseInstanceFromUrl(req.url);
        const cmds = getInstanceCommands(instKey);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(cmds));
        instanceCommandsMap.set(instKey, []); // clear after sending
    }
    // Endpoint: List all connected instances (account + symbol) with FULL data
    else if (req.method === 'GET' && req.url === '/api/accounts') {
        const instances = [];
        for (const [key, data] of instanceDataMap.entries()) {
            // Skip entries that have no real data (no symbol or never connected)
            if (!data._connected || !data.symbol || data.symbol === 'WAITING...') continue;
            const parts = key.split(':');
            instances.push({
                instance_key: key,
                account_id: parts[0] || key,
                ...data
            });
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(instances));
    }
    // Endpoint for frontend to fetch data (per-instance)
    else if (req.method === 'GET' && req.url.startsWith('/api/ea-stats')) {
        const { accountId, symbol, key: instKey } = parseInstanceFromUrl(req.url);
        const latestData = getInstanceData(instKey);
        res.writeHead(200, { 'Content-Type': 'application/json' });

        // Fetch full history from Supabase filtered by account
        let responseData = { ...latestData, account_id: accountId, instance_key: instKey };
        try {
            const { data: historyData, error } = await supabase
                .from('ea_history')
                .select('*')
                .eq('account_id', accountId)
                .order('date', { ascending: false });

            if (error) {
                console.error("[Supabase] Error fetching history:", error.message);
            } else if (historyData) {
                // Filter by symbol if provided
                responseData.history = symbol
                    ? historyData.filter(h => h.symbol === symbol)
                    : historyData;
            }
        } catch (e) {
            console.error("[Supabase] Query exception:", e);
        }

        res.end(JSON.stringify(responseData));
    }
    // Serve the HTML Web App
    else if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
        fs.readFile(path.join(__dirname, 'index.html'), (err, content) => {
            if (err) {
                res.writeHead(500);
                res.end("Error loading HTML");
            } else {
                res.writeHead(200, { 'Content-Type': 'text/html' });
                res.end(content);
            }
        });
    }
    // Serve Service Worker file (CRITICAL for Push Notifications)
    else if (req.method === 'GET' && req.url === '/sw.js') {
        fs.readFile(path.join(__dirname, 'sw.js'), (err, content) => {
            if (err) {
                res.writeHead(500);
                res.end("Error loading service worker");
            } else {
                res.writeHead(200, {
                    'Content-Type': 'application/javascript',
                    'Service-Worker-Allowed': '/'
                });
                res.end(content);
            }
        });
    }
    // Serve the manifest for PWA
    else if (req.method === 'GET' && req.url === '/manifest.json') {
        fs.readFile(path.join(__dirname, 'manifest.json'), (err, content) => {
            if (err) {
                res.writeHead(500);
                res.end("Error loading manifest");
            } else {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(content);
            }
        });
    }
    // Endpoint for frontend to get VAPID Public Key
    else if (req.method === 'GET' && req.url === '/api/vapid-public-key') {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end(vapidPublicKey);
    }
    // Endpoint for frontend to register Push Subscription
    else if (req.method === 'POST' && req.url === '/api/subscribe') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                const subscription = JSON.parse(body);
                // Basic check if already exists
                const exists = pushSubscriptions.find(sub => sub.endpoint === subscription.endpoint);
                if (!exists) {
                    pushSubscriptions.push(subscription);
                    console.log(`[Push] New subscriber added! Total: ${pushSubscriptions.length}`);
                }
                res.writeHead(201, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true }));
            } catch (e) {
                res.writeHead(400);
                res.end("Bad Request");
            }
        });
    }
    // Endpoint for EA to test Push Notifications manually
    else if (req.method === 'POST' && req.url === '/api/test-push') {
        let body = '';
        req.on('data', chunk => { body += chunk.toString(); });
        req.on('end', () => {
            try {
                sendPushNotification({
                    title: '🛠️ ทดสอบแจ้งเตือนจาก EA',
                    body: 'ระบบ Web Push Notification ทำงานได้ปกติครับ!',
                    icon: '/icon.png'
                });
                console.log(`[WebCmd] Test push notification triggered by EA.`);
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true }));
            } catch (e) {
                res.writeHead(400);
                res.end("Bad Request");
            }
        });
    }
    else {
        res.writeHead(404);
        res.end("Not Found");
    }
});

const PORT = 3000;
server.listen(PORT, async () => {
    console.log(`\n===========================================`);
    console.log(`✅ Simple Web App is running!`);
    console.log(`Open your browser and visit: http://localhost:${PORT}`);
    console.log(`===========================================\n`);

    // Fetch initial settings from DB so frontend can populate before MT5 connects
    try {
        const { data, error } = await supabase.from('ea_settings_master').select('*').limit(10);
        if (data && !error && data.length > 0) {
            data.forEach(row => {
                const accId = row.account_id || 'default';
                // Store in separate preloaded map — NOT in instanceDataMap
                preloadedSettings.set(accId, {
                    start_lot: row.start_lot,
                    lot_multiplier: row.lot_multiplier,
                    max_levels: row.max_levels,
                    tp_mode: row.tp_mode,
                    tp_usd: row.take_profit_usd,
                    use_dynamic_step: row.use_dynamic_step,
                    grid_step: row.fixed_grid_step,
                    atr_period: row.atr_period,
                    atr_multiplier: row.atr_multiplier,
                    use_trend_filter: row.use_trend_filter,
                    ema_fast: row.ema_fast,
                    ema_slow: row.ema_slow,
                    rsi_period: row.rsi_period,
                    rsi_tf: row.rsi_tf,
                    rsi_buy: row.rsi_buy_level,
                    rsi_sell: row.rsi_sell_level,
                    use_basket_trail: row.use_basket_trail,
                    trail_start: row.basket_trail_start_usd,
                    trail_step: row.basket_trail_step_usd
                });
                console.log(`[Supabase] Pre-loaded settings for account: ${accId}`);
            });
        }
    } catch (e) {
        console.error("[Supabase] Failed to pre-load settings.");
    }

    console.log(`Waiting for data from EA...`);
});
