//+------------------------------------------------------------------+
//|                                     CamarillaStrategyModules.mqh |
//| Reusable Camarilla setup modules                                 |
//+------------------------------------------------------------------+
#ifndef __DIGITALROGUE_CAMARILLA_STRATEGY_MODULES_MQH__
#define __DIGITALROGUE_CAMARILLA_STRATEGY_MODULES_MQH__

enum DRCamSetupModuleType
{
   DR_CAM_SETUP_NONE = 0,
   DR_CAM_SETUP_H4_SWEEP_RECLAIM_SHORT,
   DR_CAM_SETUP_L4_SWEEP_RECLAIM_LONG,
   DR_CAM_SETUP_H4_ACCEPTANCE_LONG,
   DR_CAM_SETUP_L4_ACCEPTANCE_SHORT,
   DR_CAM_SETUP_H3_REJECTION_SHORT,
   DR_CAM_SETUP_L3_REJECTION_LONG,
   DR_CAM_SETUP_H3_H4_REJECTION_SHORT,
   DR_CAM_SETUP_L3_L4_REJECTION_LONG,
   DR_CAM_SETUP_H5_EXHAUSTION_SHORT,
   DR_CAM_SETUP_L5_EXHAUSTION_LONG
};

struct DRCamSetupModuleContext
{
   MqlRates bar1;
   MqlRates bar2;
   MqlRates bar3;
   double   atr;
   double   ema20;
   double   vwap;
   double   h3;
   double   h4;
   double   h5;
   double   l3;
   double   l4;
   double   l5;
   double   spreadPoints;
   int      hour;
   double   candleRange;
   double   body;
   double   bodyToRangeRatio;
   double   upperWick;
   double   lowerWick;
};

struct DRCamSetupModuleResult
{
   DRCamSetupModuleType type;
   bool                 detected;
   bool                 bullish;
   bool                 bearish;
   int                  score;
   double               triggerPrice;
   string               tag;
   string               reason;
   string               summary;
};

void DRCSM_ResetResult(DRCamSetupModuleResult &result)
{
   result.type         = DR_CAM_SETUP_NONE;
   result.detected     = false;
   result.bullish      = false;
   result.bearish      = false;
   result.score        = 0;
   result.triggerPrice = 0.0;
   result.tag          = "";
   result.reason       = "NO_CAMARILLA_SIGNAL";
   result.summary      = "No Camarilla signal";
}

int DRCSM_ClampScore(const int score)
{
   if(score < 0)
      return 0;
   if(score > 10)
      return 10;
   return score;
}

bool DRCSM_IsBearishBar(const MqlRates &bar)
{
   return(bar.close < bar.open);
}

bool DRCSM_IsBullishBar(const MqlRates &bar)
{
   return(bar.close > bar.open);
}

bool DRCSM_BarTouchesZone(const MqlRates &bar,const double lower,const double upper)
{
   if(lower <= 0.0 || upper <= 0.0 || lower > upper)
      return false;
   return(bar.high >= lower && bar.low <= upper);
}

bool DRCSM_AnyRecentTouch3(const DRCamSetupModuleContext &ctx,const double lower,const double upper)
{
   return(DRCSM_BarTouchesZone(ctx.bar1, lower, upper) ||
          DRCSM_BarTouchesZone(ctx.bar2, lower, upper) ||
          DRCSM_BarTouchesZone(ctx.bar3, lower, upper));
}

bool DRCSM_IsLondonHour(const int hour)
{
   return(hour >= 7 && hour <= 12);
}

bool DRCSM_IsNewYorkHour(const int hour)
{
   return(hour >= 13 && hour <= 16);
}

bool DRCSM_IsAllowedSession(const int hour,const bool useLondon,const bool useNewYork)
{
   if(!useLondon && !useNewYork)
      return true;
   if(useLondon && DRCSM_IsLondonHour(hour))
      return true;
   if(useNewYork && DRCSM_IsNewYorkHour(hour))
      return true;
   return false;
}

