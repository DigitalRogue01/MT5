//+------------------------------------------------------------------+
//|                                                    Codex-Test.mq5 |
//| Test EA for "Previouse Day High and Low"                         |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Test EA that attaches the Previous Day High/Low indicator and reads its chart objects."

input string IndicatorName            = "DigitalRogue\\Previouse Day High and Low";
input bool   AttachIndicatorToChart   = true;
input bool   ShowChartComment         = true;
input bool   EnablePopupAlerts        = true;
input bool   AlertOnNewBarOnly        = true;
input double BreakBufferPoints        = 5.0;

string PDH_Line   = "PDH_LINE";
string PDL_Line   = "PDL_LINE";
string MID_Line   = "MID_LINE";
string QLO_Line   = "QLO_LINE";
string QHI_Line   = "QHI_LINE";
string DOPEN_Line = "DOPEN_LINE";
string WOPEN_Line = "WOPEN_LINE";

int      g_indicator_handle = INVALID_HANDLE;
datetime g_last_bar_time    = 0;
int      g_last_pdh_state   = 0;
int      g_last_pdl_state   = 0;
bool     g_states_ready     = false;

int OnInit()
{
   g_indicator_handle = iCustom(_Symbol, PERIOD_CURRENT, IndicatorName);
   if(g_indicator_handle == INVALID_HANDLE)
   {
      PrintFormat("Codex-Test: failed to load indicator '%s'. Error=%d", IndicatorName, GetLastError());
      return(INIT_FAILED);
   }

   if(AttachIndicatorToChart && !ChartIndicatorAdd(0, 0, g_indicator_handle))
      PrintFormat("Codex-Test: indicator loaded but ChartIndicatorAdd failed. Error=%d", GetLastError());

   Print("Codex-Test initialized.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(ShowChartComment)
      Comment("");

   if(g_indicator_handle != INVALID_HANDLE)
      IndicatorRelease(g_indicator_handle);
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

   const double buffer = BreakBufferPoints * _Point;
   const int pdh_state = RelationToLevel(bid, pdh, buffer);
   const int pdl_state = RelationToLevel(bid, pdl, buffer);

   if(!g_states_ready)
   {
      g_last_pdh_state = pdh_state;
      g_last_pdl_state = pdl_state;
      g_states_ready = true;
   }
   else if(!AlertOnNewBarOnly || is_new_bar)
   {
      ProcessAlerts(bid, pdh, pdl, pdh_state, pdl_state);
      g_last_pdh_state = pdh_state;
      g_last_pdl_state = pdl_state;
   }
   else
   {
      g_last_pdh_state = pdh_state;
      g_last_pdl_state = pdl_state;
   }

   if(ShowChartComment)
      ShowStatus(bid, pdh, pdl, mid, qlo, qhi, dopen, wopen, pdh_state, pdl_state);
}

double GetLinePrice(const string name)
{
   if(ObjectFind(0, name) < 0)
      return(0.0);

   return(ObjectGetDouble(0, name, OBJPROP_PRICE));
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
   status += StringFormat("Symbol: %s  TF: %s\n", _Symbol, EnumToString(_Period));
   status += StringFormat("Bid: %.5f\n", bid);
   status += StringFormat("PDH: %.5f  PDL: %.5f\n", pdh, pdl);

   if(mid > 0.0)
      status += StringFormat("Mid: %.5f\n", mid);
   if(qlo > 0.0 || qhi > 0.0)
      status += StringFormat("Discount: %.5f  Premium: %.5f\n", qlo, qhi);
   if(dopen > 0.0)
      status += StringFormat("Daily Open: %.5f\n", dopen);
   if(wopen > 0.0)
      status += StringFormat("Weekly Open: %.5f\n", wopen);

   status += StringFormat("Zone: %s\n", DescribeZone(bid, pdh, pdl, mid, qlo, qhi));
   status += StringFormat("PDH State: %s  PDL State: %s",
                          StateLabel(pdh_state),
                          StateLabel(pdl_state));

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

