//+------------------------------------------------------------------+
//|                              PrevDay_VWAP_Q25_EA_v1_02.mq5       |
//| Version: v1.02                                                   |
//| Strategy: PDH/PDL + Q25 + combined PrevDay_VWAP_Levels indicator EA      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.02"
#property description "Prev-day PDH/PDL + Q25 + VWAP classifier with ATR risk, 2% sizing, and trailing protection."

#include <Trade/Trade.mqh>

#define PREV_DAY_INDICATOR_NAME "DigitalRogue\\PrevDay_VWAP_Levels"

// Version
input string EA_Version = "DigitalRogue\\PrevDay_VWAP_Q25_EA v1.02";

// Trend break classification
input bool   UseCloseForTrendBreak = true;
input double BreakBufferPoints     = 10.0;
input bool   UseVWAPFilter         = true;
input bool   UseTrendModeAfterBreak = true;
input bool   UseTriggerConfirmation = true;
input double ExtremePercent        = 25.0; // percent distance from PDH/PDL for premium/discount

// Execution controls
input bool   AllowBuy              = true;
input bool   AllowSell             = true;
input bool   OneTradePerBar        = true;
input bool   OnePositionAtATime    = true;
input bool   UseSpreadFilter       = true;
input int    MaxSpreadPoints       = 25;
input ulong  MagicNumber           = 26031303;
input bool   EnableDebugPrints     = true;
input bool   ShowChartDiagnostics  = true;
// Risk management
input double RiskPercent            = 2.0;
input int    ATR_Period             = 14;
input double ATR_Stop_Multiplier    = 1.5;
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_CURRENT;

// Profit protection
input bool   UseTrailingAfter1ATR      = true;
input double TrailTriggerATRMultiple   = 1.5;
input double TrailDistanceATRMultiple  = 1.5;
input bool   MoveToBreakevenFirst      = true;
input double BreakevenOffsetPoints     = 2.0;

enum MarketState
{
   MARKET_RANGE = 0,
   MARKET_TREND_BULL,
   MARKET_TREND_BEAR
};

CTrade trade;

int      g_atr_handle          = INVALID_HANDLE;
datetime g_last_bar_time       = 0;
datetime g_last_trade_bar_time = 0;
datetime g_last_debug_bar_time = 0;
MarketState g_last_state       = MARKET_RANGE;
int      g_trigger_handle      = INVALID_HANDLE;

enum PrevDayBufferIndex
{
   BUFFER_TRIGGER_LONG = 0,
   BUFFER_TRIGGER_SHORT,
   BUFFER_PDH,
   BUFFER_PDL,
   BUFFER_MID,
   BUFFER_DISCOUNT,
   BUFFER_PREMIUM,
   BUFFER_DOPEN,
   BUFFER_WOPEN,
   BUFFER_VWAP
};

// Forward declarations
bool GetPreviousDayLevels(double &pdh, double &pdl);
double GetVWAP(int shift=0);
double GetATRValue();
double CalculateRiskLotSize(double entryPrice, double stopPrice);
MarketState GetMarketState(double pdh, double pdl);
bool IsInLowerRangeZone(double price, double pdl, double lowerQ25);
bool IsInUpperRangeZone(double price, double upperQ25, double pdh);
bool IsRangeLongSetup(double price, double pdl, double lowerQ25, double vwap, double lastClose, double longTrigger);
bool IsRangeShortSetup(double price, double upperQ25, double pdh, double vwap, double lastClose, double shortTrigger);
bool IsTrendLongSetup(double price, double pdh, double vwap);
bool IsTrendShortSetup(double price, double pdl, double vwap);
bool ConfirmBreakHold(const double level, const bool is_short);
bool OpenBuy(double slPrice);
bool OpenSell(double slPrice);
void ManageOpenPositions();
bool HasOpenPosition();
bool IsOurOpenPosition();
bool IsSpreadOk();
string MarketStateToString(MarketState state);
bool IsVWAPLongPass(double price, double vwap);
bool IsVWAPShortPass(double price, double vwap);
void PrintDebugState(const double pdh,
                     const double pdl,
                     const double mid,
                     const double discount,
                     const double premium,
                     const double lowerQ25,
                     const double upperQ25,
                     const double vwap,
                     const double atr,
                     const MarketState state,
                     const bool lowerZone,
                     const bool upperZone,
                     const double longTrigger,
                     const double shortTrigger,
                     const double dailyOpen,
                     const double weeklyOpen);
