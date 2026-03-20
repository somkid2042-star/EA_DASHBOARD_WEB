//+------------------------------------------------------------------+
//|                                                       X_XAU.mq5  |
//|         XAU Smart Trend Strategy                                  |
//+------------------------------------------------------------------+
#property copyright "X_XAU v2.0"
#property version   "2.00"
#property description "XAU Smart Trend — No Inputs, Web-Controlled, Real-time Sync"

#include <Trade\Trade.mqh>

// Magic Number
long g_MagicNumber = 20261111;

//+------------------------------------------------------------------+
//| ===== Global Variables =====                                       |
//+------------------------------------------------------------------+
CTrade   g_trade;

// Version
string g_EAVersion = "1.3.3";
string g_EAName    = "X_XAU";

//--- XAU Strategy Variables
int      g_xauHandleEMA21   = INVALID_HANDLE;
int      g_xauHandleEMA55   = INVALID_HANDLE;
int      g_xauHandleADX     = INVALID_HANDLE;
int      g_xauHandleRSI     = INVALID_HANDLE;
int      g_xauHandleATR     = INVALID_HANDLE;
double   g_xauEMA21 = 0, g_xauEMA55 = 0;
double   g_xauRSI = 0, g_xauATR = 0, g_xauADX = 0;
int      g_xauTrend = 0;            // 1=UP, -1=DOWN, 0=FLAT
ulong    g_xauTicket = 0;
double   g_xauEntrySL = 0;
double   g_xauHighWater = 0;
bool     g_xauPartialDone = false;

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

//--- XAU Settings (Defaults — overridden by web app)
int      g_SetXAU_EMA_Fast     = 21;
int      g_SetXAU_EMA_Slow     = 55;
ENUM_TIMEFRAMES g_SetXAU_TrendTF = PERIOD_H4;
int      g_SetXAU_ADX_Period   = 14;
int      g_SetXAU_ADX_Min      = 20;
int      g_SetXAU_RSI_Period   = 14;
ENUM_TIMEFRAMES g_SetXAU_RSI_TF  = PERIOD_H1;
int      g_SetXAU_RSI_Buy      = 40;
int      g_SetXAU_RSI_Sell     = 60;
double   g_SetXAU_RiskReward   = 2.0;
double   g_SetXAU_ATR_SL_Mult  = 2.0;
double   g_SetXAU_LotSize      = 0.01;
double   g_SetXAU_TrailATRMult = 1.5;
bool     g_SetXAU_PartialTP    = true;
int      g_SetXAU_SessionStart = 8;
int      g_SetXAU_SessionEnd   = 22;

//--- Dashboard
string   g_prefix        = "XAU_";

