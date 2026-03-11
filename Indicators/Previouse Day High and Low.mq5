//+------------------------------------------------------------------+
//| Previous Day High / Low + Equilibrium + Discount/Premium + Opens |
//| FAST + Safe + Alerts (1 per candle)                              |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property indicator_plots 0

// --- Visual inputs
input color PDH_Color   = clrRed;
input color PDL_Color   = clrDodgerBlue;
input int   LineWidth   = 2;
input bool  ShowLabels  = true;

input bool  ShowMidLine = true;
input bool  ShowQLines  = true;                 // Discount/Premium bands from Q%
input int   Q_Percent   = 10;                   // 10 => 10/90
input color MidQ_Color  = clrSilver;
input int   MidQ_Width  = 1;
input ENUM_LINE_STYLE MidQ_Style = STYLE_DASH;  // slim dashed reminder lines

// Label text options
input bool  UseEquilibriumLabel = true;         // MID label becomes EQUILIBRIUM if true

// --- Open lines (the "one level" + optional macro)
input bool  ShowDailyOpenLine  = true;
input bool  ShowWeeklyOpenLine = false;
input color Open_Color         = clrSilver;
input int   Open_Width         = 1;
input ENUM_LINE_STYLE Open_Style = STYLE_DOT;

// --- Alert inputs
input bool  EnableAlerts      = true;
input bool  AlertPDH_PDL      = true;
input bool  AlertMid_Q        = false;
input bool  AlertOpens        = true;           // Alerts for D-OPEN / W-OPEN
input bool  AlertOnTouch      = false;          // false=cross only, true=touch band counts
input int   TouchTolerancePts = 5;              // used if AlertOnTouch=true

// --- Alert behavior
input bool  LimitAlertsToOnePerCandle = true;

// --- Object names
string PDH_Line   = "PDH_LINE";
string PDL_Line   = "PDL_LINE";
string MID_Line   = "MID_LINE";
string QLO_Line   = "QLO_LINE";     // Discount
string QHI_Line   = "QHI_LINE";     // Premium
string DOPEN_Line = "DOPEN_LINE";
string WOPEN_Line = "WOPEN_LINE";

string PDH_Label   = "PDH_LABEL";
string PDL_Label   = "PDL_LABEL";
string MID_Label   = "MID_LABEL";
string QLO_Label   = "QLO_LABEL";
string QHI_Label   = "QHI_LABEL";
string DOPEN_Label = "DOPEN_LABEL";
string WOPEN_Label = "WOPEN_LABEL";

// --- State
datetime last_day = 0;

int lastSide_PDH   = 0;
int lastSide_PDL   = 0;
int lastSide_MID   = 0;
int lastSide_QLO   = 0;
int lastSide_QHI   = 0;
int lastSide_DOPEN = 0;
int lastSide_WOPEN = 0;

