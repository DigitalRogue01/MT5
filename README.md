# MT5

This repo contains local MetaTrader 5 projects and test harnesses, with an emphasis on structured market levels, indicator-driven workflows, and AI-assisted trading experiments.

## Current layout

- `Codex-Test.mq5`
  A test EA that loads the `Previouse Day High and Low` indicator, reads its chart objects, and reports breakout state without placing trades.
- `MACD_Trinity/MACD_Trinity.mq5`
  The current active MACD Trinity EA source.
- `MACD_Trinity/versions/`
  Archived historical versions kept for reference while Git history remains the primary record.

## Direction

The broader project vision is an MT5 trading system that can extract structured market context from MetaTrader 5, package it into deterministic payloads, and hand that context to an external AI decision engine for analysis, bias, and trade guidance.
