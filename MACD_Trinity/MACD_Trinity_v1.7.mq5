//+------------------------------------------------------------------+
//|                                                   MACD_TrinityEA |
//|                    MACD-only system + optional AI confirmation    |
//|                                                                  |
//|  v1.7: SystemMode + MTF MACD confirmation + robust CopyBuffer     |
//|        + Signal Source display (TREND vs REVERSAL)                |
//|        - Adds SystemMode: TREND_ONLY / REVERSAL_ONLY / BOTH       |
//|        - Adds MTF confirm (TF1/TF2) with warmup checks            |
//|        - Fixes "all zeros" logs by enforcing BarsCalculated/Copy   |
//|        - HUD shows MTF + last signal source/reason                |
//|        - AI packet includes MTF + SystemMode                       |
//|        - CSV includes signal_source, signal_note                  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//---------------------------- Enums ----------------------------------
enum ENUM_SystemMode
{
   TREND_ONLY = 0,
   REVERSAL_ONLY = 1,
   BOTH = 2
};

//---------------------------- Inputs --------------------------------
input ENUM_SystemMode InpSystemMode        = BOTH;

// MACD
input int    InpMACD_Fast          = 12;
input int    InpMACD_Slow          = 26;
input int    InpMACD_Signal        = 9;

// Filters / stops
input int    InpMedianLookbackN    = 50;     // Median lookback for chop filters
input int    InpSwingLookbackL     = 10;     // Swing lookback for stop loss

input double InpZeroZoneFactor     = 0.60;   // ZeroZone = factor * median(|MACD|)
input double InpFlatHistFactor     = 0.15;   // flatHist if |hist| < factor * median(|hist|)

// Trade control
input bool   InpOneTradePerBar     = true;
input int    InpCooldownBars       = 2;      // after close, wait bars before re-enter

// Arming window (for TREND logic)
input int    InpArmBars            = 6;
input bool   InpRequireSetupTurn   = true;

// Option A early exit on histogram weakening
input bool   InpExitOnHistWeakening = true;

// Risk/size
input double InpLots               = 0.10;   // Fixed lot for now
input int    InpSlippagePoints     = 20;

// ----------------- MTF Confirmation (System 3) ----------------------
input bool            InpUseMTFConfirm = true;
input ENUM_TIMEFRAMES InpMTF_TF1       = PERIOD_H1;
input ENUM_TIMEFRAMES InpMTF_TF2       = PERIOD_H4;

// What should MTF confirm?
input bool InpMTF_RequireRegimeSign  = true; // BUY: macd>0, SELL: macd<0 on TF1+TF2
input bool InpMTF_RequireMomentum    = true; // BUY: macd>signal, SELL: macd<signal on TF1+TF2

// ----------------- AI Confirmation (ChatGPT/OpenAI) -----------------
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
// Handles
int      g_macdHandle = INVALID_HANDLE;
int      g_macdHandleTF1 = INVALID_HANDLE;
int      g_macdHandleTF2 = INVALID_HANDLE;

datetime g_lastBarTime = 0;
int      g_cooldownRemaining = 0;

// arming state (TREND)
int g_armDir  = 0;   // 0 none, 1 long armed, -1 short armed
int g_armLeft = 0;

// MACD buffers (local)
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

// MTF status (latest)
bool   g_mtfOK = true;
string g_mtfReason = "N/A";

// --- Signal source tracking ---
string g_lastSignalSource = "NONE";   // TREND / REVERSAL / NONE
string g_lastSignalNote   = "";

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

// Median of abs(values) over [startShift .. startShift+count-1] from series[]
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

// ---------------- Robust MACD Copy (fixes "zeros") ------------------
bool CopyMACDSeries(const int handle, const int count, double &mainBuf[], double &sigBuf[])
{
   if(handle == INVALID_HANDLE) return false;

   int calc = BarsCalculated(handle);
   if(calc < count + 5) // warmup cushion
      return false;

   ArrayResize(mainBuf, count);
   ArrayResize(sigBuf,  count);
   ArraySetAsSeries(mainBuf, true);
   ArraySetAsSeries(sigBuf,  true);

   int c1 = CopyBuffer(handle, 0, 0, count, mainBuf);
   int c2 = CopyBuffer(handle, 1, 0, count, sigBuf);

   if(c1 != count || c2 != count) return false;
   return true;
}