void DRCSM_FillResult(DRCamSetupModuleResult &result,
                      const DRCamSetupModuleType type,
                      const bool bullish,
                      const bool bearish,
                      const int score,
                      const double triggerPrice,
                      const string tag,
                      const string reason,
                      const string summary)
{
   result.type         = type;
   result.detected     = true;
   result.bullish      = bullish;
   result.bearish      = bearish;
   result.score        = score;
   result.triggerPrice = triggerPrice;
   result.tag          = tag;
   result.reason       = reason;
   result.summary      = summary;
}

bool DRCSM_EvaluateH4SweepReclaimShort(const DRCamSetupModuleContext &ctx,
                                       const bool useLondon,
                                       const bool useNewYork,
                                       const double minBodyToRange,
                                       const double minSweepAtrFrac,
                                       const int minScoreToTrade,
                                       DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }

   if(ctx.h4 <= 0.0)
   {
      result.reason = "SKIP_H4_UNAVAILABLE";
      return false;
   }

   if(ctx.ema20 <= 0.0 || ctx.bar1.close >= ctx.ema20)
   {
      result.reason = "SKIP_NOT_BELOW_EMA20";
      return false;
   }

   if(ctx.bar1.high < ctx.h4)
   {
      result.reason = "SKIP_NO_H4_SWEEP";
      return false;
   }

   if(ctx.bar1.close >= ctx.h4)
   {
      result.reason = "SKIP_NO_RECLAIM";
      return false;
   }

   if(ctx.atr <= 0.0)
   {
      result.reason = "SKIP_ATR_UNAVAILABLE";
      return false;
   }

   double excursion = ctx.bar1.high - ctx.h4;
   if(excursion < (ctx.atr * minSweepAtrFrac))
   {
      result.reason = "SKIP_SWEEP_TOO_SHALLOW";
      return false;
   }

   int score = 4;
   if(DRCSM_IsBearishBar(ctx.bar1))
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.upperWick > ctx.body)
      score += 1;
   if(ctx.bar1.close < ctx.vwap && ctx.vwap > 0.0)
      score += 1;
   if(ctx.bar1.close < ctx.bar2.close)
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_H4_SWEEP_RECLAIM_SHORT,
                    false,
                    true,
                    score,
                    ctx.bar1.close,
                    "CAM_H4_SWEEP_RECLAIM_SHORT_v100",
                    "CAM_H4_SWEEP_RECLAIM_SHORT_READY",
                    "Camarilla H4 sweep reclaim short");
   return true;
}

bool DRCSM_EvaluateL4SweepReclaimLong(const DRCamSetupModuleContext &ctx,
                                      const bool useLondon,
                                      const bool useNewYork,
                                      const double minBodyToRange,
                                      const double minSweepAtrFrac,
                                      const int minScoreToTrade,
                                      DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }

   if(ctx.l4 <= 0.0)
   {
      result.reason = "SKIP_L4_UNAVAILABLE";
      return false;
   }

   if(ctx.ema20 <= 0.0 || ctx.bar1.close <= ctx.ema20)
   {
      result.reason = "SKIP_NOT_ABOVE_EMA20";
      return false;
   }

   if(ctx.bar1.low > ctx.l4)
   {
      result.reason = "SKIP_NO_L4_SWEEP";
      return false;
   }

   if(ctx.bar1.close <= ctx.l4)
   {
      result.reason = "SKIP_NO_RECLAIM";
      return false;
   }

   if(ctx.atr <= 0.0)
   {
      result.reason = "SKIP_ATR_UNAVAILABLE";
      return false;
   }

   double excursion = ctx.l4 - ctx.bar1.low;
   if(excursion < (ctx.atr * minSweepAtrFrac))
   {
      result.reason = "SKIP_SWEEP_TOO_SHALLOW";
      return false;
   }

   int score = 4;
   if(ctx.bar1.close > ctx.bar1.open)
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.lowerWick > ctx.body)
      score += 1;
   if(ctx.bar1.close > ctx.vwap && ctx.vwap > 0.0)
      score += 1;
   if(ctx.bar1.close > ctx.bar2.close)
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_L4_SWEEP_RECLAIM_LONG,
                    true,
                    false,
                    score,
                    ctx.bar1.close,
                    "CAM_L4_SWEEP_RECLAIM_LONG_v100",
                    "CAM_L4_SWEEP_RECLAIM_LONG_READY",
                    "Camarilla L4 sweep reclaim long");
   return true;
}

