//+------------------------------------------------------------------+
//|                            Camarilla_Modular_EA_v1_00.mq5        |
//| One EA that can toggle Camarilla modules on/off                  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include <DigitalRogue/CamarillaStrategyModules.mqh>
#include <DigitalRogue/TradePerformanceTracker.mqh>

CTrade trade;

enum DRPerformanceWindowMode
{
   DR_PERF_ALL = 0,
   DR_PERF_DAILY = 1,
   DR_PERF_WEEKLY = 2,
   DR_PERF_MONTHLY = 3
};

enum DRWeekResetDay
{
   DR_WEEK_RESET_SUNDAY = 0,
   DR_WEEK_RESET_MONDAY = 1,
   DR_WEEK_RESET_TUESDAY = 2,
   DR_WEEK_RESET_WEDNESDAY = 3,
   DR_WEEK_RESET_THURSDAY = 4,
   DR_WEEK_RESET_FRIDAY = 5,
   DR_WEEK_RESET_SATURDAY = 6
};

input double RiskPercent              = 0.25;
input int    ATR_Period               = 14;
input double ATR_SL_Mult              = 1.5;
input double RR_For_TP                = 2.0;
input bool   UseBreakEven             = true;
input double BreakEvenAtR             = 0.5;
input bool   UseTrailingStop          = true;
input double TrailStartAtR            = 1.0;
input bool   TrailOncePerBar          = true;
input double Trail_ATR_Mult           = 1.0;
input double MinTrailStepATR          = 0.25;
input bool   UseEMAFailureExit        = true;
input double EMAFailureExitUntilR     = 1.0;
input bool   UsePSARExit              = true;
input double PSARStep                 = 0.02;
input double PSARMaximum              = 0.2;
input bool   UseReloadGuard           = true;
input int    SlippagePoints           = 20;
input long   MagicNumber              = 2310;
input bool   EnableLogging            = true;
input bool   UseCommonLogFiles        = true;
input bool   OneTradePerBar           = true;
input double MaxSpreadPoints          = 100;
input string VWAPIndicatorName        = "DigitalRogue\\VWAP";
input string CamarillaIndicatorName   = "DigitalRogue\\Camarilla_Levels";
input int    EMAPeriod                = 10;
input bool   UseH1TrendBias           = true;
input int    H1FastEMAPeriod          = 10;
input int    H1SlowEMAPeriod          = 20;
input bool   UseH4TrendBias           = false;
input int    H4FastEMAPeriod          = 10;
input int    H4SlowEMAPeriod          = 20;
input bool   UseLondonSession         = true;
input bool   UseNewYorkSession        = true;
input int    MinScoreToTrade          = 6;
input double MinBodyToRange           = 0.25;
input double MinSweepATRFrac          = 0.05;
input bool   LogEachCandle            = true;
input bool   ShowCommentHUD           = true;
input bool   ShowPerformanceHUD       = true;
input DRPerformanceWindowMode PerformanceWindow = DR_PERF_ALL;
input DRWeekResetDay WeeklyPerformanceResetDay = DR_WEEK_RESET_SATURDAY;
input bool   EnableCandleScreenshots  = false;
input int    ScreenshotWidth          = 1600;
input int    ScreenshotHeight         = 900;
input string ScreenshotBaseFolder     = "DigitalRogue\\CandleScreenshots";
input bool   SeparateFolderPerChart   = true;

input bool Enable_H4SweepReclaimShort = true;
input bool Enable_L4SweepReclaimLong  = true;
input bool Enable_H4AcceptanceLong    = true;
input bool Enable_L4AcceptanceShort   = true;
input bool Enable_H3RejectionShort    = false;
input bool Enable_L3RejectionLong     = false;
input bool Enable_H3H4RejectionShort  = true;
input bool Enable_L3L4RejectionLong   = true;
input bool Enable_H5ExhaustionShort   = true;
input bool Enable_L5ExhaustionLong    = true;

string   g_logFileName      = "";
string   g_lastStatus       = "";
string   g_lastSetupSummary = "";
datetime g_lastBarTime      = 0;
datetime g_lastTradeBar     = 0;
datetime g_lastTrailBar     = 0;
datetime g_reloadGuardClosedBar = 0;
int      g_atrHandle        = INVALID_HANDLE;
int      g_vwapHandle       = INVALID_HANDLE;
int      g_emaHandle        = INVALID_HANDLE;
int      g_h1FastHandle     = INVALID_HANDLE;
int      g_h1SlowHandle     = INVALID_HANDLE;
int      g_h4FastHandle     = INVALID_HANDLE;
int      g_h4SlowHandle     = INVALID_HANDLE;
int      g_camarillaHandle  = INVALID_HANDLE;
int      g_psarHandle       = INVALID_HANDLE;
string   g_topCandidateLines[3];
int      g_topCandidateRanks[3];
DRTradePerformanceStats g_perfStats;
datetime g_lastPerfRefresh = 0;
datetime g_lastScreenshotBar = 0;
int      g_lastEvalHour = -1;
bool     g_lastEvalSessionActive = false;
string   g_lastCloseReason = "";
datetime g_lastCloseReasonTime = 0;

string TradeLockKey(const datetime barTime)
{
   return StringFormat("DR_CAM_MOD_LOCK_%s_%d_%d_%I64d", _Symbol, (int)Period(), (int)MagicNumber, (long)barTime);
}

bool AcquireTradeLock(const datetime barTime)
{
   string key = TradeLockKey(barTime);
   if(GlobalVariableCheck(key))
      return false;
   return GlobalVariableTemp(key);
}

void ReleaseTradeLock(const datetime barTime)
{
   string key = TradeLockKey(barTime);
   if(GlobalVariableCheck(key))
      GlobalVariableDel(key);
}

void ResetTopCandidates()
{
   for(int i = 0; i < 3; i++)
   {
      g_topCandidateLines[i] = "";
      g_topCandidateRanks[i] = -999999;
   }
}

void RefreshPerformanceStats(const bool force=false)
{
   datetime nowTime = TimeCurrent();
   if(!force && g_lastPerfRefresh != 0 && (nowTime - g_lastPerfRefresh) < 10)
      return;

   datetime fromTime = 0;
   MqlDateTime dt;
   TimeToStruct(nowTime, dt);
   if(PerformanceWindow == DR_PERF_DAILY)
   {
      dt.hour = 0;
      dt.min = 0;
      dt.sec = 0;
      fromTime = StructToTime(dt);
   }
   else if(PerformanceWindow == DR_PERF_WEEKLY)
   {
      int resetDay = (int)WeeklyPerformanceResetDay;
      int daysBack = dt.day_of_week - resetDay;
      if(daysBack < 0)
         daysBack += 7;
      datetime dayStart = nowTime - (dt.hour * 3600 + dt.min * 60 + dt.sec);
      fromTime = dayStart - (daysBack * 86400);
   }
   else if(PerformanceWindow == DR_PERF_MONTHLY)
   {
      dt.day = 1;
      dt.hour = 0;
      dt.min = 0;
      dt.sec = 0;
      fromTime = StructToTime(dt);
   }

   DRTP_RefreshStats(MagicNumber, _Symbol, g_perfStats, fromTime, nowTime);
   g_lastPerfRefresh = nowTime;
}

