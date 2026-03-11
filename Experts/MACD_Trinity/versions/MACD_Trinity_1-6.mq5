//+------------------------------------------------------------------+
//|                                                   MACD_TrinityEA |
//|                     MACD-only system + optional AI confirmation  |
//|                                                                  |
//|  v1.6.1: MTF always-updating HUD + MTF gate uses cached status     |
//|        - UpdateMTFStatus() runs every tick/newbar                 |
//|        - HUD shows H1/H4 bias/regime even with no trade candidate |
//|        - MTF gate blocks trades if alignment FAIL or data not ready|
//|                                                                  |
//|  v1.6: SystemMode + MTF MACD confirmation Proceed with 1.7(H1/H4 by default)      |
//|  v1.5: Fix AI parsing + better error reason                       |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//============================ v1.6: SystemMode =======================
enum SystemModeEnum
{
   SYSTEM_TREND_ONLY    = 0,
   SYSTEM_REVERSAL_ONLY = 1,   // reserved for v1.7
   SYSTEM_BOTH          = 2
};
input SystemModeEnum InpSystemMode = SYSTEM_TREND_ONLY;

//---------------------------- Inputs --------------------------------
input int    InpMACD_Fast          = 12;
input int    InpMACD_Slow          = 26;
input int    InpMACD_Signal        = 9;

input int    InpMedianLookbackN    = 50;     // Median lookback for chop filters
input int    InpSwingLookbackL     = 10;     // Swing lookback for stop loss

input double InpZeroZoneFactor     = 0.60;   // factor * median(|MACD|)
input double InpFlatHistFactor     = 0.15;   // factor * median(|Hist|)

input bool   InpOneTradePerBar     = true;
input int    InpCooldownBars       = 2;      // after close, wait this many bars before re-enter

// Setup arming window
input int    InpArmBars            = 6;
input bool   InpRequireSetupTurn   = true;

// Option A early exit on histogram weakening
input bool   InpExitOnHistWeakening = true;

input double InpLots               = 0.10;   // Fixed lot for v1
input int    InpSlippagePoints     = 20;

//============================ v1.6: MTF Confirmation ==================
input bool            InpUseMTFConfirm = true;
input ENUM_TIMEFRAMES InpTF_Bias       = PERIOD_H1;  // bias timeframe
input ENUM_TIMEFRAMES InpTF_Regime     = PERIOD_H4;  // regime timeframe

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

// v1.6: MTF handles
int      g_macdHandleBias   = INVALID_HANDLE;
int      g_macdHandleRegime = INVALID_HANDLE;

datetime g_lastBarTime = 0;
int      g_cooldownRemaining = 0;

// arming state
int g_armDir  = 0;   // 0 none, 1 long armed, -1 short armed
int g_armLeft = 0;   // bars remaining while armed

// MACD buffers
double g_macdMain[];
double g_macdSignal[];

// AI runtime
string g_apiKey = "";
bool   g_useAIConfirm = false;

// v1.6/v1.6.1: MTF status globals (for HUD + AI packet)
bool   g_mtfEnabled     = false;
bool   g_mtfOK          = true;
bool   g_mtfBiasBull    = false;
bool   g_mtfRegimeBull  = false;
string g_mtfStr         = "N/A";
string g_systemName     = "TREND"; // for AI packet

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

// Escape for CSV fields (minimal)
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
      FileWriteString(h, "time,symbol,tf,candidate,decision,confidence,approved,regime,nearZero,flatHist,macd0,sig0,hist0,reason\r\n");
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
      CsvEscape(regimeStr) + "," +
      (nearZero ? "1" : "0") + "," +
      (flatHist ? "1" : "0") + "," +
      DoubleToString(macd0, 10) + "," +
      DoubleToString(sig0, 10) + "," +
      DoubleToString(hist0, 10) + "," +
      CsvEscape(TruncReason(reason, 500)) +
      "\r\n";

   FileWriteString(h, line);
   FileClose(h);
}

