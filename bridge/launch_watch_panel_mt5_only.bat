@echo off
setlocal

set "PYTHON_EXE=python"
set "SCRIPT_DIR=%~dp0"
set "WATCHER=%SCRIPT_DIR%watch_camarilla_ai.py"
set "POPUP=%SCRIPT_DIR%ai_watch_panel_popup.py"
set "OUTDIR=C:\Users\digit\OneDrive\Documents\Codex-Projects\artifacts\camarilla_watcher"

REM Stop any older watcher loops so only one process owns the panel file.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'python.exe' -and $_.CommandLine -match 'watch_camarilla_ai.py' }; if($p){ $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } }"

REM Start the live watcher in technical-only mode (no AI commentary).
start "MT5 Camarilla Watcher" /min %PYTHON_EXE% "%WATCHER%" ^
  --symbols USDCHF EURUSD GBPUSD AUDUSD NZDUSD USDCAD EURAUD GBPAUD ^
  --timeframe M15 ^
  --ema-period 10 ^
  --output-dir "%OUTDIR%" ^
  --top-n 5 ^
  --loop-seconds 60

REM Start the popup panel on top.
start "Watch Panel" %PYTHON_EXE% "%POPUP%" --always-on-top

endlocal
