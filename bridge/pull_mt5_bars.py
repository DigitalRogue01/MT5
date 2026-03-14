import argparse
from pathlib import Path

import MetaTrader5 as mt5
import pandas as pd


TIMEFRAME_MAP = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export bars directly from a local MT5 terminal.")
    parser.add_argument("--symbol", default="EURAUD")
    parser.add_argument("--timeframe", default="M15", choices=sorted(TIMEFRAME_MAP.keys()))
    parser.add_argument("--start", default="2024-01-01 00:00")
    parser.add_argument("--end", default="2025-12-31 23:59")
    parser.add_argument("--output", required=True)
    parser.add_argument("--terminal", help="Optional full path to terminal64.exe")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    start = pd.Timestamp(args.start)
    end = pd.Timestamp(args.end)
    if end <= start:
        raise ValueError("end must be after start")

    init_kwargs = {}
    if args.terminal:
        init_kwargs["path"] = args.terminal

    if not mt5.initialize(**init_kwargs):
        raise RuntimeError(f"MetaTrader5 initialize failed: {mt5.last_error()}")

    try:
        rates = mt5.copy_rates_range(args.symbol, TIMEFRAME_MAP[args.timeframe], start.to_pydatetime(), end.to_pydatetime())
        if rates is None or len(rates) == 0:
            raise RuntimeError(f"No rates returned: {mt5.last_error()}")

        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        df.to_csv(output_path, index=False)
        print(f"Exported {len(df)} bars to {output_path}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
