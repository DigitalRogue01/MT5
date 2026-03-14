import pandas as pd
from pathlib import Path

def main():
    src = Path(r"C:\Users\digit\OneDrive\Documents\Codex-Projects\MT5\bridge\exports\EURUSD_M15_20260307_20260314.csv")
    if not src.exists():
        raise FileNotFoundError(src)

    df = pd.read_csv(src, parse_dates=["time"])
    df["date"] = df["time"].dt.date

    daily = (
        df.groupby("date")
        .agg(daily_high=("high", "max"), daily_low=("low", "min"))
    )
    daily["prev_day"] = daily.index.to_series().shift(1)
    prev_levels = daily[["daily_high", "daily_low"]].copy()
    prev_levels.index = daily["prev_day"]
    prev_levels = prev_levels.rename(columns={"daily_high": "pdh", "daily_low": "pdl"})

    volume = df["real_volume"].where(df["real_volume"] > 0, df["tick_volume"])
    df["typical"] = (df["high"] + df["low"] + df["close"]) / 3
    df["vwap"] = 0.0

    for name, group in df.groupby("date"):
        vol_slice = volume.loc[group.index]
        cum_pv = (group["typical"] * vol_slice).cumsum()
        cum_vol = vol_slice.cumsum()
        df.loc[group.index, "vwap"] = cum_pv / cum_vol.replace(0, float("nan"))

    df = df.join(prev_levels, on="date")
    df = df.dropna(subset=["pdh", "pdl", "vwap"])
    out = df[
        [
            "time",
            "open",
            "high",
            "low",
            "close",
            "tick_volume",
            "vwap",
            "pdh",
            "pdl",
        ]
    ]
    out_path = src.parent / "EURUSD_M15_20260307_20260314_with_pdh_pdl_vwap.csv"
    out.to_csv(out_path, index=False)
    print(f"Created {out_path} with {len(out)} rows")


if __name__ == "__main__":
    main()