string PerformanceWindowLabel()
{
   if(PerformanceWindow == DR_PERF_DAILY)
      return "Daily";
   if(PerformanceWindow == DR_PERF_WEEKLY)
      return "Weekly";
   if(PerformanceWindow == DR_PERF_MONTHLY)
      return "Monthly";
   return "All";
}

int CurrentServerHour()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour;
}

bool IsCurrentSessionActive()
{
   return DRCSM_IsAllowedSession(CurrentServerHour(), UseLondonSession, UseNewYorkSession);
}

string CurrentChartFolderName()
{
   return _Symbol + "_" + EnumToString((ENUM_TIMEFRAMES)_Period);
}

string SanitizeForFileName(string value)
{
   string badChars[] = {"\\","/",":","*","?","\"","<",">","|"," "};
   for(int i = 0; i < ArraySize(badChars); i++)
      StringReplace(value, badChars[i], "_");
   return value;
}

bool EnsureFolderTree(const string relativePath)
{
   string normalized = relativePath;
   StringReplace(normalized, "/", "\\");
   string parts[];
   int count = StringSplit(normalized, '\\', parts);
   if(count <= 0)
      return false;

   string current = "";
   for(int i = 0; i < count; i++)
   {
      if(parts[i] == "")
         continue;
      current = (current == "" ? parts[i] : current + "\\" + parts[i]);
      if(!FolderCreate(current) && GetLastError() != 5018)
         return false;
      ResetLastError();
   }
   return true;
}

void CaptureCandleScreenshot(const datetime closedBarTime)
{
   if(!EnableCandleScreenshots || closedBarTime <= 0 || closedBarTime == g_lastScreenshotBar)
      return;

   string folder = ScreenshotBaseFolder;
   if(SeparateFolderPerChart)
      folder += "\\" + CurrentChartFolderName();
   if(!EnsureFolderTree(folder))
      return;

   MqlDateTime dt;
   TimeToStruct(closedBarTime, dt);
   string stamp = StringFormat("%04d%02d%02d_%02d%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min);
   string statusTag = SanitizeForFileName(DisplayStatusLabel(g_lastStatus == "" ? "WAIT_NEW_BAR" : g_lastStatus));
   string fileName = folder + "\\" + stamp + "_" + statusTag + ".png";

   if(ChartScreenShot(ChartID(), fileName, ScreenshotWidth, ScreenshotHeight, ALIGN_RIGHT))
      g_lastScreenshotBar = closedBarTime;
}

struct StrategyContext
{
   datetime                currentBarTime;
   MqlRates                bar1;
   MqlRates                bar2;
   MqlRates                bar3;
   double                  spreadPoints;
   double                  atr;
   double                  vwap;
   double                  ema;
   double                  h1;
   double                  h2;
   double                  h3;
   double                  h4;
   double                  h5;
   double                  l1;
   double                  l2;
   double                  l3;
   double                  l4;
   double                  l5;
   double                  h1FastEMA;
   double                  h1SlowEMA;
   bool                    h1BiasBull;
   bool                    h1BiasBear;
   double                  h4FastEMA;
   double                  h4SlowEMA;
   bool                    h4BiasBull;
   bool                    h4BiasBear;
   int                     hour;
   double                  candleRange;
   double                  body;
   double                  bodyToRangeRatio;
   double                  upperWick;
   double                  lowerWick;
   DRCamSetupModuleContext moduleCtx;
};

string g_locationLabel = "";

bool NewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

double PipValuePerLot()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      return 0.0;
   return tickValue / tickSize;
}

double ReadIndicatorValue(const int handle,const int bufferIndex,const int shift)
{
   if(handle == INVALID_HANDLE)
      return 0.0;

   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, bufferIndex, shift, 1, buffer) < 1)
      return 0.0;
   if(buffer[0] == EMPTY_VALUE)
      return 0.0;
   return buffer[0];
}

void ResetHandle(int &handle)
{
   if(handle != INVALID_HANDLE)
      IndicatorRelease(handle);
   handle = INVALID_HANDLE;
}

bool EnsureATRHandle()
{
   if(g_atrHandle != INVALID_HANDLE)
      return true;
   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   return(g_atrHandle != INVALID_HANDLE);
}

bool EnsureVWAPHandle()
{
   if(g_vwapHandle != INVALID_HANDLE)
      return true;
   g_vwapHandle = iCustom(_Symbol, PERIOD_CURRENT, VWAPIndicatorName);
   return(g_vwapHandle != INVALID_HANDLE);
}

