//+------------------------------------------------------------------+
//|                                                       X_BTC.mq5  |
//|         BTC Momentum + RSI Pullback Strategy                      |
//+------------------------------------------------------------------+
#property copyright "X_BTC v2.0"
#property version   "2.00"
#property description "BTC Momentum — No Inputs, Web-Controlled, Real-time Sync"

#include <Trade\Trade.mqh>

// Magic Number
long g_MagicNumber = 20261111;

//+------------------------------------------------------------------+
//| ===== Global Variables =====                                       |
//+------------------------------------------------------------------+
CTrade   g_trade;

// Version
string g_EAVersion = "1.5.0";
string g_EAName    = "X_BTC";

//--- BTC Strategy Variables
int      g_btcHandleEMA50  = INVALID_HANDLE;
int      g_btcHandleEMA200 = INVALID_HANDLE;
int      g_btcHandleRSI    = INVALID_HANDLE;
int      g_btcHandleATR    = INVALID_HANDLE;
double   g_btcEMA50 = 0, g_btcEMA200 = 0;
double   g_btcRSI = 0, g_btcATR = 0;
int      g_btcTrend = 0;           // 1=UP, -1=DOWN, 0=FLAT
ulong    g_btcTicket = 0;          // Current open ticket
double   g_btcEntrySL = 0;         // SL distance for trailing calc
double   g_btcHighWater = 0;       // Highest profit for trailing
bool     g_btcPartialDone = false; // Has partial TP been taken?

//--- Order Stats
int      g_totalOrders    = 0;
int      g_buyOrders      = 0;
int      g_sellOrders     = 0;
double   g_totalLot       = 0;
double   g_buyLot         = 0;
double   g_sellLot        = 0;
double   g_totalProfit    = 0;
double   g_buyProfit      = 0;
double   g_sellProfit     = 0;

//--- BTC Settings (Defaults — overridden by web app)
int      g_SetBTC_EMA_Fast     = 50;
int      g_SetBTC_EMA_Slow     = 200;
ENUM_TIMEFRAMES g_SetBTC_TrendTF = PERIOD_H4;
int      g_SetBTC_RSI_Period   = 14;
ENUM_TIMEFRAMES g_SetBTC_RSI_TF  = PERIOD_H1;
int      g_SetBTC_RSI_Buy      = 35;
int      g_SetBTC_RSI_Sell     = 65;
double   g_SetBTC_RiskReward   = 2.0;
double   g_SetBTC_ATR_SL_Mult  = 1.5;
double   g_SetBTC_LotSize      = 0.01;
double   g_SetBTC_TrailATRMult = 1.0;
bool     g_SetBTC_PartialTP    = true;

//--- Dashboard
string   g_prefix        = "BTC_";

