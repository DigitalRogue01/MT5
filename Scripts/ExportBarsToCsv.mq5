//+------------------------------------------------------------------+
//|                                             ExportBarsToCsv.mq5  |
//| Exports local MT5 bar history to CSV for offline analysis.       |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

input string          InpSymbol         = "EURAUD";
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_M15;
input string          InpStartDate      = "2024.01.01 00:00";
input string          InpEndDate        = "2024.12.31 23:59";
input string          InpOutputFile     = "EURAUD_M15_2024.csv";
input bool            InpUseCommonFiles = true;

void OnStart()
{
   const datetime start_time = StringToTime(InpStartDate);
   const datetime end_time = StringToTime(InpEndDate);

   if(start_time <= 0 || end_time <= 0 || end_time <= start_time)
   {
      PrintFormat("ExportBarsToCsv: invalid date range. Start='%s' End='%s'",
                  InpStartDate,
                  InpEndDate);
      return;
   }

   MqlRates rates[];
   const int copied = CopyRates(InpSymbol, InpTimeframe, start_time, end_time, rates);
   if(copied <= 0)
   {
      PrintFormat("ExportBarsToCsv: no bars copied for %s %s. Error=%d",
                  InpSymbol,
                  EnumToString(InpTimeframe),
                  GetLastError());
      return;
   }

   const int flags = FILE_WRITE | FILE_CSV | FILE_ANSI | (InpUseCommonFiles ? FILE_COMMON : 0);
   const int handle = FileOpen(InpOutputFile, flags);
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("ExportBarsToCsv: failed to open '%s'. Error=%d", InpOutputFile, GetLastError());
      return;
   }

   FileWrite(handle,
             "time",
             "open",
             "high",
             "low",
             "close",
             "tick_volume",
             "spread",
             "real_volume");

   ArraySetAsSeries(rates, false);
   for(int i = 0; i < copied; i++)
   {
      FileWrite(handle,
                TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES),
                DoubleToString(rates[i].open, _Digits),
                DoubleToString(rates[i].high, _Digits),
                DoubleToString(rates[i].low, _Digits),
                DoubleToString(rates[i].close, _Digits),
                (string)rates[i].tick_volume,
                (string)rates[i].spread,
                (string)rates[i].real_volume);
   }

   FileClose(handle);

   string base_path = TerminalInfoString(InpUseCommonFiles ? TERMINAL_COMMONDATA_PATH : TERMINAL_DATA_PATH);
   string full_path = base_path + "\\Files\\" + InpOutputFile;
   PrintFormat("ExportBarsToCsv: exported %d bars for %s %s to %s",
               copied,
               InpSymbol,
               EnumToString(InpTimeframe),
               full_path);
}
