//+------------------------------------------------------------------+
//|                                                   MACD_TrinityEA |
//|                     MACD-only system + optional AI confirmation  |
//|                                                                  |
//|  v1.7: SystemMode + MTF confirmation + compile fixes             |
//|        - SystemMode: TREND / REVERSAL / BOTH                     |
//|        - MTF confirm using MACD Histogram sign + strength        |
//|        - Fix ArraySort/MODE_ASCEND issue on some MT5 builds      |
//|        - Rename Trim() helper to avoid conflicts                 |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//---------------------------- Inputs --------------------------------
enum ENUM_SYSTEM_MODE
{
   MODE_BOTH         = 0,
   MODE_TREND_ONLY   = 1,
   MODE_REVERSAL_ONLY= 2
};

input ENUM_SYSTEM_MODE InpSystemMode      = MODE_BOTH;

// MACD
input int    InpMACD_Fast          = 12;
input int    InpMACD_Slow          = 26;
input int    InpMACD_Signal        = 9;

// Chop filters / adaptive zones
input int    InpMedianLookbackN    = 50;     // Median lookback for chop filters
input int    InpSwingLookbackL     = 10;     // Swing lookback for stop loss

input double InpZeroZoneFactor     = 0.30;   // factor * median(|MACD|)  (near-zero zone)
input double InpFlatHistFactor     = 0.15;   // factor * median(|Hist|)  (flat histogram)

// Trade pacing
input bool   InpOneTradePerBar     = true;
input int    InpCooldownBars       = 2;      // after close, wait this many bars before re-enter

// Setup arming window
input int    InpArmBars            = 6;
input bool   InpRequireSetupTurn   = true;

// Option A early exit on histogram weakening
input bool   InpExitOnHistWeakening = true;

// Basic trade params
input double InpLots               = 0.10;   // Fixed lot for v1.x
input int    InpSlippagePoints     = 20;

// --- MTF confirmation ---
input bool            InpUseMTFConfirm      = true;
input ENUM_TIMEFRAMES InpMTF_TF1            = PERIOD_H1;
input ENUM_TIMEFRAMES InpMTF_TF2            = PERIOD_H4;
input bool            InpMTF_RequireStrength= true; // require hist magnitude > TF zone
input double          InpMTF_ZoneFactor     = 0.30; // TF NearZero based on TF median(|Hist|)

// --- AI Confirmation (ChatGPT/OpenAI) ---
input bool   InpUseAIConfirm       = true;
input double InpMinAIConfidence    = 0.60;

input string InpAI_Url             = "https://api.openai.com/v1/chat/completions";
input string InpAI_Model           = "gpt-4o-mini";
input string InpAI_KeyFile         = "openai.key";  // MQL5/Files/openai.key
input int    InpAI_TimeoutMS       = 12000;
input bool   InpAI_DebugPrint      = false;

// --- AI Feedback controls ---
input bool   InpAI_PrintDecisions  = true;   // Print to Experts/Journal
input bool   InpAI_LogCSV          = true;   // Write CSV log in MQL5/Files
input string InpAI_LogFile         = "MACD_Trinity_AIlog.csv";
input int    InpAI_ReasonMaxChars  = 140;    // trim reason on HUD/log

//---------------------------- Globals --------------------------------
int      g_macdHandle = INVALID_HANDLE;
int      g_macdHandleTF1 = INVALID_HANDLE;
int      g_macdHandleTF2 = INVALID_HANDLE;

datetime g_lastBarTime = 0;
int      g_cooldownRemaining = 0;

// arming state (for whichever system is active)
int g_armDir  = 0;   // 0 none, 1 long armed, -1 short armed
int g_armLeft = 0;   // bars remaining while armed

// MACD buffers (current TF)
double g_macdMain[];
double g_macdSignal[];

// AI runtime
string g_apiKey = "";
bool   g_useAIConfirm = false;

