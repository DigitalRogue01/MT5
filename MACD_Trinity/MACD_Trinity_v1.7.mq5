//+------------------------------------------------------------------+
//|                                                   MACD_TrinityEA |
//|                 MACD Trinity: Trend + Reversal + MTF + optional AI|
//|                                                                  |
//|  v1.7: System 2 Reversal added (MACD divergence + trigger)        |
//|       - Trend System kept intact                                 |
//|       - Reversal: swing divergence + MACD/hist weakening + trigger|
//|       - MTF: always-updating HUD + gates for Trend/Reversal       |
//|       - AI packet includes system + mtf status                    |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//============================ SystemMode =============================
enum SystemModeEnum
{
   SYSTEM_TREND_ONLY    = 0,
   SYSTEM_REVERSAL_ONLY = 1,
   SYSTEM_BOTH          = 2
};
input SystemModeEnum InpSystemMode = SYSTEM_BOTH;

//---------------------------- MACD Inputs ----------------------------
input int    InpMACD_Fast          = 12;
input int    InpMACD_Slow          = 26;
input int    InpMACD_Signal        = 9;

input int    InpMedianLookbackN    = 50;     // Median lookback for chop filters
input int    InpSwingLookbackL     = 10;     // Swing lookback for stop loss

input double InpZeroZoneFactor     = 0.30;   // factor * median(|MACD|)
input double InpFlatHistFactor     = 0.15;   // factor * median(|Hist|)

input bool   InpOneTradePerBar     = true;
input int    InpCooldownBars       = 2;      // after close, wait this many bars before re-enter

// Trend arming window
input int    InpArmBars            = 6;
input bool   InpRequireSetupTurn   = true;

// Option A early exit on histogram weakening (applies to all positions)
input bool   InpExitOnHistWeakening = true;

input double InpLots               = 0.10;
input int    InpSlippagePoints     = 20;

//============================ MTF Confirmation =======================
input bool            InpUseMTFConfirm = true;
input ENUM_TIMEFRAMES InpTF_Bias       = PERIOD_H1;
input ENUM_TIMEFRAMES InpTF_Regime     = PERIOD_H4;

//============================ v1.7 Reversal Inputs ===================
// Swing detection for divergence (local TF)
input int    InpRevSwingLen            = 3;     // pivot sensitivity: 2..5 typical
input int    InpRevMaxLookbackBars     = 120;   // how far back to search swings

// Divergence strength gates (MACD-only magnitude control)
input double InpRevMinHistFactor       = 0.20;  // require |hist0| > factor*median(|hist|)

// Reversal trigger selection (kept simple, robust)
input bool   InpRevTrigger_HistCross0  = true;  // hist crosses 0
input bool   InpRevTrigger_MacdCrossSig= true;  // macd crosses signal
input bool   InpRevTrigger_MacdCross0  = true;  // macd crosses 0

// MTF weakening logic for reversal (prevents fading strong HTF impulse)
input bool   InpRevRequireHTFNotStrong = true;  // block reversal if BOTH HTFs are strongly trending

//============================ AI Confirmation =========================
input bool   InpUseAIConfirm       = true;
input double InpMinAIConfidence    = 0.60;

input string InpAI_Url             = "https://api.openai.com/v1/chat/completions";
input string InpAI_Model           = "gpt-4o-mini";
input string InpAI_KeyFile         = "openai.key";  // MQL5/Files/openai.key
input int    InpAI_TimeoutMS       = 12000;
input bool   InpAI_DebugPrint      = false;

// --- AI Feedback controls ---
input bool   InpAI_PrintDecisions  = true;
input bool   InpAI_LogCSV          = true;
input string InpAI_LogFile         = "MACD_Trinity_AIlog.csv";
input int    InpAI_ReasonMaxChars  = 140;

//---------------------------- Globals --------------------------------
int      g_macdHandle = INVALID_HANDLE;
int      g_macdHandleBias   = INVALID_HANDLE;
int      g_macdHandleRegime = INVALID_HANDLE;

datetime g_lastBarTime = 0;
int      g_cooldownRemaining = 0;

// Trend arming state
int g_armDir  = 0;   // 0 none, 1 long armed, -1 short armed
int g_armLeft = 0;   // bars remaining while armed

// MACD buffers (local TF)
double g_macdMain[];
double g_macdSignal[];

// AI runtime
string g_apiKey = "";
bool   g_useAIConfirm = false;

// MTF status globals (for HUD + gating + AI packet)
bool   g_mtfEnabled     = false;
bool   g_mtfOK          = true;
bool   g_mtfBiasBull    = false;
bool   g_mtfRegimeBull  = false;
double g_mtfBiasHist0   = 0.0;
double g_mtfBiasHist1   = 0.0;
double g_mtfRegHist0    = 0.0;
double g_mtfRegHist1    = 0.0;
string g_mtfStr         = "N/A";

string g_systemName     = "TREND"; // "TREND" or "REVERSAL" (for AI packet)

// AI feedback (latest)
string   g_aiLastCandidate = "";
string   g_aiLastDecision  = "";
double   g_aiLastConf      = 0.0;
string   g_aiLastReason    = "";
bool     g_aiLastApproved  = false;
datetime g_aiLastTime      = 0;

//---------------------------- Helpers --------------------------------
bool IsNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == 0) return false;
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

double AbsD(const double x) { return (x < 0.0 ? -x : x); }

string TrimString(string s)
{
   s = StringTrimLeft(s);
   s = StringTrimRight(s);
   return s;
}

string TruncReason(const string s, const int maxChars)
{
   if(maxChars <= 0) return "";
   if(StringLen(s) <= maxChars) return s;
   return StringSubstr(s, 0, maxChars) + "...";
}

string CsvEscape(string s)
{
   s = StringReplace(s, "\"", "\"\"");
   if(StringFind(s, ",") >= 0 || StringFind(s, "\n") >= 0 || StringFind(s, "\r") >= 0)
      s = "\"" + s + "\"";
   return s;
}

