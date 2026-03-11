# MT5

This repo contains MetaTrader 5 projects and test harnesses organized in an MT5-style layout.

## Layout

- `Experts/Codex-Test/Codex-Test.mq5`
  Test EA that loads the `Previouse Day High and Low` indicator, reads its chart objects, and reports breakout state without placing live trades.
- `Experts/MACD_Trinity/MACD_Trinity.mq5`
  Current active MACD Trinity EA source.
- `Experts/MACD_Trinity/versions/`
  Archived EA snapshots kept for reference.
- `Indicators/Previouse Day High and Low.mq5`
  Tracked copy of the previous-day levels indicator used by `Codex-Test`.
- `Scripts/`
  Reserved for future MT5 helper scripts.

## Notes

The Git repo itself lives inside the local `MQL5\\Experts` tree, so the repo's `Indicators` folder is the tracked project copy, not the global terminal indicator folder. For local MT5 use, the indicator should also exist under the terminal's real `MQL5\\Indicators` path.
