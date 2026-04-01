@echo off
python "%~dp0watch_camarilla_ai.py" ^
  --symbols USDCHF EURUSD GBPUSD AUDUSD NZDUSD USDCAD ^
  --timeframe M15 ^
  --ema-period 10 ^
  --output-dir "C:\Users\digit\OneDrive\Documents\Codex-Projects\artifacts\camarilla_watcher" ^
  --use-ai ^
  --model "llama3.2:latest" ^
  --host "http://127.0.0.1:11434" ^
  --connect-timeout 5 ^
  --read-timeout 15 ^
  --ai-num-predict 24 ^
  --top-n 3 ^
  --loop-seconds 60
