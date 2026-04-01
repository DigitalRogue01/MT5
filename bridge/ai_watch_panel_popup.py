import argparse
import os
import tkinter as tk
from pathlib import Path


def default_panel_path() -> Path:
    appdata = os.environ.get("APPDATA", "")
    if not appdata:
        return Path("latest_watch_panel.txt")
    return (
        Path(appdata)
        / "MetaQuotes"
        / "Terminal"
        / "Common"
        / "Files"
        / "DigitalRogue"
        / "AIWatchPanel"
        / "latest_watch_panel.txt"
    )


class WatchPanelPopup:
    def __init__(self, panel_path: Path, refresh_ms: int, always_on_top: bool) -> None:
        self.panel_path = panel_path
        self.refresh_ms = refresh_ms
        self.root = tk.Tk()
        self.root.title("AI Watch Panel")
        self.root.geometry("560x420+60+60")
        self.root.configure(bg="#111111")
        self.root.attributes("-topmost", always_on_top)

        self.status_var = tk.StringVar(value="Waiting for panel file...")
        self.topmost_var = tk.BooleanVar(value=always_on_top)
        self.last_text = ""
        self.last_mtime = 0.0

        self.build_ui()
        self.refresh()

    def build_ui(self) -> None:
        toolbar = tk.Frame(self.root, bg="#1d1d1d")
        toolbar.pack(fill="x", padx=8, pady=(8, 4))

        title = tk.Label(
            toolbar,
            text="AI Watch Panel",
            bg="#1d1d1d",
            fg="#f0f0f0",
            font=("Segoe UI", 11, "bold"),
        )
        title.pack(side="left")

        topmost = tk.Checkbutton(
            toolbar,
            text="Always on top",
            variable=self.topmost_var,
            command=self.toggle_topmost,
            bg="#1d1d1d",
            fg="#d0d0d0",
            selectcolor="#1d1d1d",
            activebackground="#1d1d1d",
            activeforeground="#ffffff",
        )
        topmost.pack(side="right")

        path_label = tk.Label(
            self.root,
            text=str(self.panel_path),
            anchor="w",
            justify="left",
            bg="#111111",
            fg="#8fb3ff",
            font=("Consolas", 8),
        )
        path_label.pack(fill="x", padx=10, pady=(0, 6))

        self.text = tk.Text(
            self.root,
            wrap="word",
            bg="#0f0f0f",
            fg="#f5f5f5",
            insertbackground="#f5f5f5",
            relief="flat",
            font=("Consolas", 10),
            padx=10,
            pady=10,
        )
        self.text.pack(fill="both", expand=True, padx=10, pady=(0, 6))
        self.text.config(state="disabled")

        status = tk.Label(
            self.root,
            textvariable=self.status_var,
            anchor="w",
            justify="left",
            bg="#111111",
            fg="#bbbbbb",
            font=("Segoe UI", 9),
        )
        status.pack(fill="x", padx=10, pady=(0, 10))

    def toggle_topmost(self) -> None:
        self.root.attributes("-topmost", self.topmost_var.get())

    def read_panel_text(self) -> str:
        if not self.panel_path.exists():
            return (
                "AI Watch Panel\n\n"
                "No panel file found yet.\n\n"
                "Run the watcher script first:\n"
                "watch_camarilla_ai.py"
            )
        return self.panel_path.read_text(encoding="utf-8", errors="replace")

    def set_text(self, content: str) -> None:
        self.text.config(state="normal")
        self.text.delete("1.0", "end")
        self.text.insert("1.0", content)
        self.text.config(state="disabled")

    def refresh(self) -> None:
        try:
            mtime = self.panel_path.stat().st_mtime if self.panel_path.exists() else 0.0
            if mtime != self.last_mtime:
                self.last_mtime = mtime
                content = self.read_panel_text()
                if content != self.last_text:
                    self.last_text = content
                    self.set_text(content)
            self.status_var.set(
                f"Watching: {self.panel_path.name} | Refresh: {self.refresh_ms} ms"
            )
        except Exception as exc:
            self.status_var.set(f"Read error: {exc}")

        self.root.after(self.refresh_ms, self.refresh)

    def run(self) -> None:
        self.root.mainloop()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Popup viewer for the AI watch panel text file.")
    parser.add_argument("--panel-file", default=str(default_panel_path()))
    parser.add_argument("--refresh-ms", type=int, default=3000)
    parser.add_argument("--always-on-top", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    app = WatchPanelPopup(
        panel_path=Path(args.panel_file),
        refresh_ms=args.refresh_ms,
        always_on_top=args.always_on_top,
    )
    app.run()


if __name__ == "__main__":
    main()
