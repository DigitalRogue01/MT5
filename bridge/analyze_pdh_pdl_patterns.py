import argparse
from pathlib import Path

import pandas as pd


def compute_report(df: pd.DataFrame) -> tuple[dict, pd.DataFrame]:
    work = df.copy()
    work["time"] = pd.to_datetime(work["time"])
    work["date"] = work["time"].dt.date
    work["hour"] = work["time"].dt.hour

    daily = (
        work.groupby("date")
        .agg(day_high=("high", "max"), day_low=("low", "min"))
        .reset_index()
    )
    daily["next_date"] = daily["date"].shift(-1)
    daily["pdh"] = daily["day_high"]
    daily["pdl"] = daily["day_low"]
    daily["equilibrium"] = (daily["pdh"] + daily["pdl"]) / 2.0

    prior_levels = daily[["next_date", "pdh", "pdl", "equilibrium"]].rename(columns={"next_date": "date"})
    work = work.merge(prior_levels, on="date", how="left")
    work = work.dropna(subset=["pdh", "pdl", "equilibrium"]).reset_index(drop=True)

    work["atr14"] = (
        pd.concat(
            [
                (work["high"] - work["low"]),
                (work["high"] - work["close"].shift(1)).abs(),
                (work["low"] - work["close"].shift(1)).abs(),
            ],
            axis=1,
        )
        .max(axis=1)
        .rolling(14)
        .mean()
    )

    work["prev_close"] = work["close"].shift(1)
    work["buy_break"] = (work["prev_close"] <= work["pdh"]) & (work["close"] > work["pdh"])
    work["sell_break"] = (work["prev_close"] >= work["pdl"]) & (work["close"] < work["pdl"])

    events = []
    for idx, row in work[(work["buy_break"]) | (work["sell_break"])].iterrows():
        same_day = work[(work["date"] == row["date"]) & (work.index > idx)]
        next4 = same_day.head(4)
        next8 = same_day.head(8)
        direction = "buy" if row["buy_break"] else "sell"
        atr = row["atr14"] if pd.notna(row["atr14"]) and row["atr14"] > 0 else (row["high"] - row["low"])
        if atr <= 0:
            atr = 0.0001

        if direction == "buy":
            inside_fail = bool((next4["close"] < row["pdh"]).any())
            reached_equilibrium = bool((same_day["low"] <= row["equilibrium"]).any())
            continuation_1atr = bool((next8["high"] >= row["close"] + atr).any())
            adverse_1atr = bool((next8["low"] <= row["close"] - atr).any())
            excursion_to_eq = row["close"] - row["equilibrium"]
        else:
            inside_fail = bool((next4["close"] > row["pdl"]).any())
            reached_equilibrium = bool((same_day["high"] >= row["equilibrium"]).any())
            continuation_1atr = bool((next8["low"] <= row["close"] - atr).any())
            adverse_1atr = bool((next8["high"] >= row["close"] + atr).any())
            excursion_to_eq = row["equilibrium"] - row["close"]

        events.append(
            {
                "time": row["time"],
                "date": row["date"],
                "hour": int(row["hour"]),
                "direction": direction,
                "close": float(row["close"]),
                "pdh": float(row["pdh"]),
                "pdl": float(row["pdl"]),
                "equilibrium": float(row["equilibrium"]),
                "atr14": float(atr),
                "distance_to_equilibrium": float(excursion_to_eq),
                "inside_fail_4": inside_fail,
                "reached_equilibrium_same_day": reached_equilibrium,
                "continuation_1atr_8": continuation_1atr,
                "adverse_1atr_8": adverse_1atr,
            }
        )

    events_df = pd.DataFrame(events)
    if events_df.empty:
        return {}, events_df

    def direction_summary(direction: str) -> dict:
        subset = events_df[events_df["direction"] == direction]
        return {
            "count": int(len(subset)),
            "inside_fail_4_rate": round(float(subset["inside_fail_4"].mean()), 3),
            "reach_equilibrium_same_day_rate": round(float(subset["reached_equilibrium_same_day"].mean()), 3),
            "continuation_1atr_8_rate": round(float(subset["continuation_1atr_8"].mean()), 3),
            "adverse_1atr_8_rate": round(float(subset["adverse_1atr_8"].mean()), 3),
            "avg_distance_to_equilibrium": round(float(subset["distance_to_equilibrium"].mean()), 6),
            "top_hours": {str(int(k)): int(v) for k, v in subset["hour"].value_counts().head(6).items()},
        }

    report = {
        "buy_breakouts": direction_summary("buy"),
        "sell_breakouts": direction_summary("sell"),
        "total_events": int(len(events_df)),
        "date_range": {
            "start": str(events_df["time"].min()),
            "end": str(events_df["time"].max()),
        },
    }
    return report, events_df


def write_report(report: dict, events_df: pd.DataFrame, output: Path) -> None:
    lines = []
    lines.append("PDH/PDL Breakout Report")
    lines.append("")
    lines.append(f"Total events: {report['total_events']}")
    lines.append(f"Date range: {report['date_range']['start']} to {report['date_range']['end']}")
    lines.append("")

    for label, key in [("Buy breakouts above PDH", "buy_breakouts"), ("Sell breakouts below PDL", "sell_breakouts")]:
        stats = report[key]
        lines.append(label)
        lines.append(f"- Count: {stats['count']}")
        lines.append(f"- Failed back inside range within 4 bars: {stats['inside_fail_4_rate']:.1%}")
        lines.append(f"- Reached equilibrium later that day: {stats['reach_equilibrium_same_day_rate']:.1%}")
        lines.append(f"- Continued 1 ATR in breakout direction within 8 bars: {stats['continuation_1atr_8_rate']:.1%}")
        lines.append(f"- Moved 1 ATR against entry within 8 bars: {stats['adverse_1atr_8_rate']:.1%}")
        lines.append(f"- Avg distance from breakout close to equilibrium: {stats['avg_distance_to_equilibrium']:.6f}")
        lines.append(f"- Top hours: {stats['top_hours']}")
        lines.append("")

    lines.append("Sample events")
    sample = events_df.head(12).copy()
    for _, row in sample.iterrows():
        lines.append(
            f"- {row['time']}: {row['direction']} | inside_fail_4={row['inside_fail_4']} | "
            f"reach_eq_day={row['reached_equilibrium_same_day']} | cont_1atr_8={row['continuation_1atr_8']}"
        )

    output.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze PDH/PDL breakout behavior from exported MT5 bars.")
    parser.add_argument("csv_path")
    parser.add_argument("--output", required=True)
    parser.add_argument("--events-output")
    args = parser.parse_args()

    df = pd.read_csv(args.csv_path)
    required = {"time", "open", "high", "low", "close"}
    missing = required.difference(df.columns)
    if missing:
        raise ValueError(f"CSV is missing required columns: {sorted(missing)}")

    report, events_df = compute_report(df)
    if not report:
        raise RuntimeError("No PDH/PDL breakout events found in the provided CSV")

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    write_report(report, events_df, output_path)

    if args.events_output:
        Path(args.events_output).parent.mkdir(parents=True, exist_ok=True)
        events_df.to_csv(args.events_output, index=False)

    print(output_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