//+------------------------------------------------------------------+
//| ===== OnInit() =====                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== X_BTC v2.0 Momentum + RSI Pullback (Web-Controlled) ===");
   
   g_trade.SetExpertMagicNumber(g_MagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_btcHandleEMA50  = iMA(_Symbol, g_SetBTC_TrendTF, g_SetBTC_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_btcHandleEMA200 = iMA(_Symbol, g_SetBTC_TrendTF, g_SetBTC_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_btcHandleRSI    = iRSI(_Symbol, g_SetBTC_RSI_TF, g_SetBTC_RSI_Period, PRICE_CLOSE);
   g_btcHandleATR    = iATR(_Symbol, g_SetBTC_RSI_TF, 14);
   
   if(g_btcHandleEMA50 == INVALID_HANDLE || g_btcHandleEMA200 == INVALID_HANDLE ||
      g_btcHandleRSI == INVALID_HANDLE || g_btcHandleATR == INVALID_HANDLE)
   {
      Print("❌ BTC indicator handles failed!");
      return INIT_FAILED;
   }
   g_btcTicket = 0;
   g_btcHighWater = 0;
   g_btcPartialDone = false;

   UpdateBTCDashboard();
   EventSetTimer(1);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| ===== OnDeinit() =====                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_btcHandleEMA50  != INVALID_HANDLE) IndicatorRelease(g_btcHandleEMA50);
   if(g_btcHandleEMA200 != INVALID_HANDLE) IndicatorRelease(g_btcHandleEMA200);
   if(g_btcHandleRSI    != INVALID_HANDLE) IndicatorRelease(g_btcHandleRSI);
   if(g_btcHandleATR    != INVALID_HANDLE) IndicatorRelease(g_btcHandleATR);
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
}

//+------------------------------------------------------------------+
//| ===== OnTick() =====                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1) Read BTC Indicators
   double ema50[], ema200[], rsiArr[], atrArr[];
   if(CopyBuffer(g_btcHandleEMA50,  0, 0, 2, ema50) < 2) return;
   if(CopyBuffer(g_btcHandleEMA200, 0, 0, 2, ema200) < 2) return;
   if(CopyBuffer(g_btcHandleRSI,    0, 0, 2, rsiArr) < 2) return;
   if(CopyBuffer(g_btcHandleATR,    0, 0, 2, atrArr) < 2) return;
   
   g_btcEMA50  = ema50[0];
   g_btcEMA200 = ema200[0];
   g_btcRSI    = rsiArr[0];
   g_btcATR    = atrArr[0];
   
   //--- 2) Determine H4 Trend
   if(g_btcEMA50 > g_btcEMA200) g_btcTrend = 1;
   else if(g_btcEMA50 < g_btcEMA200) g_btcTrend = -1;
   else g_btcTrend = 0;
   
   //--- 3) Scan current positions
   ScanOrders();
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   //--- 4) Check if our BTC ticket is still open
   bool hasPosition = false;
   if(g_btcTicket > 0)
   {
      if(PositionSelectByTicket(g_btcTicket))
      {
         hasPosition = true;
         double posProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(posProfit > g_btcHighWater) g_btcHighWater = posProfit;
         
         double slDist = g_btcEntrySL;
         double trailStep = g_btcATR * g_SetBTC_TrailATRMult;
         
         //--- Partial TP: close 50% at TP level
         if(g_SetBTC_PartialTP && !g_btcPartialDone)
         {
            double tpDist = slDist * g_SetBTC_RiskReward;
            long posType = PositionGetInteger(POSITION_TYPE);
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;
            double priceProfit = (posType == POSITION_TYPE_BUY) ? (currentPrice - openPrice) : (openPrice - currentPrice);
            
            if(priceProfit >= tpDist)
            {
               double currentLot = PositionGetDouble(POSITION_VOLUME);
               double halfLot = NormalizeDouble(currentLot / 2.0, 2);
               double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
               if(halfLot < minLot) halfLot = minLot;
               
               if(currentLot > minLot)
               {
                  g_trade.PositionClosePartial(g_btcTicket, halfLot);
                  Print("🟠 BTC Partial TP: Closed ", DoubleToString(halfLot,2), " lots");
                  g_btcPartialDone = true;
                  if(posType == POSITION_TYPE_BUY)
                     g_trade.PositionModify(g_btcTicket, openPrice + _Point, 0);
                  else
                     g_trade.PositionModify(g_btcTicket, openPrice - _Point, 0);
               }
            }
         }
         
         //--- ATR Trailing Stop (after partial TP)
         if(g_btcPartialDone && trailStep > 0)
         {
            long posType = PositionGetInteger(POSITION_TYPE);
            double currentSL = PositionGetDouble(POSITION_SL);
            
            if(posType == POSITION_TYPE_BUY)
            {
               double newSL = bid - trailStep;
               if(newSL > currentSL && newSL > PositionGetDouble(POSITION_PRICE_OPEN))
                  g_trade.PositionModify(g_btcTicket, newSL, 0);
            }
            else
            {
               double newSL = ask + trailStep;
               if((newSL < currentSL || currentSL == 0) && newSL < PositionGetDouble(POSITION_PRICE_OPEN))
                  g_trade.PositionModify(g_btcTicket, newSL, 0);
            }
         }
      }
      else
      {
         g_btcTicket = 0;
         g_btcHighWater = 0;
         g_btcPartialDone = false;
      }
   }
   
   //--- 5) Entry Signal (no position open)
   if(!hasPosition && g_btcATR > 0)
   {
      double slDist = g_btcATR * g_SetBTC_ATR_SL_Mult;
      double tpDist = slDist * g_SetBTC_RiskReward;
      
      // BUY: Uptrend + RSI pullback
      if(g_btcTrend == 1 && g_btcRSI < g_SetBTC_RSI_Buy)
      {
         double sl = ask - slDist;
         double tp = ask + tpDist;
         if(g_trade.Buy(g_SetBTC_LotSize, _Symbol, ask, sl, tp, "BTC_MOM_BUY"))
         {
            g_btcTicket = g_trade.ResultOrder();
            g_btcEntrySL = slDist;
            g_btcHighWater = 0;
            g_btcPartialDone = false;
            Print("🟠 BTC BUY: RSI=", DoubleToString(g_btcRSI,1), " SL=", DoubleToString(sl,_Digits), " TP=", DoubleToString(tp,_Digits));
         }
      }
      // SELL: Downtrend + RSI overbought
      else if(g_btcTrend == -1 && g_btcRSI > g_SetBTC_RSI_Sell)
      {
         double sl = bid + slDist;
         double tp = bid - tpDist;
         if(g_trade.Sell(g_SetBTC_LotSize, _Symbol, bid, sl, tp, "BTC_MOM_SELL"))
         {
            g_btcTicket = g_trade.ResultOrder();
            g_btcEntrySL = slDist;
            g_btcHighWater = 0;
            g_btcPartialDone = false;
            Print("🟠 BTC SELL: RSI=", DoubleToString(g_btcRSI,1), " SL=", DoubleToString(sl,_Digits), " TP=", DoubleToString(tp,_Digits));
         }
      }
   }
   
   //--- 6) Update Dashboard
   UpdateBTCDashboard();
}