double MedianAbsFromSeries(const double &series[], int startShift, int count)
{
   if(count <= 0) return 0.0;

   double tmp[];
   ArrayResize(tmp, count);
   for(int i=0; i<count; i++)
      tmp[i] = AbsD(series[startShift + i]);

   ArraySort(tmp);

   int mid = count / 2;
   if((count % 2) == 1) return tmp[mid];
   return 0.5 * (tmp[mid-1] + tmp[mid]);
}

double LowestLow(int lookbackL)
{
   double low = DBL_MAX;
   for(int i=1; i<=lookbackL; i++)
   {
      double v = iLow(_Symbol, _Period, i);
      if(v < low) low = v;
   }
   return (low == DBL_MAX ? 0.0 : low);
}

double HighestHigh(int lookbackL)
{
   double high = -DBL_MAX;
   for(int i=1; i<=lookbackL; i++)
   {
      double v = iHigh(_Symbol, _Period, i);
      if(v > high) high = v;
   }
   return (high == -DBL_MAX ? 0.0 : high);
}

bool HasPositionForSymbol(const string sym, long &posType, ulong &ticket)
{
   posType = -1;
   ticket  = 0;

   if(!PositionSelect(sym)) return false;

   posType = (long)PositionGetInteger(POSITION_TYPE);
   ticket  = (ulong)PositionGetInteger(POSITION_TICKET);
   return true;
}

bool LoadApiKeyFromFile()
{
   if(InpAI_KeyFile == "")
      return false;

   int h = FileOpen(InpAI_KeyFile, FILE_READ | FILE_TXT);
   if(h == INVALID_HANDLE)
   {
      Print("AIConfirm: Failed to open key file '", InpAI_KeyFile,
            "' in MQL5/Files. Error=", GetLastError());
      return false;
   }

   string key = FileReadString(h);
   FileClose(h);

   key = TrimString(key);
   if(key == "")
   {
      Print("AIConfirm: Key file '", InpAI_KeyFile, "' is empty.");
      return false;
   }

   g_apiKey = key;
   return true;
}

void SaveAIFeedback(const string candidate, const string decision, const double conf, const string reason, const bool approved)
{
   g_aiLastCandidate = candidate;
   g_aiLastDecision  = decision;
   g_aiLastConf      = conf;
   g_aiLastReason    = reason;
   g_aiLastApproved  = approved;
   g_aiLastTime      = TimeCurrent();

   if(InpAI_PrintDecisions)
   {
      Print("AI_DECISION: cand=", candidate,
            " decision=", decision,
            " conf=", DoubleToString(conf, 3),
            " approved=", (approved ? "Y" : "N"),
            " reason=", TruncReason(reason, InpAI_ReasonMaxChars));
   }
}

void AppendAICsv(const string candidate,
                 const string decision,
                 const double conf,
                 const bool approved,
                 const string regimeStr,
                 const bool nearZero,
                 const bool flatHist,
                 const double macd0,
                 const double sig0,
                 const double hist0,
                 const string reason)
{
   if(!InpAI_LogCSV) return;

   int h = FileOpen(InpAI_LogFile, FILE_READ|FILE_WRITE|FILE_TXT);
   if(h == INVALID_HANDLE)
   {
      static bool warned=false;
      if(!warned)
      {
         warned=true;
         Print("AI CSV: Failed to open log file '", InpAI_LogFile, "'. Error=", GetLastError());
      }
      return;
   }

   if(FileSize(h) == 0)
   {
      FileWriteString(h, "time,symbol,tf,candidate,decision,confidence,approved,system,regime,nearZero,flatHist,macd0,sig0,hist0,mtf,reason\r\n");
   }

   FileSeek(h, 0, SEEK_END);

   string line =
      CsvEscape(TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)) + "," +
      CsvEscape(_Symbol) + "," +
      CsvEscape(EnumToString(_Period)) + "," +
      CsvEscape(candidate) + "," +
      CsvEscape(decision) + "," +
      DoubleToString(conf, 6) + "," +
      (approved ? "1" : "0") + "," +
      CsvEscape(g_systemName) + "," +
      CsvEscape(regimeStr) + "," +
      (nearZero ? "1" : "0") + "," +
      (flatHist ? "1" : "0") + "," +
      DoubleToString(macd0, 10) + "," +
      DoubleToString(sig0, 10) + "," +
      DoubleToString(hist0, 10) + "," +
      CsvEscape(g_mtfStr + (g_mtfEnabled ? (g_mtfOK ? " (OK)" : " (WAIT)") : " (OFF)")) + "," +
      CsvEscape(TruncReason(reason, 500)) +
      "\r\n";

   FileWriteString(h, line);
   FileClose(h);
}

//--------------------- MACD read helper for any handle ---------------
bool ReadMACD(const int handle, const int shift, double &mainOut, double &sigOut)
{
   if(handle == INVALID_HANDLE) return false;

   double m[1], s[1];
   int c1 = CopyBuffer(handle, 0, shift, 1, m);
   int c2 = CopyBuffer(handle, 1, shift, 1, s);
   if(c1 <= 0 || c2 <= 0) return false;

   mainOut = m[0];
   sigOut  = s[0];
   return true;
}

