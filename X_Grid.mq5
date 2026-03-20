//+------------------------------------------------------------------+
//|                                                      X_Grid.mq5  |
//|         Smart Grid EA — Web Dashboard Controlled                  |
//+------------------------------------------------------------------+
#property copyright "X_Grid v2.0"
#property version   "2.00"
#property description "Smart Grid — No Inputs, Web-Controlled, Real-time Sync"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ===== Enums =====                                                 |
//+------------------------------------------------------------------+
enum ENUM_TP_MODE
{
   TP_MODE_BASKET, // TP แบบรวบยอดทั้งตระกร้า
   TP_MODE_SINGLE  // TP แยกตามแต่ละออเดอร์
};

// Magic Number
long g_MagicNumber = 20261111;

//+------------------------------------------------------------------+
//| ===== Global Variables =====                                       |
//+------------------------------------------------------------------+
CTrade   g_trade;

// Version
string g_EAVersion = "1.5.0";
string g_EAName    = "X_Grid";
int      g_handleEmaFast = INVALID_HANDLE;
int      g_handleEmaSlow = INVALID_HANDLE;
int      g_handleATR     = INVALID_HANDLE;
int      g_handleRSI     = INVALID_HANDLE;

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

//--- Basket Trailing Stop Logic (USD logic)
double   g_highestProfitUSD = 0;
double   g_maxDrawdownPct   = 0;

//--- Trend & Indicators
int      g_trendDir       = 0;
double   g_emaFastVal     = 0;
double   g_emaSlowVal     = 0;
double   g_currentATR     = 0;
double   g_currentRSI     = 0;
double   g_currentGridStepPt = 0;

//--- Hedge & Recovery State
bool     g_isHedged         = false;
int      g_hedgeDirection   = 0;
int      g_prevTrendDir     = 0;
bool     g_SetUseAutoHedge;
double   g_SetHedgeMaxDDPct;
bool     g_SetUseReverseGrid;
double   g_SetRecoveryTargetUSD;

//--- Smart Grid: Cooldown & Protection
datetime g_lastCloseTime    = 0;
int      g_cooldownSeconds  = 30;

//--- Dynamic Settings (Defaults — overridden by web app)
double   g_SetStartLot        = 0.01;
double   g_SetLotMultiplier   = 1.5;
int      g_SetMaxLevels       = 10;
ENUM_TP_MODE g_SetTPMode      = TP_MODE_BASKET;
double   g_SetTakeProfitUSD   = 10.0;
bool     g_SetUseDynamicStep  = true;
double   g_SetFixedGridStep   = 200;
int      g_SetATRPeriod       = 14;
double   g_SetATRMultiplier   = 1.0;
bool     g_SetUseTrendFilter  = true;
int      g_SetEmaFast         = 21;
int      g_SetEmaSlow         = 50;
int      g_SetRSIPeriod       = 14;
ENUM_TIMEFRAMES g_SetRSITF    = PERIOD_M15;
int      g_SetRSIBuyLevel     = 30;
int      g_SetRSISellLevel    = 70;
bool     g_SetUseBasketTrail  = true;
double   g_SetBasketTrailStartUSD = 5.0;
double   g_SetBasketTrailStepUSD  = 2.0;
ENUM_TIMEFRAMES g_SetTrendTF  = PERIOD_H1;

//--- Dashboard
string   g_prefix        = "GRID_";