//+------------------------------------------------------------------+
//| ===== OnTimer() =====                                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   ScanOrders();
   SyncToWebApp();
}

//+------------------------------------------------------------------+
//| ===== ScanOrders() =====                                          |
//+------------------------------------------------------------------+
void ScanOrders()
{
   g_totalOrders = 0; g_buyOrders = 0; g_sellOrders = 0;
   g_totalLot = 0;    g_buyLot = 0;    g_sellLot = 0;
   g_totalProfit = 0; g_buyProfit = 0; g_sellProfit = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      long   type   = PositionGetInteger(POSITION_TYPE);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      
      g_totalOrders++;
      g_totalLot    += vol;
      g_totalProfit += profit;
      
      if(type == POSITION_TYPE_BUY)
      { g_buyOrders++; g_buyLot += vol; g_buyProfit += profit; }
      else
      { g_sellOrders++; g_sellLot += vol; g_sellProfit += profit; }
   }
}

//+------------------------------------------------------------------+
//| ===== NormalizeLot() =====                                        |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathMax(lot, minL);
   lot = MathMin(lot, maxL);
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| ===== Web Dashboard Sync =====                                    |
//+------------------------------------------------------------------+
string LOCAL_API_URL = "http://127.0.0.1:3000/api/ea-stats";

string GetDailyProfitsJSON()
{
   datetime endTime = TimeCurrent();
   datetime startTime = endTime - (14 * 24 * 60 * 60);
   if(!HistorySelect(startTime, endTime)) return "[]";
   
   string json = "[";
   int count = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != g_MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(sym != _Symbol) continue;
      
      long typeInt = HistoryDealGetInteger(ticket, DEAL_TYPE);
      string typeStr = (typeInt == DEAL_TYPE_BUY) ? "BUY_CLOSE" : "SELL_CLOSE";
      double vol = HistoryDealGetDouble(ticket, DEAL_VOLUME);
      double openPrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      datetime time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      string dateStr = TimeToString(time, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
      StringReplace(dateStr, ".", "-");
      
      if(count > 0) json += ",";
      json += StringFormat("{\"ticket\":%llu, \"symbol\":\"%s\", \"type\":\"%s\", \"volume\":%.2f, \"open_price\":%.5f, \"profit\":%.2f, \"date\":\"%s\"}",
                           ticket, sym, typeStr, vol, openPrice, profit, dateStr);
      count++;
   }
   json += "]";
   return json;
}

string GetActiveOrdersJSON()
{
   string json = "[";
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      string typeStr = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double vol = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      
      if(count > 0) json += ",";
      json += StringFormat("{\"ticket\":%llu, \"type\":\"%s\", \"volume\":%.2f, \"open_price\":%.5f, \"profit\":%.2f}",
                           ticket, typeStr, vol, openPrice, profit);
      count++;
   }
   json += "]";
   return json;
}