bool IsTriggerSatisfiedLong(const double close, const double trigger);
bool IsTriggerSatisfiedShort(const double close, const double trigger);
bool GetIndicatorLevels(double &longTrigger,
                        double &shortTrigger,
                        double &pdh,
                        double &pdl,
                        double &mid,
                        double &discount,
                        double &premium,
                        double &dailyOpen,
                        double &weeklyOpen);
string CurrentMonthName();
void LogDealToCsv(const ulong deal_ticket);

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   g_atr_handle = iATR(_Symbol, ATR_Timeframe, ATR_Period);
   if(g_atr_handle == INVALID_HANDLE)
   {
      PrintFormat("%s: failed to create ATR handle. Error=%d", EA_Version, GetLastError());
      return(INIT_FAILED);
   }
   g_trigger_handle = iCustom(_Symbol, _Period, PREV_DAY_INDICATOR_NAME);
   if(g_trigger_handle == INVALID_HANDLE)
   {
      PrintFormat("%s: failed to create trigger indicator handle. Error=%d", EA_Version, GetLastError());
      return(INIT_FAILED);
   }

   PrintFormat("%s initialized on %s %s", EA_Version, _Symbol, EnumToString(_Period));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   if(g_trigger_handle != INVALID_HANDLE)
      IndicatorRelease(g_trigger_handle);
}

void OnTick()
{
   const datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   const bool is_new_bar = (bar_time != 0 && bar_time != g_last_bar_time);
   if(is_new_bar)
      g_last_bar_time = bar_time;

   ManageOpenPositions();

   if(UseSpreadFilter && !IsSpreadOk())
      return;

   if(OnePositionAtATime && HasOpenPosition())
      return;

   if(OneTradePerBar && g_last_trade_bar_time == bar_time)
      return;

    double pdh = 0.0, pdl = 0.0;
    double mid = 0.0;
    double discount = 0.0, premium = 0.0;
    double dailyOpen = 0.0, weeklyOpen = 0.0;
    double longTrigger = 0.0, shortTrigger = 0.0;

    const double atr = GetATRValue();
    if(atr <= 0.0)
       return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;
   const double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);

    bool indicatorReady = GetIndicatorLevels(longTrigger, shortTrigger,
                                             pdh, pdl, mid, discount,
                                             premium, dailyOpen, weeklyOpen);

    if(!indicatorReady && !GetPreviousDayLevels(pdh, pdl))
       return;

    const double range = pdh - pdl;
    if(range <= 0.0)
       return;

    const double clampedPercent = MathMax(0.0, MathMin(49.0, ExtremePercent));
    const double ratio = clampedPercent / 100.0;
    const double lowerQ25 = pdl + (range * 0.25);
    const double upperQ25 = pdh - (range * 0.25);

    if(!indicatorReady)
    {
       mid = (pdh + pdl) * 0.5;
       discount = pdl + (range * ratio);
       premium = pdh - (range * ratio);
       longTrigger = (pdl + discount) * 0.5;
       shortTrigger = (pdh + premium) * 0.5;
    }

    const double vwap = GetVWAP(0);
    const MarketState state = GetMarketState(pdh, pdl);
    const bool lowerZone = IsInLowerRangeZone(bid, pdl, lowerQ25);
    const bool upperZone = IsInUpperRangeZone(bid, upperQ25, pdh);

    if(is_new_bar)
       PrintDebugState(pdh, pdl, mid, discount, premium, lowerQ25, upperQ25,
                       vwap, atr, state, lowerZone, upperZone, longTrigger,
                       shortTrigger, dailyOpen, weeklyOpen);

   bool wantBuy = false;
   bool wantSell = false;

   if(state == MARKET_RANGE)
   {
      wantBuy = AllowBuy && IsRangeLongSetup(bid, pdl, lowerQ25, vwap, close1, longTrigger);
      wantSell = AllowSell && IsRangeShortSetup(bid, upperQ25, pdh, vwap, close1, shortTrigger);
   }
   else if(state == MARKET_TREND_BULL && UseTrendModeAfterBreak)
   {
      wantBuy = AllowBuy && IsTrendLongSetup(bid, pdh, vwap);
   }
   else if(state == MARKET_TREND_BEAR && UseTrendModeAfterBreak)
   {
      wantSell = AllowSell && IsTrendShortSetup(bid, pdl, vwap);
   }

   if(wantBuy && !wantSell)
   {
      const double sl = NormalizeDouble(ask - (atr * ATR_Stop_Multiplier), _Digits);
      if(OpenBuy(sl))
         g_last_trade_bar_time = bar_time;
   }
   else if(wantSell && !wantBuy)
   {
      const double sl = NormalizeDouble(bid + (atr * ATR_Stop_Multiplier), _Digits);
      if(OpenSell(sl))
         g_last_trade_bar_time = bar_time;
   }
}

