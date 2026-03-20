//+------------------------------------------------------------------+
//|                                                 X_Dashbord.mq5   |
//|         Smart Grid EA — All Settings from Web Dashboard          |
//+------------------------------------------------------------------+
#property copyright "X_Dashbord v2.0"
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

// Magic Number (hardcoded — ไม่ต้อง input)
long g_MagicNumber = 20261111;

//+------------------------------------------------------------------+
//| ===== Global Variables =====                                       |
//+------------------------------------------------------------------+

CTrade   g_trade;
int      g_handleEmaFast = INVALID_HANDLE;
int      g_handleEmaSlow = INVALID_HANDLE;
int      g_handleATR     = INVALID_HANDLE;
int      g_handleRSI     = INVALID_HANDLE;

//--- BTC Strategy Variables
bool     g_isBTC = false;
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

//--- XAU Strategy Variables
bool     g_isXAU = false;
int      g_xauHandleEMA21   = INVALID_HANDLE;
int      g_xauHandleEMA55   = INVALID_HANDLE;
int      g_xauHandleADX     = INVALID_HANDLE;
int      g_xauHandleRSI     = INVALID_HANDLE;
int      g_xauHandleATR     = INVALID_HANDLE;
double   g_xauEMA21 = 0, g_xauEMA55 = 0;
double   g_xauRSI = 0, g_xauATR = 0, g_xauADX = 0;
int      g_xauTrend = 0;            // 1=UP, -1=DOWN, 0=FLAT
ulong    g_xauTicket = 0;            // Current open ticket
double   g_xauEntrySL = 0;          // SL distance for trailing calc
double   g_xauHighWater = 0;        // Highest profit for trailing
bool     g_xauPartialDone = false;   // Has partial TP been taken?

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
double   g_highestProfitUSD = 0; // จำสถิติสูงสุดของรอบตระกร้านี้
double   g_maxDrawdownPct   = 0; // บันทึก Drawdown สูงสุดของตระกร้านี้ (%)

//--- Trend & Indicators
int      g_trendDir       = 0;       // 1=UP, -1=DN, 0=SIDE
double   g_emaFastVal     = 0;
double   g_emaSlowVal     = 0;
double   g_currentATR     = 0;
double   g_currentRSI     = 0;
double   g_currentGridStepPt = 0;    // คำนวณเป็นราคาดิบ (อัพเดตราย Tick)

//--- Hedge & Recovery State
bool     g_isHedged         = false; // อยู่ในสถานะ Hedge หรือไม่
int      g_hedgeDirection   = 0;     // 1=hedge SELL(ของBUY), -1=hedge BUY(ของSELL)
int      g_prevTrendDir     = 0;     // เทรนด์ก่อนหน้า
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
string   g_prefix        = "SMART_";