//====================== Always Update MTF Status ======================
bool UpdateMTFStatus()
{
   g_mtfOK = true;
   g_mtfStr = "N/A";
   g_mtfBiasBull = false;
   g_mtfRegimeBull = false;
   g_mtfBiasHist0 = 0.0;
   g_mtfBiasHist1 = 0.0;
   g_mtfRegHist0  = 0.0;
   g_mtfRegHist1  = 0.0;

   if(!g_mtfEnabled) return true;

   if(g_macdHandleBias == INVALID_HANDLE || g_macdHandleRegime == INVALID_HANDLE)
   {
      g_mtfOK = false;
      g_mtfStr = "MTF_HANDLE_ERR";
      return false;
   }

   // closed bars on HTF
   double b0m,b0s,b1m,b1s, r0m,r0s,r1m,r1s;
   if(!ReadMACD(g_macdHandleBias,   1, b0m, b0s) ||
      !ReadMACD(g_macdHandleBias,   2, b1m, b1s) ||
      !ReadMACD(g_macdHandleRegime, 1, r0m, r0s) ||
      !ReadMACD(g_macdHandleRegime, 2, r1m, r1s))
   {
      g_mtfOK = false;
      g_mtfStr = "MTF_DATA_WAIT";
      return false;
   }

   g_mtfBiasBull   = (b0m > 0.0);
   g_mtfRegimeBull = (r0m > 0.0);

   g_mtfBiasHist0  = (b0m - b0s);
   g_mtfBiasHist1  = (b1m - b1s);
   g_mtfRegHist0   = (r0m - r0s);
   g_mtfRegHist1   = (r1m - r1s);

   g_mtfStr = StringFormat("%s=%s(h%.5f)  %s=%s(h%.5f)",
                           EnumToString(InpTF_Bias),   g_mtfBiasBull ? "BULL" : "BEAR", g_mtfBiasHist0,
                           EnumToString(InpTF_Regime), g_mtfRegimeBull ? "BULL" : "BEAR", g_mtfRegHist0);
   return true;
}

//--------------------- Minimal JSON extraction helpers ----------------
bool JsonFindKey(const string &json, const string &key, int &posOut)
{
   string needle = "\"" + key + "\"";
   int p = StringFind(json, needle);
   if(p < 0) return false;
   p = StringFind(json, ":", p);
   if(p < 0) return false;
   posOut = p + 1;
   return true;
}

string JsonGetString(const string &json, const string &key)
{
   int p=0;
   if(!JsonFindKey(json, key, p)) return "";

   while(p < StringLen(json))
   {
      ushort c = StringGetCharacter(json, p);
      if(c==' ' || c=='\t' || c=='\r' || c=='\n') p++;
      else break;
   }
   if(p >= StringLen(json)) return "";

   if(StringGetCharacter(json, p) == '\"')
   {
      p++;
      int start = p;
      while(p < StringLen(json))
      {
         ushort c = StringGetCharacter(json, p);
         if(c=='\"') break;
         if(c=='\\' && p+1 < StringLen(json)) { p+=2; continue; }
         p++;
      }
      int len = p - start;
      if(len < 0) return "";
      return StringSubstr(json, start, len);
   }
   return "";
}

double JsonGetDouble(const string &json, const string &key, double def=0.0)
{
   int p=0;
   if(!JsonFindKey(json, key, p)) return def;

   while(p < StringLen(json))
   {
      ushort c = StringGetCharacter(json, p);
      if(c==' ' || c=='\t' || c=='\r' || c=='\n') p++;
      else break;
   }
   if(p >= StringLen(json)) return def;

   int start = p;
   while(p < StringLen(json))
   {
      ushort c = StringGetCharacter(json, p);
      if(c==',' || c=='}' || c==']' || c==' ' || c=='\t' || c=='\r' || c=='\n') break;
      p++;
   }
   string tok = StringSubstr(json, start, p-start);
   if(tok == "") return def;
   return StringToDouble(tok);
}

//--------------------- Robust OpenAI content extraction ---------------
string ExtractContentFromOpenAI(const string &resp)
{
   int p = StringFind(resp, "\"choices\"");
   if(p < 0) return "";

   p = StringFind(resp, "\"message\"", p);
   if(p < 0) return "";

   p = StringFind(resp, "\"content\"", p);
   if(p < 0) return "";

   p = StringFind(resp, ":", p);
   if(p < 0) return "";
   p++;

   while(p < StringLen(resp))
   {
      ushort c = StringGetCharacter(resp, p);
      if(c==' ' || c=='\t' || c=='\r' || c=='\n') p++;
      else break;
   }
   if(p >= StringLen(resp)) return "";

   if(StringGetCharacter(resp, p) == '\"')
   {
      p++;
      int start = p;
      while(p < StringLen(resp))
      {
         ushort c = StringGetCharacter(resp, p);
         if(c=='\"') break;
         if(c=='\\' && p+1 < StringLen(resp)) { p+=2; continue; }
         p++;
      }
      int len = p - start;
      if(len <= 0) return "";

      string content = StringSubstr(resp, start, len);
      content = StringReplace(content, "\\\"", "\"");
      content = StringReplace(content, "\\n", "\n");
      content = StringReplace(content, "\\r", "\r");
      content = StringReplace(content, "\\t", "\t");
      return content;
   }

   if(StringGetCharacter(resp, p) == '[')
   {
      string out = "";
      int q = p;
      while(true)
      {
         int t = StringFind(resp, "\"text\"", q);
         if(t < 0) break;

         t = StringFind(resp, ":", t);
         if(t < 0) break;
         t++;

         while(t < StringLen(resp))
         {
            ushort c = StringGetCharacter(resp, t);
            if(c==' ' || c=='\t' || c=='\r' || c=='\n') t++;
            else break;
         }
         if(t >= StringLen(resp) || StringGetCharacter(resp, t)!='\"') { q = t; continue; }

         t++;
         int start = t;
         while(t < StringLen(resp))
         {
            ushort c = StringGetCharacter(resp, t);
            if(c=='\"') break;
            if(c=='\\' && t+1 < StringLen(resp)) { t+=2; continue; }
            t++;
         }
         int len = t - start;
         if(len > 0)
         {
            string chunk = StringSubstr(resp, start, len);
            chunk = StringReplace(chunk, "\\\"", "\"");
            chunk = StringReplace(chunk, "\\n", "\n");
            out += chunk;
         }
         q = t;
      }
      return out;
   }

   return "";
}

string JsonEscape(string s)
{
   s = StringReplace(s, "\\", "\\\\");
   s = StringReplace(s, "\"", "\\\"");
   s = StringReplace(s, "\r", "\\r");
   s = StringReplace(s, "\n", "\\n");
   s = StringReplace(s, "\t", "\\t");
   return s;
}

