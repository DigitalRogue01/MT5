//+------------------------------------------------------------------+
//| Camarilla_Levels.mq5                                             |
//| Day-segmented Camarilla levels from previous daily OHLC          |
//| Shows current day plus recent history and exposes current buffers|
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property indicator_plots   10
#property indicator_buffers 10

#property indicator_type1   DRAW_NONE
#property indicator_type2   DRAW_NONE
#property indicator_type3   DRAW_NONE
#property indicator_type4   DRAW_NONE
#property indicator_type5   DRAW_NONE
#property indicator_type6   DRAW_NONE
#property indicator_type7   DRAW_NONE
#property indicator_type8   DRAW_NONE
#property indicator_type9   DRAW_NONE
#property indicator_type10  DRAW_NONE

#property indicator_label1  "L1"
#property indicator_label2  "L2"
#property indicator_label3  "L3"
#property indicator_label4  "L4"
#property indicator_label5  "L5"
#property indicator_label6  "H1"
#property indicator_label7  "H2"
#property indicator_label8  "H3"
#property indicator_label9  "H4"
#property indicator_label10 "H5"

double L1Buffer[];
double L2Buffer[];
double L3Buffer[];
double L4Buffer[];
double L5Buffer[];
double H1Buffer[];
double H2Buffer[];
double H3Buffer[];
double H4Buffer[];
double H5Buffer[];

input double CamarillaMultiplier = 1.1;
input int    VisibleDaySets      = 3;

input color  H1_Color = clrSilver;
input color  H2_Color = clrSilver;
input color  H3_Color = clrOrange;
input color  H4_Color = clrRed;
input color  H5_Color = clrFireBrick;
input color  L1_Color = clrSilver;
input color  L2_Color = clrSilver;
input color  L3_Color = clrDodgerBlue;
input color  L4_Color = clrDeepSkyBlue;
input color  L5_Color = clrRoyalBlue;

input int    MinorWidth = 1;
input int    MajorWidth = 2;
input int    ExtremeWidth = 2;
input ENUM_LINE_STYLE MinorStyle   = STYLE_DOT;
input ENUM_LINE_STYLE MajorStyle   = STYLE_SOLID;
input ENUM_LINE_STYLE ExtremeStyle = STYLE_DASH;

input bool   ShowLabels    = true;
input color  LabelColor    = clrWhite;
input int    LabelFontSize = 8;

input bool   EnableAlerts  = false;
input bool   AlertOnTouch  = false;
input bool   AlertOnCross  = false;
input int    TouchTolerancePoints = 5;

datetime g_lastDay = 0;
datetime g_lastAlertBar = 0;
datetime g_lastChartBar = 0;
bool     g_needFullBufferSync = true;

double   g_l1 = EMPTY_VALUE;
double   g_l2 = EMPTY_VALUE;
double   g_l3 = EMPTY_VALUE;
double   g_l4 = EMPTY_VALUE;
double   g_l5 = EMPTY_VALUE;
double   g_h1 = EMPTY_VALUE;
double   g_h2 = EMPTY_VALUE;
double   g_h3 = EMPTY_VALUE;
double   g_h4 = EMPTY_VALUE;
double   g_h5 = EMPTY_VALUE;

int g_lastSideL3 = 0;
int g_lastSideL4 = 0;
int g_lastSideL5 = 0;
int g_lastSideH3 = 0;
int g_lastSideH4 = 0;
int g_lastSideH5 = 0;

string PREFIX = "DR_CAM_";

bool CurrentDayObjectsMissing()
{
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDay <= 0)
      return false;

   string suffix = TimeToString(currentDay, TIME_DATE);
   string probe  = PREFIX + "H4_" + suffix + "_LINE";
   return(ObjectFind(0, probe) < 0);
}