//+------------------------------------------------------------------+
//| ===== OnInit() =====                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== X_Grid v2.0 Smart Grid (Web-Controlled) ===");
   
   g_trade.SetExpertMagicNumber(g_MagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   g_SetUseAutoHedge      = true;
   g_SetHedgeMaxDDPct     = 50.0;
   g_SetUseReverseGrid    = true;
   g_SetRecoveryTargetUSD = 0.0;
   g_lastCloseTime        = 0;
   
   g_highestProfitUSD = 0;
   g_maxDrawdownPct = 0;
   g_currentGridStepPt = g_SetFixedGridStep * _Point;
   g_isHedged           = false;
   g_hedgeDirection     = 0;
   g_prevTrendDir       = 0;

   g_handleEmaFast = iMA(_Symbol, g_SetTrendTF, g_SetEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEmaSlow = iMA(_Symbol, g_SetTrendTF, g_SetEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_handleATR     = iATR(_Symbol, g_SetTrendTF, g_SetATRPeriod);
   g_handleRSI     = iRSI(_Symbol, g_SetRSITF, g_SetRSIPeriod, PRICE_CLOSE);
   
   if(g_handleEmaFast == INVALID_HANDLE || g_handleEmaSlow == INVALID_HANDLE || g_handleATR == INVALID_HANDLE || g_handleRSI == INVALID_HANDLE)
   {
      Print("❌ สร้าง Handles ล้มเหลว!");
      return INIT_FAILED;
   }

   UpdateDashboardOnChart();
   EventSetTimer(1);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| ===== OnDeinit() =====                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_handleEmaFast != INVALID_HANDLE) IndicatorRelease(g_handleEmaFast);
   if(g_handleEmaSlow != INVALID_HANDLE) IndicatorRelease(g_handleEmaSlow);
   if(g_handleATR     != INVALID_HANDLE) IndicatorRelease(g_handleATR);
   if(g_handleRSI     != INVALID_HANDLE) IndicatorRelease(g_handleRSI);
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
}

//+------------------------------------------------------------------+
//| ===== OnTick() =====                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1) Update Indicators
   UpdateIndicators();
   
   //--- 1.5) Spread Filter
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double maxSpread = g_currentGridStepPt * 0.3;
   bool spreadTooWide = (maxSpread > 0 && spread > maxSpread);
   
   //--- 2) สแกนออเดอร์
   ScanOrders();
   
   //--- 3) คำนวณ Grid Step
   CalculateGridStep();
   
   //--- 3.5) คำนวณ Max Drawdown
   double floating = AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE);
   if(AccountInfoDouble(ACCOUNT_BALANCE) > 0 && floating < 0)
   {
      double currentDD = (MathAbs(floating) / AccountInfoDouble(ACCOUNT_BALANCE)) * 100.0;
      if(currentDD > g_maxDrawdownPct) g_maxDrawdownPct = currentDD;
   }
   
   UpdateDashboardOnChart();

   //--- 4) Risk Management: TP / SL รวบตระกร้า
   if(g_totalOrders > 0)
   {
      if(g_SetTakeProfitUSD > 0)
      {
         if(g_SetTPMode == TP_MODE_BASKET)
         {
            if(g_totalProfit >= g_SetTakeProfitUSD)
            {
               Print("💰 กำไรรวมเป้าหมายแตะ TP ($", DoubleToString(g_totalProfit,2), ") → ปิดตระกร้ารวบยอด");
               CloseAllOrders();
               g_highestProfitUSD = 0;
               return;
            }
         }
         else if(g_SetTPMode == TP_MODE_SINGLE)
         {
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket <= 0) continue;
               if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
               if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
               
               double orderProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
               if(orderProfit >= g_SetTakeProfitUSD)
               {
                  Print("🎯 ออเดอร์ #", ticket, " แตะ TP เดี่ยว ($", DoubleToString(orderProfit,2), ") → ปิดเฉพาะออเดอร์นี้");
                  g_trade.PositionClose(ticket);
               }
            }
            ScanOrders(); 
            if(g_totalOrders == 0) g_highestProfitUSD = 0;
         }
      }
      
      // --- Trailing Stop ตระกร้า ---
      if(g_SetUseBasketTrail)
      {
         if(g_totalProfit > g_highestProfitUSD)
            g_highestProfitUSD = g_totalProfit;
         
         if(g_highestProfitUSD >= g_SetBasketTrailStartUSD)
         {
            double lockLevel = g_highestProfitUSD - g_SetBasketTrailStepUSD;
            if(lockLevel > 0 && g_totalProfit <= lockLevel)
            {
               Print("🛡️ Basket Trailing Stop ทํางาน Lock กำไรไว้ที่ $", DoubleToString(g_totalProfit,2), " (Max was $", DoubleToString(g_highestProfitUSD,2), ")");
               CloseAllOrders();
               g_highestProfitUSD = 0;
               return;
            }
         }
      }
   }
   else
   {
      g_highestProfitUSD = 0;
      g_maxDrawdownPct = 0;
   }

   //--- 5) Hedge & Recovery Logic
   if(g_isHedged)
   {
      double recoveryTarget = g_SetRecoveryTargetUSD > 0 ? g_SetRecoveryTargetUSD : g_SetTakeProfitUSD;
      if(g_totalProfit >= recoveryTarget && recoveryTarget > 0)
      {
         Print("Recovery OK! Total Profit $", DoubleToString(g_totalProfit,2), " >= Target $", DoubleToString(recoveryTarget,2));
         CloseAllOrders();
         g_isHedged = false;
         g_hedgeDirection = 0;
         g_highestProfitUSD = 0;
         return;
      }
      
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance > 0)
      {
         double ddPct = MathAbs(g_totalProfit) / balance * 100.0;
         if(g_totalProfit < 0 && ddPct >= g_SetHedgeMaxDDPct)
         {
            Print("CUT LOSS! Drawdown ", DoubleToString(ddPct,2), "% >= ", DoubleToString(g_SetHedgeMaxDDPct,2), "% -> Close All");
            CloseAllOrders();
            g_isHedged = false;
            g_hedgeDirection = 0;
            g_highestProfitUSD = 0;
            return;
         }
      }
      
      if(g_SetUseReverseGrid)
      {
         if(g_hedgeDirection == -1 && g_buyOrders > 0)
            CheckGridExpansion();
         else if(g_hedgeDirection == 1 && g_sellOrders > 0)
            CheckGridExpansion();
      }
   }
   else
   {
      if(g_totalOrders > 0 && g_SetUseAutoHedge)
      {
         int reversal = DetectTrendReversal();
         if(reversal != 0)
         {
            if(reversal == -1 && g_buyOrders > 0 && g_sellOrders == 0)
            {
               Print("Trend Reversal! UP->DOWN | BUY open: ", g_buyOrders, " -> Hedge SELL");
               ExecuteAutoHedge(-1);
            }
            else if(reversal == 1 && g_sellOrders > 0 && g_buyOrders == 0)
            {
               Print("Trend Reversal! DOWN->UP | SELL open: ", g_sellOrders, " -> Hedge BUY");
               ExecuteAutoHedge(1);
            }
         }
      }
      
      if(g_totalOrders == 0)
         OpenFirstOrder();
      else if(!g_isHedged && !spreadTooWide)
         CheckGridExpansion();
   }
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
//| ===== UpdateIndicators() =====                                    |
//+------------------------------------------------------------------+
void UpdateIndicators()
{
   double fast[1], slow[1], atr[1], rsi[1];
   if(CopyBuffer(g_handleEmaFast, 0, 0, 1, fast) == 1) g_emaFastVal = fast[0];
   if(CopyBuffer(g_handleEmaSlow, 0, 0, 1, slow) == 1) g_emaSlowVal = slow[0];
   if(CopyBuffer(g_handleATR, 0, 0, 1, atr) == 1) g_currentATR = atr[0];
   if(CopyBuffer(g_handleRSI, 0, 0, 1, rsi) == 1) g_currentRSI = rsi[0];
   
   if(g_emaFastVal > g_emaSlowVal) g_trendDir = 1;
   else if(g_emaFastVal < g_emaSlowVal) g_trendDir = -1;
   else g_trendDir = 0;
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
      {
         g_buyOrders++;
         g_buyLot    += vol;
         g_buyProfit += profit;
      }
      else
      {
         g_sellOrders++;
         g_sellLot    += vol;
         g_sellProfit += profit;
      }
   }
}

