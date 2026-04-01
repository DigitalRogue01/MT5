//+------------------------------------------------------------------+
//|                   Camarilla_L4_Sweep_Reclaim_Long_EA_v1_00.mq5   |
//| Focused Camarilla L4 sweep reclaim long EA                       |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include <DigitalRogue/CamarillaStrategyModules.mqh>

CTrade trade;

input double RiskPercent              = 2.0;
input int    ATR_Period               = 14;
input double ATR_SL_Mult              = 1.5;
input double RR_For_TP                = 2.0;
input bool   UseBreakEven             = true;
input double BreakEvenAtR             = 1.0;
input bool   UseTrailingStop          = true;
input bool   TrailOncePerBar          = true;
input double Trail_ATR_Mult           = 1.0;
input double MinTrailStepATR          = 0.25;
input int    SlippagePoints           = 20;
input long   MagicNumber              = 2301;
input bool   EnableLogging            = true;
input bool   UseCommonLogFiles        = true;
input bool   OneTradePerBar           = true;
input double MaxSpreadPoints          = 100;
input string VWAPIndicatorName        = "DigitalRogue\\VWAP";
input string CamarillaIndicatorName   = "DigitalRogue\\Camarilla_Levels";
input bool   UseLondonSession         = true;
input bool   UseNewYorkSession        = true;
input int    MinScoreToTrade          = 6;
input double MinBodyToRange           = 0.25;
input double MinSweepATRFrac          = 0.05;
input bool   LogEachCandle            = true;
input bool   ShowCommentHUD           = true;

string   g_logFileName       = "";
string   g_lastStatus        = "";
string   g_lastSetupSummary  = "";
datetime g_lastBarTime       = 0;
datetime g_lastTradeBar      = 0;
datetime g_lastTrailBar      = 0;
int      g_atrHandle         = INVALID_HANDLE;
int      g_vwapHandle        = INVALID_HANDLE;
int      g_ema20Handle       = INVALID_HANDLE;
int      g_camarillaHandle   = INVALID_HANDLE;

struct StrategyContext
{
   datetime                currentBarTime;
   MqlRates                bar1;
   MqlRates                bar2;
   double                  spreadPoints;
   double                  atr;
   double                  vwap;
   double                  ema20;
   double                  l4;
   int                     hour;
   double                  candleRange;
   double                  body;
   double                  bodyToRangeRatio;
   double                  upperWick;
   double                  lowerWick;
   DRCamSetupModuleContext moduleCtx;
};

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

bool EnsureEMA20Handle()
{
   if(g_ema20Handle != INVALID_HANDLE)
      return true;
   g_ema20Handle = iMA(_Symbol, PERIOD_CURRENT, 20, 0, MODE_EMA, PRICE_CLOSE);
   return(g_ema20Handle != INVALID_HANDLE);
}

bool EnsureCamarillaHandle()
{
   if(g_camarillaHandle != INVALID_HANDLE)
      return true;
   g_camarillaHandle = iCustom(_Symbol, PERIOD_CURRENT, CamarillaIndicatorName);
   return(g_camarillaHandle != INVALID_HANDLE);
}

double GetATR(const int shift=1)
{
   if(!EnsureATRHandle())
      return 0.0;
   return ReadIndicatorValue(g_atrHandle, 0, shift);
}

double GetVWAP(const int shift=1)
{
   if(!EnsureVWAPHandle())
      return 0.0;
   return ReadIndicatorValue(g_vwapHandle, 0, shift);
}

double GetEMA20(const int shift=1)
{
   if(!EnsureEMA20Handle())
      return 0.0;
   return ReadIndicatorValue(g_ema20Handle, 0, shift);
}

double GetCamarillaL4(const int shift=1)
{
   if(!EnsureCamarillaHandle())
      return 0.0;
   return ReadIndicatorValue(g_camarillaHandle, 3, shift);
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

   double lots = riskAmount / (distance * pipValue);
   return NormalizeLots(lots);
}