int OnInit()
{
   IndicatorSetString(INDICATOR_SHORTNAME, "DigitalRogue Camarilla Levels");

   SetIndexBuffer(0, L1Buffer, INDICATOR_DATA);
   SetIndexBuffer(1, L2Buffer, INDICATOR_DATA);
   SetIndexBuffer(2, L3Buffer, INDICATOR_DATA);
   SetIndexBuffer(3, L4Buffer, INDICATOR_DATA);
   SetIndexBuffer(4, L5Buffer, INDICATOR_DATA);
   SetIndexBuffer(5, H1Buffer, INDICATOR_DATA);
   SetIndexBuffer(6, H2Buffer, INDICATOR_DATA);
   SetIndexBuffer(7, H3Buffer, INDICATOR_DATA);
   SetIndexBuffer(8, H4Buffer, INDICATOR_DATA);
   SetIndexBuffer(9, H5Buffer, INDICATOR_DATA);

   ArraySetAsSeries(L1Buffer, true);
   ArraySetAsSeries(L2Buffer, true);
   ArraySetAsSeries(L3Buffer, true);
   ArraySetAsSeries(L4Buffer, true);
   ArraySetAsSeries(L5Buffer, true);
   ArraySetAsSeries(H1Buffer, true);
   ArraySetAsSeries(H2Buffer, true);
   ArraySetAsSeries(H3Buffer, true);
   ArraySetAsSeries(H4Buffer, true);
   ArraySetAsSeries(H5Buffer, true);

   for(int i = 0; i < 10; i++)
      PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   RefreshLevels();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   DeleteAllObjects();
}

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
   if(rates_total <= 0)
      return 0;

   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   bool refreshed = false;
   if(currentDay != g_lastDay || CurrentDayObjectsMissing())
   {
      RefreshLevels();
      refreshed = true;
   }

   bool newBar = (g_lastChartBar != time[0]);
   if(newBar)
      g_lastChartBar = time[0];

   SyncBuffers(rates_total, (prev_calculated <= 0) || refreshed || g_needFullBufferSync);

   if(ShowLabels && (prev_calculated <= 0 || refreshed || newBar))
      AlignCurrentLabels();

   CheckAlerts(time);
   return rates_total;
}

void RefreshLevels()
{
   g_lastDay = iTime(_Symbol, PERIOD_D1, 0);
   DeleteAllObjects();

   int daySets = MathMax(1, VisibleDaySets);
   for(int shift = daySets - 1; shift >= 0; shift--)
      BuildDaySet(shift, shift == 0);

   ResetAlertSides();
   g_needFullBufferSync = true;
}

void SyncBuffers(const int rates_total,const bool fullSync)
{
   int limit = (fullSync ? rates_total : MathMin(rates_total, 3));
   if(limit <= 0)
      return;

   for(int i = 0; i < limit; i++)
   {
      L1Buffer[i] = g_l1;
      L2Buffer[i] = g_l2;
      L3Buffer[i] = g_l3;
      L4Buffer[i] = g_l4;
      L5Buffer[i] = g_l5;
      H1Buffer[i] = g_h1;
      H2Buffer[i] = g_h2;
      H3Buffer[i] = g_h3;
      H4Buffer[i] = g_h4;
      H5Buffer[i] = g_h5;
   }

   g_needFullBufferSync = false;
}

