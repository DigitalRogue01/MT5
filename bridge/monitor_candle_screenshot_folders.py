from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path


BASE_SCREENSHOT_FOLDER = Path(
    r"C:\Users\digit\AppData\Roaming\MetaQuotes\Terminal\D3E6E9F9DA42E1A2ED575A94AE88F6CD\MQL5\Files\DigitalRogue\CandleScreenshots"
)


def snapshot(folder: Path) -> dict[str, float]:
    if not folder.exists():
        return {}
    return {p.name: p.stat().st_mtime for p in folder.glob("*.png")}


def newest_png(folder: Path) -> Path | None:
    files = list(folder.glob("*.png"))
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_mtime)


def discover_chart_folders(base_folder: Path) -> list[Path]:
    base_folder.mkdir(parents=True, exist_ok=True)
    return sorted([p for p in base_folder.iterdir() if p.is_dir()], key=lambda p: p.name.lower())


def print_folder_header(folder: Path, previous: dict[str, float]) -> None:
    latest = newest_png(folder)
    latest_text = latest.name if latest else "none yet"
    print(f"- {folder} | existing: {len(previous)} | latest: {latest_text}")


def monitor(base_folder: Path, folders: list[Path], interval: float) -> int:
    previous: dict[Path, dict[str, float]] = {}
    print("Monitoring screenshot folders:")
    for folder in folders:
        folder.mkdir(parents=True, exist_ok=True)
        previous[folder] = snapshot(folder)
        print_folder_header(folder, previous[folder])

    print("\nWaiting for new PNG files. Press Ctrl+C to stop.\n")

    try:
        while True:
            discovered = discover_chart_folders(base_folder)
            for folder in discovered:
                if folder not in previous:
                    previous[folder] = snapshot(folder)
                    print(f"[WATCH]  Added folder {folder.name}")
                    print_folder_header(folder, previous[folder])

            for folder in folders:
                if folder not in previous:
                    previous[folder] = snapshot(folder)
                    print_folder_header(folder, previous[folder])
            for folder in sorted(previous.keys(), key=lambda p: p.name.lower()):
                current = snapshot(folder)
                old = previous.get(folder, {})
                new_files = [name for name in current if name not in old]
                changed_files = [name for name, mtime in current.items() if name in old and old[name] != mtime]

                for name in sorted(new_files):
                    print(f"[NEW]    {folder.name} -> {name}")
                for name in sorted(changed_files):
                    print(f"[UPDATE] {folder.name} -> {name}")

                previous[folder] = current
            sys.stdout.flush()
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\nStopped.")
        return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Monitor MT5 candle screenshot folders for new PNG files.")
    parser.add_argument("--interval", type=float, default=5.0, help="Polling interval in seconds.")
    parser.add_argument("--base-folder", default=str(BASE_SCREENSHOT_FOLDER), help="Base folder that contains chart screenshot subfolders.")
    parser.add_argument("folders", nargs="*", help="Optional folders to monitor.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    base_folder = Path(args.base_folder)
    folders = [Path(p) for p in args.folders] if args.folders else discover_chart_folders(base_folder)
    return monitor(base_folder, folders, args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