bool EnsureEMAHandle()
{
   if(g_emaHandle != INVALID_HANDLE)
      return true;
   g_emaHandle = iMA(_Symbol, PERIOD_CURRENT, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   return(g_emaHandle != INVALID_HANDLE);
}

bool EnsurePSARHandle()
{
   if(g_psarHandle != INVALID_HANDLE)
      return true;
   g_psarHandle = iSAR(_Symbol, PERIOD_CURRENT, PSARStep, PSARMaximum);
   return(g_psarHandle != INVALID_HANDLE);
}

bool EnsureH1FastHandle()
{
   if(g_h1FastHandle != INVALID_HANDLE)
      return true;
   g_h1FastHandle = iMA(_Symbol, PERIOD_H1, H1FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   return(g_h1FastHandle != INVALID_HANDLE);
}

bool EnsureH1SlowHandle()
{
   if(g_h1SlowHandle != INVALID_HANDLE)
      return true;
   g_h1SlowHandle = iMA(_Symbol, PERIOD_H1, H1SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   return(g_h1SlowHandle != INVALID_HANDLE);
}

bool EnsureH4FastHandle()
{
   if(g_h4FastHandle != INVALID_HANDLE)
      return true;
   g_h4FastHandle = iMA(_Symbol, PERIOD_H4, H4FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   return(g_h4FastHandle != INVALID_HANDLE);
}

bool EnsureH4SlowHandle()
{
   if(g_h4SlowHandle != INVALID_HANDLE)
      return true;
   g_h4SlowHandle = iMA(_Symbol, PERIOD_H4, H4SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   return(g_h4SlowHandle != INVALID_HANDLE);
}

bool EnsureCamarillaHandle()
{
   if(g_camarillaHandle != INVALID_HANDLE)
      return true;
   g_camarillaHandle = iCustom(_Symbol, PERIOD_CURRENT, CamarillaIndicatorName);
   return(g_camarillaHandle != INVALID_HANDLE);
}

double ReadATRWithRetry(const int shift)
{
   if(!EnsureATRHandle())
      return 0.0;

   double value = ReadIndicatorValue(g_atrHandle, 0, shift);
   if(value > 0.0)
      return value;

   ResetHandle(g_atrHandle);
   if(!EnsureATRHandle())
      return 0.0;

   return ReadIndicatorValue(g_atrHandle, 0, shift);
}

double ReadVWAPWithRetry(const int shift)
{
   if(!EnsureVWAPHandle())
      return 0.0;

   double value = ReadIndicatorValue(g_vwapHandle, 0, shift);
   if(value > 0.0)
      return value;

   ResetHandle(g_vwapHandle);
   if(!EnsureVWAPHandle())
      return 0.0;

   return ReadIndicatorValue(g_vwapHandle, 0, shift);
}

double ReadEMAWithRetry(const int shift)
{
   if(!EnsureEMAHandle())
      return 0.0;

   double value = ReadIndicatorValue(g_emaHandle, 0, shift);
   if(value > 0.0)
      return value;

   ResetHandle(g_emaHandle);
   if(!EnsureEMAHandle())
      return 0.0;

   return ReadIndicatorValue(g_emaHandle, 0, shift);
}

double ReadPSARWithRetry(const int shift)
{
   if(!EnsurePSARHandle())
      return 0.0;

   double value = ReadIndicatorValue(g_psarHandle, 0, shift);
   if(value > 0.0)
      return value;

   ResetHandle(g_psarHandle);
   if(!EnsurePSARHandle())
      return 0.0;

   return ReadIndicatorValue(g_psarHandle, 0, shift);
}

double ReadH1FastWithRetry(const int shift)
{
   if(!EnsureH1FastHandle())
      return 0.0;

   double value = ReadIndicatorValue(g_h1FastHandle, 0, shift);
   if(value > 0.0)
      return value;

   ResetHandle(g_h1FastHandle);
   if(!EnsureH1FastHandle())
      return 0.0;

   return ReadIndicatorValue(g_h1FastHandle, 0, shift);
}

double ReadH1SlowWithRetry(const int shift)
{
   if(!EnsureH1SlowHandle())
      return 0.0;

   double value = ReadIndicatorValue(g_h1SlowHandle, 0, shift);
   if(value > 0.0)
      return value;

   ResetHandle(g_h1SlowHandle);
   if(!EnsureH1SlowHandle())
      return 0.0;

   return ReadIndicatorValue(g_h1SlowHandle, 0, shift);
}

double ReadH4FastWithRetry(const int shift)
{
   if(!EnsureH4FastHandle())
      return 0.0;

   double value = ReadIndicatorValue(g_h4FastHandle, 0, shift);
   if(value > 0.0)
      return value;

   ResetHandle(g_h4FastHandle);
   if(!EnsureH4FastHandle())
      return 0.0;

   return ReadIndicatorValue(g_h4FastHandle, 0, shift);
}

double ReadH4SlowWithRetry(const int shift)
{
   if(!EnsureH4SlowHandle())
      return 0.0;

   double value = ReadIndicatorValue(g_h4SlowHandle, 0, shift);
   if(value > 0.0)
      return value;

   ResetHandle(g_h4SlowHandle);
   if(!EnsureH4SlowHandle())
      return 0.0;

   return ReadIndicatorValue(g_h4SlowHandle, 0, shift);
}

bool ComputeCamarillaFallback(const int shift,double &l1,double &l2,double &l3,double &l4,double &l5,double &h1,double &h2,double &h3,double &h4,double &h5)
{
   double prevHigh  = iHigh(_Symbol, PERIOD_D1, shift + 1);
   double prevLow   = iLow(_Symbol, PERIOD_D1, shift + 1);
   double prevClose = iClose(_Symbol, PERIOD_D1, shift + 1);
   if(prevHigh <= 0.0 || prevLow <= 0.0 || prevClose <= 0.0 || prevHigh <= prevLow)
      return false;

   double range  = prevHigh - prevLow;
   double factor = range * 1.1;

   l1 = prevClose - factor / 12.0;
   l2 = prevClose - factor / 6.0;
   l3 = prevClose - factor / 4.0;
   l4 = prevClose - factor / 2.0;
   h1 = prevClose + factor / 12.0;
   h2 = prevClose + factor / 6.0;
   h3 = prevClose + factor / 4.0;
   h4 = prevClose + factor / 2.0;
   h5 = (prevLow > 0.0 ? (prevHigh / prevLow) * prevClose : 0.0);
   l5 = (h5 > 0.0 ? (2.0 * prevClose) - h5 : 0.0);
   return(l1 > 0.0 && l2 > 0.0 && l3 > 0.0 && l4 > 0.0 && h1 > 0.0 && h2 > 0.0 && h3 > 0.0 && h4 > 0.0);
}

double GetATR(const int shift=1)       { return ReadATRWithRetry(shift); }
double GetVWAP(const int shift=1)      { return ReadVWAPWithRetry(shift); }
double GetEMA(const int shift=1)       { return ReadEMAWithRetry(shift); }
double GetPSAR(const int shift=1)      { return ReadPSARWithRetry(shift); }
double GetH1FastEMA(const int shift=1) { return ReadH1FastWithRetry(shift); }
double GetH1SlowEMA(const int shift=1) { return ReadH1SlowWithRetry(shift); }
double GetH4FastEMA(const int shift=1) { return ReadH4FastWithRetry(shift); }
double GetH4SlowEMA(const int shift=1) { return ReadH4SlowWithRetry(shift); }

bool GetCamarillaValues(const int shift,double &l1,double &l2,double &l3,double &l4,double &l5,double &h1,double &h2,double &h3,double &h4,double &h5)
{
   if(EnsureCamarillaHandle())
   {
      l1 = ReadIndicatorValue(g_camarillaHandle, 0, shift);
      l2 = ReadIndicatorValue(g_camarillaHandle, 1, shift);
      l3 = ReadIndicatorValue(g_camarillaHandle, 2, shift);
      l4 = ReadIndicatorValue(g_camarillaHandle, 3, shift);
      l5 = ReadIndicatorValue(g_camarillaHandle, 4, shift);
      h1 = ReadIndicatorValue(g_camarillaHandle, 5, shift);
      h2 = ReadIndicatorValue(g_camarillaHandle, 6, shift);
      h3 = ReadIndicatorValue(g_camarillaHandle, 7, shift);
      h4 = ReadIndicatorValue(g_camarillaHandle, 8, shift);
      h5 = ReadIndicatorValue(g_camarillaHandle, 9, shift);
      if(l1 > 0.0 && l2 > 0.0 && l3 > 0.0 && l4 > 0.0 && h1 > 0.0 && h2 > 0.0 && h3 > 0.0 && h4 > 0.0)
         return true;

      IndicatorRelease(g_camarillaHandle);
      g_camarillaHandle = INVALID_HANDLE;
   }

   return ComputeCamarillaFallback(shift, l1, l2, l3, l4, l5, h1, h2, h3, h4, h5);
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0)
      stepLot = 0.01;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / stepLot) * stepLot;
   return NormalizeDouble(lots, 2);
}

double CalcLotsFromRisk(const double entryPrice,const double stopPrice)
{
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
   double distance   = MathAbs(entryPrice - stopPrice);
   if(distance <= 0.0)
      return 0.0;
   double pipValue = PipValuePerLot();
   if(pipValue <= 0.0)
      return 0.0;
   return NormalizeLots(riskAmount / (distance * pipValue));
}

string CurrentMonthName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string months[12] = {"January","February","March","April","May","June","July","August","September","October","November","December"};
   if(dt.mon < 1 || dt.mon > 12)
      return "UnknownMonth";
   return months[dt.mon - 1];
}

void InitLogFile()
{
   if(!EnableLogging)
      return;
   g_logFileName = StringFormat("Camarilla_Modular_EA_v1_00_%s.csv", CurrentMonthName());
   int flags = FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(UseCommonLogFiles)
      flags |= FILE_COMMON;
   int h = FileOpen(g_logFileName, flags);
   if(h == INVALID_HANDLE)
      return;
   if(FileSize(h) == 0)
   {
      FileWriteString(h, "Time,Symbol,TF,Bid,Ask,H3,H4,H5,L3,L4,L5,VWAP,EMA,SpreadPoints,BestTag,BestScore,Decision,Reason,ATR,Lots,SL,TP\r\n");
   }
   FileClose(h);
}

void LogLine(const StrategyContext &ctx,const string bestTag,const int bestScore,const string decision,const string reason,const double lots,const double sl,const double tp)
{
   if(!EnableLogging)
      return;
   int flags = FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(UseCommonLogFiles)
      flags |= FILE_COMMON;
   int h = FileOpen(g_logFileName, flags);
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   string line =
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "," + _Symbol + "," + EnumToString((ENUM_TIMEFRAMES)_Period) + "," +
      DoubleToString(bid, _Digits) + "," + DoubleToString(ask, _Digits) + "," +
      DoubleToString(ctx.h3, _Digits) + "," + DoubleToString(ctx.h4, _Digits) + "," + DoubleToString(ctx.h5, _Digits) + "," +
      DoubleToString(ctx.l3, _Digits) + "," + DoubleToString(ctx.l4, _Digits) + "," + DoubleToString(ctx.l5, _Digits) + "," +
      DoubleToString(ctx.vwap, _Digits) + "," + DoubleToString(ctx.ema, _Digits) + "," + DoubleToString(ctx.spreadPoints, 1) + "," +
      bestTag + "," + IntegerToString(bestScore) + "," + decision + "," + reason + "," +
      DoubleToString(ctx.atr, _Digits) + "," + DoubleToString(lots, 2) + "," + DoubleToString(sl, _Digits) + "," + DoubleToString(tp, _Digits) + "\r\n";
   FileWriteString(h, line);
   FileClose(h);
}

string DisplayStatusLabel(const string status)
{
   if(status == "SKIP_RELOAD_GUARD")
      return "Reload Guard";
   if(status == "SKIP_NOT_BELOW_EMA20")
      return "Not Below EMA";
   if(status == "SKIP_ATR_UNAVAILABLE")
      return "ATR Unavailable";
   if(status == "SKIP_VWAP_UNAVAILABLE")
      return "VWAP Unavailable";
   if(status == "SKIP_EMA_UNAVAILABLE")
      return "EMA Unavailable";
   if(status == "SKIP_H1_EMA_UNAVAILABLE")
      return "H1 EMA Unavailable";
   if(status == "SKIP_H4_EMA_UNAVAILABLE")
      return "H4 EMA Unavailable";
   if(status == "SKIP_CAMARILLA_UNAVAILABLE")
      return "Camarilla Unavailable";
   if(status == "SKIP_H1_BEARISH_BIAS")
      return "H1 Bearish Bias";
   if(status == "SKIP_H1_BULLISH_BIAS")
      return "H1 Bullish Bias";
   if(status == "SKIP_H4_BEARISH_BIAS")
      return "H4 Bearish Bias";
   if(status == "SKIP_H4_BULLISH_BIAS")
      return "H4 Bullish Bias";
   if(status == "SKIP_LONG_NEAR_H5")
      return "Long Near H5";
   if(status == "SKIP_SHORT_NEAR_L5")
      return "Short Near L5";
   if(status == "SKIP_INSIDE_RANGE")
      return "Inside Range";
   if(status == "SKIP_SPREAD_TOO_WIDE")
      return "Spread Too Wide";
   if(status == "SKIP_SESSION_FILTER")
      return "Out Of Session";
   if(status == "WAIT_NEW_BAR")
      return "Wait New Bar";
   return status;
}

string ClassifySinglePriceLocation(const double closePrice,const StrategyContext &ctx)
{
   if(closePrice >= ctx.h5)
      return "Above H5";
   if(closePrice >= ctx.h4)
      return "H4-H5";
   if(closePrice >= ctx.h3)
      return "H3-H4";
   if(closePrice >= ctx.h2)
      return "H2-H3";
   if(closePrice >= ctx.h1)
      return "H1-H2";
   if(closePrice > ctx.l1)
      return "Inside H1-L1";
   if(closePrice >= ctx.l2)
      return "L2-L1";
   if(closePrice >= ctx.l3)
      return "L3-L2";
   if(closePrice >= ctx.l4)
      return "L4-L3";
   if(closePrice >= ctx.l5)
      return "L5-L4";
   return "Below L5";
}

string ClassifyPriceLocation(const StrategyContext &ctx)
{
   string loc1 = ClassifySinglePriceLocation(ctx.bar1.close, ctx);
   string loc2 = ClassifySinglePriceLocation(ctx.bar2.close, ctx);
   string loc3 = ClassifySinglePriceLocation(ctx.bar3.close, ctx);

   if(loc1 == loc2 || loc1 == loc3)
      return loc1;
   if(loc2 == loc3)
      return loc2;

   double avgClose = (ctx.bar1.close + ctx.bar2.close + ctx.bar3.close) / 3.0;
   return ClassifySinglePriceLocation(avgClose, ctx);
}

bool ModuleRelevantForLocation(const int moduleType, const string location)
{
   if(location == "Inside H1-L1" || location == "H1-H2" || location == "L2-L1")
      return false;
   if(location == "H2-H3")
      return (moduleType == DR_CAM_SETUP_H3_REJECTION_SHORT || moduleType == DR_CAM_SETUP_H3_H4_REJECTION_SHORT);
   if(location == "H3-H4")
      return (moduleType == DR_CAM_SETUP_H3_H4_REJECTION_SHORT || moduleType == DR_CAM_SETUP_H3_REJECTION_SHORT ||
              moduleType == DR_CAM_SETUP_H4_SWEEP_RECLAIM_SHORT || moduleType == DR_CAM_SETUP_H4_ACCEPTANCE_LONG);
   if(location == "H4-H5" || location == "Above H5")
      return (moduleType == DR_CAM_SETUP_H4_SWEEP_RECLAIM_SHORT || moduleType == DR_CAM_SETUP_H4_ACCEPTANCE_LONG ||
              moduleType == DR_CAM_SETUP_H5_EXHAUSTION_SHORT || moduleType == DR_CAM_SETUP_H3_H4_REJECTION_SHORT);
   if(location == "L3-L2")
      return (moduleType == DR_CAM_SETUP_L3_REJECTION_LONG || moduleType == DR_CAM_SETUP_L3_L4_REJECTION_LONG);
   if(location == "L4-L3")
      return (moduleType == DR_CAM_SETUP_L3_L4_REJECTION_LONG || moduleType == DR_CAM_SETUP_L3_REJECTION_LONG ||
              moduleType == DR_CAM_SETUP_L4_SWEEP_RECLAIM_LONG || moduleType == DR_CAM_SETUP_L4_ACCEPTANCE_SHORT);
   if(location == "L5-L4" || location == "Below L5")
      return (moduleType == DR_CAM_SETUP_L4_SWEEP_RECLAIM_LONG || moduleType == DR_CAM_SETUP_L4_ACCEPTANCE_SHORT ||
              moduleType == DR_CAM_SETUP_L5_EXHAUSTION_LONG || moduleType == DR_CAM_SETUP_L3_L4_REJECTION_LONG);
   return true;
}

int CandidatePriority(const DRCamSetupModuleResult &candidate)
{
   if(candidate.detected)
      return 300 + candidate.score;
   if(StringFind(candidate.reason, "SKIP_SCORE_TOO_LOW") == 0)
      return 220 + candidate.score;
   if(StringFind(candidate.reason, "SKIP_NO_RECLAIM") == 0 || StringFind(candidate.reason, "SKIP_NO_ZONE_REJECTION") == 0 ||
      StringFind(candidate.reason, "SKIP_NO_H3_REJECTION") == 0 || StringFind(candidate.reason, "SKIP_NO_L3_REJECTION") == 0 ||
      StringFind(candidate.reason, "SKIP_NO_EXHAUSTION_REVERSAL") == 0 || StringFind(candidate.reason, "SKIP_NO_ACCEPTANCE") == 0)
      return 170 + candidate.score;
   if(StringFind(candidate.reason, "SKIP_NOT_BELOW") == 0 || StringFind(candidate.reason, "SKIP_NOT_ABOVE") == 0)
      return 140 + candidate.score;
   if(StringFind(candidate.reason, "SKIP_NO_H3") == 0 || StringFind(candidate.reason, "SKIP_NO_H4") == 0 ||
      StringFind(candidate.reason, "SKIP_NO_L3") == 0 || StringFind(candidate.reason, "SKIP_NO_L4") == 0 ||
      StringFind(candidate.reason, "SKIP_NO_H5") == 0 || StringFind(candidate.reason, "SKIP_NO_L5") == 0)
      return 100 + candidate.score;
   if(StringFind(candidate.reason, "SKIP_SESSION_FILTER") == 0 || StringFind(candidate.reason, "SKIP_SPREAD_TOO_WIDE") == 0)
      return 40;
   return candidate.score;
}

void AddCandidateHUD(const string moduleLabel, const DRCamSetupModuleResult &candidate)
{
   string state = (candidate.detected ? "Ready" : DisplayStatusLabel(candidate.reason));
   string line = moduleLabel + ": " + state;
   if(candidate.score > 0)
      line += " (" + IntegerToString(candidate.score) + ")";
   int rank = CandidatePriority(candidate);

   for(int i = 0; i < 3; i++)
   {
      if(rank > g_topCandidateRanks[i])
      {
         for(int j = 2; j > i; j--)
         {
            g_topCandidateRanks[j] = g_topCandidateRanks[j - 1];
            g_topCandidateLines[j] = g_topCandidateLines[j - 1];
         }
         g_topCandidateRanks[i] = rank;
         g_topCandidateLines[i] = line;
         break;
      }
   }
}

string CurrentH1BiasLabel()
{
   if(!UseH1TrendBias)
      return "OFF";
   double fast = GetH1FastEMA(1);
   double slow = GetH1SlowEMA(1);
   if(fast <= 0.0 || slow <= 0.0)
      return "ON";
   if(fast > slow)
      return "Bullish";
   if(fast < slow)
      return "Bearish";
   return "Neutral";
}

string CurrentH4BiasLabel()
{
   if(!UseH4TrendBias)
      return "OFF";
   double fast = GetH4FastEMA(1);
   double slow = GetH4SlowEMA(1);
   if(fast <= 0.0 || slow <= 0.0)
      return "ON";
   if(fast > slow)
      return "Bullish";
   if(fast < slow)
      return "Bearish";
   return "Neutral";
}

string CurrentLastCloseReason()
{
   if(g_lastCloseReason != "" && g_lastCloseReasonTime >= g_perfStats.lastClosedTime)
      return g_lastCloseReason;
   return g_perfStats.lastCloseReason;
}

void MarkCloseReason(const string reason)
{
   g_lastCloseReason = reason;
   g_lastCloseReasonTime = TimeCurrent();
   g_lastPerfRefresh = 0;
}

void UpdateComment()
{
   if(!ShowCommentHUD)
   {
      Comment("");
      return;
   }
   if(ShowPerformanceHUD)
      RefreshPerformanceStats();
   string sessionLabel = (UseLondonSession && UseNewYorkSession ? "London+NY" : (UseLondonSession ? "London" : (UseNewYorkSession ? "NY" : "All")));
   string evalHourLabel = (g_lastEvalHour >= 0 ? IntegerToString(g_lastEvalHour) : "-");
   string sessionState = (IsCurrentSessionActive() ? "Active" : "Off");
   string perfBlock = "";
   if(ShowPerformanceHUD)
   {
      perfBlock =
         "Perf Window: " + PerformanceWindowLabel() + "\n" +
         "Closed: " + IntegerToString(g_perfStats.closedTrades) +
         " | W: " + IntegerToString(g_perfStats.wins) +
         " | L: " + IntegerToString(g_perfStats.losses) + "\n" +
         "Win%: " + DoubleToString(g_perfStats.winRate, 1) +
         " | Net: " + DoubleToString(g_perfStats.netProfit, 2) + "\n" +
         "Gross+: " + DoubleToString(g_perfStats.grossProfit, 2) +
         " | Gross-: " + DoubleToString(g_perfStats.grossLoss, 2) + "\n" +
         "Last Closed: " + DoubleToString(g_perfStats.lastClosedPnl, 2) +
         (CurrentLastCloseReason() == "" ? "" : " (" + CurrentLastCloseReason() + ")") + "\n";
   }
   Comment(
      "Camarilla Modular EA v1.00\n",
      "Status: ", DisplayStatusLabel(g_lastStatus == "" ? "WAIT_NEW_BAR" : g_lastStatus), "\n",
      "Setup: ", (g_lastSetupSummary == "" ? "None" : g_lastSetupSummary), "\n",
      "Location: ", (g_locationLabel == "" ? "Unknown" : g_locationLabel), "\n",
      "Top: ", (g_topCandidateLines[0] == "" ? "None" : g_topCandidateLines[0]), "\n",
      "2nd: ", (g_topCandidateLines[1] == "" ? "-" : g_topCandidateLines[1]), "\n",
      "3rd: ", (g_topCandidateLines[2] == "" ? "-" : g_topCandidateLines[2]), "\n",
      "Sessions: ", sessionLabel, "\n",
      "Server Hr: ", IntegerToString(CurrentServerHour()), " | Session: ", sessionState, "\n",
      "Eval Hr: ", evalHourLabel, " | Eval Session: ", (g_lastEvalSessionActive ? "Active" : "Off"), "\n",
      "EMA(", IntegerToString(EMAPeriod), ")\n",
      "PSAR Exit: ", (UsePSARExit ? "ON" : "OFF"), "\n",
      "H1 Bias: ", CurrentH1BiasLabel(), "\n",
      "H4 Bias: ", CurrentH4BiasLabel(), "\n",
      perfBlock,
      "Risk%: ", DoubleToString(RiskPercent, 2), "\n",
      "Magic: ", IntegerToString((int)MagicNumber)
   );
}

void ManageOpenTrades()
{
   if(!UseTrailingStop && !UseBreakEven && !UsePSARExit && !UseEMAFailureExit)
      return;
   double atr = GetATR(1);
   double ema = (UseEMAFailureExit ? GetEMA(1) : 0.0);
   double psar = (UsePSARExit ? GetPSAR(1) : 0.0);
   if((UseTrailingStop || UseBreakEven) && atr <= 0.0)
      return;
   if(UseEMAFailureExit && ema <= 0.0)
      return;
   if(UsePSARExit && psar <= 0.0)
      return;
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(TrailOncePerBar && currentBar == g_lastTrailBar)
      return;
   double minStep = atr * MinTrailStepATR;
   bool modifiedAny = false;
   bool closedAny = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double current   = (type == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK));
      double riskDist  = MathAbs(openPrice - sl);
      if(riskDist <= 0.0)
         continue;
      double candidateSL = sl;
      bool changed = false;
      if(type == POSITION_TYPE_BUY)
      {
         double currentR = (current - openPrice) / riskDist;
         bool beActive = (current - openPrice >= riskDist * BreakEvenAtR);
        if(UseEMAFailureExit && currentR < EMAFailureExitUntilR && iClose(_Symbol, PERIOD_CURRENT, 1) < ema)
        {
            if(trade.PositionClose(_Symbol))
            {
               MarkCloseReason("EMA Failure");
               closedAny = true;
               continue;
            }
         }
        if(UsePSARExit && beActive && psar > 0.0 && iClose(_Symbol, PERIOD_CURRENT, 1) < psar)
        {
            if(trade.PositionClose(_Symbol))
            {
               MarkCloseReason("PSAR Exit");
               closedAny = true;
               continue;
            }
         }
         if(UseBreakEven && current - openPrice >= riskDist * BreakEvenAtR && (sl == 0.0 || sl < openPrice))
         {
            candidateSL = openPrice;
            changed = true;
         }
         if(UseTrailingStop && currentR >= TrailStartAtR)
         {
            double trailSL = current - atr * Trail_ATR_Mult;
            if(sl == 0.0 || trailSL > candidateSL)
            {
               candidateSL = trailSL;
               changed = true;
            }
         }
         if(changed && (sl == 0.0 || candidateSL > sl + minStep) && trade.PositionModify(_Symbol, candidateSL, tp))
            modifiedAny = true;
      }
      else
      {
         double currentR = (openPrice - current) / riskDist;
         bool beActive = (openPrice - current >= riskDist * BreakEvenAtR);
        if(UseEMAFailureExit && currentR < EMAFailureExitUntilR && iClose(_Symbol, PERIOD_CURRENT, 1) > ema)
        {
            if(trade.PositionClose(_Symbol))
            {
               MarkCloseReason("EMA Failure");
               closedAny = true;
               continue;
            }
         }
        if(UsePSARExit && beActive && psar > 0.0 && iClose(_Symbol, PERIOD_CURRENT, 1) > psar)
        {
            if(trade.PositionClose(_Symbol))
            {
               MarkCloseReason("PSAR Exit");
               closedAny = true;
               continue;
            }
         }
         if(UseBreakEven && openPrice - current >= riskDist * BreakEvenAtR && (sl == 0.0 || sl > openPrice))
         {
            candidateSL = openPrice;
            changed = true;
         }
         if(UseTrailingStop && currentR >= TrailStartAtR)
         {
            double trailSL = current + atr * Trail_ATR_Mult;
            if(sl == 0.0 || trailSL < candidateSL)
            {
               candidateSL = trailSL;
               changed = true;
            }
         }
         if(changed && (sl == 0.0 || candidateSL < sl - minStep) && trade.PositionModify(_Symbol, candidateSL, tp))
            modifiedAny = true;
      }
   }
   if(TrailOncePerBar && (modifiedAny || closedAny))
      g_lastTrailBar = currentBar;
}