bool DRCSM_EvaluateH4AcceptanceLong(const DRCamSetupModuleContext &ctx,
                                    const bool useLondon,
                                    const bool useNewYork,
                                    const double minBodyToRange,
                                    const int minScoreToTrade,
                                    DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }
   if(ctx.h4 <= 0.0)
   {
      result.reason = "SKIP_H4_UNAVAILABLE";
      return false;
   }
   if(ctx.bar1.close <= ctx.h4)
   {
      result.reason = "SKIP_NOT_ABOVE_H4";
      return false;
   }
   if(ctx.bar1.low < ctx.h4)
   {
      result.reason = "SKIP_NO_ACCEPTANCE";
      return false;
   }

   int score = 4;
   if(DRCSM_IsBullishBar(ctx.bar1))
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.bar1.close > ctx.ema20 && ctx.ema20 > 0.0)
      score += 1;
   if(ctx.bar1.close > ctx.vwap && ctx.vwap > 0.0)
      score += 1;
   if(ctx.bar1.close > ctx.bar2.high)
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_H4_ACCEPTANCE_LONG,
                    true,
                    false,
                    score,
                    ctx.bar1.close,
                    "CAM_H4_ACCEPTANCE_LONG_v100",
                    "CAM_H4_ACCEPTANCE_LONG_READY",
                    "Camarilla H4 acceptance long");
   return true;
}

bool DRCSM_EvaluateL4AcceptanceShort(const DRCamSetupModuleContext &ctx,
                                     const bool useLondon,
                                     const bool useNewYork,
                                     const double minBodyToRange,
                                     const int minScoreToTrade,
                                     DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }
   if(ctx.l4 <= 0.0)
   {
      result.reason = "SKIP_L4_UNAVAILABLE";
      return false;
   }
   if(ctx.bar1.close >= ctx.l4)
   {
      result.reason = "SKIP_NOT_BELOW_L4";
      return false;
   }
   if(ctx.bar1.high > ctx.l4)
   {
      result.reason = "SKIP_NO_ACCEPTANCE";
      return false;
   }

   int score = 4;
   if(DRCSM_IsBearishBar(ctx.bar1))
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.bar1.close < ctx.ema20 && ctx.ema20 > 0.0)
      score += 1;
   if(ctx.bar1.close < ctx.vwap && ctx.vwap > 0.0)
      score += 1;
   if(ctx.bar1.close < ctx.bar2.low)
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_L4_ACCEPTANCE_SHORT,
                    false,
                    true,
                    score,
                    ctx.bar1.close,
                    "CAM_L4_ACCEPTANCE_SHORT_v100",
                    "CAM_L4_ACCEPTANCE_SHORT_READY",
                    "Camarilla L4 acceptance short");
   return true;
}

bool DRCSM_EvaluateH3RejectionShort(const DRCamSetupModuleContext &ctx,
                                    const bool useLondon,
                                    const bool useNewYork,
                                    const double minBodyToRange,
                                    const int minScoreToTrade,
                                    DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }
   if(ctx.h3 <= 0.0)
   {
      result.reason = "SKIP_H3_UNAVAILABLE";
      return false;
   }
   if(ctx.bar1.high < ctx.h3)
   {
      result.reason = "SKIP_NO_H3_TEST";
      return false;
   }
   if(ctx.bar1.close >= ctx.h3)
   {
      result.reason = "SKIP_NO_H3_REJECTION";
      return false;
   }

   int score = 3;
   if(DRCSM_IsBearishBar(ctx.bar1))
      score += 1;
   if(ctx.upperWick > ctx.body)
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.bar1.close < ctx.ema20 && ctx.ema20 > 0.0)
      score += 1;
   if(ctx.bar1.close < ctx.vwap && ctx.vwap > 0.0)
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_H3_REJECTION_SHORT,
                    false,
                    true,
                    score,
                    ctx.bar1.close,
                    "CAM_H3_REJECTION_SHORT_v100",
                    "CAM_H3_REJECTION_SHORT_READY",
                    "Camarilla H3 rejection short");
   return true;
}

