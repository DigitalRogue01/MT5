import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze Camarilla H3/H4 and L3/L4 rejection/acceptance patterns from market-state data."
    )
    parser.add_argument(
        "--market-state-csv",
        default=r"C:\Users\digit\OneDrive\Documents\Codex-Projects\artifacts\market_state\USDCHF_M15_20250101_20260101_market_state.csv",
    )
    parser.add_argument(
        "--output-dir",
        default=r"C:\Users\digit\OneDrive\Documents\Codex-Projects\artifacts\camarilla_analysis",
    )
    parser.add_argument("--lookahead-bars", type=int, default=8)
    parser.add_argument("--acceptance-buffer-atr", type=float, default=0.10)
    return parser.parse_args()


def add_forward_labels(df: pd.DataFrame, lookahead_bars: int) -> pd.DataFrame:
    out = df.copy()
    highs = out["high"].to_numpy()
    lows = out["low"].to_numpy()
    closes = out["close"].to_numpy()
    atrs = out["atr14"].to_numpy()

    fwd_mfe_long = np.full(len(out), np.nan)
    fwd_mae_long = np.full(len(out), np.nan)
    fwd_mfe_short = np.full(len(out), np.nan)
    fwd_mae_short = np.full(len(out), np.nan)

    for i in range(len(out)):
        atr = atrs[i]
        if not np.isfinite(atr) or atr <= 0:
            continue

        end = min(len(out), i + 1 + lookahead_bars)
        if end <= i + 1:
            continue

        future_highs = highs[i + 1 : end]
        future_lows = lows[i + 1 : end]
        entry = closes[i]

        fwd_mfe_long[i] = (np.max(future_highs) - entry) / atr
        fwd_mae_long[i] = (entry - np.min(future_lows)) / atr
        fwd_mfe_short[i] = (entry - np.min(future_lows)) / atr
        fwd_mae_short[i] = (np.max(future_highs) - entry) / atr

    out["fwd_mfe_long_atr"] = np.round(fwd_mfe_long, 3)
    out["fwd_mae_long_atr"] = np.round(fwd_mae_long, 3)
    out["fwd_mfe_short_atr"] = np.round(fwd_mfe_short, 3)
    out["fwd_mae_short_atr"] = np.round(fwd_mae_short, 3)
    return out


def build_events(df: pd.DataFrame, acceptance_buffer_atr: float) -> pd.DataFrame:
    out = df.copy()
    out["time"] = pd.to_datetime(out["time"])

    atr = out["atr14"]
    out["h3_reject_short"] = out["touched_cam_h3"] & out["bearish"] & (out["close"] < out["cam_h3"])
    out["h4_sweep_reclaim_short"] = (out["high"] > out["cam_h4"]) & out["bearish"] & (out["close"] < out["cam_h4"])
    out["h4_accept_long"] = out["close"] > (out["cam_h4"] + atr * acceptance_buffer_atr)
    out["l3_reject_long"] = out["touched_cam_l3"] & out["bullish"] & (out["close"] > out["cam_l3"])
    out["l4_sweep_reclaim_long"] = (out["low"] < out["cam_l4"]) & out["bullish"] & (out["close"] > out["cam_l4"])
    out["l4_accept_short"] = out["close"] < (out["cam_l4"] - atr * acceptance_buffer_atr)

    event_specs = [
        ("H3 Rejection Short", out["h3_reject_short"], "short"),
        ("H4 Sweep Reclaim Short", out["h4_sweep_reclaim_short"], "short"),
        ("H4 Acceptance Long", out["h4_accept_long"], "long"),
        ("L3 Rejection Long", out["l3_reject_long"], "long"),
        ("L4 Sweep Reclaim Long", out["l4_sweep_reclaim_long"], "long"),
        ("L4 Acceptance Short", out["l4_accept_short"], "short"),
    ]

    frames = []
    for label, mask, side in event_specs:
        subset = out.loc[mask].copy()
        if subset.empty:
            continue

        if side == "long":
            subset["event_mfe_atr"] = subset["fwd_mfe_long_atr"]
            subset["event_mae_atr"] = subset["fwd_mae_long_atr"]
        else:
            subset["event_mfe_atr"] = subset["fwd_mfe_short_atr"]
            subset["event_mae_atr"] = subset["fwd_mae_short_atr"]

        subset["event_label"] = label
        subset["event_side"] = side
        frames.append(
            subset[
                [
                    "time",
                    "hour",
                    "dow",
                    "server_session_bucket",
                    "pd_zone",
                    "cam_zone",
                    "event_label",
                    "event_side",
                    "close",
                    "cam_l3",
                    "cam_l4",
                    "cam_h3",
                    "cam_h4",
                    "cam_h5",
                    "vwap",
                    "ema20",
                    "atr14",
                    "body_to_range",
                    "adx14",
                    "dist_cam_l3_atr",
                    "dist_cam_l4_atr",
                    "dist_cam_h3_atr",
                    "dist_cam_h4_atr",
                    "event_mfe_atr",
                    "event_mae_atr",
                ]
            ]
        )

    if not frames:
        return pd.DataFrame()

    events = pd.concat(frames, ignore_index=True)
    events["good_0p5"] = (events["event_mfe_atr"] >= 0.5) & (events["event_mae_atr"] <= 0.5)
    events["strong_1p0"] = (events["event_mfe_atr"] >= 1.0) & (events["event_mae_atr"] <= 0.5)
    return events