void SyncToWebApp()
{
   string headers = "Content-Type: application/json\r\n";
   string historyJson = GetDailyProfitsJSON();
   string activeOrdersJson = GetActiveOrdersJSON();
   
   string trendStr = (g_btcTrend == 1) ? "UP" : (g_btcTrend == -1) ? "DOWN" : "FLAT";
   
   // BTC position info
   string btcPosJson = "null";
   if(g_btcTicket > 0 && PositionSelectByTicket(g_btcTicket))
   {
      long posType = PositionGetInteger(POSITION_TYPE);
      string typeStr = (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double posProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double posLot = PositionGetDouble(POSITION_VOLUME);
      double posSL = PositionGetDouble(POSITION_SL);
      double posTP = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      
      btcPosJson = StringFormat("{\"ticket\":%llu, \"type\":\"%s\", \"lot\":%.2f, \"open_price\":%.5f, \"sl\":%.5f, \"tp\":%.5f, \"profit\":%.2f, \"partial_done\":%s, \"status\":\"%s\"}",
                                g_btcTicket, typeStr, posLot, openPrice, posSL, posTP, posProfit,
                                g_btcPartialDone ? "true" : "false",
                                g_btcPartialDone ? "TRAILING" : "ACTIVE");
   }
   
   // BTC settings
   string btcSettingsJson = StringFormat("{\"ema_fast\":%d, \"ema_slow\":%d, \"trend_tf\":%d, \"rsi_period\":%d, \"rsi_tf\":%d, \"rsi_buy\":%d, \"rsi_sell\":%d, \"risk_reward\":%.1f, \"atr_sl_mult\":%.1f, \"lot_size\":%.2f, \"trail_atr_mult\":%.1f, \"partial_tp\":%s}",
                                        g_SetBTC_EMA_Fast, g_SetBTC_EMA_Slow, g_SetBTC_TrendTF, g_SetBTC_RSI_Period, g_SetBTC_RSI_TF,
                                        g_SetBTC_RSI_Buy, g_SetBTC_RSI_Sell, g_SetBTC_RiskReward, g_SetBTC_ATR_SL_Mult,
                                        g_SetBTC_LotSize, g_SetBTC_TrailATRMult, g_SetBTC_PartialTP ? "true" : "false");
   
   string payload = StringFormat("{\"account_id\":\"%lld\", \"symbol\":\"%s\", \"strategy\":\"BTC_MOMENTUM\", \"ea_version\":\"%s\", \"ea_name\":\"%s\", \"equity\":%.2f, \"balance\":%.2f, \"total_profit\":%.2f, \"open_orders\":%d, \"trend_direction\":\"%s\", \"btc_ema50\":%.2f, \"btc_ema200\":%.2f, \"btc_rsi\":%.1f, \"btc_atr\":%.2f, \"btc_position\":%s, \"history\":%s, \"active_orders\":%s, \"ea_settings\":%s}",
                              AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, g_EAVersion, g_EAName, AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE), g_totalProfit, g_totalOrders, trendStr,
                              g_btcEMA50, g_btcEMA200, g_btcRSI, g_btcATR, btcPosJson, historyJson, activeOrdersJson, btcSettingsJson);
   
   char post[], result[];
   StringToCharArray(payload, post, 0, StringLen(payload));
   string resHeaders;
   
   int res = WebRequest("POST", LOCAL_API_URL, headers, 5000, post, result, resHeaders);
   
   if(res == 200 || res == 201)
   {
      string jsonResp = CharArrayToString(result);
      if(StringLen(jsonResp) > 10)
         ProcessCommands(jsonResp);
   }
}