bool GetPreviousDayLevels(double &pdh, double &pdl)
{
   pdh = iHigh(_Symbol, PERIOD_D1, 1);
   pdl = iLow(_Symbol, PERIOD_D1, 1);
   return(pdh > 0.0 && pdl > 0.0 && pdh > pdl);
}

double GetVWAP(int shift=0)
{
   if(g_trigger_handle != INVALID_HANDLE)
   {
      double temp[];
      ArrayResize(temp,1);
      if(CopyBuffer(g_trigger_handle, BUFFER_VWAP, shift, 1, temp) > 0 && temp[0] != EMPTY_VALUE && temp[0] > 0.0)
         return(temp[0]);
   }

   MqlRates rates[];
   const int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, 3000, rates);
   if(copied <= shift)
      return(0.0);

   ArraySetAsSeries(rates, true);
   const datetime bar_time = rates[shift].time;

   MqlDateTime dt;
   TimeToStruct(bar_time, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   const datetime day_start = StructToTime(dt);

   double cumulative_pv = 0.0;
   double cumulative_vol = 0.0;

   for(int i = shift; i < copied; i++)
   {
      if(rates[i].time < day_start)
         break;

      const double price = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      const double vol = (rates[i].real_volume > 0 ? (double)rates[i].real_volume : (double)rates[i].tick_volume);
      if(vol <= 0.0)
         continue;

      cumulative_pv += price * vol;
      cumulative_vol += vol;
   }

   if(cumulative_vol <= 0.0)
      return(0.0);

   return(cumulative_pv / cumulative_vol);
}

double GetATRValue()
{
   if(g_atr_handle == INVALID_HANDLE)
      return(0.0);

   double atr_buf[];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buf) < 1)
      return(0.0);

   return(atr_buf[0]);
}

double CalculateRiskLotSize(double entryPrice, double stopPrice)
{
   const double stop_distance = MathAbs(entryPrice - stopPrice);
   if(stop_distance <= 0.0)
      return(0.0);

   const double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
   if(risk_amount <= 0.0)
      return(0.0);

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0 || tick_value <= 0.0)
   {
      tick_size = _Point;
      tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   }
   if(tick_size <= 0.0 || tick_value <= 0.0)
      return(0.0);

   const double value_per_price_unit = tick_value / tick_size;
   const double loss_per_lot = stop_distance * value_per_price_unit;
   if(loss_per_lot <= 0.0)
      return(0.0);

   double lots = risk_amount / loss_per_lot;
   const double vol_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(vol_min <= 0.0 || vol_max <= 0.0 || vol_step <= 0.0)
      return(0.0);

   lots = MathFloor(lots / vol_step) * vol_step;
   lots = MathMax(lots, vol_min);
   lots = MathMin(lots, vol_max);
   if(lots < vol_min)
      return(0.0);

   return(NormalizeDouble(lots, 2));
}

MarketState GetMarketState(double pdh, double pdl)
{
   const double buffer = BreakBufferPoints * _Point;
   bool bull_break = false;
   bool bear_break = false;

   if(UseCloseForTrendBreak)
   {
      const double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
      bull_break = (close1 > (pdh + buffer));
      bear_break = (close1 < (pdl - buffer));
   }
   else
   {
      const double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
      const double low1 = iLow(_Symbol, PERIOD_CURRENT, 1);
      bull_break = (high1 > (pdh + buffer));
      bear_break = (low1 < (pdl - buffer));
   }

   if(bull_break && !bear_break)
      return(MARKET_TREND_BULL);
   if(bear_break && !bull_break)
      return(MARKET_TREND_BEAR);
   return(MARKET_RANGE);
}