def summarize_events(events: pd.DataFrame) -> dict:
    summary = {"total_events": int(len(events)), "event_types": {}}
    for label, subset in events.groupby("event_label"):
        summary["event_types"][label] = {
            "count": int(len(subset)),
            "side": subset["event_side"].iloc[0],
            "good_0p5_rate": round(float(subset["good_0p5"].mean()), 3),
            "strong_1p0_rate": round(float(subset["strong_1p0"].mean()), 3),
            "avg_mfe_atr": round(float(subset["event_mfe_atr"].mean()), 3),
            "avg_mae_atr": round(float(subset["event_mae_atr"].mean()), 3),
            "top_hours": {str(int(k)): int(v) for k, v in subset["hour"].value_counts().head(6).items()},
            "top_sessions": {str(k): int(v) for k, v in subset["server_session_bucket"].value_counts().items()},
            "top_cam_zones": {str(k): int(v) for k, v in subset["cam_zone"].value_counts().items()},
            "top_pd_zones": {str(k): int(v) for k, v in subset["pd_zone"].value_counts().items()},
        }
    return summary


def render_markdown(summary: dict) -> str:
    lines = [
        "# Camarilla Pattern Report",
        "",
        f"- total events: `{summary['total_events']}`",
        "",
        "## Event Types",
        "",
    ]

    ranked = sorted(
        summary["event_types"].items(),
        key=lambda kv: (kv[1]["good_0p5_rate"], kv[1]["count"]),
        reverse=True,
    )

    for label, stats in ranked:
        lines.append(f"### {label}")
        lines.append(f"- count: `{stats['count']}`")
        lines.append(f"- side: `{stats['side']}`")
        lines.append(f"- good 0.5 ATR / controlled heat: `{stats['good_0p5_rate']}`")
        lines.append(f"- strong 1.0 ATR / controlled heat: `{stats['strong_1p0_rate']}`")
        lines.append(f"- avg MFE ATR: `{stats['avg_mfe_atr']}`")
        lines.append(f"- avg MAE ATR: `{stats['avg_mae_atr']}`")
        lines.append(f"- top hours: `{stats['top_hours']}`")
        lines.append(f"- top sessions: `{stats['top_sessions']}`")
        lines.append(f"- top Camarilla zones: `{stats['top_cam_zones']}`")
        lines.append(f"- top previous-day zones: `{stats['top_pd_zones']}`")
        lines.append("")

    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    input_path = Path(args.market_state_csv)
    if not input_path.exists():
        raise FileNotFoundError(f"Market state CSV not found: {input_path}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    df = pd.read_csv(input_path, parse_dates=["time"])
    df = add_forward_labels(df, args.lookahead_bars)
    events = build_events(df, args.acceptance_buffer_atr)
    if events.empty:
        raise RuntimeError("No Camarilla events found in the provided market-state file.")

    summary = summarize_events(events)
    base_name = input_path.stem.replace("_market_state", "")
    events_path = output_dir / f"{base_name}_camarilla_events.csv"
    summary_path = output_dir / f"{base_name}_camarilla_summary.json"
    report_path = output_dir / f"{base_name}_camarilla_report.md"

    events.to_csv(events_path, index=False)
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    report_path.write_text(render_markdown(summary), encoding="utf-8")

    print(report_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