//+------------------------------------------------------------------+
//| ===== OnInit() =====                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== X_XAU v2.0 Smart Trend (Web-Controlled) ===");
   
   g_trade.SetExpertMagicNumber(g_MagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_xauHandleEMA21  = iMA(_Symbol, g_SetXAU_TrendTF, g_SetXAU_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_xauHandleEMA55  = iMA(_Symbol, g_SetXAU_TrendTF, g_SetXAU_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_xauHandleADX    = iADX(_Symbol, g_SetXAU_TrendTF, g_SetXAU_ADX_Period);
   g_xauHandleRSI    = iRSI(_Symbol, g_SetXAU_RSI_TF, g_SetXAU_RSI_Period, PRICE_CLOSE);
   g_xauHandleATR    = iATR(_Symbol, g_SetXAU_RSI_TF, 14);
   
   if(g_xauHandleEMA21 == INVALID_HANDLE || g_xauHandleEMA55 == INVALID_HANDLE ||
      g_xauHandleADX == INVALID_HANDLE || g_xauHandleRSI == INVALID_HANDLE || g_xauHandleATR == INVALID_HANDLE)
   {
      Print("❌ XAU indicator handles failed!");
      return INIT_FAILED;
   }
   g_xauTicket = 0;
   g_xauHighWater = 0;
   g_xauPartialDone = false;

   UpdateXAUDashboard();
   EventSetTimer(1);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| ===== OnDeinit() =====                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_xauHandleEMA21  != INVALID_HANDLE) IndicatorRelease(g_xauHandleEMA21);
   if(g_xauHandleEMA55  != INVALID_HANDLE) IndicatorRelease(g_xauHandleEMA55);
   if(g_xauHandleADX    != INVALID_HANDLE) IndicatorRelease(g_xauHandleADX);
   if(g_xauHandleRSI    != INVALID_HANDLE) IndicatorRelease(g_xauHandleRSI);
   if(g_xauHandleATR    != INVALID_HANDLE) IndicatorRelease(g_xauHandleATR);
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
}

//+------------------------------------------------------------------+
//| ===== OnTick() =====                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1) Read XAU Indicators
   double ema21[], ema55[], rsiArr[], atrArr[], adxArr[];
   if(CopyBuffer(g_xauHandleEMA21,  0, 0, 2, ema21) < 2) return;
   if(CopyBuffer(g_xauHandleEMA55,  0, 0, 2, ema55) < 2) return;
   if(CopyBuffer(g_xauHandleRSI,    0, 0, 2, rsiArr) < 2) return;
   if(CopyBuffer(g_xauHandleATR,    0, 0, 2, atrArr) < 2) return;
   if(CopyBuffer(g_xauHandleADX,    0, 0, 2, adxArr) < 2) return;
   
   g_xauEMA21 = ema21[0];
   g_xauEMA55 = ema55[0];
   g_xauRSI   = rsiArr[0];
   g_xauATR   = atrArr[0];
   g_xauADX   = adxArr[0];
   
   //--- 2) Determine H4 Trend (EMA21 vs EMA55)
   if(g_xauEMA21 > g_xauEMA55) g_xauTrend = 1;
   else if(g_xauEMA21 < g_xauEMA55) g_xauTrend = -1;
   else g_xauTrend = 0;
   
   //--- 3) Scan current positions
   ScanOrders();
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   //--- 4) Session Filter (London + NY)
   MqlDateTime dt;
   TimeGMT(dt);
   int gmtHour = dt.hour;
   bool inSession = (gmtHour >= g_SetXAU_SessionStart && gmtHour < g_SetXAU_SessionEnd);
   
   //--- 5) Check if our XAU ticket is still open
   bool hasPosition = false;
   if(g_xauTicket > 0)
   {
      if(PositionSelectByTicket(g_xauTicket))
      {
         hasPosition = true;
         double posProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(posProfit > g_xauHighWater) g_xauHighWater = posProfit;
         
         double slDist = g_xauEntrySL;
         double trailStep = g_xauATR * g_SetXAU_TrailATRMult;
         
         //--- Partial TP: close 50% at 1:1 RR level
         if(g_SetXAU_PartialTP && !g_xauPartialDone)
         {
            double tpDist = slDist * 1.0;
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
                  g_trade.PositionClosePartial(g_xauTicket, halfLot);
                  Print("🟡 XAU Partial TP: Closed ", DoubleToString(halfLot,2), " lots at 1:1 RR");
                  g_xauPartialDone = true;
                  if(posType == POSITION_TYPE_BUY)
                     g_trade.PositionModify(g_xauTicket, openPrice + _Point, 0);
                  else
                     g_trade.PositionModify(g_xauTicket, openPrice - _Point, 0);
               }
            }
         }
         
         //--- ATR Trailing Stop (after partial TP)
         if(g_xauPartialDone && trailStep > 0)
         {
            long posType = PositionGetInteger(POSITION_TYPE);
            double currentSL = PositionGetDouble(POSITION_SL);
            
            if(posType == POSITION_TYPE_BUY)
            {
               double newSL = bid - trailStep;
               if(newSL > currentSL && newSL > PositionGetDouble(POSITION_PRICE_OPEN))
                  g_trade.PositionModify(g_xauTicket, newSL, 0);
            }
            else
            {
               double newSL = ask + trailStep;
               if((newSL < currentSL || currentSL == 0) && newSL < PositionGetDouble(POSITION_PRICE_OPEN))
                  g_trade.PositionModify(g_xauTicket, newSL, 0);
            }
         }
      }
      else
      {
         g_xauTicket = 0;
         g_xauHighWater = 0;
         g_xauPartialDone = false;
      }
   }
   
   //--- 6) Entry Signal (no position open, in session, ADX confirms trend)
   if(!hasPosition && g_xauATR > 0 && inSession && g_xauADX >= g_SetXAU_ADX_Min)
   {
      double slDist = g_xauATR * g_SetXAU_ATR_SL_Mult;
      double tpDist = slDist * g_SetXAU_RiskReward;
      
      // BUY: Uptrend + ADX strong + RSI pullback
      if(g_xauTrend == 1 && g_xauRSI < g_SetXAU_RSI_Buy)
      {
         double sl = ask - slDist;
         double tp = ask + tpDist;
         if(g_trade.Buy(g_SetXAU_LotSize, _Symbol, ask, sl, tp, "XAU_TREND_BUY"))
         {
            g_xauTicket = g_trade.ResultOrder();
            g_xauEntrySL = slDist;
            g_xauHighWater = 0;
            g_xauPartialDone = false;
            Print("🟡 XAU BUY: EMA21=", DoubleToString(g_xauEMA21,_Digits), 
                  " ADX=", DoubleToString(g_xauADX,1), 
                  " RSI=", DoubleToString(g_xauRSI,1),
                  " SL=", DoubleToString(sl,_Digits), 
                  " TP=", DoubleToString(tp,_Digits));
         }
      }
      // SELL: Downtrend + ADX strong + RSI overbought
      else if(g_xauTrend == -1 && g_xauRSI > g_SetXAU_RSI_Sell)
      {
         double sl = bid + slDist;
         double tp = bid - tpDist;
         if(g_trade.Sell(g_SetXAU_LotSize, _Symbol, bid, sl, tp, "XAU_TREND_SELL"))
         {
            g_xauTicket = g_trade.ResultOrder();
            g_xauEntrySL = slDist;
            g_xauHighWater = 0;
            g_xauPartialDone = false;
            Print("🟡 XAU SELL: EMA21=", DoubleToString(g_xauEMA21,_Digits), 
                  " ADX=", DoubleToString(g_xauADX,1), 
                  " RSI=", DoubleToString(g_xauRSI,1),
                  " SL=", DoubleToString(sl,_Digits), 
                  " TP=", DoubleToString(tp,_Digits));
         }
      }
   }
   
   //--- 7) Update Dashboard
   UpdateXAUDashboard();
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
   
   string trendStr = (g_xauTrend == 1) ? "UP" : (g_xauTrend == -1) ? "DOWN" : "FLAT";
   
   // XAU position info
   string xauPosJson = "null";
   if(g_xauTicket > 0 && PositionSelectByTicket(g_xauTicket))
   {
      long posType = PositionGetInteger(POSITION_TYPE);
      string typeStr = (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double posProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double posLot = PositionGetDouble(POSITION_VOLUME);
      double posSL = PositionGetDouble(POSITION_SL);
      double posTP = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      
      xauPosJson = StringFormat("{\"ticket\":%llu, \"type\":\"%s\", \"lot\":%.2f, \"open_price\":%.5f, \"sl\":%.5f, \"tp\":%.5f, \"profit\":%.2f, \"partial_done\":%s, \"status\":\"%s\"}",
                                g_xauTicket, typeStr, posLot, openPrice, posSL, posTP, posProfit,
                                g_xauPartialDone ? "true" : "false",
                                g_xauPartialDone ? "TRAILING" : "ACTIVE");
   }
   
   // XAU settings
   string xauSettingsJson = StringFormat("{\"ema_fast\":%d, \"ema_slow\":%d, \"trend_tf\":%d, \"adx_period\":%d, \"adx_min\":%d, \"rsi_period\":%d, \"rsi_tf\":%d, \"rsi_buy\":%d, \"rsi_sell\":%d, \"risk_reward\":%.1f, \"atr_sl_mult\":%.1f, \"lot_size\":%.2f, \"trail_atr_mult\":%.1f, \"partial_tp\":%s, \"session_start\":%d, \"session_end\":%d}",
                                        g_SetXAU_EMA_Fast, g_SetXAU_EMA_Slow, g_SetXAU_TrendTF, g_SetXAU_ADX_Period, g_SetXAU_ADX_Min,
                                        g_SetXAU_RSI_Period, g_SetXAU_RSI_TF, g_SetXAU_RSI_Buy, g_SetXAU_RSI_Sell,
                                        g_SetXAU_RiskReward, g_SetXAU_ATR_SL_Mult, g_SetXAU_LotSize, g_SetXAU_TrailATRMult,
                                        g_SetXAU_PartialTP ? "true" : "false", g_SetXAU_SessionStart, g_SetXAU_SessionEnd);
   
   string payload = StringFormat("{\"account_id\":\"%lld\", \"symbol\":\"%s\", \"strategy\":\"XAU_TREND\", \"ea_version\":\"%s\", \"ea_name\":\"%s\", \"equity\":%.2f, \"balance\":%.2f, \"total_profit\":%.2f, \"open_orders\":%d, \"trend_direction\":\"%s\", \"xau_ema21\":%.2f, \"xau_ema55\":%.2f, \"xau_adx\":%.1f, \"xau_rsi\":%.1f, \"xau_atr\":%.2f, \"xau_position\":%s, \"history\":%s, \"active_orders\":%s, \"ea_settings\":%s}",
                              AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, g_EAVersion, g_EAName, AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE), g_totalProfit, g_totalOrders, trendStr,
                              g_xauEMA21, g_xauEMA55, g_xauADX, g_xauRSI, g_xauATR, xauPosJson, historyJson, activeOrdersJson, xauSettingsJson);
   
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
            idx = StringFind(jsonResp, "\"xau_ema_fast\":", setIndex);
            if(idx > 0) g_SetXAU_EMA_Fast = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"xau_ema_slow\":", setIndex);
            if(idx > 0) g_SetXAU_EMA_Slow = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"xau_adx_period\":", setIndex);
            if(idx > 0) g_SetXAU_ADX_Period = (int)StringToInteger(StringSubstr(jsonResp, idx+17, StringFind(jsonResp, ",", idx)-idx-17));
            idx = StringFind(jsonResp, "\"xau_adx_min\":", setIndex);
            if(idx > 0) g_SetXAU_ADX_Min = (int)StringToInteger(StringSubstr(jsonResp, idx+14, StringFind(jsonResp, ",", idx)-idx-14));
            idx = StringFind(jsonResp, "\"xau_rsi_period\":", setIndex);
            if(idx > 0) g_SetXAU_RSI_Period = (int)StringToInteger(StringSubstr(jsonResp, idx+17, StringFind(jsonResp, ",", idx)-idx-17));
            idx = StringFind(jsonResp, "\"xau_rsi_buy\":", setIndex);
            if(idx > 0) g_SetXAU_RSI_Buy = (int)StringToInteger(StringSubstr(jsonResp, idx+14, StringFind(jsonResp, ",", idx)-idx-14));
            idx = StringFind(jsonResp, "\"xau_rsi_sell\":", setIndex);
            if(idx > 0) g_SetXAU_RSI_Sell = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"xau_risk_reward\":", setIndex);
            if(idx > 0) g_SetXAU_RiskReward = StringToDouble(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
            idx = StringFind(jsonResp, "\"xau_atr_sl_mult\":", setIndex);
            if(idx > 0) g_SetXAU_ATR_SL_Mult = StringToDouble(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
            idx = StringFind(jsonResp, "\"xau_lot_size\":", setIndex);
            if(idx > 0) g_SetXAU_LotSize = StringToDouble(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"xau_trail_atr_mult\":", setIndex);
            if(idx > 0) g_SetXAU_TrailATRMult = StringToDouble(StringSubstr(jsonResp, idx+21, StringFind(jsonResp, ",", idx)-idx-21));
            idx = StringFind(jsonResp, "\"xau_partial_tp\":", setIndex);
            if(idx > 0) g_SetXAU_PartialTP = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
            idx = StringFind(jsonResp, "\"xau_session_start\":", setIndex);
            if(idx > 0) g_SetXAU_SessionStart = (int)StringToInteger(StringSubstr(jsonResp, idx+20, StringFind(jsonResp, ",", idx)-idx-20));
            idx = StringFind(jsonResp, "\"xau_session_end\":", setIndex);
            if(idx > 0) g_SetXAU_SessionEnd = (int)StringToInteger(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
            
            Print("✅ XAU Settings Synced with Web Server Successfully.");
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
         g_xauTicket = 0;
         g_xauHighWater = 0;
         g_xauPartialDone = false;
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
                  if(targetTicket == g_xauTicket)
                  {
                     g_xauTicket = 0;
                     g_xauHighWater = 0;
                     g_xauPartialDone = false;
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
//| ===== XAU Dashboard on Chart =====                                |
//+------------------------------------------------------------------+
void UpdateXAUDashboard()
{
   string trendStr = (g_xauTrend == 1) ? "UP" : (g_xauTrend == -1) ? "DOWN" : "FLAT";
   
   MqlDateTime dt;
   TimeGMT(dt);
   int gmtHour = dt.hour;
   bool inSession = (gmtHour >= g_SetXAU_SessionStart && gmtHour < g_SetXAU_SessionEnd);
   
   string lines[25];
   color textColors[25];
   for(int c=0; c<25; c++) textColors[c] = C'220,220,230';
   
   int idx = 0;
   lines[idx] = "==== XAU SMART TREND (" + _Symbol + ") ====";
   textColors[idx] = C'255,215,0'; idx++;
   
   lines[idx] = "Trend: " + trendStr;
   textColors[idx] = (g_xauTrend == 1) ? clrLime : (g_xauTrend == -1) ? clrRed : clrGray; idx++;
   
   lines[idx] = "EMA21: " + DoubleToString(g_xauEMA21, _Digits) + " | EMA55: " + DoubleToString(g_xauEMA55, _Digits); idx++;
   lines[idx] = "ADX: " + DoubleToString(g_xauADX, 1) + " (min " + IntegerToString(g_SetXAU_ADX_Min) + ")";
   textColors[idx] = (g_xauADX >= g_SetXAU_ADX_Min) ? clrLime : clrOrangeRed; idx++;
   lines[idx] = "RSI: " + DoubleToString(g_xauRSI, 1) + " | ATR: " + DoubleToString(g_xauATR, _Digits); idx++;
   
   lines[idx] = "Session: " + (inSession ? "ACTIVE (London+NY)" : "CLOSED");
   textColors[idx] = inSession ? clrLime : clrGray; idx++;
   
   if(g_xauTicket > 0 && PositionSelectByTicket(g_xauTicket))
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
      string st = g_xauPartialDone ? "TRAILING" : "Active";
      lines[idx] = "Status: " + st; idx++;
   }
   else
   {
      lines[idx] = "---- No Position ----";
      textColors[idx] = clrGray; idx++;
      string sig = "Waiting...";
      if(!inSession) sig = "Session closed";
      else if(g_xauADX < g_SetXAU_ADX_Min) sig = "ADX too low (" + DoubleToString(g_xauADX,1) + ")";
      else if(g_xauTrend == 1) sig = "Up, RSI=" + DoubleToString(g_xauRSI,1) + " (need<" + IntegerToString(g_SetXAU_RSI_Buy) + ")";
      else if(g_xauTrend == -1) sig = "Dn, RSI=" + DoubleToString(g_xauRSI,1) + " (need>" + IntegerToString(g_SetXAU_RSI_Sell) + ")";
      lines[idx] = sig; idx++;
   }
   
   lines[idx] = "---- Active Settings ----";
   textColors[idx] = clrDodgerBlue; idx++;
   lines[idx] = "Lot:" + DoubleToString(g_SetXAU_LotSize,2) + " RR:1:" + DoubleToString(g_SetXAU_RiskReward,1) + " SL:" + DoubleToString(g_SetXAU_ATR_SL_Mult,1) + "xATR"; idx++;
   lines[idx] = "EMA: " + IntegerToString(g_SetXAU_EMA_Fast) + "/" + IntegerToString(g_SetXAU_EMA_Slow) + " | ADX>" + IntegerToString(g_SetXAU_ADX_Min); idx++;
   lines[idx] = "RSI(" + IntegerToString(g_SetXAU_RSI_Period) + ") B<" + IntegerToString(g_SetXAU_RSI_Buy) + " S>" + IntegerToString(g_SetXAU_RSI_Sell); idx++;
   lines[idx] = "Trail: " + DoubleToString(g_SetXAU_TrailATRMult,1) + "xATR | Partial TP: " + (g_SetXAU_PartialTP ? "ON" : "OFF"); idx++;
   lines[idx] = "Session: " + IntegerToString(g_SetXAU_SessionStart) + ":00 - " + IntegerToString(g_SetXAU_SessionEnd) + ":00 GMT"; idx++;
   
   int totalLines = idx;
   
   int panelPadding = 8;
   int lineHeight = 18;
   int panelWidth = 420;
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
      ObjectSetInteger(0, panelName, OBJPROP_BORDER_COLOR, C'255,215,0');
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
