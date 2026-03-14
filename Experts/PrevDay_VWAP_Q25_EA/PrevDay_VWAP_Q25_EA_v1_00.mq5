//+------------------------------------------------------------------+
//|                              PrevDay_VWAP_Q25_EA_v1_00.mq5       |
//| Version: v1.00                                                    |
//| Strategy: PDH/PDL + Q25 + VWAP range/trend classification EA      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Prev-day PDH/PDL + Q25 + VWAP classifier with ATR risk, 2% sizing, and trailing protection."

#include <Trade/Trade.mqh>

// Version
input string EA_Version = "PrevDay_VWAP_Q25_EA v1.00";

// Trend break classification
input bool   UseCloseForTrendBreak = true;
input double BreakBufferPoints     = 10.0;
input bool   UseVWAPFilter         = true;
input bool   UseTrendModeAfterBreak = true;

// Execution controls
input bool   AllowBuy              = true;
input bool   AllowSell             = true;
input bool   OneTradePerBar        = true;
input bool   OnePositionAtATime    = true;
input bool   UseSpreadFilter       = true;
input int    MaxSpreadPoints       = 50;
input ulong  MagicNumber           = 26031303;
input bool   EnableDebugPrints     = true;
input bool   ShowChartDiagnostics  = false;

// Risk management
input double RiskPercent            = 2.0;
input int    ATR_Period             = 14;
input double ATR_Stop_Multiplier    = 1.5;
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_CURRENT;

// Profit protection
input bool   UseTrailingAfter1ATR      = true;
input double TrailTriggerATRMultiple   = 1.0;
input double TrailDistanceATRMultiple  = 1.0;
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

// Forward declarations
bool GetPreviousDayLevels(double &pdh, double &pdl);
bool GetQ25Levels(double pdh, double pdl, double &lowerQ25, double &upperQ25);
double GetVWAP(int shift=0);
double GetATRValue();
double CalculateRiskLotSize(double entryPrice, double stopPrice);
MarketState GetMarketState(double pdh, double pdl);
bool IsInLowerRangeZone(double price, double pdl, double lowerQ25);
bool IsInUpperRangeZone(double price, double upperQ25, double pdh);
bool IsRangeLongSetup(double price, double pdl, double lowerQ25, double vwap);
bool IsRangeShortSetup(double price, double upperQ25, double pdh, double vwap);
bool IsTrendLongSetup(double price, double pdh, double vwap);
bool IsTrendShortSetup(double price, double pdl, double vwap);
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
                     const double lowerQ25,
                     const double upperQ25,
                     const double vwap,
                     const double atr,
                     const MarketState state,
                     const bool lowerZone,
                     const bool upperZone);
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

   PrintFormat("%s initialized on %s %s", EA_Version, _Symbol, EnumToString(_Period));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
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
   if(!GetPreviousDayLevels(pdh, pdl))
      return;

   double lowerQ25 = 0.0, upperQ25 = 0.0;
   if(!GetQ25Levels(pdh, pdl, lowerQ25, upperQ25))
      return;

   const double atr = GetATRValue();
   if(atr <= 0.0)
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   const double vwap = GetVWAP(0);
   const MarketState state = GetMarketState(pdh, pdl);
   const bool lowerZone = IsInLowerRangeZone(bid, pdl, lowerQ25);
   const bool upperZone = IsInUpperRangeZone(bid, upperQ25, pdh);

   if(is_new_bar)
      PrintDebugState(pdh, pdl, lowerQ25, upperQ25, vwap, atr, state, lowerZone, upperZone);

   bool wantBuy = false;
   bool wantSell = false;

   if(state == MARKET_RANGE)
   {
      wantBuy = AllowBuy && IsRangeLongSetup(bid, pdl, lowerQ25, vwap);
      wantSell = AllowSell && IsRangeShortSetup(bid, upperQ25, pdh, vwap);
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

bool GetQ25Levels(double pdh, double pdl, double &lowerQ25, double &upperQ25)
{
   const double range = pdh - pdl;
   if(range <= 0.0)
      return(false);

   lowerQ25 = pdl + (range * 0.25);
   upperQ25 = pdh - (range * 0.25);
   return(lowerQ25 > pdl && upperQ25 < pdh && lowerQ25 < upperQ25);
}

double GetVWAP(int shift=0)
{
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

bool IsRangeLongSetup(double price, double pdl, double lowerQ25, double vwap)
{
   return(IsInLowerRangeZone(price, pdl, lowerQ25) && IsVWAPLongPass(price, vwap));
}

bool IsRangeShortSetup(double price, double upperQ25, double pdh, double vwap)
{
   return(IsInUpperRangeZone(price, upperQ25, pdh) && IsVWAPShortPass(price, vwap));
}

bool IsTrendLongSetup(double price, double pdh, double vwap)
{
   return((price >= pdh || iClose(_Symbol, PERIOD_CURRENT, 1) >= pdh) && IsVWAPLongPass(price, vwap));
}

bool IsTrendShortSetup(double price, double pdl, double vwap)
{
   return((price <= pdl || iClose(_Symbol, PERIOD_CURRENT, 1) <= pdl) && IsVWAPShortPass(price, vwap));
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
                     const double lowerQ25,
                     const double upperQ25,
                     const double vwap,
                     const double atr,
                     const MarketState state,
                     const bool lowerZone,
                     const bool upperZone)
{
   if(!EnableDebugPrints)
      return;
   if(g_last_debug_bar_time == g_last_bar_time && g_last_state == state)
      return;

   g_last_debug_bar_time = g_last_bar_time;
   g_last_state = state;

   PrintFormat("%s | PDH=%.5f PDL=%.5f LQ25=%.5f UQ25=%.5f VWAP=%.5f ATR=%.5f State=%s LongZone=%s ShortZone=%s",
               EA_Version,
               pdh, pdl, lowerQ25, upperQ25, vwap, atr,
               MarketStateToString(state),
               (lowerZone ? "true" : "false"),
               (upperZone ? "true" : "false"));

   if(ShowChartDiagnostics)
   {
      string c = EA_Version + "\n";
      c += StringFormat("PDH: %.5f  PDL: %.5f\n", pdh, pdl);
      c += StringFormat("LowerQ25: %.5f  UpperQ25: %.5f\n", lowerQ25, upperQ25);
      c += StringFormat("VWAP: %.5f  ATR: %.5f\n", vwap, atr);
      c += StringFormat("State: %s  LongZone: %s  ShortZone: %s",
                        MarketStateToString(state),
                        (lowerZone ? "true" : "false"),
                        (upperZone ? "true" : "false"));
      Comment(c);
   }
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