bool IsInLowerRangeZone(double price, double pdl, double lowerQ25)
{
   return(price >= pdl && price <= lowerQ25);
}

bool IsInUpperRangeZone(double price, double upperQ25, double pdh)
{
   return(price >= upperQ25 && price <= pdh);
}

bool IsVWAPLongPass(double price, double vwap)
{
   if(!UseVWAPFilter)
      return(true);
   if(vwap <= 0.0)
      return(false);

   const double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   return(price >= vwap || close1 >= vwap);
}

bool IsVWAPShortPass(double price, double vwap)
{
   if(!UseVWAPFilter)
      return(true);
   if(vwap <= 0.0)
      return(false);

   const double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   return(price <= vwap || close1 <= vwap);
}

bool IsTriggerSatisfiedLong(const double close, const double trigger)
{
   if(!UseTriggerConfirmation || trigger <= 0.0 || close <= 0.0)
      return(true);
   return(close <= trigger);
}

bool IsTriggerSatisfiedShort(const double close, const double trigger)
{
   if(!UseTriggerConfirmation || trigger <= 0.0 || close <= 0.0)
      return(true);
   return(close >= trigger);
}

bool IsRangeLongSetup(double price, double pdl, double lowerQ25, double vwap, double lastClose, double longTrigger)
{
   return(IsInLowerRangeZone(price, pdl, lowerQ25)
          && IsVWAPLongPass(price, vwap)
          && IsTriggerSatisfiedLong(lastClose, longTrigger));
}

bool IsRangeShortSetup(double price, double upperQ25, double pdh, double vwap, double lastClose, double shortTrigger)
{
   return(IsInUpperRangeZone(price, upperQ25, pdh)
          && IsVWAPShortPass(price, vwap)
          && IsTriggerSatisfiedShort(lastClose, shortTrigger));
}

bool IsTrendLongSetup(double price, double pdh, double vwap)
{
   return((price >= pdh || iClose(_Symbol, PERIOD_CURRENT, 1) >= pdh) && ConfirmBreakHold(pdh, false) && IsVWAPLongPass(price, vwap));
}

bool IsTrendShortSetup(double price, double pdl, double vwap)
{
   return((price <= pdl || iClose(_Symbol, PERIOD_CURRENT, 1) <= pdl) && ConfirmBreakHold(pdl, true) && IsVWAPShortPass(price, vwap));
}

bool ConfirmBreakHold(const double level, const bool is_short)
{
   const double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   const double open0 = iOpen(_Symbol, PERIOD_CURRENT, 0);
   const double buffer = BreakBufferPoints * _Point;
   if(is_short)
      return(close1 < level - buffer && open0 < level - buffer);
   return(close1 > level + buffer && open0 > level + buffer);
}

bool OpenBuy(double slPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return(false);

   if(slPrice <= 0.0 || slPrice >= tick.ask)
      return(false);

   const double lots = CalculateRiskLotSize(tick.ask, slPrice);
   if(lots <= 0.0)
      return(false);

   if(trade.Buy(lots, _Symbol, 0.0, slPrice, 0.0, EA_Version + " BUY"))
   {
      if(EnableDebugPrints)
         PrintFormat("%s BUY opened lots=%.2f entry=%.5f sl=%.5f", EA_Version, lots, tick.ask, slPrice);
      return(true);
   }

   if(EnableDebugPrints)
      PrintFormat("%s BUY failed. Error=%d", EA_Version, GetLastError());
   return(false);
}

bool OpenSell(double slPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return(false);

   if(slPrice <= tick.bid)
      return(false);

   const double lots = CalculateRiskLotSize(tick.bid, slPrice);
   if(lots <= 0.0)
      return(false);

   if(trade.Sell(lots, _Symbol, 0.0, slPrice, 0.0, EA_Version + " SELL"))
   {
      if(EnableDebugPrints)
         PrintFormat("%s SELL opened lots=%.2f entry=%.5f sl=%.5f", EA_Version, lots, tick.bid, slPrice);
      return(true);
   }

   if(EnableDebugPrints)
      PrintFormat("%s SELL failed. Error=%d", EA_Version, GetLastError());
   return(false);
}

