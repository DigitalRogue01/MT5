//+------------------------------------------------------------------+
//|                                                    Codex-Test.mq5 |
//| Tester-only PDH/PDL breakout EA                                  |
//+------------------------------------------------------------------+
#property strict
#property version   "1.30"
#property description "Loads the Previous Day High/Low indicator, marks PDH/PDL breakout signals, and can place tester-only trades."

#include <Trade/Trade.mqh>

input string IndicatorName            = "DigitalRogue\\Previouse Day High and Low";
input bool   AttachIndicatorToChart   = true;
input bool   ShowChartComment         = true;
input bool   EnablePopupAlerts        = true;
input bool   AlertOnNewBarOnly        = true;
input double BreakBufferPoints        = 5.0;
input bool   EnableTesterTrades       = true;
input double FixedLotSize             = 0.10;
input int    ATRPeriod                = 14;
input double ATRStopMultiplier        = 1.0;
input double ATRTargetMultiplier      = 1.5;
input bool   EnableProfitProtection   = true;
input double BreakEvenTriggerATR      = 1.0;
input double BreakEvenOffsetATR       = 0.10;
input ulong  MagicNumber              = 260311;
input bool   DrawSignalMarkers        = true;

string PDH_Line   = "PDH_LINE";
string PDL_Line   = "PDL_LINE";
string MID_Line   = "MID_LINE";
string QLO_Line   = "QLO_LINE";
string QHI_Line   = "QHI_LINE";
string DOPEN_Line = "DOPEN_LINE";
string WOPEN_Line = "WOPEN_LINE";
string SignalPrefix = "CODEX_SIGNAL_";

int      g_indicator_handle = INVALID_HANDLE;
int      g_atr_handle       = INVALID_HANDLE;
datetime g_last_bar_time    = 0;
int      g_last_pdh_state   = 0;
int      g_last_pdl_state   = 0;
bool     g_states_ready     = false;
datetime g_last_signal_bar  = 0;
int      g_buy_signals      = 0;
int      g_sell_signals     = 0;
int      g_trade_count      = 0;
double   g_last_atr_value   = 0.0;

CTrade trade;

int OnInit()
{
   g_indicator_handle = iCustom(_Symbol, PERIOD_CURRENT, IndicatorName);
   if(g_indicator_handle == INVALID_HANDLE)
   {
      PrintFormat("Codex-Test: failed to load indicator '%s'. Error=%d", IndicatorName, GetLastError());
      return(INIT_FAILED);
   }

   g_atr_handle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      PrintFormat("Codex-Test: failed to create ATR handle. Error=%d", GetLastError());
      return(INIT_FAILED);
   }

   if(AttachIndicatorToChart && !ChartIndicatorAdd(0, 0, g_indicator_handle))
      PrintFormat("Codex-Test: indicator loaded but ChartIndicatorAdd failed. Error=%d", GetLastError());

   trade.SetExpertMagicNumber(MagicNumber);
   Print("Codex-Test initialized.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(ShowChartComment)
      Comment("");

   if(g_indicator_handle != INVALID_HANDLE)
      IndicatorRelease(g_indicator_handle);

   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
}

void OnTick()
{
   const datetime current_bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   const bool is_new_bar = (current_bar_time != 0 && current_bar_time != g_last_bar_time);
   if(is_new_bar)
      g_last_bar_time = current_bar_time;

   double pdh   = GetLinePrice(PDH_Line);
   double pdl   = GetLinePrice(PDL_Line);
   double mid   = GetLinePrice(MID_Line);
   double qlo   = GetLinePrice(QLO_Line);
   double qhi   = GetLinePrice(QHI_Line);
   double dopen = GetLinePrice(DOPEN_Line);
   double wopen = GetLinePrice(WOPEN_Line);

   if(pdh <= 0.0 || pdl <= 0.0)
   {
      if(ShowChartComment)
         Comment("Codex-Test\nWaiting for indicator objects...");
      return;
   }

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0)
      return;

   g_last_atr_value = GetATRValue();
   ManageOpenPosition();

   const double buffer = BreakBufferPoints * _Point;
   const int pdh_state = RelationToLevel(bid, pdh, buffer);
   const int pdl_state = RelationToLevel(bid, pdl, buffer);

   if(!g_states_ready)
   {
      g_last_pdh_state = pdh_state;
      g_last_pdl_state = pdl_state;
      g_states_ready = true;
   }
   else
   {
      if(!AlertOnNewBarOnly || is_new_bar)
         ProcessAlerts(bid, pdh, pdl, pdh_state, pdl_state);

      g_last_pdh_state = pdh_state;
      g_last_pdl_state = pdl_state;
   }

   if(is_new_bar)
      EvaluateSignalBar(pdh, pdl, buffer);

   if(ShowChartComment)
      ShowStatus(bid, pdh, pdl, mid, qlo, qhi, dopen, wopen, pdh_state, pdl_state);
}