bool BuildDaySet(const int shift,const bool cacheCurrent)
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, shift);
   datetime nextDay  = dayStart + 86400;
   if(dayStart <= 0)
      return false;

   double prevHigh  = iHigh(_Symbol, PERIOD_D1, shift + 1);
   double prevLow   = iLow(_Symbol, PERIOD_D1, shift + 1);
   double prevClose = iClose(_Symbol, PERIOD_D1, shift + 1);
   if(prevHigh <= 0.0 || prevLow <= 0.0 || prevClose <= 0.0 || prevHigh <= prevLow)
      return false;

   double range  = prevHigh - prevLow;
   double factor = range * CamarillaMultiplier;

   double l1 = prevClose - factor / 12.0;
   double l2 = prevClose - factor / 6.0;
   double l3 = prevClose - factor / 4.0;
   double l4 = prevClose - factor / 2.0;
   double h1 = prevClose + factor / 12.0;
   double h2 = prevClose + factor / 6.0;
   double h3 = prevClose + factor / 4.0;
   double h4 = prevClose + factor / 2.0;

   // Common Camarilla breakout extension variant.
   double h5 = (prevLow > 0.0 ? (prevHigh / prevLow) * prevClose : EMPTY_VALUE);
   double l5 = (h5 != EMPTY_VALUE ? (2.0 * prevClose) - h5 : EMPTY_VALUE);

   string suffix = TimeToString(dayStart, TIME_DATE);

   CreateSegment("L1", suffix, dayStart, nextDay, l1, L1_Color, MinorWidth, MinorStyle);
   CreateSegment("L2", suffix, dayStart, nextDay, l2, L2_Color, MinorWidth, MinorStyle);
   CreateSegment("L3", suffix, dayStart, nextDay, l3, L3_Color, MajorWidth, MajorStyle);
   CreateSegment("L4", suffix, dayStart, nextDay, l4, L4_Color, MajorWidth, MajorStyle);
   CreateSegment("L5", suffix, dayStart, nextDay, l5, L5_Color, ExtremeWidth, ExtremeStyle);
   CreateSegment("H1", suffix, dayStart, nextDay, h1, H1_Color, MinorWidth, MinorStyle);
   CreateSegment("H2", suffix, dayStart, nextDay, h2, H2_Color, MinorWidth, MinorStyle);
   CreateSegment("H3", suffix, dayStart, nextDay, h3, H3_Color, MajorWidth, MajorStyle);
   CreateSegment("H4", suffix, dayStart, nextDay, h4, H4_Color, MajorWidth, MajorStyle);
   CreateSegment("H5", suffix, dayStart, nextDay, h5, H5_Color, ExtremeWidth, ExtremeStyle);

   if(cacheCurrent)
   {
      g_l1 = l1; g_l2 = l2; g_l3 = l3; g_l4 = l4; g_l5 = l5;
      g_h1 = h1; g_h2 = h2; g_h3 = h3; g_h4 = h4; g_h5 = h5;
   }

   return true;
}

void CreateSegment(const string tag,
                   const string suffix,
                   const datetime dayStart,
                   const datetime nextDay,
                   const double price,
                   const color lineColor,
                   const int width,
                   const ENUM_LINE_STYLE style)
{
   if(price == EMPTY_VALUE || price <= 0.0)
      return;

   string lineName = PREFIX + tag + "_" + suffix + "_LINE";
   if(ObjectFind(0, lineName) < 0)
      ObjectCreate(0, lineName, OBJ_TREND, 0, dayStart, price, nextDay, price);

   ObjectMove(0, lineName, 0, dayStart, price);
   ObjectMove(0, lineName, 1, nextDay, price);
   ObjectSetInteger(0, lineName, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE, style);
   ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, lineName, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, lineName, OBJPROP_BACK, false);
   ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, false);

   UpdateLabel(tag, suffix, nextDay, price, lineColor);
}

void UpdateLabel(const string tag,
                 const string suffix,
                 const datetime nextDay,
                 const double price,
                 const color textColor)
{
   string labelName = PREFIX + tag + "_" + suffix + "_LABEL";
   if(!ShowLabels || price == EMPTY_VALUE || price <= 0.0)
   {
      if(ObjectFind(0, labelName) >= 0)
         ObjectDelete(0, labelName);
      return;
   }

   datetime anchorTime = nextDay - (datetime)(PeriodSeconds(PERIOD_CURRENT) * 2);
   if(anchorTime <= 0)
      anchorTime = TimeCurrent();

   if(ObjectFind(0, labelName) < 0)
      ObjectCreate(0, labelName, OBJ_TEXT, 0, anchorTime, price);

   ObjectMove(0, labelName, 0, anchorTime, price);
   ObjectSetString(0, labelName, OBJPROP_TEXT, tag + "  " + DoubleToString(price, _Digits));
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, LabelColor == clrNONE ? textColor : LabelColor);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, LabelFontSize);
   ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_RIGHT);
   ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, labelName, OBJPROP_HIDDEN, false);
}