string CurrentMonthName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   string months[12] =
   {
      "January","February","March","April","May","June",
      "July","August","September","October","November","December"
   };

   if(dt.mon < 1 || dt.mon > 12)
      return "UnknownMonth";
   return months[dt.mon - 1];
}

void InitLogFile()
{
   if(!EnableLogging)
      return;

   g_logFileName = StringFormat("Camarilla_L4_Sweep_Reclaim_Long_EA_v1_00_%s.csv", CurrentMonthName());

   int flags = FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(UseCommonLogFiles)
      flags |= FILE_COMMON;

   int h = FileOpen(g_logFileName, flags);
   if(h == INVALID_HANDLE)
   {
      Print("LOG_INIT_FAILED | File=", g_logFileName, " | Error=", GetLastError());
      return;
   }

   if(FileSize(h) == 0)
   {
      string header =
         "Time,Symbol,TF,Bid,Ask,L4,VWAP,EMA20,SpreadPoints,BuyScore,Decision,Reason,ATR,Lots,SL,TP\r\n";
      FileWriteString(h, header);
   }
   FileClose(h);
}

void LogLine(const StrategyContext &ctx,
             const int buyScore,
             const string decision,
             const string reason,
             const double lots,
             const double sl,
             const double tp)
{
   if(!EnableLogging)
      return;

   int flags = FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(UseCommonLogFiles)
      flags |= FILE_COMMON;

   int h = FileOpen(g_logFileName, flags);
   if(h == INVALID_HANDLE)
   {
      Print("LOG_WRITE_FAILED | File=", g_logFileName, " | Error=", GetLastError());
      return;
   }

   FileSeek(h, 0, SEEK_END);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   string line =
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "," +
      _Symbol + "," +
      EnumToString((ENUM_TIMEFRAMES)_Period) + "," +
      DoubleToString(bid, _Digits) + "," +
      DoubleToString(ask, _Digits) + "," +
      DoubleToString(ctx.l4, _Digits) + "," +
      DoubleToString(ctx.vwap, _Digits) + "," +
      DoubleToString(ctx.ema20, _Digits) + "," +
      DoubleToString(ctx.spreadPoints, 1) + "," +
      IntegerToString(buyScore) + "," +
      decision + "," +
      reason + "," +
      DoubleToString(ctx.atr, _Digits) + "," +
      DoubleToString(lots, 2) + "," +
      DoubleToString(sl, _Digits) + "," +
      DoubleToString(tp, _Digits) + "\r\n";

   FileWriteString(h, line);
   FileClose(h);
}

void LogStatusRow(const string decision,const string reason)
{
   if(!EnableLogging)
      return;

   int flags = FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;
   if(UseCommonLogFiles)
      flags |= FILE_COMMON;

   int h = FileOpen(g_logFileName, flags);
   if(h == INVALID_HANDLE)
   {
      Print("LOG_STATUS_FAILED | File=", g_logFileName, " | Error=", GetLastError());
      return;
   }

   FileSeek(h, 0, SEEK_END);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   string line =
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "," +
      _Symbol + "," +
      EnumToString((ENUM_TIMEFRAMES)_Period) + "," +
      DoubleToString(bid, _Digits) + "," +
      DoubleToString(ask, _Digits) + "," +
      "0,0,0,0,0," +
      decision + "," +
      reason + "," +
      "0,0,0,0\r\n";

   FileWriteString(h, line);
   FileClose(h);
}

void LogNoTradeReason(const StrategyContext &ctx,const int buyScore,const string reason)
{
   g_lastStatus = reason;
   LogLine(ctx, buyScore, "WAIT", reason, 0.0, 0.0, 0.0);
}

void LogEarlyBarStatus(const string reason)
{
   if(!EnableLogging || !LogEachCandle)
      return;
   LogStatusRow("WAIT", reason);
}

string SessionSummary()
{
   if(UseLondonSession && UseNewYorkSession)
      return "London+NY";
   if(UseLondonSession)
      return "London";
   if(UseNewYorkSession)
      return "NY";
   return "All";
}