// one-alert-per-candle gate
datetime lastAlertBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   IndicatorSetString(INDICATOR_SHORTNAME,
      "Prev Day Levels + Discount/Premium + Opens + Alerts");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // lines
   ObjectDelete(0,PDH_Line);
   ObjectDelete(0,PDL_Line);
   ObjectDelete(0,MID_Line);
   ObjectDelete(0,QLO_Line);
   ObjectDelete(0,QHI_Line);
   ObjectDelete(0,DOPEN_Line);
   ObjectDelete(0,WOPEN_Line);

   // labels
   ObjectDelete(0,PDH_Label);
   ObjectDelete(0,PDL_Label);
   ObjectDelete(0,MID_Label);
   ObjectDelete(0,QLO_Label);
   ObjectDelete(0,QHI_Label);
   ObjectDelete(0,DOPEN_Label);
   ObjectDelete(0,WOPEN_Label);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   datetime d1 = iTime(_Symbol, PERIOD_D1, 0);
   if(d1 == 0) return(rates_total);

   // Recompute levels only on new D1 bar
   if(d1 != last_day)
   {
      last_day = d1;

      double pdh = iHigh(_Symbol, PERIOD_D1, 1);
      double pdl = iLow(_Symbol,  PERIOD_D1, 1);
      if(pdh == 0.0 || pdl == 0.0) return(rates_total);

      double range = pdh - pdl;
      if(range <= 0) return(rates_total);

      int q = (int)MathMax(1, MathMin(49, Q_Percent));
      double mid = (pdh + pdl) * 0.5;
      double qlo = pdl + range * (q / 100.0);
      double qhi = pdl + range * (1.0 - (q / 100.0));

      // Draw PDH/PDL
      CreateLine(PDH_Line, pdh, PDH_Color, LineWidth, STYLE_SOLID);
      CreateLine(PDL_Line, pdl, PDL_Color, LineWidth, STYLE_SOLID);

      // Equilibrium
      if(ShowMidLine)
         CreateLine(MID_Line, mid, MidQ_Color, MidQ_Width, MidQ_Style);
      else
         ObjectDelete(0, MID_Line);

      // Discount/Premium bands
      if(ShowQLines)
      {
         CreateLine(QLO_Line, qlo, MidQ_Color, MidQ_Width, MidQ_Style);
         CreateLine(QHI_Line, qhi, MidQ_Color, MidQ_Width, MidQ_Style);
      }
      else
      {
         ObjectDelete(0, QLO_Line);
         ObjectDelete(0, QHI_Line);
      }

      // Opens
      if(ShowDailyOpenLine)
      {
         double dopen = iOpen(_Symbol, PERIOD_D1, 0);
         if(dopen > 0)
            CreateLine(DOPEN_Line, dopen, Open_Color, Open_Width, Open_Style);
      }
      else ObjectDelete(0, DOPEN_Line);

      if(ShowWeeklyOpenLine)
      {
         double wopen = iOpen(_Symbol, PERIOD_W1, 0);
         if(wopen > 0)
            CreateLine(WOPEN_Line, wopen, Open_Color, Open_Width, STYLE_DASH);
      }
      else ObjectDelete(0, WOPEN_Line);

      // Labels
      if(ShowLabels)
      {
         CreateLabel(PDH_Label, "PDH", pdh, PDH_Color);
         CreateLabel(PDL_Label, "PDL", pdl, PDL_Color);

         if(ShowMidLine)
            CreateLabel(MID_Label, (UseEquilibriumLabel ? "EQUILIBRIUM" : "MID"), mid, MidQ_Color);
         else
            ObjectDelete(0, MID_Label);

         if(ShowQLines)
         {
            CreateLabel(QLO_Label, "DISCOUNT", qlo, MidQ_Color);
            CreateLabel(QHI_Label, "PREMIUM",  qhi, MidQ_Color);
         }
         else
         {
            ObjectDelete(0, QLO_Label);
            ObjectDelete(0, QHI_Label);
         }

         if(ShowDailyOpenLine)
         {
            double dopen = GetLinePrice(DOPEN_Line);
            if(dopen > 0) CreateLabel(DOPEN_Label, "D-OPEN", dopen, Open_Color);
            else ObjectDelete(0, DOPEN_Label);
         }
         else ObjectDelete(0, DOPEN_Label);

         if(ShowWeeklyOpenLine)
         {
            double wopen = GetLinePrice(WOPEN_Line);
            if(wopen > 0) CreateLabel(WOPEN_Label, "W-OPEN", wopen, Open_Color);
            else ObjectDelete(0, WOPEN_Label);
         }
         else ObjectDelete(0, WOPEN_Label);
      }

      // Reset alert states so we don't fire immediately after recalculation
      ResetAlertSides();
      lastAlertBarTime = 0;
   }
   else
   {
      if(ShowLabels)
         AlignLabels();
   }

   if(EnableAlerts)
      CheckAlerts(time);

   return(rates_total);
}

//+------------------------------------------------------------------+
// Alerts
//+------------------------------------------------------------------+
void ResetAlertSides()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0) return;

   lastSide_PDH   = Side(bid, GetLinePrice(PDH_Line), 0);
   lastSide_PDL   = Side(bid, GetLinePrice(PDL_Line), 0);
   lastSide_MID   = Side(bid, GetLinePrice(MID_Line), 0);
   lastSide_QLO   = Side(bid, GetLinePrice(QLO_Line), 0);
   lastSide_QHI   = Side(bid, GetLinePrice(QHI_Line), 0);
   lastSide_DOPEN = Side(bid, GetLinePrice(DOPEN_Line), 0);
   lastSide_WOPEN = Side(bid, GetLinePrice(WOPEN_Line), 0);
}