//+------------------------------------------------------------------+
//| ===== OnInit() =====                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== X_Dashbord v2.0 Smart Grid (Web-Controlled) ===");
   
   g_trade.SetExpertMagicNumber(g_MagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   //--- Hedge defaults
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

   //--- Auto-Detection: XAU / BTC / Grid
   g_isXAU = (StringFind(_Symbol, "XAU") >= 0);
   g_isBTC = (StringFind(_Symbol, "BTC") >= 0);
   
   if(g_isXAU)
   {
      Print("🟡 Gold Detected! Using XAU Smart Trend Strategy (Non-Grid)");
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
   }
   else if(g_isBTC)
   {
      Print("🟠 BTC Detected! Using Momentum + RSI Pullback Strategy");
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
   }
   else
   {
      //--- Grid Indicator Handles (non-XAU, non-BTC)
      g_handleEmaFast = iMA(_Symbol, g_SetTrendTF, g_SetEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      g_handleEmaSlow = iMA(_Symbol, g_SetTrendTF, g_SetEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      g_handleATR     = iATR(_Symbol, g_SetTrendTF, g_SetATRPeriod);
      g_handleRSI     = iRSI(_Symbol, g_SetRSITF, g_SetRSIPeriod, PRICE_CLOSE);
      
      if(g_handleEmaFast == INVALID_HANDLE || g_handleEmaSlow == INVALID_HANDLE || g_handleATR == INVALID_HANDLE || g_handleRSI == INVALID_HANDLE)
      {
         Print("❌ สร้าง Handles ล้มเหลว!");
         return INIT_FAILED;
      }
   }

   //--- Dashboard Panel is created dynamically
   
   //--- Initial Dashboard Draw (in case market is closed / no ticks)
   if(g_isXAU) UpdateXAUDashboard();
   else if(g_isBTC) UpdateBTCDashboard();
   else UpdateDashboardOnChart();
   
   //--- Timer setup for dashboard sync
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
   if(g_btcHandleEMA50  != INVALID_HANDLE) IndicatorRelease(g_btcHandleEMA50);
   if(g_btcHandleEMA200 != INVALID_HANDLE) IndicatorRelease(g_btcHandleEMA200);
   if(g_btcHandleRSI    != INVALID_HANDLE) IndicatorRelease(g_btcHandleRSI);
   if(g_btcHandleATR    != INVALID_HANDLE) IndicatorRelease(g_btcHandleATR);
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
   //--- XAU Mode: use Smart Trend strategy
   if(g_isXAU) { OnTickXAU(); return; }
   //--- BTC Mode: use Momentum strategy instead of Grid
   if(g_isBTC) { OnTickBTC(); return; }
   //--- 1) Update Indicators
   UpdateIndicators();
   
   //--- 1.5) Spread Filter — skip if spread is too wide
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double maxSpread = g_currentGridStepPt * 0.3;
   if(maxSpread > 0 && spread > maxSpread) return;
   
   //--- 2) สแกนออเดอร์
   ScanOrders();
   
   //--- 3) คำนวณ Grid Step ของ Tick นี้
   CalculateGridStep();
   
   //--- 3.5) คำนวณ Max Drawdown
   double floating = AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE);
   if(AccountInfoDouble(ACCOUNT_BALANCE) > 0 && floating < 0)
   {
      double currentDD = (MathAbs(floating) / AccountInfoDouble(ACCOUNT_BALANCE)) * 100.0;
      if(currentDD > g_maxDrawdownPct) g_maxDrawdownPct = currentDD;
   }
   
   //--- Update Dashboard Comment
   UpdateDashboardOnChart();

   //--- 4) Risk Management: TP / SL รวบตระกร้า
   if(g_totalOrders > 0)
   {
      // --- TP Check ---
      if(g_SetTakeProfitUSD > 0)
      {
         if(g_SetTPMode == TP_MODE_BASKET)
         {
            // เช็คบรรทัดสุดท้ายแบบรวบยอด
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
            // เช็คแยกทีละออเดอร์
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
            // จำเป็นต้องสแกนใหม่ถ้ามีออเดอร์ถูกปิดไป
            ScanOrders(); 
            if(g_totalOrders == 0) g_highestProfitUSD = 0;
         }
      }
      
      // --- Trailing Stop ตระกร้า ---
      if(g_SetUseBasketTrail)
      {
         if(g_totalProfit > g_highestProfitUSD)
         {
            g_highestProfitUSD = g_totalProfit; // จำ High Water Mark
         }
         
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
      // ไม่มีออเดอร์ รีเซ็ตยอดสูงสุด และ Max DD
      g_highestProfitUSD = 0;
      g_maxDrawdownPct = 0;
   }

   //--- 5) Hedge & Recovery Logic
   if(g_isHedged)
   {
      // We're in hedge mode - check recovery
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
      
      // Max DD cut loss check
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
      
      // Reverse Grid: open grid orders in the NEW trend direction
      if(g_SetUseReverseGrid)
      {
         if(g_hedgeDirection == -1 && g_buyOrders > 0) // hedged SELL, now doing BUY reverse grid
         {
            CheckGridExpansion(); // This will expand the BUY side (reverse direction grid)
         }
         else if(g_hedgeDirection == 1 && g_sellOrders > 0) // hedged BUY, now doing SELL reverse grid
         {
            CheckGridExpansion(); // This will expand the SELL side
         }
      }
   }
   else
   {
      //--- 5b) Auto Hedge Detection - only if we have open orders
      if(g_totalOrders > 0 && g_SetUseAutoHedge)
      {
         int reversal = DetectTrendReversal();
         if(reversal != 0)
         {
            // reversal = -1 means was UP(BUY), now DOWN → hedge with SELL
            // reversal =  1 means was DOWN(SELL), now UP → hedge with BUY
            if(reversal == -1 && g_buyOrders > 0 && g_sellOrders == 0)
            {
               Print("Trend Reversal! UP->DOWN | BUY open: ", g_buyOrders, " -> Hedge SELL");
               ExecuteAutoHedge(-1); // hedge BUY with SELL
            }
            else if(reversal == 1 && g_sellOrders > 0 && g_buyOrders == 0)
            {
               Print("Trend Reversal! DOWN->UP | SELL open: ", g_sellOrders, " -> Hedge BUY");
               ExecuteAutoHedge(1); // hedge SELL with BUY
            }
         }
      }
      
      //--- 6) Normal Grid: open first or expand
      if(g_totalOrders == 0)
      {
         OpenFirstOrder();
      }
      else if(!g_isHedged) // Only expand grid if not hedged
      {
         CheckGridExpansion();
      }
   }

   // (Web sync and command checking moved to OnTimer)
}

//+------------------------------------------------------------------+
//| ===== OnTimer() =====                                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Scan orders to keep stats fresh
   ScanOrders();
   
   // Sync to web dashboard (also receives commands in response)
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
   {
      g_currentGridStepPt = g_SetFixedGridStep * _Point;
   }
   else 
   {
      // ATR ให้ค่าเป็นแก๊ปราคา ตัวอย่าง XAUUSD ATR=5.50 (แสดงว่าวิ่งเฉลี่ยแท่งละ 5.5 เหรียญทอง)
      if(g_currentATR > 0)
      {
         g_currentGridStepPt = g_currentATR * g_SetATRMultiplier;
      }
      else 
      {
         g_currentGridStepPt = g_SetFixedGridStep * _Point; // ถ่ายโอนกรณีที่ ATR หาค่าไม่ได้
      }
   }
}

//+------------------------------------------------------------------+
//| ===== OpenFirstOrder() =====                                      |
//+------------------------------------------------------------------+
void OpenFirstOrder()
{
   //--- Cooldown: รอหลังปิดตระกร้า
   if(g_lastCloseTime > 0 && (TimeCurrent() - g_lastCloseTime) < g_cooldownSeconds)
      return;
   
   //--- Max Floating Loss protection
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
      //--- RSI-gated entry: ต้องรอ RSI pullback ก่อนเปิด
      if(g_trendDir == 1 && g_currentRSI < g_SetRSIBuyLevel) doBuy = true;
      else if(g_trendDir == -1 && g_currentRSI > g_SetRSISellLevel) doSell = true;
   }
   else
   {
      doBuy = true;
   }
   
   if(!doBuy && !doSell) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = g_SetStartLot;
   
   if(!IsTradeAllowedSafe(lot)) return;
   
   if(doBuy)
   {
      g_trade.Buy(lot, _Symbol, ask, 0, 0, "SMART L1 BUY");
      Print("✅ เปิดไม้แรก BUY L1 | Lot: ", lot, " | RSI: ", DoubleToString(g_currentRSI,1));
   }
   else if(doSell)
   {
      g_trade.Sell(lot, _Symbol, bid, 0, 0, "SMART L1 SELL");
      Print("✅ เปิดไม้แรก SELL L1 | Lot: ", lot, " | RSI: ", DoubleToString(g_currentRSI,1));
   }
}