void UpdateComment()
{
   if(!ShowCommentHUD)
   {
      Comment("");
      return;
   }

   Comment(
      "Camarilla L4 Sweep Reclaim Long EA v1.00\n",
      "Status: ", (g_lastStatus == "" ? "WAIT_NEW_BAR" : g_lastStatus), "\n",
      "Setup: ", (g_lastSetupSummary == "" ? "None" : g_lastSetupSummary), "\n",
      "Sessions: ", SessionSummary(), "\n",
      "EMA20 Filter: ON\n",
      "Risk%: ", DoubleToString(RiskPercent, 2), "\n",
      "Magic: ", IntegerToString((int)MagicNumber)
   );
}

void ManageOpenTrades()
{
   if(!UseTrailingStop && !UseBreakEven)
      return;

   double atr = GetATR(1);
   if(atr <= 0.0)
      return;

   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(TrailOncePerBar && currentBar == g_lastTrailBar)
      return;

   double minStep = atr * MinTrailStepATR;
   bool modifiedAny = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double current   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double riskDist  = MathAbs(openPrice - sl);
      if(riskDist <= 0.0 || type != POSITION_TYPE_BUY)
         continue;

      double candidateSL = sl;
      bool changed = false;

      if(UseBreakEven && current - openPrice >= riskDist * BreakEvenAtR && (sl == 0.0 || sl < openPrice))
      {
         candidateSL = openPrice;
         changed = true;
      }

      if(UseTrailingStop)
      {
         double trailSL = current - atr * Trail_ATR_Mult;
         if(sl == 0.0 || trailSL > candidateSL)
         {
            candidateSL = trailSL;
            changed = true;
         }
      }

      if(changed && (sl == 0.0 || candidateSL > sl + minStep))
      {
         if(trade.PositionModify(_Symbol, candidateSL, tp))
            modifiedAny = true;
      }
   }

   if(TrailOncePerBar && modifiedAny)
      g_lastTrailBar = currentBar;
}

bool LoadContext(StrategyContext &ctx,string &reason)
{
   reason = "";

   int barsAvailable = Bars(_Symbol, PERIOD_CURRENT);
   if(barsAvailable < ATR_Period + 10)
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
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, bars) < 3)
   {
      reason = "SKIP_NOT_ENOUGH_BARS";
      return false;
   }

   ctx.bar1 = bars[1];
   ctx.bar2 = bars[2];
   ctx.atr  = GetATR(1);
   ctx.vwap = GetVWAP(1);
   ctx.ema20 = GetEMA20(1);
   ctx.l4   = GetCamarillaL4(1);

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
   if(ctx.ema20 <= 0.0)
   {
      reason = "SKIP_EMA20_UNAVAILABLE";
      return false;
   }
   if(ctx.l4 <= 0.0)
   {
      reason = "SKIP_L4_UNAVAILABLE";
      return false;
   }

   MqlDateTime dt;
   TimeToStruct(ctx.bar1.time, dt);
   ctx.hour = dt.hour;
   ctx.candleRange      = ctx.bar1.high - ctx.bar1.low;
   ctx.body             = MathAbs(ctx.bar1.close - ctx.bar1.open);
   ctx.bodyToRangeRatio = (ctx.candleRange > _Point ? ctx.body / ctx.candleRange : 0.0);
   ctx.upperWick        = ctx.bar1.high - MathMax(ctx.bar1.open, ctx.bar1.close);
   ctx.lowerWick        = MathMin(ctx.bar1.open, ctx.bar1.close) - ctx.bar1.low;

   ctx.moduleCtx.bar1             = ctx.bar1;
   ctx.moduleCtx.bar2             = ctx.bar2;
   ctx.moduleCtx.atr              = ctx.atr;
   ctx.moduleCtx.ema20            = ctx.ema20;
   ctx.moduleCtx.vwap             = ctx.vwap;
   ctx.moduleCtx.l4               = ctx.l4;
   ctx.moduleCtx.spreadPoints     = ctx.spreadPoints;
   ctx.moduleCtx.hour             = ctx.hour;
   ctx.moduleCtx.candleRange      = ctx.candleRange;
   ctx.moduleCtx.body             = ctx.body;
   ctx.moduleCtx.bodyToRangeRatio = ctx.bodyToRangeRatio;
   ctx.moduleCtx.upperWick        = ctx.upperWick;
   ctx.moduleCtx.lowerWick        = ctx.lowerWick;
   return true;
}

