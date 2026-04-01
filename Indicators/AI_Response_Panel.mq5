//+------------------------------------------------------------------+
//| AI_Response_Panel.mq5                                            |
//| Reads the latest AI watcher response from Common\Files and       |
//| displays it on the chart.                                        |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

input string PanelFileName   = "DigitalRogue\\AIWatchPanel\\latest_watch_panel.txt";
input int    RefreshSeconds  = 10;
input int    PanelX          = 12;
input int    PanelY          = 24;
input int    PanelWidth      = 420;
input int    PanelHeight     = 220;
input color  PanelBgColor    = clrBlack;
input color  PanelBorderColor= clrDimGray;
input color  PanelTextColor  = clrWhite;
input int    FontSize        = 9;
input string FontName        = "Consolas";

string   g_boxName   = "DR_AI_PANEL_BOX";
string   g_textName  = "DR_AI_PANEL_TEXT";
datetime g_lastRead  = 0;
string   g_lastText  = "";

void EnsureObjects()
{
   if(ObjectFind(0, g_boxName) < 0)
   {
      ObjectCreate(0, g_boxName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, g_boxName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, g_boxName, OBJPROP_XDISTANCE, PanelX);
      ObjectSetInteger(0, g_boxName, OBJPROP_YDISTANCE, PanelY);
      ObjectSetInteger(0, g_boxName, OBJPROP_XSIZE, PanelWidth);
      ObjectSetInteger(0, g_boxName, OBJPROP_YSIZE, PanelHeight);
      ObjectSetInteger(0, g_boxName, OBJPROP_BGCOLOR, PanelBgColor);
      ObjectSetInteger(0, g_boxName, OBJPROP_BORDER_COLOR, PanelBorderColor);
      ObjectSetInteger(0, g_boxName, OBJPROP_COLOR, PanelBorderColor);
      ObjectSetInteger(0, g_boxName, OBJPROP_BACK, false);
      ObjectSetInteger(0, g_boxName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_boxName, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, g_boxName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, g_boxName, OBJPROP_ZORDER, 0);
   }

   if(ObjectFind(0, g_textName) < 0)
   {
      ObjectCreate(0, g_textName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, g_textName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, g_textName, OBJPROP_XDISTANCE, PanelX + 10);
      ObjectSetInteger(0, g_textName, OBJPROP_YDISTANCE, PanelY + 8);
      ObjectSetInteger(0, g_textName, OBJPROP_COLOR, PanelTextColor);
      ObjectSetInteger(0, g_textName, OBJPROP_FONTSIZE, FontSize);
      ObjectSetString(0, g_textName, OBJPROP_FONT, FontName);
      ObjectSetInteger(0, g_textName, OBJPROP_BACK, false);
      ObjectSetInteger(0, g_textName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_textName, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, g_textName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, g_textName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, g_textName, OBJPROP_ZORDER, 1);
   }
}

string ReadPanelText()
{
   int h = FileOpen(PanelFileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return "AI Watch Panel\n\nNo panel file yet.\n\nRun the watcher script to populate:\nwatch_camarilla_ai.py";

   string text = "";
   while(!FileIsEnding(h))
      text += FileReadString(h) + "\n";
   FileClose(h);

   if(StringLen(text) == 0)
      return "AI Watch Panel\n\nPanel file is empty.";
   return text;
}

void RefreshPanel(const bool force = false)
{
   datetime now = TimeCurrent();
   if(!force && (now - g_lastRead) < RefreshSeconds)
      return;

   g_lastRead = now;
   EnsureObjects();
   g_lastText = ReadPanelText();
   ObjectSetString(0, g_textName, OBJPROP_TEXT, g_lastText);
   ChartRedraw(0);
}

int OnInit()
{
   EnsureObjects();
   RefreshPanel(true);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectDelete(0, g_textName);
   ObjectDelete(0, g_boxName);
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
   RefreshPanel();
   return(rates_total);
}