//+------------------------------------------------------------------+
//| ===== IsTradeAllowedSafe() =====                                 |
//+------------------------------------------------------------------+
bool IsTradeAllowedSafe(double reqLot)
{
   // 1. Check if Market is Open (SYMBOL_TRADE_MODE returns whether broker allows trading)
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode != SYMBOL_TRADE_MODE_FULL)
   {
      Print("⚠️ [Safety Check] Market is Closed/Restricted for ", _Symbol, " (TradeMode: ", EnumToString(tradeMode), ") - Cannot open trade.");
      return false;
   }
   
   // 2. Check Margin availability
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginRequired = 0;
   
   // Calculate margin required for a BUY order (margin is usually same for sell on most brokers)
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, reqLot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired))
   {
      Print("⚠️ [Safety Check] Failed to calculate margin for lot: ", reqLot);
      return false; // Safest is to block if we can't calculate
   }
   
   if(freeMargin < marginRequired)
   {
      Print("⚠️ [Safety Check] Insufficient Margin! Free: $", DoubleToString(freeMargin,2), " | Required: $", DoubleToString(marginRequired,2));
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
   
   // (Max Lot check removed)
   
   // --- เพิ่ม BUY Level ---
   if(g_buyOrders > 0 && g_buyOrders < g_SetMaxLevels && lowestBuyPrice < 1e10)
   {
      double dist = lowestBuyPrice - ask;
      if(dist >= g_currentGridStepPt)
      {
         double lot = NormalizeLot(lastBuyLot * g_SetLotMultiplier);
         if(IsTradeAllowedSafe(lot)) // Safety Check
         {
             if(g_trade.Buy(lot, _Symbol, ask, 0, 0, "SMART L"+IntegerToString(g_buyOrders+1)+" BUY"))
                Print("📉 ราคาลงหลุดกริด (", DoubleToString(dist/_Point,0), " pts) → ถัว BUY | Lot: ", lot);
         }
      }
   }
   
   // --- เพิ่ม SELL Level ---
   if(g_sellOrders > 0 && g_sellOrders < g_SetMaxLevels && highestSellPrice > 0)
   {
      double dist = bid - highestSellPrice;
      if(dist >= g_currentGridStepPt)
      {
         double lot = NormalizeLot(lastSellLot * g_SetLotMultiplier);
         if(IsTradeAllowedSafe(lot)) // Safety Check
         {
             if(g_trade.Sell(lot, _Symbol, bid, 0, 0, "SMART L"+IntegerToString(g_sellOrders+1)+" SELL"))
                Print("📈 ราคาขึ้นทะลุกริด (", DoubleToString(dist/_Point,0), " pts) → ถัว SELL | Lot: ", lot);
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
//|  Return:  0 = no reversal                                        |
//|          -1 = was UP, now DOWN (BUY ค้าง ต้อง hedge SELL)       |
//|           1 = was DOWN, now UP (SELL ค้าง ต้อง hedge BUY)        |
//+------------------------------------------------------------------+
int DetectTrendReversal()
{
   // Only detect once per trend change using prevTrendDir
   if(g_prevTrendDir == 0)
   {
      g_prevTrendDir = g_trendDir;
      return 0;
   }
   
   int result = 0;
   
   // Was UP (1), now DOWN (-1): EMA crossed down + RSI > 50 confirms
   if(g_prevTrendDir == 1 && g_trendDir == -1 && g_currentRSI > 50)
   {
      result = -1;
      Print("Trend Reversal Confirmed: EMA Cross DOWN + RSI=", DoubleToString(g_currentRSI,1), " > 50");
   }
   // Was DOWN (-1), now UP (1): EMA crossed up + RSI < 50 confirms
   else if(g_prevTrendDir == -1 && g_trendDir == 1 && g_currentRSI < 50)
   {
      result = 1;
      Print("Trend Reversal Confirmed: EMA Cross UP + RSI=", DoubleToString(g_currentRSI,1), " < 50");
   }
   
   // Always update previous trend after checking
   g_prevTrendDir = g_trendDir;
   
   return result;
}

//+------------------------------------------------------------------+
//| ===== ExecuteAutoHedge() =====                                    |
//| direction: -1 = hedge BUY ด้วย SELL, 1 = hedge SELL ด้วย BUY   |
//+------------------------------------------------------------------+
void ExecuteAutoHedge(int direction)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(direction == -1) // BUY ค้าง → เปิด SELL lock
   {
      double hedgeLot = NormalizeLot(g_buyLot);
      if(hedgeLot <= 0) return;
      if(!IsTradeAllowedSafe(hedgeLot)) return;
      
      if(g_trade.Sell(hedgeLot, _Symbol, bid, 0, 0, "HEDGE SELL LOCK"))
      {
         Print("Hedge SELL opened OK | Lot: ", hedgeLot, " (lock BUY ", g_buyLot, " lots)");
         g_isHedged = true;
         g_hedgeDirection = -1;
         
         // Start reverse grid: open first SELL grid level 
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
   else if(direction == 1) // SELL ค้าง → เปิด BUY lock
   {
      double hedgeLot = NormalizeLot(g_sellLot);
      if(hedgeLot <= 0) return;
      if(!IsTradeAllowedSafe(hedgeLot)) return;
      
      if(g_trade.Buy(hedgeLot, _Symbol, ask, 0, 0, "HEDGE BUY LOCK"))
      {
         Print("Hedge BUY opened OK | Lot: ", hedgeLot, " (lock SELL ", g_sellLot, " lots)");
         g_isHedged = true;
         g_hedgeDirection = 1;
         
         // Start reverse grid: open first BUY grid level
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
//| ===== Local Web Dashboard Sync Logic =====                        |
//+------------------------------------------------------------------+
// Note: You MUST add "http://127.0.0.1:3000" to WebRequest allowed URLs in MT5 Tools -> Options -> Expert Advisors
string LOCAL_API_URL = "http://127.0.0.1:3000/api/ea-stats";

//+------------------------------------------------------------------+
//| ===== Get Daily Profits JSON =====                                |
//+------------------------------------------------------------------+
string GetDailyProfitsJSON()
{
   datetime endTime = TimeCurrent();
   datetime startTime = endTime - (14 * 24 * 60 * 60); // 14 วันที่ผ่านมา
   
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
      if(entry != DEAL_ENTRY_OUT) continue; // Only want closed trades
      
      string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(sym != _Symbol) continue;
      
      long typeInt = HistoryDealGetInteger(ticket, DEAL_TYPE);
      // If it's an OUT deal, a BUY closed a SELL, and a SELL closed a BUY.
      string typeStr = (typeInt == DEAL_TYPE_BUY) ? "BUY_CLOSE" : "SELL_CLOSE"; 
      
      double vol = HistoryDealGetDouble(ticket, DEAL_VOLUME);
      double openPrice = HistoryDealGetDouble(ticket, DEAL_PRICE); // Price at which it was closed
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      datetime time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      string dateStr = TimeToString(time, TIME_DATE|TIME_MINUTES|TIME_SECONDS); // "YYYY.MM.DD HH:MI:SS"
      StringReplace(dateStr, ".", "-"); // Convert to standard SQL "YYYY-MM-DD HH:MI:SS"
      
      if(count > 0) json += ",";
      json += StringFormat("{\"ticket\":%llu, \"symbol\":\"%s\", \"type\":\"%s\", \"volume\":%.2f, \"open_price\":%.5f, \"profit\":%.2f, \"date\":\"%s\"}",
                           ticket, sym, typeStr, vol, openPrice, profit, dateStr);
      count++;
   }
   
   json += "]";
   return json;
}

//+------------------------------------------------------------------+
//| ===== Get Active Orders JSON =====                                |
//+------------------------------------------------------------------+
string GetActiveOrdersJSON()
{
   string json = "[";
   int count = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != g_MagicNumber) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) continue;
      
      long typeInt = PositionGetInteger(POSITION_TYPE);
      string typeStr = (typeInt == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      
      double vol = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP); // include swap
      
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
   // No delay - Sync every tick for real-time performance

   
   string headers = "Content-Type: application/json\r\n";
   string historyJson = GetDailyProfitsJSON();
   string activeOrdersJson = GetActiveOrdersJSON();
   
   string payload;
   
   if(g_isXAU)
   {
      //--- XAU Mode: send Smart Trend strategy data
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
      
      payload = StringFormat("{\"account_id\":\"%lld\", \"symbol\":\"%s\", \"strategy\":\"XAU_TREND\", \"equity\":%.2f, \"balance\":%.2f, \"total_profit\":%.2f, \"open_orders\":%d, \"trend_direction\":\"%s\", \"xau_ema21\":%.2f, \"xau_ema55\":%.2f, \"xau_adx\":%.1f, \"xau_rsi\":%.1f, \"xau_atr\":%.2f, \"xau_position\":%s, \"history\":%s, \"active_orders\":%s, \"ea_settings\":%s}",
                              AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE), g_totalProfit, g_totalOrders, trendStr,
                              g_xauEMA21, g_xauEMA55, g_xauADX, g_xauRSI, g_xauATR, xauPosJson, historyJson, activeOrdersJson, xauSettingsJson);
   }
   else if(g_isBTC)
   {
      //--- BTC Mode: send momentum strategy data
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
      
      payload = StringFormat("{\"account_id\":\"%lld\", \"symbol\":\"%s\", \"strategy\":\"BTC_MOMENTUM\", \"equity\":%.2f, \"balance\":%.2f, \"total_profit\":%.2f, \"open_orders\":%d, \"trend_direction\":\"%s\", \"btc_ema50\":%.2f, \"btc_ema200\":%.2f, \"btc_rsi\":%.1f, \"btc_atr\":%.2f, \"btc_position\":%s, \"history\":%s, \"active_orders\":%s, \"ea_settings\":%s}",
                              AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE), g_totalProfit, g_totalOrders, trendStr,
                              g_btcEMA50, g_btcEMA200, g_btcRSI, g_btcATR, btcPosJson, historyJson, activeOrdersJson, btcSettingsJson);
   }
   else
   {
      //--- Grid Mode: send original grid data
      string trendStr = (g_trendDir == 1) ? "UP" : (g_trendDir == -1) ? "DOWN" : "SIDEWAYS";
      
      string settingsJson = StringFormat("{\"start_lot\":%.2f, \"lot_multiplier\":%.2f, \"max_levels\":%d, \"tp_mode\":%d, \"tp_usd\":%.2f, \"use_dynamic_step\":%s, \"grid_step\":%.2f, \"atr_period\":%d, \"atr_multiplier\":%.2f, \"use_trend_filter\":%s, \"ema_fast\":%d, \"ema_slow\":%d, \"rsi_period\":%d, \"rsi_tf\":%d, \"rsi_buy\":%d, \"rsi_sell\":%d, \"use_basket_trail\":%s, \"trail_start\":%.2f, \"trail_step\":%.2f}",
                                         g_SetStartLot, g_SetLotMultiplier, g_SetMaxLevels, g_SetTPMode, g_SetTakeProfitUSD, 
                                         g_SetUseDynamicStep ? "true" : "false", g_SetFixedGridStep, g_SetATRPeriod, g_SetATRMultiplier,
                                         g_SetUseTrendFilter ? "true" : "false", g_SetEmaFast, g_SetEmaSlow, g_SetRSIPeriod, g_SetRSITF, 
                                         g_SetRSIBuyLevel, g_SetRSISellLevel, g_SetUseBasketTrail ? "true" : "false", 
                                         g_SetBasketTrailStartUSD, g_SetBasketTrailStepUSD);
      
      payload = StringFormat("{\"account_id\":\"%lld\", \"symbol\":\"%s\", \"strategy\":\"GRID\", \"equity\":%.2f, \"balance\":%.2f, \"total_profit\":%.2f, \"open_orders\":%d, \"trend_direction\":\"%s\", \"max_dd\":%.2f, \"is_hedged\":%s, \"hedge_direction\":%d, \"history\":%s, \"active_orders\":%s, \"ea_settings\":%s}",
                              AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE), g_totalProfit, g_totalOrders, trendStr, g_maxDrawdownPct, g_isHedged ? "true" : "false", g_hedgeDirection, historyJson, activeOrdersJson, settingsJson);
   }
   
   char post[], result[];
   StringToCharArray(payload, post, 0, StringLen(payload));
   string resHeaders;
   
   int res = WebRequest("POST", LOCAL_API_URL, headers, 5000, post, result, resHeaders);
   
   //--- Parse commands from response
   if(res == 200 || res == 201)
   {
      string jsonResp = CharArrayToString(result);
      if(StringLen(jsonResp) > 10)
         ProcessCommands(jsonResp);
   }
}

//+------------------------------------------------------------------+
//| ===== Process Commands from Web Server Response =====              |
//+------------------------------------------------------------------+
void ProcessCommands(string jsonResp)
{
         int actionIndex = StringFind(jsonResp, "\"action\":");
         while(actionIndex >= 0)
         {
            int actionStart = actionIndex + 10;
            int actionEnd = StringFind(jsonResp, "\"", actionStart);
            string actionStr = "";
            if(actionEnd > actionStart) {
               actionStr = StringSubstr(jsonResp, actionStart, actionEnd - actionStart);
            }
            
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
                  
                  idx = StringFind(jsonResp, ""use_auto_hedge":", setIndex);
                  if(idx > 0) g_SetUseAutoHedge = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
                  idx = StringFind(jsonResp, ""hedge_max_dd":", setIndex);
                  if(idx > 0) g_SetHedgeMaxDDPct = StringToDouble(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""use_reverse_grid":", setIndex);
                  if(idx > 0) g_SetUseReverseGrid = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
                  idx = StringFind(jsonResp, ""recovery_target_usd":", setIndex);
                  if(idx > 0) g_SetRecoveryTargetUSD = StringToDouble(StringSubstr(jsonResp, idx+22, StringFind(jsonResp, ",", idx)-idx-22));
                  idx = StringFind(jsonResp, ""cooldown_seconds":", setIndex);
                  if(idx > 0) g_cooldownSeconds = (int)StringToInteger(StringSubstr(jsonResp, idx+19, StringFind(jsonResp, ",", idx)-idx-19));
                  
                  // BTC Settings
                  idx = StringFind(jsonResp, ""btc_ema_fast":", setIndex);
                  if(idx > 0) g_SetBTC_EMA_Fast = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""btc_ema_slow":", setIndex);
                  if(idx > 0) g_SetBTC_EMA_Slow = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""btc_rsi_period":", setIndex);
                  if(idx > 0) g_SetBTC_RSI_Period = (int)StringToInteger(StringSubstr(jsonResp, idx+17, StringFind(jsonResp, ",", idx)-idx-17));
                  idx = StringFind(jsonResp, ""btc_rsi_buy":", setIndex);
                  if(idx > 0) g_SetBTC_RSI_Buy = (int)StringToInteger(StringSubstr(jsonResp, idx+14, StringFind(jsonResp, ",", idx)-idx-14));
                  idx = StringFind(jsonResp, ""btc_rsi_sell":", setIndex);
                  if(idx > 0) g_SetBTC_RSI_Sell = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""btc_risk_reward":", setIndex);
                  if(idx > 0) g_SetBTC_RiskReward = StringToDouble(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
                  idx = StringFind(jsonResp, ""btc_atr_sl_mult":", setIndex);
                  if(idx > 0) g_SetBTC_ATR_SL_Mult = StringToDouble(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
                  idx = StringFind(jsonResp, ""btc_lot_size":", setIndex);
                  if(idx > 0) g_SetBTC_LotSize = StringToDouble(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""btc_trail_atr_mult":", setIndex);
                  if(idx > 0) g_SetBTC_TrailATRMult = StringToDouble(StringSubstr(jsonResp, idx+21, StringFind(jsonResp, ",", idx)-idx-21));
                  idx = StringFind(jsonResp, ""btc_partial_tp":", setIndex);
                  if(idx > 0) g_SetBTC_PartialTP = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
                  
                  // XAU Settings
                  idx = StringFind(jsonResp, ""xau_ema_fast":", setIndex);
                  if(idx > 0) g_SetXAU_EMA_Fast = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""xau_ema_slow":", setIndex);
                  if(idx > 0) g_SetXAU_EMA_Slow = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""xau_adx_period":", setIndex);
                  if(idx > 0) g_SetXAU_ADX_Period = (int)StringToInteger(StringSubstr(jsonResp, idx+17, StringFind(jsonResp, ",", idx)-idx-17));
                  idx = StringFind(jsonResp, ""xau_adx_min":", setIndex);
                  if(idx > 0) g_SetXAU_ADX_Min = (int)StringToInteger(StringSubstr(jsonResp, idx+14, StringFind(jsonResp, ",", idx)-idx-14));
                  idx = StringFind(jsonResp, ""xau_rsi_period":", setIndex);
                  if(idx > 0) g_SetXAU_RSI_Period = (int)StringToInteger(StringSubstr(jsonResp, idx+17, StringFind(jsonResp, ",", idx)-idx-17));
                  idx = StringFind(jsonResp, ""xau_rsi_buy":", setIndex);
                  if(idx > 0) g_SetXAU_RSI_Buy = (int)StringToInteger(StringSubstr(jsonResp, idx+14, StringFind(jsonResp, ",", idx)-idx-14));
                  idx = StringFind(jsonResp, ""xau_rsi_sell":", setIndex);
                  if(idx > 0) g_SetXAU_RSI_Sell = (int)StringToInteger(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""xau_risk_reward":", setIndex);
                  if(idx > 0) g_SetXAU_RiskReward = StringToDouble(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
                  idx = StringFind(jsonResp, ""xau_atr_sl_mult":", setIndex);
                  if(idx > 0) g_SetXAU_ATR_SL_Mult = StringToDouble(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
                  idx = StringFind(jsonResp, ""xau_lot_size":", setIndex);
                  if(idx > 0) g_SetXAU_LotSize = StringToDouble(StringSubstr(jsonResp, idx+15, StringFind(jsonResp, ",", idx)-idx-15));
                  idx = StringFind(jsonResp, ""xau_trail_atr_mult":", setIndex);
                  if(idx > 0) g_SetXAU_TrailATRMult = StringToDouble(StringSubstr(jsonResp, idx+21, StringFind(jsonResp, ",", idx)-idx-21));
                  idx = StringFind(jsonResp, ""xau_partial_tp":", setIndex);
                  if(idx > 0) g_SetXAU_PartialTP = (StringFind(jsonResp, "true", idx) < StringFind(jsonResp, ",", idx));
                  idx = StringFind(jsonResp, ""xau_session_start":", setIndex);
                  if(idx > 0) g_SetXAU_SessionStart = (int)StringToInteger(StringSubstr(jsonResp, idx+20, StringFind(jsonResp, ",", idx)-idx-20));
                  idx = StringFind(jsonResp, ""xau_session_end":", setIndex);
                  if(idx > 0) g_SetXAU_SessionEnd = (int)StringToInteger(StringSubstr(jsonResp, idx+18, StringFind(jsonResp, ",", idx)-idx-18));
                  
                  Print("✅ All Custom EA Settings Synced with Web Server Successfully.");
                  g_currentGridStepPt = g_SetFixedGridStep * _Point;
               }
               nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
            }
            else if(actionStr == "close_all")
            {
               Print("⚡ ได้รับคำสั่งจาก Dashboard: ปิดออเดอร์ทั้งหมด!");
               CloseAllOrders();
               nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
            }
            else if(actionStr == "close_profitable")
            {
               Print("⚡ ได้รับคำสั่งจาก Dashboard: ปิดเฉพาะออเดอร์ที่ได้กำไร!");
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
               Print("Hedge status reset. Orders remain open. Normal grid resumed.");
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
                           Print("⚡ ได้รับคำสั่งจาก Dashboard: ปิดออเดอร์ #", targetTicket);
                           g_trade.PositionClose(targetTicket);
                        }
                        else if(actionStr == "open_multiplier")
                        {
                           Print("⚡ ได้รับคำสั่งจาก Dashboard: ถัวเพิ่มจากออเดอร์ #", targetTicket);
                           if(PositionSelectByTicket(targetTicket))
                           {
                              long type = PositionGetInteger(POSITION_TYPE);
                              double vol = PositionGetDouble(POSITION_VOLUME);
                              double newLot = NormalizeLot(vol * g_SetLotMultiplier);
                              
                              double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                              double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                              
                              if(type == POSITION_TYPE_BUY) {
                                 g_trade.Buy(newLot, _Symbol, ask, 0, 0, "SMART MANUAL GRID L" + IntegerToString(g_buyOrders+1));
                              } else if(type == POSITION_TYPE_SELL) {
                                 g_trade.Sell(newLot, _Symbol, bid, 0, 0, "SMART MANUAL GRID L" + IntegerToString(g_sellOrders+1));
                              }
                           }
                           else
                           {
                              Print("❌ ไม่พบออเดอร์ #", targetTicket, " (อาจจะถูกปิดไปแล้ว)");
                           }
                        }
                     }
                  }
                  nextActionIdx = StringFind(jsonResp, "\"action\":", ticketIndex);
               }
               else
               {
                  nextActionIdx = StringFind(jsonResp, "\"action\":", actionIndex + 10);
               }
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
   
   // --- Calculate Next Grid Step Info ---
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
         double dist = ask - nextPrice; // ระยะที่เหลือกว่าจะถึงราคาถัว
         nextGridStr = "Next Buy at: " + DoubleToString(nextPrice, _Digits) + " (in " + DoubleToString(dist/_Point, 0) + " pts)";
      }
      else if(g_sellOrders > 0 && highestSellPrice > 0)
      {
         double nextPrice = highestSellPrice + g_currentGridStepPt;
         double dist = nextPrice - bid; // ระยะที่เหลือกว่าจะขึ้นไปถึงราคาถัว
         nextGridStr = "Next Sell at: " + DoubleToString(nextPrice, _Digits) + " (in " + DoubleToString(dist/_Point, 0) + " pts)";
      }
   }
   
   int idx = 0;
   lines[idx] = "════ Smart Grid Pro (" + _Symbol + ") ════"; idx++;
   lines[idx] = "Trend: " + trendStr + " (RSI: " + DoubleToString(g_currentRSI, 1) + ")"; idx++;
   lines[idx] = "Grid: " + gridType + " | Step: " + DoubleToString(stepInPoints, 0) + " pts"; idx++;
   lines[idx] = nextGridStr; idx++;
   lines[idx] = "Total PnL: $" + DoubleToString(g_totalProfit, 2);
   textColors[idx] = g_totalProfit >= 0 ? clrGreen : clrRed; idx++;
   lines[idx] = "Watermark: $" + DoubleToString(g_highestProfitUSD, 2); idx++;
   lines[idx] = "Orders: " + IntegerToString(g_totalOrders) + " (B:" + IntegerToString(g_buyOrders) + " S:" + IntegerToString(g_sellOrders) + ") Lots: " + DoubleToString(g_totalLot, 2); idx++;
   
   // --- Trailing Stop ---
   if(g_SetUseBasketTrail && g_totalOrders > 0 && g_highestProfitUSD >= g_SetBasketTrailStartUSD)
   {
      double lockLevel = g_highestProfitUSD - g_SetBasketTrailStepUSD;
      if(lockLevel > 0) {
         lines[idx] = "► Trail Lock: $" + DoubleToString(lockLevel, 2);
         textColors[idx] = clrGreen; idx++;
      }
   }
   
   // --- Active Settings Section ---
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
   
   // --- Background Panel ---
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
      // Use white text on dark background, except special colors
      color txtColor = (textColors[i] == clrBlack) ? C'220,220,230' : textColors[i];
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, txtColor);
   }
   
   for(int j=totalLines; j<30; j++)
   {
      string lblName = g_prefix+"LBL_"+IntegerToString(j);
      if(ObjectFind(0, lblName) >= 0) ObjectDelete(0, lblName);
   }
   
   // Clean up old test push button if exists
   string btnName = g_prefix + "BTN_TEST_PUSH";
   if(ObjectFind(0, btnName) >= 0) ObjectDelete(0, btnName);
   
   ChartRedraw();
}