bool LoadContext(StrategyContext &ctx,string &reason)
{
   reason = "";
   if(Bars(_Symbol, PERIOD_CURRENT) < ATR_Period + 10)
   {
      reason = "WAIT_FOR_HISTORY";
      return false;
   }
   ctx.currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   ctx.spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(ctx.spreadPoints > MaxSpreadPoints)
   {
      reason = "SKIP_SPREAD_TOO_WIDE";
      return false;
   }
   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 4, bars) < 4)
   {
      reason = "SKIP_NOT_ENOUGH_BARS";
      return false;
   }
   ctx.bar1 = bars[1];
   ctx.bar2 = bars[2];
   ctx.bar3 = bars[3];
   ctx.atr  = GetATR(1);
   ctx.vwap = GetVWAP(1);
   ctx.ema  = GetEMA(1);
   ctx.h1FastEMA = GetH1FastEMA(1);
   ctx.h1SlowEMA = GetH1SlowEMA(1);
   ctx.h4FastEMA = GetH4FastEMA(1);
   ctx.h4SlowEMA = GetH4SlowEMA(1);
   if(!GetCamarillaValues(1, ctx.l1, ctx.l2, ctx.l3, ctx.l4, ctx.l5, ctx.h1, ctx.h2, ctx.h3, ctx.h4, ctx.h5))
   {
      reason = "SKIP_CAMARILLA_UNAVAILABLE";
      return false;
   }
   if(ctx.atr <= 0.0)
   {
      reason = "SKIP_ATR_UNAVAILABLE";
      return false;
   }
   if(ctx.vwap <= 0.0)
   {
      reason = "SKIP_VWAP_UNAVAILABLE";
      return false;
   }
   if(ctx.ema <= 0.0)
   {
      reason = "SKIP_EMA_UNAVAILABLE";
      return false;
   }
   if(ctx.h1 <= 0.0 || ctx.l1 <= 0.0)
   {
      reason = "SKIP_CAMARILLA_UNAVAILABLE";
      return false;
   }
   if(UseH1TrendBias && (ctx.h1FastEMA <= 0.0 || ctx.h1SlowEMA <= 0.0))
   {
      reason = "SKIP_H1_EMA_UNAVAILABLE";
      return false;
   }
   if(UseH4TrendBias && (ctx.h4FastEMA <= 0.0 || ctx.h4SlowEMA <= 0.0))
   {
      reason = "SKIP_H4_EMA_UNAVAILABLE";
      return false;
   }
   ctx.h1BiasBull = (ctx.h1FastEMA > ctx.h1SlowEMA);
   ctx.h1BiasBear = (ctx.h1FastEMA < ctx.h1SlowEMA);
   ctx.h4BiasBull = (ctx.h4FastEMA > ctx.h4SlowEMA);
   ctx.h4BiasBear = (ctx.h4FastEMA < ctx.h4SlowEMA);
   g_locationLabel = ClassifyPriceLocation(ctx);
   MqlDateTime dt;
   TimeToStruct(ctx.bar1.time, dt);
   ctx.hour = dt.hour;
   g_lastEvalHour = ctx.hour;
   g_lastEvalSessionActive = DRCSM_IsAllowedSession(ctx.hour, UseLondonSession, UseNewYorkSession);
   ctx.candleRange      = ctx.bar1.high - ctx.bar1.low;
   ctx.body             = MathAbs(ctx.bar1.close - ctx.bar1.open);
   ctx.bodyToRangeRatio = (ctx.candleRange > _Point ? ctx.body / ctx.candleRange : 0.0);
   ctx.upperWick        = ctx.bar1.high - MathMax(ctx.bar1.open, ctx.bar1.close);
   ctx.lowerWick        = MathMin(ctx.bar1.open, ctx.bar1.close) - ctx.bar1.low;
   ctx.moduleCtx.bar1             = ctx.bar1;
   ctx.moduleCtx.bar2             = ctx.bar2;
   ctx.moduleCtx.bar3             = ctx.bar3;
   ctx.moduleCtx.atr              = ctx.atr;
   ctx.moduleCtx.ema20            = ctx.ema;
   ctx.moduleCtx.vwap             = ctx.vwap;
   ctx.moduleCtx.h3               = ctx.h3;
   ctx.moduleCtx.h4               = ctx.h4;
   ctx.moduleCtx.h5               = ctx.h5;
   ctx.moduleCtx.l3               = ctx.l3;
   ctx.moduleCtx.l4               = ctx.l4;
   ctx.moduleCtx.l5               = ctx.l5;
   ctx.moduleCtx.spreadPoints     = ctx.spreadPoints;
   ctx.moduleCtx.hour             = ctx.hour;
   ctx.moduleCtx.candleRange      = ctx.candleRange;
   ctx.moduleCtx.body             = ctx.body;
   ctx.moduleCtx.bodyToRangeRatio = ctx.bodyToRangeRatio;
   ctx.moduleCtx.upperWick        = ctx.upperWick;
   ctx.moduleCtx.lowerWick        = ctx.lowerWick;
   return true;
}