double GetLinePrice(const string name)
{
   if(ObjectFind(0, name) < 0)
      return(0.0);

   return(ObjectGetDouble(0, name, OBJPROP_PRICE));
}

double GetATRValue()
{
   if(g_atr_handle == INVALID_HANDLE)
      return(0.0);

   double atr_buffer[];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buffer) < 1)
      return(0.0);

   return(atr_buffer[0]);
}

int RelationToLevel(const double price, const double level, const double buffer)
{
   if(level <= 0.0)
      return(0);

   if(price > level + buffer)
      return(1);

   if(price < level - buffer)
      return(-1);

   return(0);
}

void ProcessAlerts(const double bid,
                   const double pdh,
                   const double pdl,
                   const int pdh_state,
                   const int pdl_state)
{
   if(g_last_pdh_state <= 0 && pdh_state == 1)
      FireAlert(StringFormat("%s %s broke above PDH at %.5f (Bid %.5f)",
                             _Symbol, EnumToString(_Period), pdh, bid));

   if(g_last_pdl_state >= 0 && pdl_state == -1)
      FireAlert(StringFormat("%s %s broke below PDL at %.5f (Bid %.5f)",
                             _Symbol, EnumToString(_Period), pdl, bid));
}

void EvaluateSignalBar(const double pdh, const double pdl, const double buffer)
{
   const datetime signal_bar_time = iTime(_Symbol, PERIOD_CURRENT, 1);
   if(signal_bar_time == 0 || signal_bar_time == g_last_signal_bar)
      return;

   const double open1  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   const double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   const double high1  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   const double low1   = iLow(_Symbol, PERIOD_CURRENT, 1);

   const bool buy_break  = (open1 <= pdh + buffer && close1 > pdh + buffer);
   const bool sell_break = (open1 >= pdl - buffer && close1 < pdl - buffer);

   if(!buy_break && !sell_break)
      return;

   g_last_signal_bar = signal_bar_time;

   if(buy_break)
   {
      g_buy_signals++;
      CreateSignalMarker(signal_bar_time, low1, true);
      FireAlert(StringFormat("BUY signal on %s %s. Bar close %.5f broke PDH %.5f",
                             _Symbol, EnumToString(_Period), close1, pdh));
      if(CanTradeInTester())
         ExecuteTrade(ORDER_TYPE_BUY);
   }

   if(sell_break)
   {
      g_sell_signals++;
      CreateSignalMarker(signal_bar_time, high1, false);
      FireAlert(StringFormat("SELL signal on %s %s. Bar close %.5f broke PDL %.5f",
                             _Symbol, EnumToString(_Period), close1, pdl));
      if(CanTradeInTester())
         ExecuteTrade(ORDER_TYPE_SELL);
   }
}

bool CanTradeInTester()
{
   return(EnableTesterTrades && MQLInfoInteger(MQL_TESTER) != 0);
}

void ManageOpenPosition()
{
   if(!EnableProfitProtection || !CanTradeInTester())
      return;

   if(!PositionSelect(_Symbol))
      return;

   double atr = GetATRValue();
   if(atr <= 0.0)
      return;

   ENUM_POSITION_TYPE position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl = PositionGetDouble(POSITION_SL);
   double current_tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double trigger_distance = atr * BreakEvenTriggerATR;
   double offset_distance = atr * BreakEvenOffsetATR;

   if(position_type == POSITION_TYPE_BUY)
   {
      if(bid < open_price + trigger_distance)
         return;

      double protected_sl = NormalizeDouble(open_price + offset_distance, _Digits);
      if(current_sl >= protected_sl)
         return;

      if(!trade.PositionModify(_Symbol, protected_sl, current_tp))
         PrintFormat("Codex-Test: failed to protect BUY trade. Error=%d", GetLastError());
   }
   else if(position_type == POSITION_TYPE_SELL)
   {
      if(ask > open_price - trigger_distance)
         return;

      double protected_sl = NormalizeDouble(open_price - offset_distance, _Digits);
      if(current_sl > 0.0 && current_sl <= protected_sl)
         return;

      if(!trade.PositionModify(_Symbol, protected_sl, current_tp))
         PrintFormat("Codex-Test: failed to protect SELL trade. Error=%d", GetLastError());
   }
}

