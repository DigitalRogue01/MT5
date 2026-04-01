import argparse
import json
import os
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import MetaTrader5 as mt5
import numpy as np
import pandas as pd
import requests


TIMEFRAME_MAP = {
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
}


@dataclass
class WatchRow:
    symbol: str
    timeframe: str
    bar_time: str
    session: str
    location: str
    h1_bias: str
    h4_bias: str
    trend_alignment: str
    spread_points: float
    close: float
    ema20: float
    vwap: float
    atr14: float
    cam_h3: float
    cam_h4: float
    cam_h5: float
    cam_l3: float
    cam_l4: float
    cam_l5: float
    best_module: str
    best_state: str
    best_reason: str
    best_score: int
    position_state: str
    position_volume: float
    module_states: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Watch multiple MT5 charts for Camarilla near/valid setups and ask Ollama for a ranked readout.")
    parser.add_argument("--symbols", nargs="+", default=["USDCHF", "EURUSD", "GBPUSD", "AUDUSD", "EURAUD", "GBPAUD"])
    parser.add_argument("--timeframe", default="M15", choices=sorted(TIMEFRAME_MAP.keys()))
    parser.add_argument("--terminal", default=r"C:\Program Files\MetaTrader 5 FOREX.com US\terminal64.exe")
    parser.add_argument("--output-dir", default="artifacts/camarilla_watcher")
    parser.add_argument("--max-spread-points", type=float, default=100.0)
    parser.add_argument("--ema-period", type=int, default=10)
    parser.add_argument("--min-score", type=int, default=6)
    parser.add_argument("--min-body-to-range", type=float, default=0.25)
    parser.add_argument("--min-sweep-atr-frac", type=float, default=0.05)
    parser.add_argument("--near-atr-distance", type=float, default=0.25)
    parser.add_argument("--use-ai", action="store_true")
    parser.add_argument("--host", default="http://127.0.0.1:11434")
    parser.add_argument("--model", default="llama3.2:latest")
    parser.add_argument("--top-n", type=int, default=3)
    parser.add_argument("--connect-timeout", type=int, default=8)
    parser.add_argument("--read-timeout", type=int, default=12)
    parser.add_argument("--ai-num-predict", type=int, default=24)
    parser.add_argument("--loop-seconds", type=int, default=0)
    return parser.parse_args()


def initialize_mt5(terminal: str) -> None:
    kwargs: dict[str, Any] = {}
    if terminal:
        kwargs["path"] = terminal
    if not mt5.initialize(**kwargs):
        raise RuntimeError(f"MetaTrader5 initialize failed: {mt5.last_error()}")


def session_bucket(hour: int) -> str:
    if 0 <= hour <= 6:
        return "AsiaLike"
    if 7 <= hour <= 12:
        return "LondonLike"
    if 13 <= hour <= 16:
        return "NYLike"
    if 17 <= hour <= 20:
        return "USLate"
    return "OffHours"


def allowed_session(hour: int) -> bool:
    return 7 <= hour <= 16


def fetch_rates(symbol: str, timeframe: str, bars: int) -> pd.DataFrame:
    rates = mt5.copy_rates_from_pos(symbol, TIMEFRAME_MAP[timeframe], 0, bars)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No rates returned for {symbol} {timeframe}: {mt5.last_error()}")
    frame = pd.DataFrame(rates)
    frame["time"] = pd.to_datetime(frame["time"], unit="s")
    return frame.sort_values("time").reset_index(drop=True)


def fetch_daily(symbol: str, bars: int = 10) -> pd.DataFrame:
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_D1, 0, bars)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No D1 rates returned for {symbol}: {mt5.last_error()}")
    frame = pd.DataFrame(rates)
    frame["time"] = pd.to_datetime(frame["time"], unit="s")
    return frame.sort_values("time").reset_index(drop=True)


def ema_bias(symbol: str, timeframe: int, fast_period: int = 10, slow_period: int = 20, bars: int = 80) -> str:
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)
    if rates is None or len(rates) < slow_period + 5:
        return "Unknown"
    frame = pd.DataFrame(rates).sort_values("time").reset_index(drop=True)
    close = frame["close"]
    fast = close.ewm(span=fast_period, adjust=False).mean().iloc[-2]
    slow = close.ewm(span=slow_period, adjust=False).mean().iloc[-2]
    if pd.isna(fast) or pd.isna(slow):
        return "Unknown"
    if fast > slow:
        return "Bullish"
    if fast < slow:
        return "Bearish"
    return "Neutral"


def current_position_state(symbol: str) -> tuple[str, float]:
    positions = mt5.positions_get(symbol=symbol)
    if positions is None or len(positions) == 0:
        return "FLAT", 0.0

    net_volume = 0.0
    for pos in positions:
        if pos.type == mt5.POSITION_TYPE_BUY:
            net_volume += float(pos.volume)
        elif pos.type == mt5.POSITION_TYPE_SELL:
            net_volume -= float(pos.volume)

    if net_volume > 0:
        return "LONG", abs(net_volume)
    if net_volume < 0:
        return "SHORT", abs(net_volume)
    return "HEDGED", sum(abs(float(pos.volume)) for pos in positions)