// Get MACD(shift) and Signal(shift) from a handle (used for MTF quick checks)
bool GetMACDAtShift(const int handle, const int shift, double &macdOut, double &sigOut)
{
   macdOut = 0.0; sigOut = 0.0;
   if(handle == INVALID_HANDLE) return false;

   int calc = BarsCalculated(handle);
   if(calc < shift + 5) return false;

   double m[1], s[1];
   ArraySetAsSeries(m, true);
   ArraySetAsSeries(s, true);

   int c1 = CopyBuffer(handle, 0, shift, 1, m);
   int c2 = CopyBuffer(handle, 1, shift, 1, s);
   if(c1 != 1 || c2 != 1) return false;

   macdOut = m[0];
   sigOut  = s[0];
   return true;
}

// ---------------- AI Key loading -----------------------------------
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

// ---------------- AI feedback + CSV ---------------------------------
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
                 const string systemModeStr,
                 const string signalSource,
                 const string signalNote,
                 const string regimeStr,
                 const bool nearZero,
                 const bool flatHist,
                 const bool mtfOK,
                 const string mtfReason,
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
      FileWriteString(h,
         "time,symbol,tf,system_mode,signal_source,signal_note,"
         "candidate,decision,confidence,approved,regime,nearZero,flatHist,mtfOK,mtfReason,"
         "macd0,sig0,hist0,reason\r\n");
   }

   FileSeek(h, 0, SEEK_END);

   string line =
      CsvEscape(TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)) + "," +
      CsvEscape(_Symbol) + "," +
      CsvEscape(EnumToString(_Period)) + "," +
      CsvEscape(systemModeStr) + "," +
      CsvEscape(signalSource) + "," +
      CsvEscape(signalNote) + "," +
      CsvEscape(candidate) + "," +
      CsvEscape(decision) + "," +
      DoubleToString(conf, 6) + "," +
      (approved ? "1" : "0") + "," +
      CsvEscape(regimeStr) + "," +
      (nearZero ? "1" : "0") + "," +
      (flatHist ? "1" : "0") + "," +
      (mtfOK ? "1" : "0") + "," +
      CsvEscape(TruncReason(mtfReason, 200)) + "," +
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

string SystemModeToString(ENUM_SystemMode m)
{
   if(m == TREND_ONLY) return "TREND_ONLY";
   if(m == REVERSAL_ONLY) return "REVERSAL_ONLY";
   return "BOTH";
}

// ---------------- MTF Confirmation logic ----------------------------
bool MTFConfirm(const string candidate, string &reasonOut)
{
   reasonOut = "N/A";

   if(!InpUseMTFConfirm)
   {
      reasonOut = "MTF disabled";
      return true;
   }

   if(InpMTF_TF1 == PERIOD_CURRENT || InpMTF_TF2 == PERIOD_CURRENT)
   {
      reasonOut = "Invalid MTF TF (cannot be CURRENT)";
      return false;
   }

   double m1=0,s1=0,m2=0,s2=0;
   bool ok1 = GetMACDAtShift(g_macdHandleTF1, 1, m1, s1); // closed bar
   bool ok2 = GetMACDAtShift(g_macdHandleTF2, 1, m2, s2);

   if(!ok1 || !ok2)
   {
      reasonOut = "MTF warmup/CopyBuffer not ready (history not loaded yet)";
      return false;
   }

   bool wantBuy  = (candidate == "BUY");
   bool wantSell = (candidate == "SELL");

   bool pass = true;
   string r = "";

   if(InpMTF_RequireRegimeSign)
   {
      bool sign1 = wantBuy ? (m1 > 0.0) : (m1 < 0.0);
      bool sign2 = wantBuy ? (m2 > 0.0) : (m2 < 0.0);
      if(!sign1 || !sign2)
      {
         pass = false;
         r += StringFormat("RegimeSign fail: TF1 m=%.6f TF2 m=%.6f. ", m1, m2);
      }
   }

   if(InpMTF_RequireMomentum)
   {
      bool mom1 = wantBuy ? (m1 > s1) : (m1 < s1);
      bool mom2 = wantBuy ? (m2 > s2) : (m2 < s2);
      if(!mom1 || !mom2)
      {
         pass = false;
         r += StringFormat("Momentum fail: TF1 m-s=%.6f TF2 m-s=%.6f. ", (m1-s1), (m2-s2));
      }
   }

   if(pass) r = StringFormat("OK TF1(m=%.6f s=%.6f) TF2(m=%.6f s=%.6f)", m1, s1, m2, s2);
   reasonOut = r;
   return pass;
}