void ExecuteTrade(const ENUM_ORDER_TYPE order_type)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double atr = GetATRValue();
   if(atr <= 0.0)
   {
      Print("Codex-Test: skipped trade because ATR is unavailable.");
      return;
   }

   const double stop_distance = atr * ATRStopMultiplier;
   const double target_distance = atr * ATRTargetMultiplier;
   if(stop_distance <= 0.0 || target_distance <= 0.0)
      return;

   if(PositionSelect(_Symbol))
   {
      ENUM_POSITION_TYPE current_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((order_type == ORDER_TYPE_BUY  && current_type == POSITION_TYPE_BUY) ||
         (order_type == ORDER_TYPE_SELL && current_type == POSITION_TYPE_SELL))
         return;

      if(!trade.PositionClose(_Symbol))
      {
         PrintFormat("Codex-Test: failed to close opposite position. Error=%d", GetLastError());
         return;
      }
   }

   double entry = (order_type == ORDER_TYPE_BUY ? tick.ask : tick.bid);
   double sl = 0.0;
   double tp = 0.0;

   if(order_type == ORDER_TYPE_BUY)
   {
      sl = NormalizeDouble(entry - stop_distance, _Digits);
      tp = NormalizeDouble(entry + target_distance, _Digits);
      if(sl <= 0.0 || sl >= entry || tp <= entry)
      {
         Print("Codex-Test: skipped BUY trade because ATR levels are invalid.");
         return;
      }
      if(trade.Buy(FixedLotSize, _Symbol, 0.0, sl, tp, "Codex-Test BUY"))
         g_trade_count++;
      else
         PrintFormat("Codex-Test: BUY failed. Error=%d", GetLastError());
   }
   else if(order_type == ORDER_TYPE_SELL)
   {
      sl = NormalizeDouble(entry + stop_distance, _Digits);
      tp = NormalizeDouble(entry - target_distance, _Digits);
      if(sl <= entry || tp >= entry || tp <= 0.0)
      {
         Print("Codex-Test: skipped SELL trade because ATR levels are invalid.");
         return;
      }
      if(trade.Sell(FixedLotSize, _Symbol, 0.0, sl, tp, "Codex-Test SELL"))
         g_trade_count++;
      else
         PrintFormat("Codex-Test: SELL failed. Error=%d", GetLastError());
   }
}

void CreateSignalMarker(const datetime bar_time,
                        const double price,
                        const bool is_buy)
{
   if(!DrawSignalMarkers)
      return;

   string name = SignalPrefix + IntegerToString((int)bar_time) + (is_buy ? "_BUY" : "_SELL");
   if(ObjectFind(0, name) >= 0)
      return;

   if(!ObjectCreate(0, name, OBJ_ARROW, 0, bar_time, price))
      return;

   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, (is_buy ? 241 : 242));
   ObjectSetInteger(0, name, OBJPROP_COLOR, (is_buy ? clrLime : clrTomato));
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, (is_buy ? ANCHOR_BOTTOM : ANCHOR_TOP));
}

void FireAlert(const string message)
{
   Print("Codex-Test: ", message);
   if(EnablePopupAlerts)
      Alert(message);
}

string DescribeZone(const double bid,
                    const double pdh,
                    const double pdl,
                    const double mid,
                    const double qlo,
                    const double qhi)
{
   if(bid > pdh)
      return("Above PDH");

   if(bid < pdl)
      return("Below PDL");

   if(qhi > 0.0 && bid >= qhi)
      return("Premium");

   if(qlo > 0.0 && bid <= qlo)
      return("Discount");

   if(mid > 0.0)
   {
      if(bid > mid)
         return("Upper half");
      if(bid < mid)
         return("Lower half");
   }

   return("Inside range");
}

void ShowStatus(const double bid,
                const double pdh,
                const double pdl,
                const double mid,
                const double qlo,
                const double qhi,
                const double dopen,
                const double wopen,
                const int pdh_state,
                const int pdl_state)
{
   string status = "Codex-Test\n";
   status += StringFormat("Mode: %s\n", (CanTradeInTester() ? "Tester trading enabled" : "Signals only"));
   status += StringFormat("Symbol: %s  TF: %s\n", _Symbol, EnumToString(_Period));
   status += StringFormat("Bid: %.5f\n", bid);
   status += StringFormat("PDH: %.5f  PDL: %.5f\n", pdh, pdl);
   status += StringFormat("ATR(%d): %.5f\n", ATRPeriod, g_last_atr_value);

   if(mid > 0.0)
      status += StringFormat("Mid: %.5f\n", mid);
   if(qlo > 0.0 || qhi > 0.0)
      status += StringFormat("Discount: %.5f  Premium: %.5f\n", qlo, qhi);
   if(dopen > 0.0)
      status += StringFormat("Daily Open: %.5f\n", dopen);
   if(wopen > 0.0)
      status += StringFormat("Weekly Open: %.5f\n", wopen);

   status += StringFormat("Zone: %s\n", DescribeZone(bid, pdh, pdl, mid, qlo, qhi));
   status += StringFormat("PDH State: %s  PDL State: %s\n",
                          StateLabel(pdh_state),
                          StateLabel(pdl_state));
   status += StringFormat("Signals Buy/Sell: %d/%d  Trades: %d",
                          g_buy_signals,
                          g_sell_signals,
                          g_trade_count);

   Comment(status);
}

string StateLabel(const int state)
{
   if(state > 0)
      return("Above");
   if(state < 0)
      return("Below");
   return("Near");
}