//====================== v1.6.1: Always Update MTF Status =============
bool UpdateMTFStatus()
{
   g_mtfOK = true;
   g_mtfStr = "N/A";
   g_mtfBiasBull = false;
   g_mtfRegimeBull = false;

   if(!g_mtfEnabled) return true;

   if(g_macdHandleBias == INVALID_HANDLE || g_macdHandleRegime == INVALID_HANDLE)
   {
      g_mtfOK = false;
      g_mtfStr = "MTF_HANDLE_ERR";
      return false;
   }

   double biasMain[1];
   double regimeMain[1];

   int c1 = CopyBuffer(g_macdHandleBias,   0, 1, 1, biasMain);   // closed bar on bias TF
   int c2 = CopyBuffer(g_macdHandleRegime, 0, 1, 1, regimeMain); // closed bar on regime TF

   if(c1 <= 0 || c2 <= 0)
   {
      g_mtfOK = false;
      g_mtfStr = "MTF_DATA_WAIT";
      return false;
   }

   g_mtfBiasBull   = (biasMain[0] > 0.0);
   g_mtfRegimeBull = (regimeMain[0] > 0.0);

   g_mtfStr = StringFormat("%s=%s  %s=%s",
                           EnumToString(InpTF_Bias),   g_mtfBiasBull ? "BULL" : "BEAR",
                           EnumToString(InpTF_Regime), g_mtfRegimeBull ? "BULL" : "BEAR");
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

   // v1.6/v1.6.1: include system + mtf context in the packet (using globals)
   string packet =
      "{"
      "\"schema\":\"macd_trinity_v1_6_1\","
      "\"symbol\":\""+_Symbol+"\","
      "\"tf\":\""+EnumToString(_Period)+"\","
      "\"time\":\""+TimeToString(iTime(_Symbol,_Period,1), TIME_DATE|TIME_MINUTES)+"\","
      "\"system\":\""+g_systemName+"\","
      "\"mtf\":{"
         "\"enabled\":"+(g_mtfEnabled?"true":"false")+","
         "\"bias_tf\":\""+EnumToString(InpTF_Bias)+"\","
         "\"regime_tf\":\""+EnumToString(InpTF_Regime)+"\","
         "\"bias\":\""+(g_mtfBiasBull?"BULL":"BEAR")+"\","
         "\"regime\":\""+(g_mtfRegimeBull?"BULL":"BEAR")+"\","
         "\"status\":\""+(g_mtfOK?"OK":"WAIT")+"\""
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
      "You are confirming trades for a MACD-only system. "
      "Use ONLY the MACD values and the provided swing levels. "
      "If mtf.enabled is true and mtf.status is WAIT, return WAIT. "
      "Return BUY/SELL only if regime+setup+trigger align AND filters_ok; otherwise WAIT. "
      "Output ONLY valid JSON with keys: decision, confidence, reason, regime, setup, trigger, filters_ok.";

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

   // v1.6: Create MTF MACD handles
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

   Print("MACD_TrinityEA v1.6.1 initialized. Symbol=", _Symbol, " TF=", EnumToString(_Period));
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
   if(bars < (InpMedianLookbackN + 30)) return;

   // v1.6: SystemMode gate (reversal not implemented yet)
   if(InpSystemMode == SYSTEM_REVERSAL_ONLY)
      g_systemName = "REVERSAL";
   else
      g_systemName = "TREND";

   // v1.6.1: Always update MTF status (for HUD + gating)
   UpdateMTFStatus();

   int need = InpMedianLookbackN + 20;
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

   bool chop = (nearZero || flatHist);

   // Regime
   bool regimeBull = (macd0 > 0.0);
   bool regimeBear = (macd0 < 0.0);
   string regimeStr = regimeBull ? "BULL" : (regimeBear ? "BEAR" : "NEUTRAL");

   // Setup (hist turn)
   bool setupBull = regimeBull && (hist0 > hist1);
   bool setupBear = regimeBear && (hist0 < hist1);

   // Trigger (crossover)
   bool trigBuy  = (macd1 <= sig1) && (macd0 > sig0);
   bool trigSell = (macd1 >= sig1) && (macd0 < sig0);

   // Position status
   long posType;
   ulong ticket;
   bool hasPos = HasPositionForSymbol(_Symbol, posType, ticket);

   // Cooldown decrement only while flat
   if(g_cooldownRemaining > 0 && !hasPos)
      g_cooldownRemaining--;

   // Setup arming (only while flat)
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

   // Entry candidates (trend system)
   bool longCandidate  = (g_armDir == 1 && trigBuy);
   bool shortCandidate = (g_armDir == -1 && trigSell);

   // v1.6.1: Determine MTF alignment for the candidate using cached status
   bool mtfAlignOK = true;
   if(g_mtfEnabled && (longCandidate || shortCandidate))
   {
      // If MTF data isn't ready, treat as NOT OK (block safely)
      if(!g_mtfOK)
         mtfAlignOK = false;
      else
      {
         if(longCandidate)  mtfAlignOK = (g_mtfBiasBull && g_mtfRegimeBull);
         if(shortCandidate) mtfAlignOK = (!g_mtfBiasBull && !g_mtfRegimeBull);
      }
   }

   // HUD
   string posStr = "NONE";
   if(hasPos) posStr = (posType==POSITION_TYPE_BUY ? "LONG" : "SHORT");
   string armStr = (g_armDir==1 ? "LONG" : (g_armDir==-1 ? "SHORT" : "NONE"));

   string sysModeStr = (InpSystemMode==SYSTEM_TREND_ONLY ? "TREND_ONLY" :
                        InpSystemMode==SYSTEM_REVERSAL_ONLY ? "REVERSAL_ONLY" : "BOTH");

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
      "MACD Trinity EA (v1.6.1)\n"
      "Mode: %s\n"
      "%s\n"
      "Regime: %s\n"
      "MACD0: %.8f  SIG0: %.8f\n"
      "HIST0: %.8f  HIST1: %.8f\n"
      "ZeroZone: %.8f  |MACD|: %.8f  NearZero=%s\n"
      "FlatHist=%s  Chop=%s\n"
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
      (flatHist?"Y":"N"), (chop?"Y":"N"),
      (setupBull?"Y":"N"), (setupBear?"Y":"N"),
      (trigBuy?"Y":"N"), (trigSell?"Y":"N"),
      armStr, g_armLeft,
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
   if(chop) return;
   if(g_cooldownRemaining > 0) return;

   // If REVERSAL_ONLY, do not enter (v1.7 will implement reversal entries)
   if(InpSystemMode == SYSTEM_REVERSAL_ONLY)
      return;

   double closePrice = iClose(_Symbol, _Period, 1);
   double swingLow   = LowestLow(InpSwingLookbackL);
   double swingHigh  = HighestHigh(InpSwingLookbackL);

   // v1.6.1: Hard MTF gate BEFORE AI
   if(g_mtfEnabled && (longCandidate || shortCandidate) && !mtfAlignOK)
   {
      string cand = longCandidate ? "BUY" : "SELL";
      string why  = (g_mtfOK ? "MTF confirmation failed (" + g_mtfStr + ")" : "MTF not ready (" + g_mtfStr + ")");

      SaveAIFeedback(cand, "WAIT", 0.0, why, false);
      AppendAICsv(cand, "WAIT", 0.0, false, regimeStr, nearZero, flatHist, macd0, sig0, hist0, why);

      g_armDir = 0; g_armLeft = 0;
      return;
   }

   // BUY
   if(longCandidate)
   {
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
            trade.Buy(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity BUY");
      }
      return;
   }

   // SELL
   if(shortCandidate)
   {
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
            trade.Sell(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity SELL");
      }
      return;
   }
}