bool IsBetterCandidate(const DRCamSetupModuleResult &candidate,const DRCamSetupModuleResult &best)
{
   if(!candidate.detected)
      return false;
   if(!best.detected)
      return true;
   if(candidate.score > best.score)
      return true;
   if(candidate.score < best.score)
      return false;
   return((int)candidate.type < (int)best.type);
}

bool InUpperExtremeLongZone(const StrategyContext &ctx)
{
   if(ctx.h5 <= ctx.h4)
      return false;
   double threshold = ctx.h4 + (ctx.h5 - ctx.h4) * 0.75;
   return (ctx.bar1.close >= threshold || ctx.bar1.high >= ctx.h5);
}

bool InLowerExtremeShortZone(const StrategyContext &ctx)
{
   if(ctx.l5 >= ctx.l4)
      return false;
   double threshold = ctx.l4 - (ctx.l4 - ctx.l5) * 0.75;
   return (ctx.bar1.close <= threshold || ctx.bar1.low <= ctx.l5);
}

void EvaluateCandidate(const bool enabled,
                       DRCamSetupModuleResult &candidate,
                       const StrategyContext &ctx,
                       DRCamSetupModuleResult &best,
                       string &firstFailure)
{
   if(!enabled)
      return;
   if(candidate.detected)
   {
      if(candidate.bullish && InUpperExtremeLongZone(ctx))
      {
         candidate.detected = false;
         candidate.reason = "SKIP_LONG_NEAR_H5";
      }
      else if(candidate.bearish && InLowerExtremeShortZone(ctx))
      {
         candidate.detected = false;
         candidate.reason = "SKIP_SHORT_NEAR_L5";
      }
   }
   if(candidate.detected && UseH1TrendBias)
   {
      if(candidate.bullish && !ctx.h1BiasBull)
      {
         candidate.detected = false;
         candidate.reason = "SKIP_H1_BEARISH_BIAS";
      }
      else if(candidate.bearish && !ctx.h1BiasBear)
      {
         candidate.detected = false;
         candidate.reason = "SKIP_H1_BULLISH_BIAS";
      }
   }
   if(candidate.detected && UseH4TrendBias)
   {
      if(candidate.bullish && !ctx.h4BiasBull)
      {
         candidate.detected = false;
         candidate.reason = "SKIP_H4_BEARISH_BIAS";
      }
      else if(candidate.bearish && !ctx.h4BiasBear)
      {
         candidate.detected = false;
         candidate.reason = "SKIP_H4_BULLISH_BIAS";
      }
   }
   if(candidate.detected)
   {
      if(IsBetterCandidate(candidate, best))
         best = candidate;
   }
   else if(firstFailure == "")
   {
      firstFailure = candidate.reason;
   }
}