//+------------------------------------------------------------------+
//| ===== XAU Smart Trend Strategy =====                              |
//+------------------------------------------------------------------+
void OnTickXAU()
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
   if(g_xauEMA21 > g_xauEMA55) g_xauTrend = 1;      // UP
   else if(g_xauEMA21 < g_xauEMA55) g_xauTrend = -1; // DOWN
   else g_xauTrend = 0;                                // FLAT
   
   //--- 3) Scan current positions
   ScanOrders();
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   //--- 4) Session Filter (London + NY: 08:00 - 22:00 GMT)
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
            double tpDist = slDist * 1.0; // Partial at 1:1 RR
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
                  // Move SL to breakeven
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
         // Position closed
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
      
      // BUY: Uptrend (EMA21 > EMA55) + ADX strong + RSI pullback below buy level
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
      // SELL: Downtrend (EMA21 < EMA55) + ADX strong + RSI overbought above sell level
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
//| ===== XAU Dashboard on Chart =====                                |
//+------------------------------------------------------------------+
void UpdateXAUDashboard()
{
   string trendStr = (g_xauTrend == 1) ? "UP" : (g_xauTrend == -1) ? "DOWN" : "FLAT";
   
   // Session check
   MqlDateTime dt;
   TimeGMT(dt);
   int gmtHour = dt.hour;
   bool inSession = (gmtHour >= g_SetXAU_SessionStart && gmtHour < g_SetXAU_SessionEnd);
   
   string lines[25];
   color textColors[25];
   for(int c=0; c<25; c++) textColors[c] = C'220,220,230';
   
   int idx = 0;
   lines[idx] = "==== XAU SMART TREND (" + _Symbol + ") ====";
   textColors[idx] = C'255,215,0'; idx++; // Gold color
   
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
      ObjectSetInteger(0, panelName, OBJPROP_BORDER_COLOR, C'255,215,0'); // Gold border
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


//+------------------------------------------------------------------+
//| ===== BTC Momentum + RSI Pullback Strategy =====                  |
//+------------------------------------------------------------------+
void OnTickBTC()
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
                  Print("BTC Partial TP: Closed ", DoubleToString(halfLot,2), " lots");
                  g_btcPartialDone = true;
                  // Move SL to breakeven
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
         // Position closed
         g_btcTicket = 0;
         g_btcHighWater = 0;
         g_btcPartialDone = false;
      }
   }
   
   //--- 6) Entry Signal (no position open)
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
            Print("BTC BUY: RSI=", DoubleToString(g_btcRSI,1), " SL=", DoubleToString(sl,_Digits), " TP=", DoubleToString(tp,_Digits));
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
            Print("BTC SELL: RSI=", DoubleToString(g_btcRSI,1), " SL=", DoubleToString(sl,_Digits), " TP=", DoubleToString(tp,_Digits));
         }
      }
   }
   
   //--- 7) Update Dashboard
   UpdateBTCDashboard();
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