// AI feedback (latest)
string   g_aiLastCandidate = "";
string   g_aiLastDecision  = "";
double   g_aiLastConf      = 0.0;
string   g_aiLastReason    = "";
bool     g_aiLastApproved  = false;
datetime g_aiLastTime       = 0;

// For HUD clarity
string g_lastSystemFired = "NONE"; // "TREND" / "REVERSAL" / "NONE"
string g_mtfStatus = "N/A";        // "OK" / "FAIL" / "N/A"

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

// Rename to avoid conflicts with any environment macros
string TrimString2(string s)
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

// Median of abs(values) over [startShift .. startShift+count-1]
double MedianAbsFromSeries(const double &series[], int startShift, int count)
{
   if(count <= 0) return 0.0;

   double tmp[];
   ArrayResize(tmp, count);
   for(int i=0; i<count; i++)
      tmp[i] = AbsD(series[startShift + i]);

   // IMPORTANT: some MT5 builds dislike MODE_ASCEND; default sort is ascending
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

   key = TrimString2(key);
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

void AppendAICsv(const string systemFired,
                 const string candidate,
                 const string decision,
                 const double conf,
                 const bool approved,
                 const string regimeStr,
                 const bool nearZero,
                 const bool flatHist,
                 const string mtfStatus,
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
      FileWriteString(h, "time,symbol,tf,system,candidate,decision,confidence,approved,regime,nearZero,flatHist,mtf,macd0,sig0,hist0,reason\r\n");
   }

   FileSeek(h, 0, SEEK_END);

   string line =
      CsvEscape(TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)) + "," +
      CsvEscape(_Symbol) + "," +
      CsvEscape(EnumToString(_Period)) + "," +
      CsvEscape(systemFired) + "," +
      CsvEscape(candidate) + "," +
      CsvEscape(decision) + "," +
      DoubleToString(conf, 6) + "," +
      (approved ? "1" : "0") + "," +
      CsvEscape(regimeStr) + "," +
      (nearZero ? "1" : "0") + "," +
      (flatHist ? "1" : "0") + "," +
      CsvEscape(mtfStatus) + "," +
      DoubleToString(macd0, 10) + "," +
      DoubleToString(sig0, 10) + "," +
      DoubleToString(hist0, 10) + "," +
      CsvEscape(TruncReason(reason, 500)) +
      "\r\n";

   FileWriteString(h, line);
   FileClose(h);
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

//--------------------- Robust OpenAI content extraction ----------
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

//--------------------- MTF confirmation ----------------------------
// Returns true if TF hist sign aligns with candidate.
// If RequireStrength: abs(hist) must be above TF's own "near-zero" threshold.
bool GetTFHistAndZone(int handle, int lookbackN, double &hist0, double &tfZone, int &signOut)
{
   hist0 = 0.0;
   tfZone = 0.0;
   signOut = 0;

   if(handle == INVALID_HANDLE) return false;

   int need = MathMax(lookbackN + 5, 60);

   double m[], s[];
   ArrayResize(m, need);
   ArrayResize(s, need);
   ArraySetAsSeries(m, true);
   ArraySetAsSeries(s, true);

   if(CopyBuffer(handle, 0, 0, need, m) <= 0) return false;
   if(CopyBuffer(handle, 1, 0, need, s) <= 0) return false;

   // closed bar on TF: shift 1
   double h0 = m[1] - s[1];
   hist0 = h0;

   // build hist series for median(|hist|)
   double hSeries[];
   ArrayResize(hSeries, lookbackN+2);
   ArraySetAsSeries(hSeries, true);
   for(int i=1; i<=lookbackN; i++)
      hSeries[i] = m[i] - s[i];

   double medAbsHist = MedianAbsFromSeries(hSeries, 1, lookbackN);
   tfZone = InpMTF_ZoneFactor * medAbsHist;

   if(h0 > 0) signOut = 1;
   else if(h0 < 0) signOut = -1;
   else signOut = 0;

   return true;
}