//============================ AIConfirmTrade ==========================
bool AIConfirmTrade(const string dirCandidate,
                    const string regimeStr,
                    const bool setupOk,
                    const bool triggerOk,
                    const bool nearZero,
                    const bool flatHist,
                    const double macd0, const double macd1,
                    const double sig0,  const double sig1,
                    const double hist0, const double hist1,
                    const double zeroZone,
                    const double medAbsMacd,
                    const double medAbsHist,
                    const double closePrice,
                    const double swingLow,
                    const double swingHigh,
                    string &aiDecision,
                    double &aiConf,
                    string &aiReason)
{
   aiDecision = "WAIT";
   aiConf     = 0.0;
   aiReason   = "";

   // Auto-bypass AI in Strategy Tester / Optimization
   if((bool)MQLInfoInteger(MQL_TESTER) || (bool)MQLInfoInteger(MQL_OPTIMIZATION))
   {
      aiDecision = dirCandidate;
      aiConf     = 1.0;
      aiReason   = "AI bypass (tester)";
      return true;
   }

   if(!g_useAIConfirm)
   {
      aiDecision = dirCandidate;
      aiConf     = 1.0;
      aiReason   = "AI disabled/runtime";
      return true;
   }

   if(g_apiKey == "")
   {
      aiDecision = "WAIT";
      aiConf = 0.0;
      aiReason = "API key missing";
      return false;
   }

   string packet =
      "{"
      "\"schema\":\"macd_trinity_v1_7\","
      "\"symbol\":\""+_Symbol+"\","
      "\"tf\":\""+EnumToString(_Period)+"\","
      "\"time\":\""+TimeToString(iTime(_Symbol,_Period,1), TIME_DATE|TIME_MINUTES)+"\","
      "\"system\":\""+g_systemName+"\","
      "\"mtf\":{"
         "\"enabled\":"+(g_mtfEnabled?"true":"false")+","
         "\"status\":\""+(g_mtfOK?"OK":"WAIT")+"\","
         "\"bias_tf\":\""+EnumToString(InpTF_Bias)+"\","
         "\"regime_tf\":\""+EnumToString(InpTF_Regime)+"\","
         "\"bias\":\""+(g_mtfBiasBull?"BULL":"BEAR")+"\","
         "\"regime\":\""+(g_mtfRegimeBull?"BULL":"BEAR")+"\","
         "\"bias_hist0\":"+DoubleToString(g_mtfBiasHist0,10)+","
         "\"bias_hist1\":"+DoubleToString(g_mtfBiasHist1,10)+","
         "\"reg_hist0\":"+DoubleToString(g_mtfRegHist0,10)+","
         "\"reg_hist1\":"+DoubleToString(g_mtfRegHist1,10)+
      "},"
      "\"macd\":{"
         "\"main\":["+DoubleToString(macd0,10)+","+DoubleToString(macd1,10)+"],"
         "\"signal\":["+DoubleToString(sig0,10)+","+DoubleToString(sig1,10)+"],"
         "\"hist\":["+DoubleToString(hist0,10)+","+DoubleToString(hist1,10)+"],"
         "\"zero_zone\":"+DoubleToString(zeroZone,10)+","
         "\"median_abs_macd\":"+DoubleToString(medAbsMacd,10)+","
         "\"median_abs_hist\":"+DoubleToString(medAbsHist,10)+
      "},"
      "\"filters\":{"
         "\"near_zero\":"+(nearZero?"true":"false")+","
         "\"flat_hist\":"+(flatHist?"true":"false")+
      "},"
      "\"rules\":{"
         "\"regime\":\""+regimeStr+"\","
         "\"setup\":"+(setupOk?"true":"false")+","
         "\"trigger\":"+(triggerOk?"true":"false")+","
         "\"direction_candidate\":\""+dirCandidate+"\""
      "},"
      "\"price\":{"
         "\"close\":"+DoubleToString(closePrice,_Digits)+","
         "\"swing_L\":"+IntegerToString(InpSwingLookbackL)+","
         "\"swing_low\":"+DoubleToString(swingLow,_Digits)+","
         "\"swing_high\":"+DoubleToString(swingHigh,_Digits)+
      "}"
      "}";

   string systemPrompt =
      "You confirm trades for a MACD-only system. "
      "Use ONLY the packet data (MACD/MTF/swing levels). "
      "If mtf.enabled is true and mtf.status is WAIT, return WAIT. "
      "Return BUY/SELL only if system rules align AND filters_ok; otherwise WAIT. "
      "Output ONLY valid JSON keys: decision, confidence, reason.";

   string userPrompt = "PACKET:\n" + packet;

   string req =
      "{"
      "\"model\":\""+InpAI_Model+"\","
      "\"temperature\":0.1,"
      "\"messages\":["
         "{\"role\":\"system\",\"content\":\""+JsonEscape(systemPrompt)+"\"},"
         "{\"role\":\"user\",\"content\":\""+JsonEscape(userPrompt)+"\"}"
      "]"
      "}";

   uchar post[];
   StringToCharArray(req, post, 0, -1, CP_UTF8);

   uchar result[];
   string result_headers;

   string headers =
      "Content-Type: application/json\r\n"
      "Authorization: Bearer " + g_apiKey + "\r\n";

   ResetLastError();
   int code = WebRequest("POST", InpAI_Url, headers, InpAI_TimeoutMS, post, result, result_headers);

   string resp = CharArrayToString(result, 0, -1, CP_UTF8);

   if(code == -1)
   {
      int err = GetLastError();
      aiDecision = "WAIT";
      aiConf = 0.0;
      aiReason = "WebRequest failed err=" + IntegerToString(err);
      if(InpAI_DebugPrint)
         Print("AIConfirm: WebRequest failed. err=", err,
               " (Add URL in Tools->Options->Expert Advisors->Allow WebRequest)");
      return false;
   }

   if(InpAI_DebugPrint) Print("AIConfirm: HTTP ", code, " resp=", resp);

   string content = ExtractContentFromOpenAI(resp);
   if(content == "")
   {
      aiDecision = "WAIT";
      aiConf = 0.0;
      aiReason = "Could not extract content. HTTP=" + IntegerToString(code) +
                 " resp=" + TruncReason(resp, 200);
      return false;
   }

   string decision = JsonGetString(content, "decision");
   double conf     = JsonGetDouble(content, "confidence", 0.0);
   string reason   = JsonGetString(content, "reason");

   if(decision == "") decision = "WAIT";

   aiDecision = decision;
   aiConf     = conf;
   aiReason   = reason;

   return (decision == dirCandidate && conf >= InpMinAIConfidence);
}