bool DRCSM_EvaluateL3RejectionLong(const DRCamSetupModuleContext &ctx,
                                   const bool useLondon,
                                   const bool useNewYork,
                                   const double minBodyToRange,
                                   const int minScoreToTrade,
                                   DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }
   if(ctx.l3 <= 0.0)
   {
      result.reason = "SKIP_L3_UNAVAILABLE";
      return false;
   }
   if(ctx.bar1.low > ctx.l3)
   {
      result.reason = "SKIP_NO_L3_TEST";
      return false;
   }
   if(ctx.bar1.close <= ctx.l3)
   {
      result.reason = "SKIP_NO_L3_REJECTION";
      return false;
   }

   int score = 3;
   if(DRCSM_IsBullishBar(ctx.bar1))
      score += 1;
   if(ctx.lowerWick > ctx.body)
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.bar1.close > ctx.ema20 && ctx.ema20 > 0.0)
      score += 1;
   if(ctx.bar1.close > ctx.vwap && ctx.vwap > 0.0)
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_L3_REJECTION_LONG,
                    true,
                    false,
                    score,
                    ctx.bar1.close,
                    "CAM_L3_REJECTION_LONG_v100",
                    "CAM_L3_REJECTION_LONG_READY",
                    "Camarilla L3 rejection long");
   return true;
}

bool DRCSM_EvaluateH3H4RejectionShort(const DRCamSetupModuleContext &ctx,
                                      const bool useLondon,
                                      const bool useNewYork,
                                      const double minBodyToRange,
                                      const int minScoreToTrade,
                                      DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }
   if(ctx.h3 <= 0.0 || ctx.h4 <= 0.0)
   {
      result.reason = "SKIP_ZONE_UNAVAILABLE";
      return false;
   }
   if(!DRCSM_AnyRecentTouch3(ctx, ctx.h3, ctx.h4))
   {
      result.reason = "SKIP_NO_H3_H4_TEST";
      return false;
   }
   if(ctx.bar1.close >= ctx.h3)
   {
      result.reason = "SKIP_NO_ZONE_REJECTION";
      return false;
   }

   int score = 4;
   if(DRCSM_IsBearishBar(ctx.bar1))
      score += 1;
   if(ctx.upperWick > ctx.body)
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.bar1.close < ctx.ema20 && ctx.ema20 > 0.0)
      score += 1;
   if(ctx.bar1.close < ctx.vwap && ctx.vwap > 0.0)
      score += 1;
   if(DRCSM_BarTouchesZone(ctx.bar2, ctx.h3, ctx.h4) || DRCSM_BarTouchesZone(ctx.bar3, ctx.h3, ctx.h4))
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_H3_H4_REJECTION_SHORT,
                    false,
                    true,
                    score,
                    ctx.bar1.close,
                    "CAM_H3_H4_REJECTION_SHORT_v100",
                    "CAM_H3_H4_REJECTION_SHORT_READY",
                    "Camarilla H3-H4 rejection short");
   return true;
}

bool DRCSM_EvaluateL3L4RejectionLong(const DRCamSetupModuleContext &ctx,
                                     const bool useLondon,
                                     const bool useNewYork,
                                     const double minBodyToRange,
                                     const int minScoreToTrade,
                                     DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }
   if(ctx.l3 <= 0.0 || ctx.l4 <= 0.0)
   {
      result.reason = "SKIP_ZONE_UNAVAILABLE";
      return false;
   }
   if(!DRCSM_AnyRecentTouch3(ctx, ctx.l4, ctx.l3))
   {
      result.reason = "SKIP_NO_L3_L4_TEST";
      return false;
   }
   if(ctx.bar1.close <= ctx.l3)
   {
      result.reason = "SKIP_NO_ZONE_REJECTION";
      return false;
   }

   int score = 4;
   if(DRCSM_IsBullishBar(ctx.bar1))
      score += 1;
   if(ctx.lowerWick > ctx.body)
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.bar1.close > ctx.ema20 && ctx.ema20 > 0.0)
      score += 1;
   if(ctx.bar1.close > ctx.vwap && ctx.vwap > 0.0)
      score += 1;
   if(DRCSM_BarTouchesZone(ctx.bar2, ctx.l4, ctx.l3) || DRCSM_BarTouchesZone(ctx.bar3, ctx.l4, ctx.l3))
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_L3_L4_REJECTION_LONG,
                    true,
                    false,
                    score,
                    ctx.bar1.close,
                    "CAM_L3_L4_REJECTION_LONG_v100",
                    "CAM_L3_L4_REJECTION_LONG_READY",
                    "Camarilla L3-L4 rejection long");
   return true;
}