def wilder_atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    prev_close = df["close"].shift(1)
    tr = pd.concat(
        [
            df["high"] - df["low"],
            (df["high"] - prev_close).abs(),
            (df["low"] - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    return tr.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()


def add_vwap(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    typical = (out["high"] + out["low"] + out["close"]) / 3.0
    volume = out["real_volume"].where(out["real_volume"] > 0, out["tick_volume"]).clip(lower=1)
    session_key = out["time"].dt.normalize()
    out["vwap"] = (typical * volume).groupby(session_key).cumsum() / volume.groupby(session_key).cumsum()
    return out


def camarilla_levels(prev_high: float, prev_low: float, prev_close: float, multiplier: float = 1.1) -> dict[str, float]:
    pd_range = prev_high - prev_low
    factor = pd_range * multiplier
    h1 = prev_close + factor / 12.0
    h2 = prev_close + factor / 6.0
    h3 = prev_close + factor / 4.0
    h4 = prev_close + factor / 2.0
    l1 = prev_close - factor / 12.0
    l2 = prev_close - factor / 6.0
    l3 = prev_close - factor / 4.0
    l4 = prev_close - factor / 2.0
    h5 = (prev_high / prev_low) * prev_close if prev_low > 0 else np.nan
    l5 = (2.0 * prev_close) - h5 if pd.notna(h5) else np.nan
    return {"h1": h1, "h2": h2, "h3": h3, "h4": h4, "h5": h5, "l1": l1, "l2": l2, "l3": l3, "l4": l4, "l5": l5}


def base_checks(bar1: pd.Series) -> tuple[bool, str]:
    if bar1["spread_points"] > args.max_spread_points:
        return False, "SKIP_SPREAD_TOO_WIDE"
    return True, ""


def bullish_score(bar1: pd.Series, bar2: pd.Series, ema20: float, vwap: float, min_body_to_range: float) -> int:
    body_to_range = 0.0 if bar1["range"] <= 0 else bar1["body"] / bar1["range"]
    lower_wick = min(bar1["open"], bar1["close"]) - bar1["low"]
    score = 0
    if bar1["close"] > bar1["open"]:
        score += 1
    if body_to_range >= min_body_to_range:
        score += 1
    if lower_wick > bar1["body"]:
        score += 1
    if bar1["close"] > ema20:
        score += 1
    if bar1["close"] > vwap:
        score += 1
    if bar1["close"] > bar2["close"]:
        score += 1
    return score


def bearish_score(bar1: pd.Series, bar2: pd.Series, ema20: float, vwap: float, min_body_to_range: float) -> int:
    body_to_range = 0.0 if bar1["range"] <= 0 else bar1["body"] / bar1["range"]
    upper_wick = bar1["high"] - max(bar1["open"], bar1["close"])
    score = 0
    if bar1["close"] < bar1["open"]:
        score += 1
    if body_to_range >= min_body_to_range:
        score += 1
    if upper_wick > bar1["body"]:
        score += 1
    if bar1["close"] < ema20:
        score += 1
    if bar1["close"] < vwap:
        score += 1
    if bar1["close"] < bar2["close"]:
        score += 1
    return score


def module_result(module: str, state: str, reason: str, score: int) -> dict[str, Any]:
    return {"module": module, "state": state, "reason": reason, "score": int(score)}


def compress_module_states(module_results: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for item in module_results:
        parts.append(f"{item['module']}={item['state']}:{item['reason']}")
    return " | ".join(parts)


def module_distance_atr(module: str, close_price: float, levels: dict[str, float], atr: float) -> float:
    if atr <= 0:
        return 9999.0
    if module in ("H4SweepReclaimShort", "H4AcceptanceLong"):
        target = levels["h4"]
        return abs(close_price - target) / atr
    if module in ("L4SweepReclaimLong", "L4AcceptanceShort"):
        target = levels["l4"]
        return abs(close_price - target) / atr
    if module == "H3RejectionShort":
        return abs(close_price - levels["h3"]) / atr
    if module == "L3RejectionLong":
        return abs(close_price - levels["l3"]) / atr
    if module == "H3H4RejectionShort":
        lo = min(levels["h3"], levels["h4"])
        hi = max(levels["h3"], levels["h4"])
        if lo <= close_price <= hi:
            return 0.0
        return min(abs(close_price - lo), abs(close_price - hi)) / atr
    if module == "L3L4RejectionLong":
        lo = min(levels["l4"], levels["l3"])
        hi = max(levels["l4"], levels["l3"])
        if lo <= close_price <= hi:
            return 0.0
        return min(abs(close_price - lo), abs(close_price - hi)) / atr
    if module == "H5ExhaustionShort":
        return abs(close_price - levels["h5"]) / atr if pd.notna(levels["h5"]) else 9999.0
    if module == "L5ExhaustionLong":
        return abs(close_price - levels["l5"]) / atr if pd.notna(levels["l5"]) else 9999.0
    return 9999.0


def classify_price_location(close_price: float, levels: dict[str, float]) -> str:
    h1 = levels["h1"]
    h3 = levels["h3"]
    h4 = levels["h4"]
    h5 = levels["h5"]
    l1 = levels["l1"]
    l3 = levels["l3"]
    l4 = levels["l4"]
    l5 = levels["l5"]

    if pd.notna(h5) and close_price >= h5:
        return "Above H5"
    if close_price >= h4:
        return "H4-H5"
    if close_price >= h3:
        return "H3-H4"
    if close_price > h1:
        return "H1-H3"
    if close_price >= l1:
        return "Inside H1-L1"
    if close_price >= l3:
        return "L3-L1"
    if close_price >= l4:
        return "L4-L3"
    if pd.notna(l5) and close_price >= l5:
        return "L5-L4"
    return "Below L5"


def relevant_modules_for_location(location: str) -> list[str]:
    mapping = {
        "Above H5": ["H5ExhaustionShort", "H4SweepReclaimShort", "H4AcceptanceLong"],
        "H4-H5": ["H4SweepReclaimShort", "H4AcceptanceLong", "H5ExhaustionShort", "H3H4RejectionShort"],
        "H3-H4": ["H3H4RejectionShort", "H3RejectionShort", "H4SweepReclaimShort", "H4AcceptanceLong"],
        "H1-H3": ["H3RejectionShort", "H3H4RejectionShort"],
        "Inside H1-L1": [],
        "L3-L1": ["L3RejectionLong", "L3L4RejectionLong"],
        "L4-L3": ["L3L4RejectionLong", "L3RejectionLong", "L4SweepReclaimLong", "L4AcceptanceShort"],
        "L5-L4": ["L4SweepReclaimLong", "L4AcceptanceShort", "L5ExhaustionLong", "L3L4RejectionLong"],
        "Below L5": ["L5ExhaustionLong", "L4SweepReclaimLong", "L4AcceptanceShort"],
    }
    return mapping.get(location, [])


def choose_best_module(module_results: list[dict[str, Any]], location: str) -> dict[str, Any]:
    state_rank = {"VALID": 3, "NEAR": 2, "WAIT": 1}

    if location == "Inside H1-L1":
        return module_result("InsideRange", "WAIT", "SKIP_INSIDE_RANGE", 0)

    relevant = set(relevant_modules_for_location(location))
    candidates = [item for item in module_results if item["module"] in relevant]
    if not candidates:
        candidates = module_results

    candidates = sorted(
        candidates,
        key=lambda r: (state_rank[r["state"]], r["score"], -r["distance_atr"]),
        reverse=True,
    )
    return candidates[0]


def module_direction(module: str) -> str:
    if module in ("H4SweepReclaimShort", "L4AcceptanceShort", "H3RejectionShort", "H3H4RejectionShort", "H5ExhaustionShort"):
        return "Short"
    if module in ("L4SweepReclaimLong", "H4AcceptanceLong", "L3RejectionLong", "L3L4RejectionLong", "L5ExhaustionLong"):
        return "Long"
    return "Neutral"


def alignment_label(direction: str, h4_bias: str) -> str:
    if direction == "Neutral" or h4_bias == "Unknown" or h4_bias == "Neutral":
        return "Unknown"
    if direction == "Long":
        return "Aligned" if h4_bias == "Bullish" else "Countertrend"
    if direction == "Short":
        return "Aligned" if h4_bias == "Bearish" else "Countertrend"
    return "Unknown"


def pretty_module_name(name: str) -> str:
    mapping = {
        "InsideRange": "Inside range",
        "H4SweepReclaimShort": "H4 short",
        "L4SweepReclaimLong": "L4 long",
        "H4AcceptanceLong": "H4 accept long",
        "L4AcceptanceShort": "L4 accept short",
        "H3RejectionShort": "H3 short",
        "L3RejectionLong": "L3 long",
        "H3H4RejectionShort": "H3-H4 short",
        "L3L4RejectionLong": "L3-L4 long",
        "H5ExhaustionShort": "H5 short",
        "L5ExhaustionLong": "L5 long",
    }
    return mapping.get(name, name)


def pretty_reason(reason: str) -> str:
    mapping = {
        "SKIP_INSIDE_RANGE": "inside H1-L1 middle range",
        "SKIP_NOT_BELOW_EMA20": "blocked by EMA",
        "SKIP_NOT_ABOVE_EMA20": "blocked by EMA",
        "SKIP_NO_H4_SWEEP": "no H4 sweep",
        "SKIP_NO_L4_SWEEP": "no L4 sweep",
        "SKIP_NO_H3_TEST": "no H3 test",
        "SKIP_NO_L3_TEST": "no L3 test",
        "SKIP_NO_H3_H4_TEST": "no H3-H4 test",
        "SKIP_NO_L3_L4_TEST": "no L3-L4 test",
        "SKIP_NO_H5_TEST": "no H5 test",
        "SKIP_NO_L5_TEST": "no L5 test",
        "NEAR_H3_TEST_NO_REJECTION": "tested H3, no rejection yet",
        "NEAR_L3_TEST_NO_REJECTION": "tested L3, no rejection yet",
        "NEAR_ZONE_TEST_NO_REJECTION": "zone test, no rejection yet",
        "NEAR_BELOW_EMA20_APPROACHING_H4": "approaching H4 under EMA",
        "NEAR_ABOVE_EMA20_APPROACHING_L4": "approaching L4 above EMA",
        "NEAR_CLOSE_TO_H4_BUT_ABOVE_EMA20": "close to H4, still above EMA",
        "NEAR_CLOSE_TO_L4_BUT_BELOW_EMA20": "close to L4, still below EMA",
        "NEAR_SWEEPED_H4_NO_RECLAIM": "swept H4, no reclaim yet",
        "NEAR_SWEEPED_L4_NO_RECLAIM": "swept L4, no reclaim yet",
        "NEAR_H4_RECLAIM_WEAK_SCORE": "H4 reclaim, weak quality",
        "NEAR_L4_RECLAIM_WEAK_SCORE": "L4 reclaim, weak quality",
        "SKIP_SPREAD_TOO_WIDE": "spread too wide",
        "SKIP_H1_BEARISH_BIAS": "blocked by H1 bearish bias",
        "SKIP_H1_BULLISH_BIAS": "blocked by H1 bullish bias",
    }
    return mapping.get(reason, reason.replace("_", " ").lower())


def pretty_state_line(row: pd.Series) -> str:
    module = pretty_module_name(str(row["best_module"]))
    state = str(row["best_state"])
    reason = pretty_reason(str(row["best_reason"]))
    location = str(row["location"])
    alignment = str(row.get("trend_alignment", "Unknown"))
    position_state = str(row.get("position_state", "FLAT"))
    position_suffix = ""
    if position_state != "FLAT":
        volume = float(row.get("position_volume", 0.0))
        position_suffix = f" | in {position_state.lower()} {volume:.2f}"
    align_suffix = "" if alignment == "Unknown" else f" | {alignment.lower()} H4"
    if state == "VALID":
        return f"{row['symbol']} | {location} | {module} ready | score {int(row['best_score'])}{align_suffix}{position_suffix}"
    if state == "NEAR":
        return f"{row['symbol']} | {location} | {module} near | {reason}{align_suffix}{position_suffix}"
    return f"{row['symbol']} | {location} | {module} waiting | {reason}{align_suffix}{position_suffix}"


def eval_h4_sweep_reclaim_short(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, atr: float,
                                min_body_to_range: float, min_sweep_atr_frac: float, min_score: int, near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("H4SweepReclaimShort", "WAIT", reason, 0)
    h4 = levels["h4"]

    if bar1["close"] >= ema20:
        if atr > 0 and abs(bar1["close"] - h4) / atr <= near_atr_distance:
            return module_result("H4SweepReclaimShort", "NEAR", "NEAR_CLOSE_TO_H4_BUT_ABOVE_EMA20", 0)
        return module_result("H4SweepReclaimShort", "WAIT", "SKIP_NOT_BELOW_EMA20", 0)

    if bar1["high"] < h4:
        if atr > 0 and (h4 - bar1["high"]) / atr <= near_atr_distance:
            return module_result("H4SweepReclaimShort", "NEAR", "NEAR_BELOW_EMA20_APPROACHING_H4", 0)
        return module_result("H4SweepReclaimShort", "WAIT", "SKIP_NO_H4_SWEEP", 0)

    if bar1["close"] >= h4:
        return module_result("H4SweepReclaimShort", "NEAR", "NEAR_SWEEPED_H4_NO_RECLAIM", 0)

    excursion = bar1["high"] - h4
    if excursion < atr * min_sweep_atr_frac:
        return module_result("H4SweepReclaimShort", "WAIT", "SKIP_SWEEP_TOO_SHALLOW", 0)

    score = 4 + bearish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("H4SweepReclaimShort", "VALID", "CAM_H4_SWEEP_RECLAIM_SHORT_READY", score)
    return module_result("H4SweepReclaimShort", "NEAR", "NEAR_H4_RECLAIM_WEAK_SCORE", score)


def eval_l4_sweep_reclaim_long(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, atr: float,
                               min_body_to_range: float, min_sweep_atr_frac: float, min_score: int, near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("L4SweepReclaimLong", "WAIT", reason, 0)
    l4 = levels["l4"]

    if bar1["close"] <= ema20:
        if atr > 0 and abs(bar1["close"] - l4) / atr <= near_atr_distance:
            return module_result("L4SweepReclaimLong", "NEAR", "NEAR_CLOSE_TO_L4_BUT_BELOW_EMA20", 0)
        return module_result("L4SweepReclaimLong", "WAIT", "SKIP_NOT_ABOVE_EMA20", 0)

    if bar1["low"] > l4:
        if atr > 0 and (bar1["low"] - l4) / atr <= near_atr_distance:
            return module_result("L4SweepReclaimLong", "NEAR", "NEAR_ABOVE_EMA20_APPROACHING_L4", 0)
        return module_result("L4SweepReclaimLong", "WAIT", "SKIP_NO_L4_SWEEP", 0)

    if bar1["close"] <= l4:
        return module_result("L4SweepReclaimLong", "NEAR", "NEAR_SWEEPED_L4_NO_RECLAIM", 0)

    excursion = l4 - bar1["low"]
    if excursion < atr * min_sweep_atr_frac:
        return module_result("L4SweepReclaimLong", "WAIT", "SKIP_SWEEP_TOO_SHALLOW", 0)

    score = 4 + bullish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("L4SweepReclaimLong", "VALID", "CAM_L4_SWEEP_RECLAIM_LONG_READY", score)
    return module_result("L4SweepReclaimLong", "NEAR", "NEAR_L4_RECLAIM_WEAK_SCORE", score)


def eval_h4_acceptance_long(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, _atr: float,
                            min_body_to_range: float, _min_sweep_atr_frac: float, min_score: int, _near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("H4AcceptanceLong", "WAIT", reason, 0)
    h4 = levels["h4"]
    if bar1["close"] <= h4:
        return module_result("H4AcceptanceLong", "WAIT", "SKIP_NOT_ABOVE_H4", 0)
    if bar1["low"] < h4:
        return module_result("H4AcceptanceLong", "NEAR", "NEAR_ABOVE_H4_NO_ACCEPTANCE", 0)
    score = 4 + bullish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("H4AcceptanceLong", "VALID", "CAM_H4_ACCEPTANCE_LONG_READY", score)
    return module_result("H4AcceptanceLong", "NEAR", "NEAR_H4_ACCEPTANCE_WEAK_SCORE", score)


def eval_l4_acceptance_short(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, _atr: float,
                             min_body_to_range: float, _min_sweep_atr_frac: float, min_score: int, _near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("L4AcceptanceShort", "WAIT", reason, 0)
    l4 = levels["l4"]
    if bar1["close"] >= l4:
        return module_result("L4AcceptanceShort", "WAIT", "SKIP_NOT_BELOW_L4", 0)
    if bar1["high"] > l4:
        return module_result("L4AcceptanceShort", "NEAR", "NEAR_BELOW_L4_NO_ACCEPTANCE", 0)
    score = 4 + bearish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("L4AcceptanceShort", "VALID", "CAM_L4_ACCEPTANCE_SHORT_READY", score)
    return module_result("L4AcceptanceShort", "NEAR", "NEAR_L4_ACCEPTANCE_WEAK_SCORE", score)


def eval_h3_rejection_short(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, _atr: float,
                            min_body_to_range: float, _min_sweep_atr_frac: float, min_score: int, _near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("H3RejectionShort", "WAIT", reason, 0)
    h3 = levels["h3"]
    if bar1["high"] < h3:
        return module_result("H3RejectionShort", "WAIT", "SKIP_NO_H3_TEST", 0)
    if bar1["close"] >= h3:
        return module_result("H3RejectionShort", "NEAR", "NEAR_H3_TEST_NO_REJECTION", 0)
    score = 3 + bearish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("H3RejectionShort", "VALID", "CAM_H3_REJECTION_SHORT_READY", score)
    return module_result("H3RejectionShort", "NEAR", "NEAR_H3_REJECTION_WEAK_SCORE", score)


def eval_l3_rejection_long(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, _atr: float,
                           min_body_to_range: float, _min_sweep_atr_frac: float, min_score: int, _near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("L3RejectionLong", "WAIT", reason, 0)
    l3 = levels["l3"]
    if bar1["low"] > l3:
        return module_result("L3RejectionLong", "WAIT", "SKIP_NO_L3_TEST", 0)
    if bar1["close"] <= l3:
        return module_result("L3RejectionLong", "NEAR", "NEAR_L3_TEST_NO_REJECTION", 0)
    score = 3 + bullish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("L3RejectionLong", "VALID", "CAM_L3_REJECTION_LONG_READY", score)
    return module_result("L3RejectionLong", "NEAR", "NEAR_L3_REJECTION_WEAK_SCORE", score)


def eval_h3_h4_rejection_short(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, _atr: float,
                               min_body_to_range: float, _min_sweep_atr_frac: float, min_score: int, _near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("H3H4RejectionShort", "WAIT", reason, 0)
    h3 = levels["h3"]
    h4 = levels["h4"]
    if bar1["high"] < h3 or bar1["high"] > h4:
        return module_result("H3H4RejectionShort", "WAIT", "SKIP_NO_H3_H4_TEST", 0)
    if bar1["close"] >= h3:
        return module_result("H3H4RejectionShort", "NEAR", "NEAR_ZONE_TEST_NO_REJECTION", 0)
    score = 4 + bearish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("H3H4RejectionShort", "VALID", "CAM_H3_H4_REJECTION_SHORT_READY", score)
    return module_result("H3H4RejectionShort", "NEAR", "NEAR_H3_H4_REJECTION_WEAK_SCORE", score)


def eval_l3_l4_rejection_long(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, _atr: float,
                              min_body_to_range: float, _min_sweep_atr_frac: float, min_score: int, _near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("L3L4RejectionLong", "WAIT", reason, 0)
    l3 = levels["l3"]
    l4 = levels["l4"]
    if bar1["low"] > l3 or bar1["low"] < l4:
        return module_result("L3L4RejectionLong", "WAIT", "SKIP_NO_L3_L4_TEST", 0)
    if bar1["close"] <= l3:
        return module_result("L3L4RejectionLong", "NEAR", "NEAR_ZONE_TEST_NO_REJECTION", 0)
    score = 4 + bullish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("L3L4RejectionLong", "VALID", "CAM_L3_L4_REJECTION_LONG_READY", score)
    return module_result("L3L4RejectionLong", "NEAR", "NEAR_L3_L4_REJECTION_WEAK_SCORE", score)


def eval_h5_exhaustion_short(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, _atr: float,
                             min_body_to_range: float, _min_sweep_atr_frac: float, min_score: int, _near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("H5ExhaustionShort", "WAIT", reason, 0)
    h5 = levels["h5"]
    h4 = levels["h4"]
    if pd.isna(h5) or bar1["high"] < h5:
        return module_result("H5ExhaustionShort", "WAIT", "SKIP_NO_H5_TEST", 0)
    if bar1["close"] >= h4:
        return module_result("H5ExhaustionShort", "NEAR", "NEAR_H5_TEST_NO_REVERSAL", 0)
    score = 5 + bearish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("H5ExhaustionShort", "VALID", "CAM_H5_EXHAUSTION_SHORT_READY", score)
    return module_result("H5ExhaustionShort", "NEAR", "NEAR_H5_EXHAUSTION_WEAK_SCORE", score)


def eval_l5_exhaustion_long(bar1: pd.Series, bar2: pd.Series, levels: dict[str, float], ema20: float, vwap: float, _atr: float,
                            min_body_to_range: float, _min_sweep_atr_frac: float, min_score: int, _near_atr_distance: float) -> dict[str, Any]:
    ok, reason = base_checks(bar1)
    if not ok:
        return module_result("L5ExhaustionLong", "WAIT", reason, 0)
    l5 = levels["l5"]
    l4 = levels["l4"]
    if pd.isna(l5) or bar1["low"] > l5:
        return module_result("L5ExhaustionLong", "WAIT", "SKIP_NO_L5_TEST", 0)
    if bar1["close"] <= l4:
        return module_result("L5ExhaustionLong", "NEAR", "NEAR_L5_TEST_NO_REVERSAL", 0)
    score = 5 + bullish_score(bar1, bar2, ema20, vwap, min_body_to_range)
    if score >= min_score:
        return module_result("L5ExhaustionLong", "VALID", "CAM_L5_EXHAUSTION_LONG_READY", score)
    return module_result("L5ExhaustionLong", "NEAR", "NEAR_L5_EXHAUSTION_WEAK_SCORE", score)


WATCH_EVALUATORS = [
    eval_h4_sweep_reclaim_short,
    eval_l4_sweep_reclaim_long,
    eval_h4_acceptance_long,
    eval_l4_acceptance_short,
    eval_h3_rejection_short,
    eval_l3_rejection_long,
    eval_h3_h4_rejection_short,
    eval_l3_l4_rejection_long,
    eval_h5_exhaustion_short,
    eval_l5_exhaustion_long,
]


def build_watch_row(symbol: str, timeframe: str, max_spread_points: float, min_score: int,
                    min_body_to_range: float, min_sweep_atr_frac: float, near_atr_distance: float) -> WatchRow:
    bars = fetch_rates(symbol, timeframe, 400)
    d1 = fetch_daily(symbol, 5)

    bars = add_vwap(bars)
    bars["ema20"] = bars["close"].ewm(span=args.ema_period, adjust=False).mean()
    bars["atr14"] = wilder_atr(bars, 14)
    bars["range"] = bars["high"] - bars["low"]
    bars["body"] = (bars["close"] - bars["open"]).abs()
    tick = mt5.symbol_info_tick(symbol)
    spread_points = 0.0
    if tick is not None and tick.bid > 0 and tick.ask > 0:
        spread_points = (tick.ask - tick.bid) / mt5.symbol_info(symbol).point

    bar1 = bars.iloc[-2].copy()
    bar2 = bars.iloc[-3].copy()
    bar1["spread_points"] = spread_points
    bar2["spread_points"] = spread_points

    prev_day = d1.iloc[-2]
    levels = camarilla_levels(prev_day["high"], prev_day["low"], prev_day["close"])
    session = session_bucket(int(bar1["time"].hour))
    location = classify_price_location(float(bar1["close"]), levels)
    position_state, position_volume = current_position_state(symbol)
    h1_bias = ema_bias(symbol, mt5.TIMEFRAME_H1)
    h4_bias = ema_bias(symbol, mt5.TIMEFRAME_H4)
    module_results = [
        fn(
            bar1,
            bar2,
            levels,
            float(bar1["ema20"]),
            float(bar1["vwap"]),
            float(bar1["atr14"]),
            min_body_to_range,
            min_sweep_atr_frac,
            min_score,
            near_atr_distance,
        )
        for fn in WATCH_EVALUATORS
    ]
    for item in module_results:
        item["distance_atr"] = module_distance_atr(
            item["module"],
            float(bar1["close"]),
            levels,
            float(bar1["atr14"]),
        )
    module_results = sorted(module_results, key=lambda r: r["module"])
    best = choose_best_module(module_results, location)
    direction = module_direction(best["module"])
    trend_alignment = alignment_label(direction, h4_bias)
    module_states = compress_module_states(module_results)

    return WatchRow(
        symbol=symbol,
        timeframe=timeframe,
        bar_time=bar1["time"].strftime("%Y-%m-%d %H:%M:%S"),
        session=session,
        location=location,
        h1_bias=h1_bias,
        h4_bias=h4_bias,
        trend_alignment=trend_alignment,
        spread_points=round(float(spread_points), 1),
        close=round(float(bar1["close"]), 5),
        ema20=round(float(bar1["ema20"]), 5),
        vwap=round(float(bar1["vwap"]), 5),
        atr14=round(float(bar1["atr14"]), 5),
        cam_h3=round(float(levels["h3"]), 5),
        cam_h4=round(float(levels["h4"]), 5),
        cam_h5=round(float(levels["h5"]), 5) if pd.notna(levels["h5"]) else np.nan,
        cam_l3=round(float(levels["l3"]), 5),
        cam_l4=round(float(levels["l4"]), 5),
        cam_l5=round(float(levels["l5"]), 5) if pd.notna(levels["l5"]) else np.nan,
        best_module=best["module"],
        best_state=best["state"],
        best_reason=best["reason"],
        best_score=int(best["score"]),
        position_state=position_state,
        position_volume=round(float(position_volume), 2),
        module_states=module_states,
    )


def build_prompt(rows: list[dict[str, Any]], generated_at: str) -> str:
    return (
        "You are a trading watchlist assistant.\n"
        "Review these Camarilla setup scans and respond briefly.\n"
        "Do not predict certainty. Only say what deserves attention next.\n\n"
        f"Generated at: {generated_at}\n\n"
        "Return exactly:\n"
        "Summary: one short sentence.\n"
        "Watchlist:\n"
        "- up to 2 bullets in the format SYMBOL: why it matters next.\n"
        "Ignore:\n"
        "- up to 1 bullet.\n\n"
        f"Rows:\n{json.dumps(rows, indent=2)}"
    )


def call_ollama(host: str, model: str, prompt: str, connect_timeout: int, read_timeout: int, ai_num_predict: int) -> str:
    response = requests.post(
        f"{host.rstrip('/')}/api/generate",
        json={
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": 0.2, "num_predict": ai_num_predict},
        },
        timeout=(connect_timeout, read_timeout),
    )
    response.raise_for_status()
    return response.json().get("response", "").strip()


def frame_to_markdown_table(df: pd.DataFrame) -> str:
    headers = list(df.columns)
    rows = [[str(v) for v in row] for row in df.to_numpy().tolist()]
    widths = [len(h) for h in headers]
    for row in rows:
        for idx, value in enumerate(row):
            widths[idx] = max(widths[idx], len(value))

    def fmt_row(values: list[str]) -> str:
        return "| " + " | ".join(value.ljust(widths[idx]) for idx, value in enumerate(values)) + " |"

    header = fmt_row(headers)
    divider = "| " + " | ".join("-" * widths[idx] for idx in range(len(headers))) + " |"
    body = [fmt_row(row) for row in rows]
    return "\n".join([header, divider] + body)


def common_panel_dir() -> Path:
    appdata = os.environ.get("APPDATA", "")
    if not appdata:
        return Path("artifacts") / "camarilla_watcher"
    return Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files" / "DigitalRogue" / "AIWatchPanel"


def write_panel_file(payload: dict[str, Any], frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ai_status = "OFF"
    if payload.get("ai_error"):
        ai_status = "ERROR"
    elif payload.get("ai_commentary"):
        if str(payload["ai_commentary"]).startswith("All watched charts are currently filtered out"):
            ai_status = "SKIPPED"
        else:
            ai_status = "OK"

    lines = [
        "AI Watch Panel",
        f"Generated: {payload['generated_at']}",
        f"AI Status: {ai_status}",
        "",
    ]

    if payload.get("ai_commentary"):
        lines.extend(["AI Commentary:", payload["ai_commentary"], ""])
    elif payload.get("ai_error"):
        lines.extend(["AI Error:", payload["ai_error"], ""])
    else:
        lines.append("AI Commentary: Not requested")
        lines.append("")

    if frame.empty:
        lines.append("No watch rows.")
        if payload.get("errors"):
            lines.append("")
            lines.append("Errors:")
            for item in payload["errors"][:5]:
                lines.append(f"- {item['symbol']}: {item['error']}")
    else:
        top = frame.iloc[0]
        lines.append(f"Most Interesting: {pretty_state_line(top)}")
        lines.append(f"H1 Bias: {top['h1_bias']} | H4 Bias: {top['h4_bias']}")
        lines.append("")
        lines.append("Top Watchlist:")
        for _, row in frame.head(5).iterrows():
            lines.append(f"- {pretty_state_line(row)}")
        lines.extend(["", "Top Symbol Module States:", str(top["module_states"])])

    path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


def run_once() -> None:
    global args
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    initialize_mt5(args.terminal)
    rows: list[WatchRow] = []
    errors: list[dict[str, str]] = []
    try:
        for symbol in args.symbols:
            try:
                row = build_watch_row(
                    symbol=symbol,
                    timeframe=args.timeframe,
                    max_spread_points=args.max_spread_points,
                    min_score=args.min_score,
                    min_body_to_range=args.min_body_to_range,
                    min_sweep_atr_frac=args.min_sweep_atr_frac,
                    near_atr_distance=args.near_atr_distance,
                )
                rows.append(row)
            except Exception as exc:
                errors.append({"symbol": symbol, "error": str(exc)})
    finally:
        mt5.shutdown()

    frame = pd.DataFrame([asdict(r) for r in rows])
    if not frame.empty:
        state_order = pd.CategoricalDtype(["VALID", "NEAR", "WAIT"], ordered=True)
        frame["best_state"] = frame["best_state"].astype(state_order)
        frame = frame.sort_values(["best_state", "best_score", "spread_points"], ascending=[True, False, True]).reset_index(drop=True)

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = out_dir / f"camarilla_watchlist_{stamp}.csv"
    json_path = out_dir / f"camarilla_watchlist_{stamp}.json"
    md_path = out_dir / f"camarilla_watchlist_{stamp}.md"
    frame.to_csv(csv_path, index=False)

    payload: dict[str, Any] = {
        "generated_at": datetime.now().isoformat(),
        "rows": frame.to_dict(orient="records"),
        "errors": errors,
    }

    commentary = ""
    should_call_ai = bool(args.use_ai and not frame.empty)
    if should_call_ai:
        actionable = frame[frame["best_state"].isin(["VALID", "NEAR"])].copy()
        if actionable.empty:
            payload["ai_commentary"] = "All watched charts are currently filtered out or uninteresting. AI commentary skipped until a chart moves into a near or valid setup."
            should_call_ai = False

    if should_call_ai:
        actionable = actionable.sort_values(["best_state", "best_score", "spread_points"], ascending=[True, False, True]).reset_index(drop=True)
        top_rows = actionable.head(args.top_n).to_dict(orient="records")
        prompt = build_prompt(top_rows, payload["generated_at"])
        try:
            commentary = call_ollama(
                args.host,
                args.model,
                prompt,
                args.connect_timeout,
                args.read_timeout,
                args.ai_num_predict,
            )
            payload["ai_commentary"] = commentary
        except Exception as exc:
            payload["ai_error"] = str(exc)
    elif payload.get("ai_commentary"):
        commentary = payload["ai_commentary"]

    json_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    panel_path = common_panel_dir() / "latest_watch_panel.txt"
    write_panel_file(payload, frame, panel_path)

    lines = [
        "# Camarilla AI Watchlist",
        "",
        f"Generated: `{payload['generated_at']}`",
        "",
        "## Ranked Rows",
        "",
    ]
    if frame.empty:
        lines.append("No rows generated.")
    else:
        preview = frame[["symbol", "location", "h1_bias", "h4_bias", "trend_alignment", "best_module", "best_state", "best_reason", "best_score", "spread_points", "session"]]
        lines.append(frame_to_markdown_table(preview))
    if errors:
        lines.extend(["", "## Errors", ""])
        for item in errors:
            lines.append(f"- `{item['symbol']}`: {item['error']}")
    if commentary:
        lines.extend(["", "## AI Commentary", "", commentary])
    elif payload.get("ai_error"):
        lines.extend(["", "## AI Error", "", payload["ai_error"]])

    md_path.write_text("\n".join(lines), encoding="utf-8")

    print(f"CSV: {csv_path}")
    print(f"JSON: {json_path}")
    print(f"MD: {md_path}")
    print(f"PANEL: {panel_path}")
    if commentary:
        print("\nAI Commentary:\n")
        print(commentary)


def main() -> None:
    global args
    args = parse_args()
    if args.loop_seconds <= 0:
        run_once()
        return

    while True:
        try:
            run_once()
        except KeyboardInterrupt:
            raise
        except Exception as exc:
            print(f"WATCHER ERROR: {exc}")
        print(f"Sleeping {args.loop_seconds} seconds...")
        time.sleep(args.loop_seconds)


if __name__ == "__main__":
    main()