bool ExecuteTrade(const StrategyContext &ctx,const DRCamSetupModuleResult &best,string &reason)
{
   bool isBuy = best.bullish && !best.bearish;
   double price = (isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
   if(price <= 0.0)
   {
      reason = best.tag + "_PRICE_UNAVAILABLE";
      return false;
   }
   double stopAnchor = (isBuy ? ctx.bar1.low : ctx.bar1.high);
   if(isBuy && (best.type == DR_CAM_SETUP_L4_SWEEP_RECLAIM_LONG || best.type == DR_CAM_SETUP_L3_L4_REJECTION_LONG || best.type == DR_CAM_SETUP_L5_EXHAUSTION_LONG))
      stopAnchor = MathMin(stopAnchor, ctx.l4);
   if(!isBuy && (best.type == DR_CAM_SETUP_H4_SWEEP_RECLAIM_SHORT || best.type == DR_CAM_SETUP_H3_H4_REJECTION_SHORT || best.type == DR_CAM_SETUP_H5_EXHAUSTION_SHORT))
      stopAnchor = MathMax(stopAnchor, ctx.h4);
   if(!isBuy && best.type == DR_CAM_SETUP_L4_ACCEPTANCE_SHORT)
      stopAnchor = MathMax(stopAnchor, ctx.l4);
   if(isBuy && best.type == DR_CAM_SETUP_H4_ACCEPTANCE_LONG)
      stopAnchor = MathMin(stopAnchor, ctx.h4);
   double sl = (isBuy ? stopAnchor - ctx.atr * ATR_SL_Mult : stopAnchor + ctx.atr * ATR_SL_Mult);
   double tp = (isBuy ? price + (price - sl) * RR_For_TP : price - (sl - price) * RR_For_TP);
   double lots = CalcLotsFromRisk(price, sl);
   if(lots <= 0.0)
   {
      reason = best.tag + "_LOT_INVALID";
      LogLine(ctx, best.tag, best.score, "BLOCKED", reason, lots, sl, tp);
      return false;
   }
   bool sent = (isBuy ? trade.Buy(lots, _Symbol, price, sl, tp, best.tag) : trade.Sell(lots, _Symbol, price, sl, tp, best.tag));
   if(sent)
   {
      g_lastTradeBar = ctx.currentBarTime;
      g_lastStatus = best.tag;
      g_lastSetupSummary = best.summary + " | Score " + IntegerToString(best.score);
      LogLine(ctx, best.tag, best.score, (isBuy ? "BUY" : "SELL"), best.tag, lots, sl, tp);
      return true;
   }
   reason = best.tag + "_ORDER_FAILED";
   LogLine(ctx, best.tag, best.score, "BLOCKED", reason, lots, sl, tp);
   return false;
}

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   if(!EnsureATRHandle() || !EnsureVWAPHandle() || !EnsureEMAHandle() || !EnsurePSARHandle() || !EnsureCamarillaHandle() ||
      !EnsureH1FastHandle() || !EnsureH1SlowHandle() ||
      (UseH4TrendBias && (!EnsureH4FastHandle() || !EnsureH4SlowHandle())))
      return(INIT_FAILED);
   InitLogFile();
   g_lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_reloadGuardClosedBar = g_lastBarTime;
   g_lastStatus = "READY";
   g_lastSetupSummary = "Waiting";
   ResetTopCandidates();
    DRTP_Reset(g_perfStats);
    RefreshPerformanceStats(true);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_vwapHandle != INVALID_HANDLE) IndicatorRelease(g_vwapHandle);
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   if(g_h1FastHandle != INVALID_HANDLE) IndicatorRelease(g_h1FastHandle);
   if(g_h1SlowHandle != INVALID_HANDLE) IndicatorRelease(g_h1SlowHandle);
   if(g_h4FastHandle != INVALID_HANDLE) IndicatorRelease(g_h4FastHandle);
   if(g_h4SlowHandle != INVALID_HANDLE) IndicatorRelease(g_h4SlowHandle);
   if(g_psarHandle != INVALID_HANDLE) IndicatorRelease(g_psarHandle);
   if(g_camarillaHandle != INVALID_HANDLE) IndicatorRelease(g_camarillaHandle);
}