// ---------------- AI Confirm ----------------------------------------
bool AIConfirmTrade(const string dirCandidate,
                    const string systemModeStr,
                    const string signalSource,
                    const string signalNote,
                    const string regimeStr,
                    const bool setupOk,
                    const bool triggerOk,
                    const bool nearZero,
                    const bool flatHist,
                    const bool mtfOK,
                    const string mtfReason,
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
      "\"system_mode\":\""+systemModeStr+"\","
      "\"signal_source\":\""+signalSource+"\","
      "\"signal_note\":\""+JsonEscape(signalNote)+"\","
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
      "\"mtf\":{"
         "\"enabled\":"+(InpUseMTFConfirm?"true":"false")+","
         "\"ok\":"+(mtfOK?"true":"false")+","
         "\"reason\":\""+JsonEscape(mtfReason)+"\""
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
      "You confirm trades for a MACD-only system (Trend/Reversal + MTF filter). "
      "Use ONLY the packet values. "
      "Approve BUY/SELL only if candidate aligns with regime+setup+trigger AND mtf.ok=true. "
      "Return WAIT otherwise. "
      "Output ONLY valid JSON with keys: decision, confidence, reason, regime, setup, trigger, filters_ok, mtf_ok.";

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
      Print("Failed to create MACD handle (local).");
      return INIT_FAILED;
   }

   if(InpUseMTFConfirm)
   {
      g_macdHandleTF1 = iMACD(_Symbol, InpMTF_TF1, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
      g_macdHandleTF2 = iMACD(_Symbol, InpMTF_TF2, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
      if(g_macdHandleTF1 == INVALID_HANDLE || g_macdHandleTF2 == INVALID_HANDLE)
         Print("Warning: Failed to create one or more MTF MACD handles.");
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

   Print("MACD_TrinityEA v1.7 initialized. Symbol=", _Symbol, " TF=", EnumToString(_Period),
         " Mode=", SystemModeToString(InpSystemMode),
         " MTF=", (InpUseMTFConfirm ? "ON" : "OFF"));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_macdHandle != INVALID_HANDLE)
      IndicatorRelease(g_macdHandle);

   if(g_macdHandleTF1 != INVALID_HANDLE)
      IndicatorRelease(g_macdHandleTF1);

   if(g_macdHandleTF2 != INVALID_HANDLE)
      IndicatorRelease(g_macdHandleTF2);

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
   if(bars < (InpMedianLookbackN + 40))
      return;

   int need = InpMedianLookbackN + 30;
   if(!CopyMACDSeries(g_macdHandle, need, g_macdMain, g_macdSignal))
      return;

   // CLOSED bars
   double macd0 = g_macdMain[1];
   double macd1 = g_macdMain[2];
   double macd2 = g_macdMain[3];

   double sig0  = g_macdSignal[1];
   double sig1  = g_macdSignal[2];
   double sig2  = g_macdSignal[3];

   double hist0 = macd0 - sig0;
   double hist1 = macd1 - sig1;
   double hist2 = macd2 - sig2;

   // Filters
   double medAbsMacd = MedianAbsFromSeries(g_macdMain, 1, InpMedianLookbackN);

   double histSeries[];
   ArrayResize(histSeries, InpMedianLookbackN + 5);
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

   // Trend logic
   bool setupBull = regimeBull && (hist0 > hist1);
   bool setupBear = regimeBear && (hist0 < hist1);

   bool trigBuy  = (macd1 <= sig1) && (macd0 > sig0);
   bool trigSell = (macd1 >= sig1) && (macd0 < sig0);

   // Position
   long posType;
   ulong ticket;
   bool hasPos = HasPositionForSymbol(_Symbol, posType, ticket);

   if(g_cooldownRemaining > 0 && !hasPos)
      g_cooldownRemaining--;

   // Arm (TREND)
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

   // Reversal logic (MACD-only)
   bool revBuySetup  = ( (macd0 < 0.0) || nearZero ) && (hist0 > hist1);
   bool revSellSetup = ( (macd0 > 0.0) || nearZero ) && (hist0 < hist1);

   bool revBuyTrig   = trigBuy;
   bool revSellTrig  = trigSell;

   bool revChopBlock = flatHist; // allow nearZero for reversal, block only flat hist

   // MTF
   string mtfReason;
   bool mtfBuyOK  = MTFConfirm("BUY", mtfReason);
   bool mtfSellOK = MTFConfirm("SELL", mtfReason);

   // HUD lines
   string modeStr = SystemModeToString(InpSystemMode);

   string posStr = "NONE";
   if(hasPos) posStr = (posType==POSITION_TYPE_BUY ? "LONG" : "SHORT");

   string armStr = (g_armDir==1 ? "LONG" : (g_armDir==-1 ? "SHORT" : "NONE"));

   string aiLine = "AI: OFF";
   if(g_useAIConfirm)
   {
      aiLine = StringFormat("AI: ON cand=%s dec=%s conf=%.2f %s",
                            (g_aiLastCandidate=="" ? "-" : g_aiLastCandidate),
                            (g_aiLastDecision=="" ? "-" : g_aiLastDecision),
                            g_aiLastConf,
                            (g_aiLastApproved ? "APPROVED" : "BLOCKED"));
   }

   string mtfLine = "MTF: OFF";
   if(InpUseMTFConfirm)
      mtfLine = StringFormat("MTF: TF1=%s TF2=%s | BUY=%s SELL=%s",
                             EnumToString(InpMTF_TF1), EnumToString(InpMTF_TF2),
                             (mtfBuyOK?"OK":"FAIL"),
                             (mtfSellOK?"OK":"FAIL"));

   string hud = StringFormat(
      "MACD Trinity EA (v1.7)\n"
      "Mode: %s\n"
      "LastSignal: %s | %s\n"
      "Regime: %s\n"
      "MACD0: %.8f  SIG0: %.8f\n"
      "HIST0: %.8f  HIST1: %.8f\n"
      "ZeroZone: %.8f  |MACD|: %.8f  NearZero=%s\n"
      "FlatHist=%s  Chop(TREND)=%s\n"
      "TREND Setup(B/S): %s/%s  Trig(B/S): %s/%s  ARM: %s (%d)\n"
      "REV Setup(B/S): %s/%s  Trig(B/S): %s/%s\n"
      "Cooldown: %d\n"
      "%s\n"
      "%s\n"
      "AI Reason: %s\n"
      "Pos: %s",
      modeStr,
      g_lastSignalSource, g_lastSignalNote,
      regimeStr,
      macd0, sig0,
      hist0, hist1,
      zeroZone, AbsD(macd0), (nearZero?"Y":"N"),
      (flatHist?"Y":"N"), (chop?"Y":"N"),
      (setupBull?"Y":"N"), (setupBear?"Y":"N"),
      (trigBuy?"Y":"N"), (trigSell?"Y":"N"),
      armStr, g_armLeft,
      (revBuySetup?"Y":"N"), (revSellSetup?"Y":"N"),
      (revBuyTrig?"Y":"N"), (revSellTrig?"Y":"N"),
      g_cooldownRemaining,
      mtfLine,
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
   if(g_cooldownRemaining > 0) return;

   string candidate = "";
   bool setupOk=false, triggerOk=false;

   // reset signal info each bar
   g_lastSignalSource = "NONE";
   g_lastSignalNote   = "";

   // TREND candidate
   bool trendLongCandidate  = (g_armDir == 1 && trigBuy);
   bool trendShortCandidate = (g_armDir == -1 && trigSell);

   // REV candidate
   bool revLongCandidate  = (revBuySetup && revBuyTrig);
   bool revShortCandidate = (revSellSetup && revSellTrig);

   // TREND selection (blocks chop)
   if(InpSystemMode == TREND_ONLY || InpSystemMode == BOTH)
   {
      if(!chop)
      {
         if(trendLongCandidate)
         {
            candidate="BUY"; setupOk=true; triggerOk=true;
            g_lastSignalSource="TREND";
            g_lastSignalNote="armed+cross (trend)";
         }
         else if(trendShortCandidate)
         {
            candidate="SELL"; setupOk=true; triggerOk=true;
            g_lastSignalSource="TREND";
            g_lastSignalNote="armed+cross (trend)";
         }
      }
   }

   // REVERSAL selection (allows nearZero; blocks only flat hist)
   if(candidate=="" && (InpSystemMode == REVERSAL_ONLY || InpSystemMode == BOTH))
   {
      if(!revChopBlock)
      {
         if(revLongCandidate)
         {
            candidate="BUY"; setupOk=true; triggerOk=true;
            g_lastSignalSource="REVERSAL";
            g_lastSignalNote=(nearZero ? "nearZero+turn+cross" : "turn+cross");
         }
         else if(revShortCandidate)
         {
            candidate="SELL"; setupOk=true; triggerOk=true;
            g_lastSignalSource="REVERSAL";
            g_lastSignalNote=(nearZero ? "nearZero+turn+cross" : "turn+cross");
         }
      }
   }

   if(candidate=="") return;

   // clear arm once candidate forms
   g_armDir = 0; g_armLeft = 0;

   // MTF per candidate
   bool mtfOK = true;
   string mtfR = "MTF disabled";
   if(InpUseMTFConfirm)
   {
      mtfOK = (candidate=="BUY") ? mtfBuyOK : mtfSellOK;
      mtfR  = mtfReason;
   }
   g_mtfOK = mtfOK;
   g_mtfReason = mtfR;

   if(!mtfOK)
      return;

   double closePrice = iClose(_Symbol, _Period, 1);
   double swingLow   = LowestLow(InpSwingLookbackL);
   double swingHigh  = HighestHigh(InpSwingLookbackL);

   string modeStr2 = SystemModeToString(InpSystemMode);

   // AI confirm
   string aiDecision, aiReason;
   double aiConf;

   bool okAI = AIConfirmTrade(candidate, modeStr2, g_lastSignalSource, g_lastSignalNote,
                              regimeStr, setupOk, triggerOk, nearZero, flatHist,
                              mtfOK, mtfR,
                              macd0, macd1, sig0, sig1, hist0, hist1,
                              zeroZone, medAbsMacd, medAbsHist,
                              closePrice, swingLow, swingHigh,
                              aiDecision, aiConf, aiReason);

   bool approved = (!g_useAIConfirm || okAI);

   SaveAIFeedback(candidate, aiDecision, aiConf, aiReason, approved);
   AppendAICsv(candidate, aiDecision, aiConf, approved, modeStr2, g_lastSignalSource, g_lastSignalNote,
               regimeStr, nearZero, flatHist, mtfOK, mtfR,
               macd0, sig0, hist0, aiReason);

   if(!approved) return;

   // Print entry source to Experts
   Print("ENTRY: ", candidate,
         " source=", g_lastSignalSource,
         " note=", g_lastSignalNote,
         " mtfOK=", (mtfOK?"Y":"N"),
         " nearZero=", (nearZero?"Y":"N"),
         " flatHist=", (flatHist?"Y":"N"));

   // Place trade
   if(candidate=="BUY")
   {
      double sl = swingLow;
      if(sl > 0.0 && sl < closePrice)
         trade.Buy(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity BUY");
      return;
   }
   else if(candidate=="SELL")
   {
      double sl = swingHigh;
      if(sl > 0.0 && sl > closePrice)
         trade.Sell(InpLots, _Symbol, 0.0, sl, 0.0, "MACD Trinity SELL");
      return;
   }
}
//+------------------------------------------------------------------+

