//+------------------------------------------------------------------+
//|                                        Refresh_All_Open_Charts.mq5|
//| Force a soft reload of all open charts by toggling timeframe      |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

input bool OnlyCurrentSymbol = false;
input int  PauseMsBetweenCharts = 250;

ENUM_TIMEFRAMES AlternateTimeframe(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return PERIOD_M5;
      case PERIOD_M5:  return PERIOD_M1;
      case PERIOD_M15: return PERIOD_M5;
      case PERIOD_M30: return PERIOD_M15;
      case PERIOD_H1:  return PERIOD_M30;
      case PERIOD_H4:  return PERIOD_H1;
      case PERIOD_D1:  return PERIOD_H4;
      case PERIOD_W1:  return PERIOD_D1;
      case PERIOD_MN1: return PERIOD_W1;
      default:         return PERIOD_M1;
   }
}

void RefreshChart(const long chartId)
{
   string symbol = ChartSymbol(chartId);
   ENUM_TIMEFRAMES originalTf = (ENUM_TIMEFRAMES)ChartPeriod(chartId);
   ENUM_TIMEFRAMES tempTf = AlternateTimeframe(originalTf);

   if(tempTf == originalTf)
      tempTf = PERIOD_M1;

   // Force reinit of chart-bound indicators/EAs by briefly changing TF.
   ChartSetSymbolPeriod(chartId, symbol, tempTf);
   Sleep(100);
   ChartSetSymbolPeriod(chartId, symbol, originalTf);
   Sleep(PauseMsBetweenCharts);
   ChartRedraw(chartId);
}

void OnStart()
{
   string currentSymbol = _Symbol;
   int refreshed = 0;

   for(long chartId = ChartFirst(); chartId >= 0; chartId = ChartNext(chartId))
   {
      if(OnlyCurrentSymbol && ChartSymbol(chartId) != currentSymbol)
         continue;

      RefreshChart(chartId);
      refreshed++;
   }

   PrintFormat("Refresh_All_Open_Charts: refreshed %d chart(s)%s",
               refreshed,
               (OnlyCurrentSymbol ? " for current symbol only" : ""));
}
