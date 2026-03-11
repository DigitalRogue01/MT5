//+------------------------------------------------------------------+
//|                                         CompressionDetector.mqh   |
//| Reusable PDH/PDL compression helpers                             |
//+------------------------------------------------------------------+
#ifndef __COMPRESSION_DETECTOR_MQH__
#define __COMPRESSION_DETECTOR_MQH__

struct CompressionDetectionConfig
{
   int    lookback_bars;
   double level_tolerance_atr;
   double max_cluster_range_atr;
   double max_body_size_atr;
   int    confirmation_bars;
};

struct CompressionState
{
   bool     pdh_active;
   bool     pdl_active;
   int      pdh_bars_left;
   int      pdl_bars_left;
   datetime pdh_detected_at;
   datetime pdl_detected_at;
};

void ResetCompressionState(CompressionState &state)
{
   state.pdh_active = false;
   state.pdl_active = false;
   state.pdh_bars_left = 0;
   state.pdl_bars_left = 0;
   state.pdh_detected_at = 0;
   state.pdl_detected_at = 0;
}

void AgeCompressionState(CompressionState &state)
{
   if(state.pdh_bars_left > 0)
      state.pdh_bars_left--;
   if(state.pdl_bars_left > 0)
      state.pdl_bars_left--;

   state.pdh_active = (state.pdh_bars_left > 0);
   state.pdl_active = (state.pdl_bars_left > 0);
}

void ActivatePDHCompression(CompressionState &state,
                            const int confirmation_bars,
                            const datetime detected_at)
{
   state.pdh_active = true;
   state.pdh_bars_left = confirmation_bars;
   state.pdh_detected_at = detected_at;
}

void ActivatePDLCompression(CompressionState &state,
                            const int confirmation_bars,
                            const datetime detected_at)
{
   state.pdl_active = true;
   state.pdl_bars_left = confirmation_bars;
   state.pdl_detected_at = detected_at;
}

void ConsumePDHCompression(CompressionState &state)
{
   state.pdh_active = false;
   state.pdh_bars_left = 0;
}

void ConsumePDLCompression(CompressionState &state)
{
   state.pdl_active = false;
   state.pdl_bars_left = 0;
}

bool DetectCompressionAtLevel(const string symbol,
                              const ENUM_TIMEFRAMES timeframe,
                              const double level,
                              const double atr,
                              const int start_shift,
                              const CompressionDetectionConfig &config)
{
   if(level <= 0.0 || atr <= 0.0 || config.lookback_bars < 2)
      return(false);

   double highest_high = -DBL_MAX;
   double lowest_low = DBL_MAX;
   double first_range = 0.0;
   double last_range = 0.0;
   int touches = 0;

   for(int i = 0; i < config.lookback_bars; i++)
   {
      const int shift = start_shift + i;
      const double high = iHigh(symbol, timeframe, shift);
      const double low = iLow(symbol, timeframe, shift);
      const double open = iOpen(symbol, timeframe, shift);
      const double close = iClose(symbol, timeframe, shift);
      if(high <= 0.0 || low <= 0.0)
         return(false);

      const double range = high - low;
      const double body = MathAbs(close - open);
      if(i == 0)
         first_range = range;
      if(i == config.lookback_bars - 1)
         last_range = range;

      if(body > atr * config.max_body_size_atr)
         return(false);

      highest_high = MathMax(highest_high, high);
      lowest_low = MathMin(lowest_low, low);

      if(MathAbs(high - level) <= atr * config.level_tolerance_atr ||
         MathAbs(low - level) <= atr * config.level_tolerance_atr ||
         (low <= level && high >= level))
      {
         touches++;
      }
   }

   const double cluster_range = highest_high - lowest_low;
   const bool range_is_compressed = (cluster_range <= atr * config.max_cluster_range_atr);
   const bool range_is_tightening = (last_range <= first_range);
   const bool has_repeated_touches = (touches >= config.lookback_bars - 1);

   return(range_is_compressed && range_is_tightening && has_repeated_touches);
}

#endif