void ManageOpenPositions()
{
   if(!UseTrailingAfter1ATR)
      return;
   if(!IsOurOpenPosition())
      return;

   const double atr = GetATRValue();
   if(atr <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   const double current_sl = PositionGetDouble(POSITION_SL);
   const double current_tp = PositionGetDouble(POSITION_TP);

   const double trigger = atr * TrailTriggerATRMultiple;
   const double trail_distance = atr * TrailDistanceATRMultiple;
   const double be_offset = BreakevenOffsetPoints * _Point;

   double candidate_sl = current_sl;

   if(ptype == POSITION_TYPE_BUY)
   {
      const double profit = tick.bid - open_price;
      if(profit < trigger)
         return;

      if(MoveToBreakevenFirst)
      {
         const double be_price = NormalizeDouble(open_price + be_offset, _Digits);
         if(candidate_sl < be_price)
            candidate_sl = be_price;
      }

      const double trail_sl = NormalizeDouble(tick.bid - trail_distance, _Digits);
      if(trail_sl > candidate_sl)
         candidate_sl = trail_sl;

      if(candidate_sl > current_sl && candidate_sl < tick.bid)
      {
         if(!trade.PositionModify(_Symbol, candidate_sl, current_tp) && EnableDebugPrints)
            PrintFormat("%s BUY trail modify failed. Error=%d", EA_Version, GetLastError());
      }
   }
   else if(ptype == POSITION_TYPE_SELL)
   {
      const double profit = open_price - tick.ask;
      if(profit < trigger)
         return;

      if(MoveToBreakevenFirst)
      {
         const double be_price = NormalizeDouble(open_price - be_offset, _Digits);
         if(candidate_sl <= 0.0 || candidate_sl > be_price)
            candidate_sl = be_price;
      }

      const double trail_sl = NormalizeDouble(tick.ask + trail_distance, _Digits);
      if(candidate_sl <= 0.0 || trail_sl < candidate_sl)
         candidate_sl = trail_sl;

      if((current_sl <= 0.0 || candidate_sl < current_sl) && candidate_sl > tick.ask)
      {
         if(!trade.PositionModify(_Symbol, candidate_sl, current_tp) && EnableDebugPrints)
            PrintFormat("%s SELL trail modify failed. Error=%d", EA_Version, GetLastError());
      }
   }
}

bool HasOpenPosition()
{
   return(PositionSelect(_Symbol));
}

bool IsOurOpenPosition()
{
   if(!PositionSelect(_Symbol))
      return(false);
   return((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber);
}

bool IsSpreadOk()
{
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return(false);

   const double spread_points = (ask - bid) / _Point;
   return(spread_points <= MaxSpreadPoints);
}

string MarketStateToString(MarketState state)
{
   if(state == MARKET_TREND_BULL)
      return("TREND_BULL");
   if(state == MARKET_TREND_BEAR)
      return("TREND_BEAR");
   return("RANGE");
}

void PrintDebugState(const double pdh,
                     const double pdl,
                     const double mid,
                     const double discount,
                     const double premium,
                     const double lowerQ25,
                     const double upperQ25,
                     const double vwap,
                     const double atr,
                     const MarketState state,
                     const bool lowerZone,
                     const bool upperZone,
                     const double longTrigger,
                     const double shortTrigger,
                     const double dailyOpen,
                     const double weeklyOpen)
{
   if(!EnableDebugPrints)
      return;
   if(g_last_debug_bar_time == g_last_bar_time && g_last_state == state)
      return;

   g_last_debug_bar_time = g_last_bar_time;
   g_last_state = state;

   PrintFormat("%s | PDH=%.5f PDL=%.5f MID=%.5f DISC=%.5f PREM=%.5f DOPEN=%.5f WOPEN=%.5f LQ25=%.5f UQ25=%.5f VWAP=%.5f ATR=%.5f LTrig=%.5f STrig=%.5f State=%s LongZone=%s ShortZone=%s",
               EA_Version,
               pdh, pdl, mid, discount, premium, dailyOpen, weeklyOpen, lowerQ25, upperQ25, vwap, atr, longTrigger, shortTrigger,
               MarketStateToString(state),
               (lowerZone ? "true" : "false"),
               (upperZone ? "true" : "false"));

   if(ShowChartDiagnostics)
   {
      string c = EA_Version + "\n";
      c += StringFormat("PDH: %.5f  PDL: %.5f\n", pdh, pdl);
      c += StringFormat("Discount: %.5f  Premium: %.5f\n", discount, premium);
      c += StringFormat("LowerQ25: %.5f  UpperQ25: %.5f\n", lowerQ25, upperQ25);
      c += StringFormat("VWAP: %.5f  ATR: %.5f\n", vwap, atr);
      c += StringFormat("LongTrigger: %.5f  ShortTrigger: %.5f\n", longTrigger, shortTrigger);
      c += StringFormat("Mid: %.5f  D-Open: %.5f  W-Open: %.5f\n", mid, dailyOpen, weeklyOpen);
      c += StringFormat("State: %s  LongZone: %s  ShortZone: %s",
                        MarketStateToString(state),
                        (lowerZone ? "true" : "false"),
                       (upperZone ? "true" : "false"));
      Comment(c);
   }
}

bool CopyIndicatorBufferValue(const int bufferIndex, double &value)
{
   double temp[];
   ArrayResize(temp,1);
   const int copied = CopyBuffer(g_trigger_handle, bufferIndex, 0, 1, temp);
   if(copied < 1 || temp[0] == EMPTY_VALUE)
      return(false);
   value = temp[0];
   return(true);
}

bool GetIndicatorLevels(double &longTrigger,
                        double &shortTrigger,
                        double &pdh,
                        double &pdl,
                        double &mid,
                        double &discount,
                        double &premium,
                        double &dailyOpen,
                        double &weeklyOpen)
{
   if(g_trigger_handle == INVALID_HANDLE)
      return(false);

   if(!CopyIndicatorBufferValue(BUFFER_TRIGGER_LONG, longTrigger))
      return(false);
   if(!CopyIndicatorBufferValue(BUFFER_TRIGGER_SHORT, shortTrigger))
      return(false);
   if(!CopyIndicatorBufferValue(BUFFER_PDH, pdh))
      return(false);
   if(!CopyIndicatorBufferValue(BUFFER_PDL, pdl))
      return(false);
   if(!CopyIndicatorBufferValue(BUFFER_MID, mid))
      return(false);
   if(!CopyIndicatorBufferValue(BUFFER_DISCOUNT, discount))
      return(false);
   if(!CopyIndicatorBufferValue(BUFFER_PREMIUM, premium))
      return(false);

   // Optional buffers: opens may be EMPTY_VALUE when disabled in the indicator
   dailyOpen = 0.0;
   weeklyOpen = 0.0;
   CopyIndicatorBufferValue(BUFFER_DOPEN, dailyOpen);
   CopyIndicatorBufferValue(BUFFER_WOPEN, weeklyOpen);

   return(true);
}

string CurrentMonthName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string months[12] = {"January","February","March","April","May","June","July","August","September","October","November","December"};
   const int idx = MathMax(0, MathMin(11, dt.mon - 1));
   return(months[idx]);
}

void LogDealToCsv(const ulong deal_ticket)
{
   if(!HistoryDealSelect(deal_ticket))
      return;

   const string sym = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
   if(sym != _Symbol)
      return;

   const long magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
   if((ulong)magic != MagicNumber)
      return;

   const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   const ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   const double price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   const double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   const double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
   const datetime when = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);

   string entry_txt = "UNKNOWN";
   if(entry == DEAL_ENTRY_IN) entry_txt = "IN";
   else if(entry == DEAL_ENTRY_OUT) entry_txt = "OUT";
   else if(entry == DEAL_ENTRY_INOUT) entry_txt = "INOUT";

   string type_txt = EnumToString(type);
   string file_name = "PrevDay_VWAP_Q25_EA_" + CurrentMonthName() + ".csv";

   const int fh = FileOpen(file_name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(fh == INVALID_HANDLE)
      return;

   if(FileSize(fh) == 0)
      FileWrite(fh, "time", "symbol", "entry", "type", "volume", "price", "profit", "magic", "version");

   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh,
             TimeToString(when, TIME_DATE | TIME_SECONDS),
             sym,
             entry_txt,
             type_txt,
             DoubleToString(volume, 2),
             DoubleToString(price, _Digits),
             DoubleToString(profit, 2),
             IntegerToString((int)magic),
             EA_Version);
   FileClose(fh);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.deal > 0)
      LogDealToCsv(trans.deal);
}