//+------------------------------------------------------------------+
//| ===== CalculateGridStep() =====                                   |
//+------------------------------------------------------------------+
void CalculateGridStep()
{
   if(!g_SetUseDynamicStep) 
      g_currentGridStepPt = g_SetFixedGridStep * _Point;
   else 
   {
      if(g_currentATR > 0)
         g_currentGridStepPt = g_currentATR * g_SetATRMultiplier;
      else 
         g_currentGridStepPt = g_SetFixedGridStep * _Point;
   }
}

//+------------------------------------------------------------------+
//| ===== OpenFirstOrder() =====                                      |
//+------------------------------------------------------------------+
void OpenFirstOrder()
{
   if(g_lastCloseTime > 0 && (TimeCurrent() - g_lastCloseTime) < g_cooldownSeconds)
      return;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > 0)
   {
      double maxFloatLoss = balance * (g_SetHedgeMaxDDPct / 100.0) * 0.5;
      if(g_totalProfit < -maxFloatLoss)
         return;
   }
   
   bool doBuy = false;
   bool doSell = false;
   
   if(g_SetUseTrendFilter)
   {
      if(g_trendDir == 1) doBuy = true;
      else if(g_trendDir == -1) doSell = true;
   }
   else
      doBuy = true;
   
   if(!doBuy && !doSell) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = g_SetStartLot;
   
   if(!IsTradeAllowedSafe(lot)) return;
   
   if(doBuy)
   {
      g_trade.Buy(lot, _Symbol, ask, 0, 0, "GRID L1 BUY");
      Print("✅ เปิดไม้แรก BUY L1 | Lot: ", lot, " | RSI: ", DoubleToString(g_currentRSI,1));
   }
   else if(doSell)
   {
      g_trade.Sell(lot, _Symbol, bid, 0, 0, "GRID L1 SELL");
      Print("✅ เปิดไม้แรก SELL L1 | Lot: ", lot, " | RSI: ", DoubleToString(g_currentRSI,1));
   }
}