void OnTick()
{
   UpdateComment();
   ManageOpenTrades();
   if(!NewBar())
   {
      if(g_lastStatus == "")
         g_lastStatus = "WAIT_NEW_BAR";
      UpdateComment();
      return;
   }
   datetime closedBarTime = iTime(_Symbol, PERIOD_CURRENT, 1);
   if(UseReloadGuard && g_reloadGuardClosedBar > 0 && closedBarTime > 0 && closedBarTime <= g_reloadGuardClosedBar)
   {
      g_lastStatus = "SKIP_RELOAD_GUARD";
      g_lastSetupSummary = "Waiting for post-reload candle";
      UpdateComment();
      CaptureCandleScreenshot(closedBarTime);
      return;
   }
   if(closedBarTime > g_reloadGuardClosedBar)
      g_reloadGuardClosedBar = 0;
   if(OneTradePerBar && g_lastTradeBar == iTime(_Symbol, PERIOD_CURRENT, 0))
   {
      g_lastStatus = "SKIP_ALREADY_TRADED_THIS_BAR";
      UpdateComment();
      CaptureCandleScreenshot(closedBarTime);
      return;
   }
   if(HasOpenPosition())
   {
      g_lastStatus = "SKIP_OPEN_POSITION_EXISTS";
      UpdateComment();
      CaptureCandleScreenshot(closedBarTime);
      return;
   }

   StrategyContext ctx;
   string reason;
   ResetTopCandidates();
   if(!LoadContext(ctx, reason))
   {
      g_lastStatus = reason;
      g_lastSetupSummary = "No setup";
      if(LogEachCandle)
         LogLine(ctx, "", 0, "WAIT", reason, 0.0, 0.0, 0.0);
      UpdateComment();
      CaptureCandleScreenshot(closedBarTime);
      return;
   }

   DRCamSetupModuleResult best;
   DRCamSetupModuleResult candidate;
   DRCSM_ResetResult(best);
   string firstFailure = "";
   if(g_locationLabel == "Inside H1-L1")
      firstFailure = "SKIP_INSIDE_RANGE";

   if(Enable_H4SweepReclaimShort && ModuleRelevantForLocation(DR_CAM_SETUP_H4_SWEEP_RECLAIM_SHORT, g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateH4SweepReclaimShort(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinSweepATRFrac, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("H4 Short", candidate); }
   if(Enable_L4SweepReclaimLong  && ModuleRelevantForLocation(DR_CAM_SETUP_L4_SWEEP_RECLAIM_LONG,  g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateL4SweepReclaimLong(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinSweepATRFrac, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("L4 Long", candidate); }
   if(Enable_H4AcceptanceLong    && ModuleRelevantForLocation(DR_CAM_SETUP_H4_ACCEPTANCE_LONG,    g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateH4AcceptanceLong(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("H4 Accept", candidate); }
   if(Enable_L4AcceptanceShort   && ModuleRelevantForLocation(DR_CAM_SETUP_L4_ACCEPTANCE_SHORT,   g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateL4AcceptanceShort(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("L4 Accept", candidate); }
   if(Enable_H3RejectionShort    && ModuleRelevantForLocation(DR_CAM_SETUP_H3_REJECTION_SHORT,    g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateH3RejectionShort(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("H3 Short", candidate); }
   if(Enable_L3RejectionLong     && ModuleRelevantForLocation(DR_CAM_SETUP_L3_REJECTION_LONG,     g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateL3RejectionLong(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("L3 Long", candidate); }
   if(Enable_H3H4RejectionShort  && ModuleRelevantForLocation(DR_CAM_SETUP_H3_H4_REJECTION_SHORT, g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateH3H4RejectionShort(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("H3-H4 Short", candidate); }
   if(Enable_L3L4RejectionLong   && ModuleRelevantForLocation(DR_CAM_SETUP_L3_L4_REJECTION_LONG,  g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateL3L4RejectionLong(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("L3-L4 Long", candidate); }
   if(Enable_H5ExhaustionShort   && ModuleRelevantForLocation(DR_CAM_SETUP_H5_EXHAUSTION_SHORT,   g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateH5ExhaustionShort(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("H5 Short", candidate); }
   if(Enable_L5ExhaustionLong    && ModuleRelevantForLocation(DR_CAM_SETUP_L5_EXHAUSTION_LONG,    g_locationLabel)) { DRCSM_ResetResult(candidate); DRCSM_EvaluateL5ExhaustionLong(ctx.moduleCtx, UseLondonSession, UseNewYorkSession, MinBodyToRange, MinScoreToTrade, candidate); EvaluateCandidate(true, candidate, ctx, best, firstFailure); AddCandidateHUD("L5 Long", candidate); }

   if(best.detected)
   {
      if(ExecuteTrade(ctx, best, reason))
      {
         UpdateComment();
         CaptureCandleScreenshot(closedBarTime);
         return;
      }
   }

   if(reason == "")
      reason = (firstFailure == "" ? "NO_CAMARILLA_SIGNAL" : firstFailure);
   g_lastStatus = reason;
   if(!best.detected)
      g_lastSetupSummary = "No setup";
   if(LogEachCandle)
      LogLine(ctx, (best.detected ? best.tag : ""), (best.detected ? best.score : 0), "WAIT", reason, 0.0, 0.0, 0.0);
   UpdateComment();
   CaptureCandleScreenshot(closedBarTime);
}