bool DRCSM_EvaluateH5ExhaustionShort(const DRCamSetupModuleContext &ctx,
                                     const bool useLondon,
                                     const bool useNewYork,
                                     const double minBodyToRange,
                                     const int minScoreToTrade,
                                     DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }
   if(ctx.h5 <= 0.0 || ctx.h4 <= 0.0)
   {
      result.reason = "SKIP_H5_UNAVAILABLE";
      return false;
   }
   if(ctx.bar1.high < ctx.h5)
   {
      result.reason = "SKIP_NO_H5_TEST";
      return false;
   }
   if(ctx.bar1.close >= ctx.h4)
   {
      result.reason = "SKIP_NO_EXHAUSTION_REVERSAL";
      return false;
   }

   int score = 5;
   if(DRCSM_IsBearishBar(ctx.bar1))
      score += 1;
   if(ctx.upperWick > ctx.body)
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.bar1.close < ctx.ema20 && ctx.ema20 > 0.0)
      score += 1;
   if(ctx.bar1.close < ctx.vwap && ctx.vwap > 0.0)
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_H5_EXHAUSTION_SHORT,
                    false,
                    true,
                    score,
                    ctx.bar1.close,
                    "CAM_H5_EXHAUSTION_SHORT_v100",
                    "CAM_H5_EXHAUSTION_SHORT_READY",
                    "Camarilla H5 exhaustion short");
   return true;
}

bool DRCSM_EvaluateL5ExhaustionLong(const DRCamSetupModuleContext &ctx,
                                    const bool useLondon,
                                    const bool useNewYork,
                                    const double minBodyToRange,
                                    const int minScoreToTrade,
                                    DRCamSetupModuleResult &result)
{
   DRCSM_ResetResult(result);

   if(!DRCSM_IsAllowedSession(ctx.hour, useLondon, useNewYork))
   {
      result.reason = "SKIP_SESSION_FILTER";
      return false;
   }
   if(ctx.l5 <= 0.0 || ctx.l4 <= 0.0)
   {
      result.reason = "SKIP_L5_UNAVAILABLE";
      return false;
   }
   if(ctx.bar1.low > ctx.l5)
   {
      result.reason = "SKIP_NO_L5_TEST";
      return false;
   }
   if(ctx.bar1.close <= ctx.l4)
   {
      result.reason = "SKIP_NO_EXHAUSTION_REVERSAL";
      return false;
   }

   int score = 5;
   if(DRCSM_IsBullishBar(ctx.bar1))
      score += 1;
   if(ctx.lowerWick > ctx.body)
      score += 1;
   if(ctx.bodyToRangeRatio >= minBodyToRange)
      score += 1;
   if(ctx.bar1.close > ctx.ema20 && ctx.ema20 > 0.0)
      score += 1;
   if(ctx.bar1.close > ctx.vwap && ctx.vwap > 0.0)
      score += 1;

   score = DRCSM_ClampScore(score);
   if(score < minScoreToTrade)
   {
      result.reason = "SKIP_SCORE_TOO_LOW";
      return false;
   }

   DRCSM_FillResult(result,
                    DR_CAM_SETUP_L5_EXHAUSTION_LONG,
                    true,
                    false,
                    score,
                    ctx.bar1.close,
                    "CAM_L5_EXHAUSTION_LONG_v100",
                    "CAM_L5_EXHAUSTION_LONG_READY",
                    "Camarilla L5 exhaustion long");
   return true;
}

#endif // __DIGITALROGUE_CAMARILLA_STRATEGY_MODULES_MQH__