//+------------------------------------------------------------------+
//| ===== IsTradeAllowedSafe() =====                                 |
//+------------------------------------------------------------------+
bool IsTradeAllowedSafe(double reqLot)
{
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode != SYMBOL_TRADE_MODE_FULL)
   {
      Print("⚠️ Market is Closed/Restricted for ", _Symbol);
      return false;
   }
   
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginRequired = 0;
   
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, reqLot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired))
   {
      Print("⚠️ Failed to calculate margin for lot: ", reqLot);
      return false;
   }
   
   if(freeMargin < marginRequired)
   {
      Print("⚠️ Insufficient Margin! Free: $", DoubleToString(freeMargin,2), " | Required: $", DoubleToString(marginRequired,2));
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| ===== CheckGridExpansion() =====                                  |
//+------------------------------------------------------------------+
void CheckGridExpansion()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double lowestBuyPrice  = 1e10;
   double highestSellPrice = 0;
   double lastBuyLot      = 0;
   double lastSellLot     = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      long   type  = PositionGetInteger(POSITION_TYPE);
      double oPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double oVol   = PositionGetDouble(POSITION_VOLUME);
      
      if(type == POSITION_TYPE_BUY && oPrice < lowestBuyPrice) {
         lowestBuyPrice = oPrice;
         lastBuyLot = oVol;
      }
      if(type == POSITION_TYPE_SELL && oPrice > highestSellPrice) {
         highestSellPrice = oPrice;
         lastSellLot = oVol;
      }
   }
   
   if(g_buyOrders > 0 && g_buyOrders < g_SetMaxLevels && lowestBuyPrice < 1e10)
   {
      double dist = lowestBuyPrice - ask;
      if(dist >= g_currentGridStepPt)
      {
         double lot = NormalizeLot(lastBuyLot * g_SetLotMultiplier);
         if(IsTradeAllowedSafe(lot))
         {
             if(g_trade.Buy(lot, _Symbol, ask, 0, 0, "GRID L"+IntegerToString(g_buyOrders+1)+" BUY"))
                Print("📉 ราคาลงหลุดกริด → ถัว BUY | Lot: ", lot);
         }
      }
   }
   
   if(g_sellOrders > 0 && g_sellOrders < g_SetMaxLevels && highestSellPrice > 0)
   {
      double dist = bid - highestSellPrice;
      if(dist >= g_currentGridStepPt)
      {
         double lot = NormalizeLot(lastSellLot * g_SetLotMultiplier);
         if(IsTradeAllowedSafe(lot))
         {
             if(g_trade.Sell(lot, _Symbol, bid, 0, 0, "GRID L"+IntegerToString(g_sellOrders+1)+" SELL"))
                Print("📈 ราคาขึ้นทะลุกริด → ถัว SELL | Lot: ", lot);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ===== CloseAllOrders() =====                                      |
//+------------------------------------------------------------------+
void CloseAllOrders()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      g_trade.PositionClose(ticket);
   }
   g_lastCloseTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| ===== DetectTrendReversal() =====                                 |
//+------------------------------------------------------------------+
int DetectTrendReversal()
{
   if(g_prevTrendDir == 0)
   {
      g_prevTrendDir = g_trendDir;
      return 0;
   }
   
   int result = 0;
   
   if(g_prevTrendDir == 1 && g_trendDir == -1 && g_currentRSI > 50)
   {
      result = -1;
      Print("Trend Reversal Confirmed: EMA Cross DOWN + RSI=", DoubleToString(g_currentRSI,1));
   }
   else if(g_prevTrendDir == -1 && g_trendDir == 1 && g_currentRSI < 50)
   {
      result = 1;
      Print("Trend Reversal Confirmed: EMA Cross UP + RSI=", DoubleToString(g_currentRSI,1));
   }
   
   g_prevTrendDir = g_trendDir;
   return result;
}

//+------------------------------------------------------------------+
//| ===== ExecuteAutoHedge() =====                                    |
//+------------------------------------------------------------------+
void ExecuteAutoHedge(int direction)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(direction == -1)
   {
      double hedgeLot = NormalizeLot(g_buyLot);
      if(hedgeLot <= 0) return;
      if(!IsTradeAllowedSafe(hedgeLot)) return;
      
      if(g_trade.Sell(hedgeLot, _Symbol, bid, 0, 0, "HEDGE SELL LOCK"))
      {
         Print("Hedge SELL opened | Lot: ", hedgeLot);
         g_isHedged = true;
         g_hedgeDirection = -1;
         
         if(g_SetUseReverseGrid)
         {
            double revLot = g_SetStartLot;
            if(IsTradeAllowedSafe(revLot))
            {
               g_trade.Sell(revLot, _Symbol, bid, 0, 0, "REVERSE GRID L1 SELL");
               Print("Reverse Grid SELL L1 opened | Lot: ", revLot);
            }
         }
      }
   }
   else if(direction == 1)
   {
      double hedgeLot = NormalizeLot(g_sellLot);
      if(hedgeLot <= 0) return;
      if(!IsTradeAllowedSafe(hedgeLot)) return;
      
      if(g_trade.Buy(hedgeLot, _Symbol, ask, 0, 0, "HEDGE BUY LOCK"))
      {
         Print("Hedge BUY opened | Lot: ", hedgeLot);
         g_isHedged = true;
         g_hedgeDirection = 1;
         
         if(g_SetUseReverseGrid)
         {
            double revLot = g_SetStartLot;
            if(IsTradeAllowedSafe(revLot))
            {
               g_trade.Buy(revLot, _Symbol, ask, 0, 0, "REVERSE GRID L1 BUY");
               Print("Reverse Grid BUY L1 opened | Lot: ", revLot);
            }
         }
      }
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
      
      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(magic != g_MagicNumber) continue;
      
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;
      
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
      
      long typeInt = PositionGetInteger(POSITION_TYPE);
      string typeStr = (typeInt == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      
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
   
   string trendStr = (g_trendDir == 1) ? "UP" : (g_trendDir == -1) ? "DOWN" : "SIDEWAYS";
   
   string settingsJson = StringFormat("{\"start_lot\":%.2f, \"lot_multiplier\":%.2f, \"max_levels\":%d, \"tp_mode\":%d, \"tp_usd\":%.2f, \"use_dynamic_step\":%s, \"grid_step\":%.2f, \"atr_period\":%d, \"atr_multiplier\":%.2f, \"use_trend_filter\":%s, \"ema_fast\":%d, \"ema_slow\":%d, \"rsi_period\":%d, \"rsi_tf\":%d, \"rsi_buy\":%d, \"rsi_sell\":%d, \"use_basket_trail\":%s, \"trail_start\":%.2f, \"trail_step\":%.2f}",
                                     g_SetStartLot, g_SetLotMultiplier, g_SetMaxLevels, g_SetTPMode, g_SetTakeProfitUSD, 
                                     g_SetUseDynamicStep ? "true" : "false", g_SetFixedGridStep, g_SetATRPeriod, g_SetATRMultiplier,
                                     g_SetUseTrendFilter ? "true" : "false", g_SetEmaFast, g_SetEmaSlow, g_SetRSIPeriod, g_SetRSITF, 
                                     g_SetRSIBuyLevel, g_SetRSISellLevel, g_SetUseBasketTrail ? "true" : "false", 
                                     g_SetBasketTrailStartUSD, g_SetBasketTrailStepUSD);
   
   string payload = StringFormat("{\"account_id\":\"%lld\", \"symbol\":\"%s\", \"strategy\":\"GRID\", \"ea_version\":\"%s\", \"ea_name\":\"%s\", \"equity\":%.2f, \"balance\":%.2f, \"total_profit\":%.2f, \"open_orders\":%d, \"trend_direction\":\"%s\", \"max_dd\":%.2f, \"is_hedged\":%s, \"hedge_direction\":%d, \"history\":%s, \"active_orders\":%s, \"ea_settings\":%s}",
                              AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, g_EAVersion, g_EAName, AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE), g_totalProfit, g_totalOrders, trendStr, g_maxDrawdownPct, g_isHedged ? "true" : "false", g_hedgeDirection, historyJson, activeOrdersJson, settingsJson);
   
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
            idx = StringFind(jsonResp, "\"start_lot\":", setIndex);
            if(idx > 0) g_SetStartLot = StringToDouble(StringSubstr(jsonResp, idx+12, StringFind(jsonResp, ",", idx)-idx-12));
            idx = StringFind(jsonResp, "\"lot_multiplier\":", setIndex);
            if(idx > 0) g_SetLotMultiplier = StringToDouble(StringSubstr(jsonResp, idx+17, StringFind(jsonResp, ",", idx)-idx-17));
            idx = StringFind(jsonResp, "\"max_levels\":", setIndex);
            if(idx > 0) g_SetMaxLevels = (int)StringToInteger(StringSubstr(jsonResp, idx+13, StringFind(jsonResp, ",", idx)-idx-13));
            idx = StringFind(jsonResp, "\"tp_mode\":", setIndex);
            if(idx > 0) g_SetTPMode = (ENUM_TP_MODE)StringToInteger(StringSubstr(jsonResp, idx+10, StringFind(jsonResp, ",", idx)-idx-10));
            idx = StringFind(jsonResp, "\"tp_usd\":", setIndex);
            if(idx > 0) g_SetTakeProfitUSD = StringToDouble(StringSubstr(jsonResp, idx+9, StringFind(jsonResp, ",", idx)-idx-9));
            idx = StringFind(jsonResp, "\"use_dynamic_step\":", setIndex);
            if(idx > 0) g_SetUseDynamicStep = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
            idx = StringFind(jsonResp, "\"grid_step\":", setIndex);
            if(idx > 0) g_SetFixedGridStep = StringToDouble(StringSubstr(jsonResp, idx+12, StringFind(jsonResp, ",", idx)-idx-12));
            idx = StringFind(jsonResp, "\"atr_period\":", setIndex);
            if(idx > 0) g_SetATRPeriod = (int)StringToInteger(StringSubstr(jsonResp, idx+13, StringFind(jsonResp, ",", idx)-idx-13));
            idx = StringFind(jsonResp, "\"atr_multiplier\":", setIndex);
            if(idx > 0) g_SetATRMultiplier = StringToDouble(StringSubstr(jsonResp, idx+17, StringFind(jsonResp, ",", idx)-idx-17));
            idx = StringFind(jsonResp, "\"use_trend_filter\":", setIndex);
            if(idx > 0) g_SetUseTrendFilter = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
            idx = StringFind(jsonResp, "\"ema_fast\":", setIndex);
            if(idx > 0) g_SetEmaFast = (int)StringToInteger(StringSubstr(jsonResp, idx+11, StringFind(jsonResp, ",", idx)-idx-11));
            idx = StringFind(jsonResp, "\"ema_slow\":", setIndex);
            if(idx > 0) g_SetEmaSlow = (int)StringToInteger(StringSubstr(jsonResp, idx+11, StringFind(jsonResp, ",", idx)-idx-11));
            idx = StringFind(jsonResp, "\"rsi_period\":", setIndex);
            if(idx > 0) g_SetRSIPeriod = (int)StringToInteger(StringSubstr(jsonResp, idx+13, StringFind(jsonResp, ",", idx)-idx-13));
            idx = StringFind(jsonResp, "\"rsi_tf\":", setIndex);
            if(idx > 0) g_SetRSITF = (ENUM_TIMEFRAMES)StringToInteger(StringSubstr(jsonResp, idx+9, StringFind(jsonResp, ",", idx)-idx-9));
            idx = StringFind(jsonResp, "\"rsi_buy\":", setIndex);
            if(idx > 0) g_SetRSIBuyLevel = (int)StringToInteger(StringSubstr(jsonResp, idx+10, StringFind(jsonResp, ",", idx)-idx-10));
            idx = StringFind(jsonResp, "\"rsi_sell\":", setIndex);
            if(idx > 0) g_SetRSISellLevel = (int)StringToInteger(StringSubstr(jsonResp, idx+11, StringFind(jsonResp, ",", idx)-idx-11));
            idx = StringFind(jsonResp, "\"use_basket_trail\":", setIndex);
            if(idx > 0) g_SetUseBasketTrail = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
            idx = StringFind(jsonResp, "\"trail_start\":", setIndex);
            if(idx > 0) g_SetBasketTrailStartUSD = StringToDouble(StringSubstr(jsonResp, idx+14, StringFind(jsonResp, ",", idx)-idx-14));
            idx = StringFind(jsonResp, "\"trail_step\":", setIndex);
            if(idx > 0) g_SetBasketTrailStepUSD = StringToDouble(StringSubstr(jsonResp, idx+13, StringFind(jsonResp, "}", idx)-idx-13));
            
            idx = StringFind(jsonResp, "\"use_auto_hedge\":", setIndex);
            if(idx > 0) g_SetUseAutoHedge = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
            idx = StringFind(jsonResp, "\"hedge_max_dd\":", setIndex);
            if(idx > 0) g_SetHedgeMaxDDPct = StringToDouble(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
            idx = StringFind(jsonResp, "\"use_reverse_grid\":", setIndex);
            if(idx > 0) g_SetUseReverseGrid = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
            idx = StringFind(jsonResp, "\"recovery_target_usd\":", setIndex);
            if(idx > 0) g_SetRecoveryTargetUSD = StringToDouble(StringSubstr(jsonResp, idx+22, StringFind(jsonResp, ",", idx)-idx-22));
            idx = StringFind(jsonResp, "\"cooldown_seconds\":", setIndex);
            if(idx > 0) g_cooldownSeconds = (int)StringToInteger(StringSubstr(jsonResp, idx+19, StringFind(jsonResp, ",", idx)-idx-19));
            
            Print("✅ Grid Settings Synced with Web Server Successfully.");
            g_currentGridStepPt = g_SetFixedGridStep * _Point;
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
         g_highestProfitUSD = 0;
         g_isHedged = false;
         g_hedgeDirection = 0;
         nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      }
      else if(actionStr == "close_profitable")
      {
         Print("⚡ Dashboard: ปิดเฉพาะออเดอร์ที่ได้กำไร!");
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            if(ticket <= 0) continue;
            if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            if(profit > 0)
            {
               Print("💰 ปิดออเดอร์กำไร #", ticket, " | Profit: $", DoubleToString(profit,2));
               g_trade.PositionClose(ticket);
            }
         }
         nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      }
      else if(actionStr == "hedge_now")
      {
         Print("[Dashboard CMD] Hedge Now!");
         if(!g_isHedged && g_totalOrders > 0)
         {
            if(g_buyOrders > 0 && g_sellOrders == 0)
               ExecuteAutoHedge(-1);
            else if(g_sellOrders > 0 && g_buyOrders == 0)
               ExecuteAutoHedge(1);
            else
               Print("Cannot auto-hedge: Both BUY and SELL orders exist");
         }
         else if(g_isHedged)
            Print("Already in Hedge mode");
         else
            Print("No orders to hedge");
         nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      }
      else if(actionStr == "close_hedge")
      {
         Print("[Dashboard CMD] Close Hedge!");
         g_isHedged = false;
         g_hedgeDirection = 0;
         Print("Hedge status reset. Normal grid resumed.");
         nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      }
      else
      {
         int ticketIndex = StringFind(jsonResp, "\"ticket\":", actionIndex);
         if(ticketIndex >= 0)
         {
            int startNum = ticketIndex + 9;
            int endNum = StringFind(jsonResp, "}", startNum);
            if(endNum < 0) endNum = StringFind(jsonResp, ",", startNum);
            
            if(endNum > startNum)
            {
               string ticketStr = StringSubstr(jsonResp, startNum, endNum - startNum);
               ulong targetTicket = (ulong)StringToInteger(ticketStr);
               
               if(targetTicket > 0)
               {
                  if(actionStr == "close") 
                  {
                     Print("⚡ Dashboard: ปิดออเดอร์ #", targetTicket);
                     g_trade.PositionClose(targetTicket);
                  }
                  else if(actionStr == "open_multiplier")
                  {
                     Print("⚡ Dashboard: ถัวเพิ่มจากออเดอร์ #", targetTicket);
                     if(PositionSelectByTicket(targetTicket))
                     {
                        long type = PositionGetInteger(POSITION_TYPE);
                        double vol = PositionGetDouble(POSITION_VOLUME);
                        double newLot = NormalizeLot(vol * g_SetLotMultiplier);
                        
                        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                        
                        if(type == POSITION_TYPE_BUY)
                           g_trade.Buy(newLot, _Symbol, ask, 0, 0, "GRID MANUAL L" + IntegerToString(g_buyOrders+1));
                        else if(type == POSITION_TYPE_SELL)
                           g_trade.Sell(newLot, _Symbol, bid, 0, 0, "GRID MANUAL L" + IntegerToString(g_sellOrders+1));
                     }
                  }
               }
            }
            nextActionIdx = StringFind(jsonResp, "\"action\":", ticketIndex);
         }
         else
            nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
      }
      
      actionIndex = nextActionIdx;
   }
}