//+------------------------------------------------------------------+
//| ===== Process Commands from Web Server =====                      |
//+------------------------------------------------------------------+
void ProcessCommands(string jsonResp)
{
   int actionIndex = StringFind(jsonResp, "\"action\":");
   while(actionIndex >= 0)
   {
      int actionStart = actionIndex + 10;
      int actionEnd = StringFind(jsonResp, "\"", actionStart);
      string actionStr = "";
      if(actionEnd > actionStart)
         actionStr = StringSubstr(jsonResp, actionStart, actionEnd - actionStart);
      
      int nextActionIdx = -1;

      if(actionStr == "update_settings")
      {
         int setIndex = StringFind(jsonResp, "\"settings\":", actionIndex);
         if(setIndex >= 0)
         {
            int idx;
            idx = StringFind(jsonResp, "\"btc_ema_fast\":", setIndex);
            if(idx > 0) g_SetBTC_EMA_Fast = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"btc_ema_slow\":", setIndex);
            if(idx > 0) g_SetBTC_EMA_Slow = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"btc_rsi_period\":", setIndex);
            if(idx > 0) g_SetBTC_RSI_Period = (int)StringToInteger(StringSubstr(jsonResp, idx+17, StringFind(jsonResp, ",", idx)-idx-17));
            idx = StringFind(jsonResp, "\"btc_rsi_buy\":", setIndex);
            if(idx > 0) g_SetBTC_RSI_Buy = (int)StringToInteger(StringSubstr(jsonResp, idx+14, StringFind(jsonResp, ",", idx)-idx-14));
            idx = StringFind(jsonResp, "\"btc_rsi_sell\":", setIndex);
            if(idx > 0) g_SetBTC_RSI_Sell = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"btc_risk_reward\":", setIndex);
            if(idx > 0) g_SetBTC_RiskReward = StringToDouble(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
            idx = StringFind(jsonResp, "\"btc_atr_sl_mult\":", setIndex);
            if(idx > 0) g_SetBTC_ATR_SL_Mult = StringToDouble(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
            idx = StringFind(jsonResp, "\"btc_lot_size\":", setIndex);
            if(idx > 0) g_SetBTC_LotSize = StringToDouble(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"btc_trail_atr_mult\":", setIndex);
            if(idx > 0) g_SetBTC_TrailATRMult = StringToDouble(StringSubstr(jsonResp, idx+21, StringFind(jsonResp, ",", idx)-idx-21));
            idx = StringFind(jsonResp, "\"btc_partial_tp\":", setIndex);
            if(idx > 0) g_SetBTC_PartialTP = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
            
            Print("✅ BTC Settings Synced with Web Server Successfully.");
         }
         nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      }
      else if(actionStr == "close_all")
      {
         Print("⚡ Dashboard: ปิดออเดอร์ทั้งหมด!");
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            if(ticket <= 0) continue;
            if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            g_trade.PositionClose(ticket);
         }
         g_btcTicket = 0;
         g_btcHighWater = 0;
         g_btcPartialDone = false;
         nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      }
      else if(actionStr == "close")
      {
         int ticketIndex = StringFind(jsonResp, "\"ticket\":", actionIndex);
         if(ticketIndex >= 0)
         {
            int startNum = ticketIndex + 9;
            int endNum = StringFind(jsonResp, "}", startNum);
            if(endNum < 0) endNum = StringFind(jsonResp, ",", startNum);
            if(endNum > startNum)
            {
               ulong targetTicket = (ulong)StringToInteger(StringSubstr(jsonResp, startNum, endNum - startNum));
               if(targetTicket > 0)
               {
                  Print("⚡ Dashboard: ปิดออเดอร์ #", targetTicket);
                  g_trade.PositionClose(targetTicket);
                  if(targetTicket == g_btcTicket)
                  {
                     g_btcTicket = 0;
                     g_btcHighWater = 0;
                     g_btcPartialDone = false;
                  }
               }
            }
            nextActionIdx = StringFind(jsonResp, "\"action\":", ticketIndex);
         }
         else
            nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      }
      else
         nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      
      actionIndex = nextActionIdx;
   }
}

