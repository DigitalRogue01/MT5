import argparse
import json
from pathlib import Path

import pandas as pd
import requests


def build_summary(df: pd.DataFrame, tail_rows: int) -> dict:
    work = df.copy()
    work["time"] = pd.to_datetime(work["time"])
    work["range"] = work["high"] - work["low"]
    work["body"] = (work["close"] - work["open"]).abs()
    work["direction"] = (work["close"] > work["open"]).map({True: "up", False: "down"})
    work["close_change"] = work["close"].diff()
    work["pct_change"] = work["close"].pct_change() * 100.0
    work["upper_wick"] = work["high"] - work[["open", "close"]].max(axis=1)
    work["lower_wick"] = work[["open", "close"]].min(axis=1) - work["low"]

    rolling_high = work["high"].rolling(20).max().shift(1)
    rolling_low = work["low"].rolling(20).min().shift(1)
    work["broke_20_high"] = work["close"] > rolling_high
    work["broke_20_low"] = work["close"] < rolling_low

    tail = work.tail(tail_rows).copy()
    tail["time"] = tail["time"].dt.strftime("%Y-%m-%d %H:%M:%S")
    tail = tail.where(pd.notnull(tail), None)
    tail = tail[
        [
            "time",
            "open",
            "high",
            "low",
            "close",
            "range",
            "body",
            "direction",
            "close_change",
            "broke_20_high",
            "broke_20_low",
        ]
    ]

    summary = {
        "rows": int(len(work)),
        "start": str(work["time"].iloc[0]),
        "end": str(work["time"].iloc[-1]),
        "open_mean": round(float(work["open"].mean()), 6),
        "close_mean": round(float(work["close"].mean()), 6),
        "avg_range": round(float(work["range"].mean()), 6),
        "median_range": round(float(work["range"].median()), 6),
        "avg_body": round(float(work["body"].mean()), 6),
        "avg_upper_wick": round(float(work["upper_wick"].mean()), 6),
        "avg_lower_wick": round(float(work["lower_wick"].mean()), 6),
        "up_bars": int((work["close"] > work["open"]).sum()),
        "down_bars": int((work["close"] < work["open"]).sum()),
        "break_20_high_count": int(work["broke_20_high"].fillna(False).sum()),
        "break_20_low_count": int(work["broke_20_low"].fillna(False).sum()),
        "recent_bars": tail.to_dict(orient="records"),
    }
    return summary


def build_prompt(symbol: str, timeframe: str, summary: dict) -> str:
    return (
        "Review this MT5 bar summary for recurring trading patterns.\n"
        f"Instrument: {symbol}\n"
        f"Timeframe: {timeframe}\n"
        "Focus on practical hypotheses, not generic TA.\n"
        "Prioritize:\n"
        "- false breakouts\n"
        "- breakout continuation versus failure\n"
        "- extreme-to-equilibrium tendencies\n"
        "- anything useful for PDH/PDL M15 logic\n\n"
        "Return exactly:\n"
        "Summary: 2-3 sentences.\n"
        "Hypotheses:\n"
        "- up to 5 bullets, each with a short confirmation idea.\n\n"
        f"Data summary:\n{json.dumps(summary, indent=2)}"
    )


def call_ollama(model: str, prompt: str, host: str) -> str:
    response = requests.post(
        f"{host.rstrip('/')}/api/generate",
        json={
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {
                "temperature": 0.2,
                "num_predict": 140,
            },
        },
        timeout=300,
    )
    response.raise_for_status()
    payload = response.json()
    return payload.get("response", "").strip()


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze exported MT5 bars with a local Ollama model.")
    parser.add_argument("csv_path", help="Path to the exported MT5 CSV file")
    parser.add_argument("--symbol", default="EURAUD")
    parser.add_argument("--timeframe", default="M15")
    parser.add_argument("--model", default="llama3.2:latest")
    parser.add_argument("--host", default="http://127.0.0.1:11434")
    parser.add_argument("--tail-rows", type=int, default=60)
    parser.add_argument("--output", help="Optional path to save the analysis text")
    args = parser.parse_args()

    csv_path = Path(args.csv_path)
    if not csv_path.exists():
        raise FileNotFoundError(f"CSV not found: {csv_path}")

    df = pd.read_csv(csv_path)
    required = {"time", "open", "high", "low", "close"}
    missing = required.difference(df.columns)
    if missing:
        raise ValueError(f"CSV is missing required columns: {sorted(missing)}")

    summary = build_summary(df, args.tail_rows)
    prompt = build_prompt(args.symbol, args.timeframe, summary)
    analysis = call_ollama(args.model, prompt, args.host)

    if args.output:
        Path(args.output).write_text(analysis, encoding="utf-8")

    print(analysis)


if __name__ == "__main__":
    main()