void AlignCurrentLabels()
{
   string suffix = TimeToString(iTime(_Symbol, PERIOD_D1, 0), TIME_DATE);
   datetime nextDay = iTime(_Symbol, PERIOD_D1, 0) + 86400;
   UpdateLabel("L1", suffix, nextDay, g_l1, L1_Color);
   UpdateLabel("L2", suffix, nextDay, g_l2, L2_Color);
   UpdateLabel("L3", suffix, nextDay, g_l3, L3_Color);
   UpdateLabel("L4", suffix, nextDay, g_l4, L4_Color);
   UpdateLabel("L5", suffix, nextDay, g_l5, L5_Color);
   UpdateLabel("H1", suffix, nextDay, g_h1, H1_Color);
   UpdateLabel("H2", suffix, nextDay, g_h2, H2_Color);
   UpdateLabel("H3", suffix, nextDay, g_h3, H3_Color);
   UpdateLabel("H4", suffix, nextDay, g_h4, H4_Color);
   UpdateLabel("H5", suffix, nextDay, g_h5, H5_Color);
}

void DeleteAllObjects()
{
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

int Side(const double price,const double level,const int tolerancePoints)
{
   if(level == EMPTY_VALUE || level <= 0.0)
      return 0;

   double tol = tolerancePoints * _Point;
   if(price > level + tol)
      return 1;
   if(price < level - tol)
      return -1;
   return 0;
}

void ResetAlertSides()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0)
      return;

   g_lastSideL3 = Side(bid, g_l3, TouchTolerancePoints);
   g_lastSideL4 = Side(bid, g_l4, TouchTolerancePoints);
   g_lastSideL5 = Side(bid, g_l5, TouchTolerancePoints);
   g_lastSideH3 = Side(bid, g_h3, TouchTolerancePoints);
   g_lastSideH4 = Side(bid, g_h4, TouchTolerancePoints);
   g_lastSideH5 = Side(bid, g_h5, TouchTolerancePoints);
}

bool CanAlertThisBar(const datetime barTime)
{
   return(g_lastAlertBar != barTime);
}

void MarkAlert(const datetime barTime)
{
   g_lastAlertBar = barTime;
}

void CheckLevelAlert(const datetime barTime,
                     const string tag,
                     const double bid,
                     const double level,
                     int &lastSide)
{
   if(level == EMPTY_VALUE || level <= 0.0)
      return;

   double tol = TouchTolerancePoints * _Point;
   if(AlertOnTouch && MathAbs(bid - level) <= tol && CanAlertThisBar(barTime))
   {
      string msg = StringFormat("%s %s touch @ %s", _Symbol, tag, DoubleToString(level, _Digits));
      Alert(msg);
      Print(msg);
      MarkAlert(barTime);
   }

   if(!AlertOnCross)
      return;

   int sideNow = Side(bid, level, TouchTolerancePoints);
   if(sideNow == 0)
      return;

   if(lastSide == 0)
   {
      lastSide = sideNow;
      return;
   }

   if(sideNow != lastSide && CanAlertThisBar(barTime))
   {
      string dir = (sideNow > lastSide ? "cross up" : "cross down");
      string msg = StringFormat("%s %s %s @ %s", _Symbol, tag, dir, DoubleToString(level, _Digits));
      Alert(msg);
      Print(msg);
      MarkAlert(barTime);
   }
   lastSide = sideNow;
}

void CheckAlerts(const datetime &time[])
{
   if(!EnableAlerts)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0)
      return;

   datetime barTime = time[0];
   CheckLevelAlert(barTime, "L3", bid, g_l3, g_lastSideL3);
   CheckLevelAlert(barTime, "L4", bid, g_l4, g_lastSideL4);
   CheckLevelAlert(barTime, "L5", bid, g_l5, g_lastSideL5);
   CheckLevelAlert(barTime, "H3", bid, g_h3, g_lastSideH3);
   CheckLevelAlert(barTime, "H4", bid, g_h4, g_lastSideH4);
   CheckLevelAlert(barTime, "H5", bid, g_h5, g_lastSideH5);
}
