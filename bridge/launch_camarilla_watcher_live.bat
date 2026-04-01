@echo off
python "%~dp0watch_camarilla_ai.py" ^
  --symbols USDCHF EURUSD GBPUSD AUDUSD EURAUD GBPAUD USDCAD NZDUSD ^
  --timeframe M15 ^
  --ema-period 10 ^
  --output-dir "C:\Users\digit\OneDrive\Documents\Codex-Projects\artifacts\camarilla_watcher" ^
  --loop-seconds 60