//---------------------------- HUD ------------------------------------
void DrawHUD(const string text)
{
   string name = "MACD_TrinityEA_HUD";
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 15);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
      ObjectSetString (0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

//==================== v1.7 Swing pivot helpers =======================
// Pivot High at bar i: High[i] greater than highs of [i-len..i-1] and [i+1..i+len]
bool IsPivotHigh(const int i, const int len)
{
   double hi = iHigh(_Symbol, _Period, i);
   for(int k=1; k<=len; k++)
   {
      if(iHigh(_Symbol,_Period,i-k) >= hi) return false;
      if(iHigh(_Symbol,_Period,i+k) >  hi) return false;
   }
   return true;
}

bool IsPivotLow(const int i, const int len)
{
   double lo = iLow(_Symbol, _Period, i);
   for(int k=1; k<=len; k++)
   {
      if(iLow(_Symbol,_Period,i-k) <= lo) return false;
      if(iLow(_Symbol,_Period,i+k) <  lo) return false;
   }
   return true;
}

// Find two most recent pivot highs (returns true if found)
bool FindTwoPivotHighs(const int len, const int maxLookback, int &idxRecent, int &idxPrev)
{
   idxRecent = -1; idxPrev = -1;
   int start = len + 2;
   int end   = MathMin(maxLookback, Bars(_Symbol,_Period) - len - 3);
   for(int i=start; i<=end; i++)
   {
      if(IsPivotHigh(i, len))
      {
         if(idxRecent < 0) idxRecent = i;
         else { idxPrev = i; break; }
      }
   }
   return (idxRecent > 0 && idxPrev > 0);
}

bool FindTwoPivotLows(const int len, const int maxLookback, int &idxRecent, int &idxPrev)
{
   idxRecent = -1; idxPrev = -1;
   int start = len + 2;
   int end   = MathMin(maxLookback, Bars(_Symbol,_Period) - len - 3);
   for(int i=start; i<=end; i++)
   {
      if(IsPivotLow(i, len))
      {
         if(idxRecent < 0) idxRecent = i;
         else { idxPrev = i; break; }
      }
   }
   return (idxRecent > 0 && idxPrev > 0);
}

// HTF strong/weak detection (hist expanding vs shrinking)
bool HTF_Bull_Strengthening(const double h0, const double h1) { return (h1 > 0.0 && h0 > h1); }
bool HTF_Bear_Strengthening(const double h0, const double h1) { return (h1 < 0.0 && h0 < h1); }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_macdHandle = iMACD(_Symbol, _Period, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
   if(g_macdHandle == INVALID_HANDLE)
   {
      Print("Failed to create MACD handle.");
      return INIT_FAILED;
   }

   g_mtfEnabled = InpUseMTFConfirm;
   if(g_mtfEnabled)
   {
      g_macdHandleBias   = iMACD(_Symbol, InpTF_Bias,   InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
      g_macdHandleRegime = iMACD(_Symbol, InpTF_Regime, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);

      if(g_macdHandleBias == INVALID_HANDLE || g_macdHandleRegime == INVALID_HANDLE)
      {
         Print("Failed to create MTF MACD handles (Bias/Regime).");
         return INIT_FAILED;
      }
   }

   ArraySetAsSeries(g_macdMain, true);
   ArraySetAsSeries(g_macdSignal, true);

   trade.SetDeviationInPoints(InpSlippagePoints);

   g_useAIConfirm = InpUseAIConfirm;
   if(g_useAIConfirm)
   {
      if(!LoadApiKeyFromFile())
      {
         Print("AIConfirm: Key not loaded. AI confirmations disabled at runtime.");
         g_useAIConfirm = false;
      }
      else
      {
         Print("AIConfirm: Key loaded from '", InpAI_KeyFile, "'. AI confirmations enabled.");
      }
   }

   Print("MACD_TrinityEA v1.7 initialized. Symbol=", _Symbol, " TF=", EnumToString(_Period));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_macdHandle != INVALID_HANDLE)
      IndicatorRelease(g_macdHandle);

   if(g_macdHandleBias != INVALID_HANDLE)
      IndicatorRelease(g_macdHandleBias);

   if(g_macdHandleRegime != INVALID_HANDLE)
      IndicatorRelease(g_macdHandleRegime);

   ObjectDelete(0, "MACD_TrinityEA_HUD");
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(InpOneTradePerBar)
   {
      if(!IsNewBar()) return;
   }

   int bars = Bars(_Symbol, _Period);
   if(bars < (InpMedianLookbackN + 50)) return;

   // Always update MTF (HUD + gating)
   UpdateMTFStatus();

   int need = InpMedianLookbackN + 30;
   if(CopyBuffer(g_macdHandle, 0, 0, need, g_macdMain) <= 0) return;
   if(CopyBuffer(g_macdHandle, 1, 0, need, g_macdSignal) <= 0) return;

   // CLOSED bars (local TF)
   double macd0 = g_macdMain[1];
   double macd1 = g_macdMain[2];
   double sig0  = g_macdSignal[1];
   double sig1  = g_macdSignal[2];

   double hist0 = macd0 - sig0;
   double hist1 = macd1 - sig1;
   double hist2 = (g_macdMain[3] - g_macdSignal[3]);

   // Median-based filters
   double medAbsMacd = MedianAbsFromSeries(g_macdMain, 1, InpMedianLookbackN);

   double histSeries[];
   ArrayResize(histSeries, InpMedianLookbackN + 2);
   ArraySetAsSeries(histSeries, true);
   for(int i=1; i<=InpMedianLookbackN; i++)
      histSeries[i] = g_macdMain[i] - g_macdSignal[i];

   double medAbsHist = MedianAbsFromSeries(histSeries, 1, InpMedianLookbackN);

   double zeroZone = InpZeroZoneFactor * medAbsMacd;
   bool nearZero   = (InpZeroZoneFactor > 0.0 && AbsD(macd0) < zeroZone);

   bool flatHist = false;
   if(InpFlatHistFactor > 0.0 && medAbsHist > 0.0)
      flatHist = (AbsD(hist0) < (InpFlatHistFactor * medAbsHist));

   bool chopTrend = (nearZero || flatHist);

   // Regime (local TF)
   bool regimeBull = (macd0 > 0.0);
   bool regimeBear = (macd0 < 0.0);
   string regimeStr = regimeBull ? "BULL" : (regimeBear ? "BEAR" : "NEUTRAL");

   // Trend setup + trigger
   bool setupBull = regimeBull && (hist0 > hist1);
   bool setupBear = regimeBear && (hist0 < hist1);

   bool trigBuy  = (macd1 <= sig1) && (macd0 > sig0);
   bool trigSell = (macd1 >= sig1) && (macd0 < sig0);

   // Position status
   long posType;
   ulong ticket;
   bool hasPos = HasPositionForSymbol(_Symbol, posType, ticket);

   // Cooldown decrement only while flat
   if(g_cooldownRemaining > 0 && !hasPos)
      g_cooldownRemaining--;

   // Trend arming only while flat
   if(!hasPos)
   {
      if(g_armLeft > 0) g_armLeft--;
      else { g_armDir = 0; }

      if(InpRequireSetupTurn)
      {
         if(setupBull) { g_armDir = 1;  g_armLeft = InpArmBars; }
         if(setupBear) { g_armDir = -1; g_armLeft = InpArmBars; }
      }
      else
      {
         if(regimeBull) { g_armDir = 1;  g_armLeft = InpArmBars; }
         if(regimeBear) { g_armDir = -1; g_armLeft = InpArmBars; }
      }
   }

   // HUD text
   string sysModeStr = (InpSystemMode==SYSTEM_TREND_ONLY ? "TREND_ONLY" :
                        InpSystemMode==SYSTEM_REVERSAL_ONLY ? "REVERSAL_ONLY" : "BOTH");

   string posStr = "NONE";
   if(hasPos) posStr = (posType==POSITION_TYPE_BUY ? "LONG" : "SHORT");
   string armStr = (g_armDir==1 ? "LONG" : (g_armDir==-1 ? "SHORT" : "NONE"));

   string mtfLine = "MTF: OFF";
   if(g_mtfEnabled)
      mtfLine = "MTF: " + g_mtfStr + " (" + (g_mtfOK ? "OK" : "WAIT") + ")";

   string aiLine = "AI: OFF";
   if(g_useAIConfirm)
   {
      aiLine = StringFormat("AI: ON cand=%s dec=%s conf=%.2f %s",
                            (g_aiLastCandidate=="" ? "-" : g_aiLastCandidate),
                            (g_aiLastDecision=="" ? "-" : g_aiLastDecision),
                            g_aiLastConf,
                            (g_aiLastApproved ? "APPROVED" : "BLOCKED"));
   }

   string hud = StringFormat(
      "MACD Trinity EA (v1.7)\n"
      "Mode: %s\n"
      "%s\n"
      "Regime: %s\n"
      "MACD0: %.8f  SIG0: %.8f\n"
      "HIST0: %.8f  HIST1: %.8f\n"
      "ZeroZone: %.8f  |MACD|: %.8f  NearZero=%s\n"
      "FlatHist=%s  ChopTrend=%s\n"
      "Setup(B/S): %s/%s\n"
      "Trig(B/S): %s/%s\n"
      "ARM: %s (%d)\n"
      "Cooldown: %d\n"
      "%s\n"
      "AI Reason: %s\n"
      "Pos: %s",
      sysModeStr,
      mtfLine,
      regimeStr,
      macd0, sig0,
      hist0, hist1,
      zeroZone, AbsD(macd0), (nearZero?"Y":"N"),
      (flatHist?"Y":"N"), (chopTrend?"Y":"N"),
      (setupBull?"Y":"N"), (setupBear?"Y":"N"),
      (trigBuy?"Y":"N"), (trigSell?"Y":"N"),
      armStr, g_armLeft,
      g_cooldownRemaining,
      aiLine,
      TruncReason(g_aiLastReason, InpAI_ReasonMaxChars),
      posStr
   );
   DrawHUD(hud);

   // ------------------- Exits (unchanged; applies to any position) -------------------
   if(hasPos)
   {
      if(posType == POSITION_TYPE_BUY)
      {
         if(InpExitOnHistWeakening)
         {
            bool wasStrengthening = (hist1 > hist2);
            bool nowWeakening     = (hist0 < hist1);
            bool stillPositive    = (hist1 > 0.0);

            if(wasStrengthening && nowWeakening && stillPositive)
            {
               if(trade.PositionClose(_Symbol))
               {
                  g_cooldownRemaining = InpCooldownBars;
                  g_armDir = 0; g_armLeft = 0;
               }
               return;
            }
         }

         bool zeroFlipAgainst = (macd0 < 0.0);
         bool oppositeCross   = (macd1 >= sig1) && (macd0 < sig0);

         if(zeroFlipAgainst || oppositeCross)
         {
            if(trade.PositionClose(_Symbol))
            {
               g_cooldownRemaining = InpCooldownBars;
               g_armDir = 0; g_armLeft = 0;
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         if(InpExitOnHistWeakening)
         {
            bool wasStrengthening = (hist1 < hist2);
            bool nowWeakening     = (hist0 > hist1);
            bool stillNegative    = (hist1 < 0.0);

            if(wasStrengthening && nowWeakening && stillNegative)
            {
               if(trade.PositionClose(_Symbol))
               {
                  g_cooldownRemaining = InpCooldownBars;
                  g_armDir = 0; g_armLeft = 0;
               }
               return;
            }
         }

         bool zeroFlipAgainst = (macd0 > 0.0);
         bool oppositeCross   = (macd1 <= sig1) && (macd0 > sig0);

         if(zeroFlipAgainst || oppositeCross)
         {
            if(trade.PositionClose(_Symbol))
            {
               g_cooldownRemaining = InpCooldownBars;
               g_armDir = 0; g_armLeft = 0;
            }
         }
      }
      return;
   }

   // ------------------- Flat gates -------------------
   if(g_cooldownRemaining > 0) return;

   // =================== SYSTEM 1: TREND ENTRIES =====================
   bool allowTrend = (InpSystemMode == SYSTEM_TREND_ONLY || InpSystemMode == SYSTEM_BOTH);

   bool longCandidate  = allowTrend && (g_armDir == 1 && trigBuy);
   bool shortCandidate = allowTrend && (g_armDir == -1 && trigSell);

   // Trend requires NOT chop
   if(chopTrend)
   {
      longCandidate  = false;
      shortCandidate = false;
   }

   // Trend MTF alignment gate
   bool mtfAlignOK = true;
   if(g_mtfEnabled && (longCandidate || shortCandidate))
   {
      if(!g_mtfOK) mtfAlignOK = false;
      else
      {
         if(longCandidate)  mtfAlignOK = (g_mtfBiasBull && g_mtfRegimeBull);
         if(shortCandidate) mtfAlignOK = (!g_mtfBiasBull && !g_mtfRegimeBull);
      }
   }

   double closePrice = iClose(_Symbol, _Period, 1);
   double swingLow   = LowestLow(InpSwingLookbackL);
   double swingHigh  = HighestHigh(InpSwingLookbackL);

   if(g_mtfEnabled && (longCandidate || shortCandidate) && !mtfAlignOK)
   {
      g_systemName = "TREND";
      string cand = longCandidate ? "BUY" : "SELL";
      string why  = (g_mtfOK ? "MTF confirmation failed (" + g_mtfStr + ")" : "MTF not ready (" + g_mtfStr + ")");

      SaveAIFeedback(cand, "WAIT", 0.0, why, false);
      AppendAICsv(cand, "WAIT", 0.0, false, regimeStr, nearZero, flatHist, macd0, sig0, hist0, why);

      g_armDir = 0; g_armLeft = 0;
      return;
   }

   // Trend BUY
   if(longCandidate)
   {
      g_systemName = "TREND";
      g_armDir = 0; g_armLeft = 0;

      string aiDecision, aiReason;
      double aiConf;

      bool okAI = AIConfirmTrade("BUY", regimeStr, true, true, nearZero, flatHist,
                                 macd0, macd1, sig0, sig1, hist0, hist1,
                                 zeroZone, medAbsMacd, medAbsHist,
                                 closePrice, swingLow, swingHigh,
                                 aiDecision, aiConf, aiReason);

      bool approved = (!g_useAIConfirm || okAI);
      SaveAIFeedback("BUY", aiDecision, aiConf, aiReason, approved);
      AppendAICsv("BUY", aiDecision, aiConf, approved, regimeStr, nearZero, flatHist, macd0, sig0, hist0, aiReason);

      if(approved)
      {
         double sl = swingLow;
         if(sl > 0.0 && sl < closePrice)
            trade.Buy(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity TREND BUY");
      }
      return;
   }

   // Trend SELL
   if(shortCandidate)
   {
      g_systemName = "TREND";
      g_armDir = 0; g_armLeft = 0;

      string aiDecision, aiReason;
      double aiConf;

      bool okAI = AIConfirmTrade("SELL", regimeStr, true, true, nearZero, flatHist,
                                 macd0, macd1, sig0, sig1, hist0, hist1,
                                 zeroZone, medAbsMacd, medAbsHist,
                                 closePrice, swingLow, swingHigh,
                                 aiDecision, aiConf, aiReason);

      bool approved = (!g_useAIConfirm || okAI);
      SaveAIFeedback("SELL", aiDecision, aiConf, aiReason, approved);
      AppendAICsv("SELL", aiDecision, aiConf, approved, regimeStr, nearZero, flatHist, macd0, sig0, hist0, aiReason);

      if(approved)
      {
         double sl = swingHigh;
         if(sl > 0.0 && sl > closePrice)
            trade.Sell(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity TREND SELL");
      }
      return;
   }

   // =================== SYSTEM 2: REVERSAL ENTRIES ==================
   bool allowRev = (InpSystemMode == SYSTEM_REVERSAL_ONLY || InpSystemMode == SYSTEM_BOTH);
   if(!allowRev) return;

   // Reversal should NOT fire on completely dead hist
   bool revHistOk = true;
   if(InpRevMinHistFactor > 0.0 && medAbsHist > 0.0)
      revHistOk = (AbsD(hist0) >= (InpRevMinHistFactor * medAbsHist));
   if(!revHistOk) return;

   // HTF "Not Strong" gate: block reversal if BOTH HTFs are strongly trending in same direction
   if(g_mtfEnabled && InpRevRequireHTFNotStrong)
   {
      if(!g_mtfOK)
         return;

      bool biasStrongBull = (g_mtfBiasBull   && HTF_Bull_Strengthening(g_mtfBiasHist0, g_mtfBiasHist1));
      bool regStrongBull  = (g_mtfRegimeBull && HTF_Bull_Strengthening(g_mtfRegHist0,  g_mtfRegHist1));
      bool biasStrongBear = (!g_mtfBiasBull  && HTF_Bear_Strengthening(g_mtfBiasHist0, g_mtfBiasHist1));
      bool regStrongBear  = (!g_mtfRegimeBull&& HTF_Bear_Strengthening(g_mtfRegHist0,  g_mtfRegHist1));

      // If both HTFs strongly bullish, don't SELL reversal
      // If both HTFs strongly bearish, don't BUY reversal
      // We'll enforce per-direction below.
      // (No return here)
   }

   // Detect divergence using last two pivots (local TF)
   int hi1, hi2, lo1, lo2;
   bool haveHighs = FindTwoPivotHighs(InpRevSwingLen, InpRevMaxLookbackBars, hi1, hi2);
   bool haveLows  = FindTwoPivotLows (InpRevSwingLen, InpRevMaxLookbackBars, lo1, lo2);

   // Build hist at pivot bars (use macd buffers already copied)
   auto HistAt = [&](int shift)->double { return (g_macdMain[shift] - g_macdSignal[shift]); };

   // Bearish divergence (SELL reversal): price higher high, hist lower high
   bool bearDiv = false;
   if(haveHighs)
   {
      double ph1 = iHigh(_Symbol,_Period,hi1);
      double ph2 = iHigh(_Symbol,_Period,hi2);
      double hh1 = HistAt(hi1);
      double hh2 = HistAt(hi2);
      bearDiv = (ph1 > ph2) && (hh1 < hh2);
   }

   // Bullish divergence (BUY reversal): price lower low, hist higher low
   bool bullDiv = false;
   if(haveLows)
   {
      double pl1 = iLow(_Symbol,_Period,lo1);
      double pl2 = iLow(_Symbol,_Period,lo2);
      double hl1 = HistAt(lo1);
      double hl2 = HistAt(lo2);
      bullDiv = (pl1 < pl2) && (hl1 > hl2);
   }

   // Reversal setup (momentum exhaustion)
   bool setupRevSell = (macd0 > 0.0) && (hist0 < hist1) && bearDiv;
   bool setupRevBuy  = (macd0 < 0.0) && (hist0 > hist1) && bullDiv;

   // Reversal trigger (one of enabled triggers)
   bool trigRevSell = false;
   bool trigRevBuy  = false;

   if(InpRevTrigger_HistCross0)
   {
      trigRevSell |= (hist1 >= 0.0 && hist0 < 0.0);
      trigRevBuy  |= (hist1 <= 0.0 && hist0 > 0.0);
   }
   if(InpRevTrigger_MacdCrossSig)
   {
      trigRevSell |= (macd1 >= sig1 && macd0 < sig0);
      trigRevBuy  |= (macd1 <= sig1 && macd0 > sig0);
   }
   if(InpRevTrigger_MacdCross0)
   {
      trigRevSell |= (macd1 >= 0.0 && macd0 < 0.0);
      trigRevBuy  |= (macd1 <= 0.0 && macd0 > 0.0);
   }

   // Directional HTF "Not Strong" enforcement
   if(g_mtfEnabled && InpRevRequireHTFNotStrong && g_mtfOK)
   {
      bool biasStrongBull = (g_mtfBiasBull   && HTF_Bull_Strengthening(g_mtfBiasHist0, g_mtfBiasHist1));
      bool regStrongBull  = (g_mtfRegimeBull && HTF_Bull_Strengthening(g_mtfRegHist0,  g_mtfRegHist1));
      bool biasStrongBear = (!g_mtfBiasBull  && HTF_Bear_Strengthening(g_mtfBiasHist0, g_mtfBiasHist1));
      bool regStrongBear  = (!g_mtfRegimeBull&& HTF_Bear_Strengthening(g_mtfRegHist0,  g_mtfRegHist1));

      if(setupRevSell && trigRevSell)
      {
         if(biasStrongBull && regStrongBull) { setupRevSell=false; trigRevSell=false; }
      }
      if(setupRevBuy && trigRevBuy)
      {
         if(biasStrongBear && regStrongBear) { setupRevBuy=false; trigRevBuy=false; }
      }
   }

   // Execute Reversal SELL
   if(setupRevSell && trigRevSell)
   {
      g_systemName = "REVERSAL";

      // stop above swing high
      double sl = swingHigh;
      if(sl <= 0.0 || sl <= closePrice) sl = HighestHigh(InpSwingLookbackL);

      string aiDecision, aiReason;
      double aiConf;

      bool okAI = AIConfirmTrade("SELL", regimeStr, true, true, nearZero, flatHist,
                                 macd0, macd1, sig0, sig1, hist0, hist1,
                                 zeroZone, medAbsMacd, medAbsHist,
                                 closePrice, swingLow, swingHigh,
                                 aiDecision, aiConf, aiReason);

      bool approved = (!g_useAIConfirm || okAI);
      SaveAIFeedback("SELL", aiDecision, aiConf, aiReason, approved);
      AppendAICsv("SELL", aiDecision, aiConf, approved, regimeStr, nearZero, flatHist, macd0, sig0, hist0,
                  "REV: " + aiReason);

      if(approved)
      {
         if(sl > closePrice)
            trade.Sell(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity REV SELL");
      }
      return;
   }

   // Execute Reversal BUY
   if(setupRevBuy && trigRevBuy)
   {
      g_systemName = "REVERSAL";

      // stop below swing low
      double sl = swingLow;
      if(sl <= 0.0 || sl >= closePrice) sl = LowestLow(InpSwingLookbackL);

      string aiDecision, aiReason;
      double aiConf;

      bool okAI = AIConfirmTrade("BUY", regimeStr, true, true, nearZero, flatHist,
                                 macd0, macd1, sig0, sig1, hist0, hist1,
                                 zeroZone, medAbsMacd, medAbsHist,
                                 closePrice, swingLow, swingHigh,
                                 aiDecision, aiConf, aiReason);

      bool approved = (!g_useAIConfirm || okAI);
      SaveAIFeedback("BUY", aiDecision, aiConf, aiReason, approved);
      AppendAICsv("BUY", aiDecision, aiConf, approved, regimeStr, nearZero, flatHist, macd0, sig0, hist0,
                  "REV: " + aiReason);

      if(approved)
      {
         if(sl < closePrice)
            trade.Buy(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity REV BUY");
      }
      return;
   }
}
