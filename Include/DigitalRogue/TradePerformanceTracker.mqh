#ifndef __DIGITALROGUE_TRADE_PERFORMANCE_TRACKER_MQH__
#define __DIGITALROGUE_TRADE_PERFORMANCE_TRACKER_MQH__

struct DRTradePerformanceStats
{
   int      closedTrades;
   int      wins;
   int      losses;
   double   grossProfit;
   double   grossLoss;
   double   netProfit;
   double   winRate;
   double   lastClosedPnl;
   datetime lastClosedTime;
   string   lastCloseReason;
};

void DRTP_Reset(DRTradePerformanceStats &stats)
{
   stats.closedTrades   = 0;
   stats.wins           = 0;
   stats.losses         = 0;
   stats.grossProfit    = 0.0;
   stats.grossLoss      = 0.0;
   stats.netProfit      = 0.0;
   stats.winRate        = 0.0;
   stats.lastClosedPnl  = 0.0;
   stats.lastClosedTime = 0;
   stats.lastCloseReason = "";
}

string DRTP_MapDealReason(const long dealReason)
{
   if(dealReason == DEAL_REASON_TP)
      return "TP";
   if(dealReason == DEAL_REASON_SL)
      return "SL";
   if(dealReason == DEAL_REASON_SO)
      return "Stopout";
   if(dealReason == DEAL_REASON_CLIENT || dealReason == DEAL_REASON_MOBILE || dealReason == DEAL_REASON_WEB)
      return "Manual";
   if(dealReason == DEAL_REASON_EXPERT)
      return "Expert";
   return "Other";
}

bool DRTP_RefreshStats(const long magicNumber,
                       const string symbol,
                       DRTradePerformanceStats &stats,
                       const datetime fromTime = 0,
                       const datetime toTime = 0)
{
   DRTP_Reset(stats);

   datetime historyFrom = fromTime;
   datetime historyTo   = (toTime > 0 ? toTime : TimeCurrent());
   if(!HistorySelect(historyFrom, historyTo))
      return false;

   ulong tradeIds[];
   double tradePnls[];
   datetime tradeCloseTimes[];
   string tradeReasons[];
   bool tradeBelongs[];

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != symbol)
         continue;
      ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(positionId == 0)
         positionId = dealTicket;

      int index = -1;
      int count = ArraySize(tradeIds);
      for(int j = 0; j < count; j++)
      {
         if(tradeIds[j] == positionId)
         {
            index = j;
            break;
         }
      }

      if(index < 0)
      {
         index = count;
         ArrayResize(tradeIds, count + 1);
         ArrayResize(tradePnls, count + 1);
         ArrayResize(tradeCloseTimes, count + 1);
         ArrayResize(tradeReasons, count + 1);
         ArrayResize(tradeBelongs, count + 1);
         tradeIds[index] = positionId;
         tradePnls[index] = 0.0;
         tradeCloseTimes[index] = 0;
         tradeReasons[index] = "";
         tradeBelongs[index] = false;
      }

      long dealMagic = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      ENUM_DEAL_ENTRY entryType = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(dealMagic == magicNumber && (entryType == DEAL_ENTRY_IN || entryType == DEAL_ENTRY_INOUT || entryType == DEAL_ENTRY_OUT_BY))
         tradeBelongs[index] = true;

      if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_OUT_BY)
      {
         double pnl = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                      HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                      HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         datetime closeTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);

         tradePnls[index] += pnl;
         if(closeTime > tradeCloseTimes[index])
         {
            tradeCloseTimes[index] = closeTime;
            tradeReasons[index] = DRTP_MapDealReason(HistoryDealGetInteger(dealTicket, DEAL_REASON));
         }
      }
   }

   int totalTrades = ArraySize(tradeIds);
   for(int i = 0; i < totalTrades; i++)
   {
      if(!tradeBelongs[i] || tradeCloseTimes[i] <= 0)
         continue;

      double pnl = tradePnls[i];
      datetime closeTime = tradeCloseTimes[i];

      stats.closedTrades++;
      stats.netProfit += pnl;

      if(pnl >= 0.0)
      {
         stats.wins++;
         stats.grossProfit += pnl;
      }
      else
      {
         stats.losses++;
         stats.grossLoss += pnl;
      }

      if(closeTime >= stats.lastClosedTime)
      {
         stats.lastClosedTime = closeTime;
         stats.lastClosedPnl  = pnl;
         stats.lastCloseReason = tradeReasons[i];
      }
   }

   if(stats.closedTrades > 0)
      stats.winRate = (100.0 * stats.wins) / stats.closedTrades;

   return true;
}

#endif