bool PassMTFConfirm(const string dirCandidate)
{
   if(!InpUseMTFConfirm)
   {
      g_mtfStatus = "N/A";
      return true;
   }

   int want = (dirCandidate == "BUY" ? 1 : -1);

   double h1=0, z1=0; int s1=0;
   double h2=0, z2=0; int s2=0;

   bool ok1 = GetTFHistAndZone(g_macdHandleTF1, InpMedianLookbackN, h1, z1, s1);
   bool ok2 = GetTFHistAndZone(g_macdHandleTF2, InpMedianLookbackN, h2, z2, s2);

   // If handles not available, don't block trading
   if(!ok1 && !ok2) { g_mtfStatus="N/A"; return true; }

   bool pass = true;

   if(ok1)
   {
      if(s1 != want) pass = false;
      if(InpMTF_RequireStrength && AbsD(h1) < z1) pass = false;
   }
   if(ok2)
   {
      if(s2 != want) pass = false;
      if(InpMTF_RequireStrength && AbsD(h2) < z2) pass = false;
   }

   g_mtfStatus = (pass ? "OK" : "FAIL");
   return pass;
}

//--------------------- AI Confirm (unchanged logic from v1.5) --------
bool AIConfirmTrade(const string dirCandidate,
                    const string systemFired,
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

   // bypass AI in Strategy Tester / Optimization
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
      "\"system\":\""+systemFired+"\","
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
         "\"flat_hist\":"+(flatHist?"true":"false")+","
         "\"mtf\":\""+g_mtfStatus+"\""
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
      "You are confirming trades for a MACD-only system (Trend/Reversal + MTF filter). "
      "Use ONLY the MACD values and provided filters. "
      "Return BUY/SELL only if candidate aligns; otherwise WAIT. "
      "Output ONLY valid JSON with keys: decision, confidence, reason.";

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
               " (Allow WebRequest URL in Terminal options)");
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

   aiDecision = StringToUpper(decision);
   aiConf     = conf;
   aiReason   = reason;

   return (aiDecision == dirCandidate && aiConf >= InpMinAIConfidence);
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