//+------------------------------------------------------------------+
//| ===== BTC Dashboard on Chart =====                                |
//+------------------------------------------------------------------+
void UpdateBTCDashboard()
{
   string trendStr = (g_btcTrend == 1) ? "UP" : (g_btcTrend == -1) ? "DOWN" : "FLAT";
   
   string lines[15];
   color textColors[15];
   for(int c=0; c<15; c++) textColors[c] = C'220,220,230';
   
   int idx = 0;
   lines[idx] = "==== BTC MOMENTUM (" + _Symbol + ") ====";
   textColors[idx] = C'255,165,0'; idx++;
   
   lines[idx] = "Trend: " + trendStr;
   textColors[idx] = (g_btcTrend == 1) ? clrLime : (g_btcTrend == -1) ? clrRed : clrGray; idx++;
   
   lines[idx] = "EMA50: " + DoubleToString(g_btcEMA50, _Digits); idx++;
   lines[idx] = "EMA200: " + DoubleToString(g_btcEMA200, _Digits); idx++;
   lines[idx] = "RSI: " + DoubleToString(g_btcRSI, 1) + " | ATR: " + DoubleToString(g_btcATR, _Digits); idx++;
   
   if(g_btcTicket > 0 && PositionSelectByTicket(g_btcTicket))
   {
      long posType = PositionGetInteger(POSITION_TYPE);
      string typeStr = (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double posProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double posLot = PositionGetDouble(POSITION_VOLUME);
      double posSL = PositionGetDouble(POSITION_SL);
      double posTP = PositionGetDouble(POSITION_TP);
      
      lines[idx] = "---- Position ----";
      textColors[idx] = clrDodgerBlue; idx++;
      lines[idx] = typeStr + " " + DoubleToString(posLot, 2) + " lots";
      textColors[idx] = (posType == POSITION_TYPE_BUY) ? clrLime : clrRed; idx++;
      lines[idx] = "PnL: $" + DoubleToString(posProfit, 2);
      textColors[idx] = posProfit >= 0 ? clrLime : clrRed; idx++;
      lines[idx] = "SL: " + DoubleToString(posSL, _Digits) + " TP: " + DoubleToString(posTP, _Digits); idx++;
      string st = g_btcPartialDone ? "TRAILING" : "Active";
      lines[idx] = "Status: " + st; idx++;
   }
   else
   {
      lines[idx] = "---- No Position ----";
      textColors[idx] = clrGray; idx++;
      string sig = "Waiting...";
      if(g_btcTrend == 1) sig = "Up, RSI=" + DoubleToString(g_btcRSI,1) + " (need<" + IntegerToString(g_SetBTC_RSI_Buy) + ")";
      else if(g_btcTrend == -1) sig = "Dn, RSI=" + DoubleToString(g_btcRSI,1) + " (need>" + IntegerToString(g_SetBTC_RSI_Sell) + ")";
      lines[idx] = sig; idx++;
   }
   
   lines[idx] = "---- Active Settings ----";
   textColors[idx] = clrDodgerBlue; idx++;
   lines[idx] = "Lot:" + DoubleToString(g_SetBTC_LotSize,2) + " RR:1:" + DoubleToString(g_SetBTC_RiskReward,1) + " SL:" + DoubleToString(g_SetBTC_ATR_SL_Mult,1) + "xATR"; idx++;
   lines[idx] = "EMA: " + IntegerToString(g_SetBTC_EMA_Fast) + "/" + IntegerToString(g_SetBTC_EMA_Slow); idx++;
   lines[idx] = "RSI(" + IntegerToString(g_SetBTC_RSI_Period) + ") B<" + IntegerToString(g_SetBTC_RSI_Buy) + " S>" + IntegerToString(g_SetBTC_RSI_Sell); idx++;
   lines[idx] = "Trail: " + DoubleToString(g_SetBTC_TrailATRMult,1) + "xATR | Partial TP: " + (g_SetBTC_PartialTP ? "ON" : "OFF"); idx++;
   
   int totalLines = idx;
   
   int panelPadding = 8;
   int lineHeight = 18;
   int panelWidth = 400;
   int panelHeight = (totalLines * lineHeight) + (panelPadding * 2) + 4;
   if(panelHeight < 150) panelHeight = 150;
   
   string panelName = g_prefix + "PANEL_BG";
   if(ObjectFind(0, panelName) < 0) {
      ObjectCreate(0, panelName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, panelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, panelName, OBJPROP_XDISTANCE, 5);
      ObjectSetInteger(0, panelName, OBJPROP_YDISTANCE, 5);
      ObjectSetInteger(0, panelName, OBJPROP_BGCOLOR, C'15,15,25');
      ObjectSetInteger(0, panelName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, panelName, OBJPROP_BORDER_COLOR, C'255,140,0');
      ObjectSetInteger(0, panelName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, panelName, OBJPROP_BACK, false);
   }
   ObjectSetInteger(0, panelName, OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, panelName, OBJPROP_YSIZE, panelHeight);
   
   for(int i=0; i<totalLines; i++)
   {
      string lblName = g_prefix+"LBL_"+IntegerToString(i);
      if(ObjectFind(0, lblName) < 0) {
         ObjectCreate(0, lblName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, lblName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 10);
         ObjectSetString(0, lblName, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
      }
      ObjectSetInteger(0, lblName, OBJPROP_XDISTANCE, 5 + panelPadding);
      ObjectSetInteger(0, lblName, OBJPROP_YDISTANCE, 5 + panelPadding + (i * lineHeight));
      ObjectSetString(0, lblName, OBJPROP_TEXT, lines[i]);
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, textColors[i]);
   }
   
   for(int j=totalLines; j<30; j++)
   {
      string lblName = g_prefix+"LBL_"+IntegerToString(j);
      if(ObjectFind(0, lblName) >= 0) ObjectDelete(0, lblName);
   }
   
   ChartRedraw();
}