bool ExecuteLongTrade(const StrategyContext &ctx,
                      const string tag,
                      const int buyScore,
                      string &reason)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0)
   {
      reason = tag + "_PRICE_UNAVAILABLE";
      return false;
   }

   double stopAnchor = MathMin(ctx.bar1.low, ctx.l4);
   double sl = stopAnchor - (ctx.atr * ATR_SL_Mult);
   double tp = ask + (ask - sl) * RR_For_TP;
   double lots = CalcLotsFromRisk(ask, sl);

   if(lots <= 0.0)
   {
      reason = tag + "_LOT_INVALID";
      LogLine(ctx, buyScore, "BLOCKED", reason, lots, sl, tp);
      return false;
   }

   if(trade.Buy(lots, _Symbol, ask, sl, tp, tag))
   {
      g_lastTradeBar = ctx.currentBarTime;
      g_lastStatus = tag;
      g_lastSetupSummary = "L4 reclaim long fired";
      LogLine(ctx, buyScore, "BUY", tag, lots, sl, tp);
      return true;
   }

   reason = tag + "_ORDER_FAILED";
   LogLine(ctx, buyScore, "BLOCKED", reason, lots, sl, tp);
   return false;
}

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(!EnsureATRHandle())
      return(INIT_FAILED);
   if(!EnsureVWAPHandle())
      return(INIT_FAILED);
   if(!EnsureEMA20Handle())
      return(INIT_FAILED);
   if(!EnsureCamarillaHandle())
      return(INIT_FAILED);

   InitLogFile();
   LogStatusRow("INFO", "INIT_READY");
   g_lastStatus = "READY";
   g_lastSetupSummary = "Waiting";
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");

   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
   if(g_vwapHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_vwapHandle);
      g_vwapHandle = INVALID_HANDLE;
   }
   if(g_ema20Handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_ema20Handle);
      g_ema20Handle = INVALID_HANDLE;
   }
   if(g_camarillaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_camarillaHandle);
      g_camarillaHandle = INVALID_HANDLE;
   }
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

   if(OneTradePerBar && g_lastTradeBar == iTime(_Symbol, PERIOD_CURRENT, 0))
   {
      g_lastStatus = "SKIP_ALREADY_TRADED_THIS_BAR";
      LogEarlyBarStatus(g_lastStatus);
      UpdateComment();
      return;
   }

   if(HasOpenPosition())
   {
      g_lastStatus = "SKIP_OPEN_POSITION_EXISTS";
      LogEarlyBarStatus(g_lastStatus);
      UpdateComment();
      return;
   }

   StrategyContext ctx;
   string reason;
   if(!LoadContext(ctx, reason))
   {
      g_lastStatus = reason;
      g_lastSetupSummary = "No setup";
      LogEarlyBarStatus(reason);
      UpdateComment();
      return;
   }

   DRCamSetupModuleResult signal;
   DRCSM_ResetResult(signal);
   int buyScore = 0;

   if(DRCSM_EvaluateL4SweepReclaimLong(ctx.moduleCtx,
                                       UseLondonSession,
                                       UseNewYorkSession,
                                       MinBodyToRange,
                                       MinSweepATRFrac,
                                       MinScoreToTrade,
                                       signal))
   {
      buyScore = signal.score;
      g_lastSetupSummary = signal.summary + " | Score " + IntegerToString(signal.score);
      if(ExecuteLongTrade(ctx, signal.tag, signal.score, reason))
      {
         UpdateComment();
         return;
      }
   }

   if(reason == "")
      reason = signal.reason;
   g_lastStatus = reason;
   if(!signal.detected)
      g_lastSetupSummary = "No setup";
   if(LogEachCandle)
      LogNoTradeReason(ctx, buyScore, reason);
   UpdateComment();
}