void CheckAlerts(const datetime &time[])
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0) return;

   datetime barTime = time[0];
   int tolPts = (AlertOnTouch ? TouchTolerancePts : 0);

   if(AlertPDH_PDL)
   {
      double pdh = GetLinePrice(PDH_Line);
      double pdl = GetLinePrice(PDL_Line);
      if(pdh > 0) CheckCrossOrTouch(barTime, "PDH", bid, pdh, tolPts, lastSide_PDH);
      if(pdl > 0) CheckCrossOrTouch(barTime, "PDL", bid, pdl, tolPts, lastSide_PDL);
   }

   if(AlertMid_Q)
   {
      if(ShowMidLine)
      {
         double mid = GetLinePrice(MID_Line);
         string midTag = (UseEquilibriumLabel ? "EQUILIBRIUM" : "MID");
         if(mid > 0) CheckCrossOrTouch(barTime, midTag, bid, mid, tolPts, lastSide_MID);
      }

      if(ShowQLines)
      {
         double qlo = GetLinePrice(QLO_Line);
         double qhi = GetLinePrice(QHI_Line);
         if(qlo > 0) CheckCrossOrTouch(barTime, "DISCOUNT", bid, qlo, tolPts, lastSide_QLO);
         if(qhi > 0) CheckCrossOrTouch(barTime, "PREMIUM",  bid, qhi, tolPts, lastSide_QHI);
      }
   }

   if(AlertOpens)
   {
      if(ShowDailyOpenLine)
      {
         double dopen = GetLinePrice(DOPEN_Line);
         if(dopen > 0) CheckCrossOrTouch(barTime, "D-OPEN", bid, dopen, tolPts, lastSide_DOPEN);
      }
      if(ShowWeeklyOpenLine)
      {
         double wopen = GetLinePrice(WOPEN_Line);
         if(wopen > 0) CheckCrossOrTouch(barTime, "W-OPEN", bid, wopen, tolPts, lastSide_WOPEN);
      }
   }
}

int Side(double price, double level, int tolPoints)
{
   if(level <= 0) return 0;
   double tol = tolPoints * _Point;
   if(price > level + tol) return +1;
   if(price < level - tol) return -1;
   return 0; // inside tolerance band
}

bool CanFireThisCandle(datetime barTime)
{
   if(!LimitAlertsToOnePerCandle) return true;
   return (lastAlertBarTime != barTime);
}

void MarkAlertFired(datetime barTime)
{
   if(LimitAlertsToOnePerCandle)
      lastAlertBarTime = barTime;
}

void FireAlert(datetime barTime, const string msg)
{
   if(!CanFireThisCandle(barTime)) return;
   Alert(msg);
   Print(msg);
   MarkAlertFired(barTime);
}

void CheckCrossOrTouch(datetime barTime, const string tag, double bid, double level, int tolPts, int &lastSide)
{
   // TOUCH mode: alert if price enters tolerance band (abs <= tol)
   if(AlertOnTouch && tolPts > 0)
   {
      double tol = tolPts * _Point;
      if(MathAbs(bid - level) <= tol)
      {
         FireAlert(barTime, StringFormat("%s: TOUCH %s @ %s (Bid=%s)",
                    _Symbol, tag,
                    DoubleToString(level, _Digits),
                    DoubleToString(bid, _Digits)));
         // still update side so cross logic stays sane
      }
   }

   // CROSS logic
   int sideNow = Side(bid, level, tolPts);

   // If we're inside the band, don't trigger cross, but don't destroy state either
   if(sideNow == 0) return;

   if(lastSide == 0)
   {
      lastSide = sideNow;
      return;
   }

   if(sideNow != lastSide)
   {
      string dir = (sideNow > lastSide ? "UP" : "DOWN");
      FireAlert(barTime, StringFormat("%s: CROSS %s %s @ %s (Bid=%s)",
                 _Symbol, dir, tag,
                 DoubleToString(level, _Digits),
                 DoubleToString(bid, _Digits)));
      // Even if the alert is suppressed (1-per-candle), we STILL update side,
      // so it doesn't keep trying to fire every tick.
      lastSide = sideNow;
   }
}

//+------------------------------------------------------------------+
// Drawing helpers
//+------------------------------------------------------------------+
double GetLinePrice(const string name)
{
   if(ObjectFind(0, name) == -1) return 0.0;
   return ObjectGetDouble(0, name, OBJPROP_PRICE);
}

void CreateLine(const string name, double price, color clr, int width, ENUM_LINE_STYLE style)
{
   if(ObjectFind(0,name)==-1)
      ObjectCreate(0,name,OBJ_HLINE,0,0,price);

   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void CreateLabel(const string name, const string text, double price, color clr)
{
   datetime now = TimeCurrent();
   if(ObjectFind(0,name)==-1)
   {
      ObjectCreate(0,name,OBJ_TEXT,0,now,price);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }

   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectMove(0,name,0,now,price);
}

void AlignLabels()
{
   datetime now = TimeCurrent();
   AlignOne(PDH_Label, PDH_Line, now);
   AlignOne(PDL_Label, PDL_Line, now);
   AlignOne(MID_Label, MID_Line, now);
   AlignOne(QLO_Label, QLO_Line, now);
   AlignOne(QHI_Label, QHI_Line, now);
   AlignOne(DOPEN_Label, DOPEN_Line, now);
   AlignOne(WOPEN_Label, WOPEN_Line, now);
}

void AlignOne(const string labelName, const string lineName, datetime t)
{
   if(ObjectFind(0, labelName) == -1) return;
   double p = GetLinePrice(lineName);
   if(p > 0) ObjectMove(0, labelName, 0, t, p);
}
//+------------------------------------------------------------------+