string SystemModeStr()
{
   if(InpSystemMode == MODE_TREND_ONLY) return "TREND_ONLY";
   if(InpSystemMode == MODE_REVERSAL_ONLY) return "REVERSAL_ONLY";
   return "BOTH";
}

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

   // Create MTF handles
   if(InpUseMTFConfirm)
   {
      g_macdHandleTF1 = iMACD(_Symbol, InpMTF_TF1, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
      g_macdHandleTF2 = iMACD(_Symbol, InpMTF_TF2, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
   }

   ArraySetAsSeries(g_macdMain, true);
   ArraySetAsSeries(g_macdSignal, true);

   trade.SetDeviationInPoints(InpSlippagePoints);

   // AI runtime enablement
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

   Print("MACD_TrinityEA v1.7 initialized. Mode=", SystemModeStr(),
         " Symbol=", _Symbol, " TF=", EnumToString(_Period));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_macdHandle != INVALID_HANDLE) IndicatorRelease(g_macdHandle);
   if(g_macdHandleTF1 != INVALID_HANDLE) IndicatorRelease(g_macdHandleTF1);
   if(g_macdHandleTF2 != INVALID_HANDLE) IndicatorRelease(g_macdHandleTF2);

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
   if(bars < (InpMedianLookbackN + 30)) return;

   int need = InpMedianLookbackN + 25;
   if(CopyBuffer(g_macdHandle, 0, 0, need, g_macdMain) <= 0) return;
   if(CopyBuffer(g_macdHandle, 1, 0, need, g_macdSignal) <= 0) return;

   // CLOSED bars
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
   ArrayResize(histSeries, InpMedianLookbackN + 3);
   ArraySetAsSeries(histSeries, true);
   for(int i=1; i<=InpMedianLookbackN; i++)
      histSeries[i] = g_macdMain[i] - g_macdSignal[i];

   double medAbsHist = MedianAbsFromSeries(histSeries, 1, InpMedianLookbackN);

   double zeroZone = InpZeroZoneFactor * medAbsMacd;
   bool nearZero   = (InpZeroZoneFactor > 0.0 && AbsD(macd0) < zeroZone);

   bool flatHist = false;
   if(InpFlatHistFactor > 0.0 && medAbsHist > 0.0)
      flatHist = (AbsD(hist0) < (InpFlatHistFactor * medAbsHist));

   bool chop = (nearZero || flatHist);

   // Regime (by MACD main sign)
   bool regimeBull = (macd0 > 0.0);
   bool regimeBear = (macd0 < 0.0);
   string regimeStr = regimeBull ? "BULL" : (regimeBear ? "BEAR" : "NEUTRAL");

   // Trigger (crossover)
   bool trigBuy  = (macd1 <= sig1) && (macd0 > sig0);
   bool trigSell = (macd1 >= sig1) && (macd0 < sig0);

   // Trend setup: histogram strengthening in regime direction
   bool setupTrendBuy  = regimeBull && (hist0 > hist1);
   bool setupTrendSell = regimeBear && (hist0 < hist1);

   // Reversal setup: histogram was compressing/flat then turns (classic “turn”)
   bool setupRevBuy  = (hist1 < 0.0 && hist0 > hist1); // turning up from below
   bool setupRevSell = (hist1 > 0.0 && hist0 < hist1); // turning down from above

   // Position status
   long posType;
   ulong ticket;
   bool hasPos = HasPositionForSymbol(_Symbol, posType, ticket);

   // Cooldown decrement only while flat
   if(g_cooldownRemaining > 0 && !hasPos)
      g_cooldownRemaining--;

   // ------------------- HUD (always) -------------------
   string posStr = "NONE";
   if(hasPos) posStr = (posType==POSITION_TYPE_BUY ? "LONG" : "SHORT");

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
      "LastSystem: %s\n"
      "MTF: %s\n"
      "Regime: %s\n"
      "MACD0: %.8f  SIG0: %.8f\n"
      "HIST0: %.8f  HIST1: %.8f\n"
      "ZeroZone: %.8f |MACD|: %.8f NearZero=%s\n"
      "FlatHist=%s Chop=%s\n"
      "TrendSetup(B/S): %s/%s\n"
      "RevSetup(B/S): %s/%s\n"
      "Trig(B/S): %s/%s\n"
      "Cooldown: %d\n"
      "%s\n"
      "AI Reason: %s\n"
      "Pos: %s",
      SystemModeStr(),
      g_lastSystemFired,
      g_mtfStatus,
      regimeStr,
      macd0, sig0,
      hist0, hist1,
      zeroZone, AbsD(macd0), (nearZero?"Y":"N"),
      (flatHist?"Y":"N"), (chop?"Y":"N"),
      (setupTrendBuy?"Y":"N"), (setupTrendSell?"Y":"N"),
      (setupRevBuy?"Y":"N"), (setupRevSell?"Y":"N"),
      (trigBuy?"Y":"N"), (trigSell?"Y":"N"),
      g_cooldownRemaining,
      aiLine,
      TruncReason(g_aiLastReason, InpAI_ReasonMaxChars),
      posStr
   );
   DrawHUD(hud);

   // ------------------- Exits -------------------
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

   // ------------------- Entries -------------------
   if(chop) { g_lastSystemFired="NONE"; g_mtfStatus="N/A"; return; }
   if(g_cooldownRemaining > 0) { g_lastSystemFired="NONE"; g_mtfStatus="N/A"; return; }

   // Candidate logic depends on SystemMode
   bool allowTrend    = (InpSystemMode == MODE_BOTH || InpSystemMode == MODE_TREND_ONLY);
   bool allowReversal = (InpSystemMode == MODE_BOTH || InpSystemMode == MODE_REVERSAL_ONLY);

   bool longCandidate=false, shortCandidate=false;
   string systemFired="NONE";

   // TREND: regime + strengthening + crossover
   if(allowTrend)
   {
      if(setupTrendBuy && trigBuy)  { longCandidate=true;  systemFired="TREND"; }
      if(setupTrendSell && trigSell){ shortCandidate=true; systemFired="TREND"; }
   }

   // REVERSAL: opposite-side turn + crossover (more frequent than Trend)
   if(!longCandidate && !shortCandidate && allowReversal)
   {
      // Reversal BUY: histogram turning up from below + buy cross
      if(setupRevBuy && trigBuy)   { longCandidate=true;  systemFired="REVERSAL"; }
      // Reversal SELL: histogram turning down from above + sell cross
      if(setupRevSell && trigSell) { shortCandidate=true; systemFired="REVERSAL"; }
   }

   if(!longCandidate && !shortCandidate)
   {
      g_lastSystemFired="NONE";
      g_mtfStatus="N/A";
      return;
   }

   // MTF gating
   bool mtfPass = PassMTFConfirm(longCandidate ? "BUY" : "SELL");
   if(!mtfPass)
   {
      g_lastSystemFired = systemFired;
      // blocked by MTF
      SaveAIFeedback((longCandidate?"BUY":"SELL"), "WAIT", 0.0, "Blocked by MTF confirm", false);
      AppendAICsv(systemFired, (longCandidate?"BUY":"SELL"), "WAIT", 0.0, false, regimeStr, nearZero, flatHist, g_mtfStatus, macd0, sig0, hist0, "Blocked by MTF confirm");
      return;
   }

   double closePrice = iClose(_Symbol, _Period, 1);
   double swingLow   = LowestLow(InpSwingLookbackL);
   double swingHigh  = HighestHigh(InpSwingLookbackL);

   // BUY
   if(longCandidate)
   {
      g_lastSystemFired = systemFired;

      string aiDecision, aiReason;
      double aiConf;

      bool okAI = AIConfirmTrade("BUY", systemFired, regimeStr, true, true, nearZero, flatHist,
                                 macd0, macd1, sig0, sig1, hist0, hist1,
                                 zeroZone, medAbsMacd, medAbsHist,
                                 closePrice, swingLow, swingHigh,
                                 aiDecision, aiConf, aiReason);

      bool approved = (!g_useAIConfirm || okAI);
      SaveAIFeedback("BUY", aiDecision, aiConf, aiReason, approved);
      AppendAICsv(systemFired, "BUY", aiDecision, aiConf, approved, regimeStr, nearZero, flatHist, g_mtfStatus, macd0, sig0, hist0, aiReason);

      if(approved)
      {
         double sl = swingLow;
         if(sl > 0.0 && sl < closePrice)
            trade.Buy(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity BUY");
      }
      return;
   }

   // SELL
   if(shortCandidate)
   {
      g_lastSystemFired = systemFired;

      string aiDecision, aiReason;
      double aiConf;

      bool okAI = AIConfirmTrade("SELL", systemFired, regimeStr, true, true, nearZero, flatHist,
                                 macd0, macd1, sig0, sig1, hist0, hist1,
                                 zeroZone, medAbsMacd, medAbsHist,
                                 closePrice, swingLow, swingHigh,
                                 aiDecision, aiConf, aiReason);

      bool approved = (!g_useAIConfirm || okAI);
      SaveAIFeedback("SELL", aiDecision, aiConf, aiReason, approved);
      AppendAICsv(systemFired, "SELL", aiDecision, aiConf, approved, regimeStr, nearZero, flatHist, g_mtfStatus, macd0, sig0, hist0, aiReason);

      if(approved)
      {
         double sl = swingHigh;
         if(sl > 0.0 && sl > closePrice)
            trade.Sell(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity SELL");
      }
      return;
   }
}