//+------------------------------------------------------------------+
//| ===== UpdateDashboardOnChart() =====                              |
//+------------------------------------------------------------------+
void UpdateDashboardOnChart()
{
   string trendStr = (g_trendDir == 1) ? "UP" : (g_trendDir == -1) ? "DOWN" : "SIDEWAYS";
   string gridType = g_SetUseDynamicStep ? "DYNAMIC (ATR)" : "FIXED";
   double stepInPoints = g_currentGridStepPt / _Point;
   
   string lines[30];
   color textColors[30];
   for(int c=0; c<30; c++) textColors[c] = clrBlack;
   
   string nextGridStr = "Next Grid: N/A";
   if(g_totalOrders > 0)
   {
      double lowestBuyPrice  = 1e10;
      double highestSellPrice = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         long type = PositionGetInteger(POSITION_TYPE);
         double oPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         if(type == POSITION_TYPE_BUY && oPrice < lowestBuyPrice) lowestBuyPrice = oPrice;
         if(type == POSITION_TYPE_SELL && oPrice > highestSellPrice) highestSellPrice = oPrice;
      }
      
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      if(g_buyOrders > 0 && lowestBuyPrice < 1e10)
      {
         double nextPrice = lowestBuyPrice - g_currentGridStepPt;
         double dist = ask - nextPrice;
         nextGridStr = "Next Buy at: " + DoubleToString(nextPrice, _Digits) + " (in " + DoubleToString(dist/_Point, 0) + " pts)";
      }
      else if(g_sellOrders > 0 && highestSellPrice > 0)
      {
         double nextPrice = highestSellPrice + g_currentGridStepPt;
         double dist = nextPrice - bid;
         nextGridStr = "Next Sell at: " + DoubleToString(nextPrice, _Digits) + " (in " + DoubleToString(dist/_Point, 0) + " pts)";
      }
   }
   
   int idx = 0;
   lines[idx] = "════ Smart Grid (" + _Symbol + ") ════"; idx++;
   lines[idx] = "Trend: " + trendStr + " (RSI: " + DoubleToString(g_currentRSI, 1) + ")"; idx++;
   lines[idx] = "Grid: " + gridType + " | Step: " + DoubleToString(stepInPoints, 0) + " pts"; idx++;
   lines[idx] = nextGridStr; idx++;
   lines[idx] = "Total PnL: $" + DoubleToString(g_totalProfit, 2);
   textColors[idx] = g_totalProfit >= 0 ? clrGreen : clrRed; idx++;
   lines[idx] = "Watermark: $" + DoubleToString(g_highestProfitUSD, 2); idx++;
   lines[idx] = "Orders: " + IntegerToString(g_totalOrders) + " (B:" + IntegerToString(g_buyOrders) + " S:" + IntegerToString(g_sellOrders) + ") Lots: " + DoubleToString(g_totalLot, 2); idx++;
   
   if(g_SetUseBasketTrail && g_totalOrders > 0 && g_highestProfitUSD >= g_SetBasketTrailStartUSD)
   {
      double lockLevel = g_highestProfitUSD - g_SetBasketTrailStepUSD;
      if(lockLevel > 0) {
         lines[idx] = "► Trail Lock: $" + DoubleToString(lockLevel, 2);
         textColors[idx] = clrGreen; idx++;
      }
   }
   
   lines[idx] = "──── Active Settings ────";
   textColors[idx] = clrDodgerBlue; idx++;
   
   string tpModeStr = (g_SetTPMode == TP_MODE_BASKET) ? "Basket" : "Single";
   lines[idx] = "Lot: " + DoubleToString(g_SetStartLot, 2) + " x" + DoubleToString(g_SetLotMultiplier, 1) + " | Max Lv: " + IntegerToString(g_SetMaxLevels); idx++;
   lines[idx] = "TP: $" + DoubleToString(g_SetTakeProfitUSD, 2) + " (" + tpModeStr + ")"; idx++;
   
   string dynStr = g_SetUseDynamicStep ? "ON" : "OFF";
   lines[idx] = "DynGrid: " + dynStr + " | Fixed: " + DoubleToString(g_SetFixedGridStep, 0) + " pts"; idx++;
   lines[idx] = "ATR: " + IntegerToString(g_SetATRPeriod) + " x" + DoubleToString(g_SetATRMultiplier, 1); idx++;
   
   string tfStr = g_SetUseTrendFilter ? "ON" : "OFF";
   lines[idx] = "TrendFilter: " + tfStr + " | EMA " + IntegerToString(g_SetEmaFast) + "/" + IntegerToString(g_SetEmaSlow); idx++;
   lines[idx] = "RSI(" + IntegerToString(g_SetRSIPeriod) + ") Buy<" + IntegerToString(g_SetRSIBuyLevel) + " Sell>" + IntegerToString(g_SetRSISellLevel); idx++;
   
   string trailOnOff = g_SetUseBasketTrail ? "ON" : "OFF";
   lines[idx] = "Trail: " + trailOnOff + " Start:$" + DoubleToString(g_SetBasketTrailStartUSD, 1) + " Step:$" + DoubleToString(g_SetBasketTrailStepUSD, 1); idx++;
   
   string hedgeStr = g_SetUseAutoHedge ? "ON" : "OFF";
   string revStr = g_SetUseReverseGrid ? "ON" : "OFF";
   lines[idx] = "Hedge: " + hedgeStr + " | MaxDD: " + DoubleToString(g_SetHedgeMaxDDPct, 1) + "%"; idx++;
   lines[idx] = "RevGrid: " + revStr + " | Recovery: $" + DoubleToString(g_SetRecoveryTargetUSD, 2); idx++;
   lines[idx] = "Cooldown: " + IntegerToString(g_cooldownSeconds) + "s"; idx++;
   
   lines[idx] = "Magic: " + IntegerToString(g_MagicNumber);
   textColors[idx] = C'140,140,160'; idx++;
   
   int totalLines = idx;
   
   int panelPadding = 8;
   int lineHeight = 18;
   int panelWidth = 380;
   int panelHeight = (totalLines * lineHeight) + (panelPadding * 2) + 4;
   if(panelHeight < 150) panelHeight = 150;
   
   string panelName = g_prefix + "PANEL_BG";
   if(ObjectFind(0, panelName) < 0) {
      ObjectCreate(0, panelName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, panelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, panelName, OBJPROP_XDISTANCE, 5);
      ObjectSetInteger(0, panelName, OBJPROP_YDISTANCE, 5);
      ObjectSetInteger(0, panelName, OBJPROP_BGCOLOR, C'20,20,30');
      ObjectSetInteger(0, panelName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, panelName, OBJPROP_BORDER_COLOR, C'60,60,80');
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
      color txtColor = (textColors[i] == clrBlack) ? C'220,220,230' : textColors[i];
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, txtColor);
   }
   
   for(int j=totalLines; j<30; j++)
   {
      string lblName = g_prefix+"LBL_"+IntegerToString(j);
      if(ObjectFind(0, lblName) >= 0) ObjectDelete(0, lblName);
   }
   
   string btnName = g_prefix + "BTN_TEST_PUSH";
   if(ObjectFind(0, btnName) >= 0) ObjectDelete(0, btnName);
   
   ChartRedraw();
}
