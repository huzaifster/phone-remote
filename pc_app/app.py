"""
Phone Remote - PC app: tray icon, pairing window, paired-phones manager.

Setup:   pip install pystray
Run:     pythonw app.py      (no console window)
         python app.py       (same, but shows a console, handy if something goes wrong)
Build:   build_exe.bat       (makes dist\\PhoneRemote.exe)

Errors are written to  C:\\Users\\<you>\\.phone_remote\\agent.log
"""
import asyncio
import ctypes
import io
import logging
import queue
import sys
import threading
import time
import tkinter as tk
import winreg
from pathlib import Path
from tkinter import messagebox, ttk

import pystray
import qrcode
from PIL import Image, ImageDraw, ImageTk

import security

logging.basicConfig(
    filename=str(security.DATA_DIR / "agent.log"),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

import server  # noqa: E402  (after logging is configured)

APP_NAME = "PhoneRemote"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def resource(name: str) -> str:
    """Path to a bundled file (works from source and inside the built .exe)."""
    base = getattr(sys, "_MEIPASS", Path(__file__).resolve().parent)
    return str(Path(base) / name)


def set_window_icon(win) -> None:
    try:
        win.iconbitmap(resource("icon.ico"))
    except Exception:
        logging.exception("could not set window icon")


# ---------- start with Windows ----------
def _launch_command() -> str:
    if getattr(sys, "frozen", False):  # built .exe
        return f'"{sys.executable}"'
    pythonw = Path(sys.executable).with_name("pythonw.exe")
    return f'"{pythonw}" "{Path(__file__).resolve()}"'


def autostart_enabled() -> bool:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, APP_NAME)
            return True
    except OSError:
        return False


def set_autostart(enabled: bool) -> None:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if enabled:
            winreg.SetValueEx(key, APP_NAME, 0, winreg.REG_SZ, _launch_command())
        else:
            try:
                winreg.DeleteValue(key, APP_NAME)
            except OSError:
                pass


# ---------- tray icon image ----------
def make_icon(connected: bool) -> Image.Image:
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    blue = (88, 101, 242, 255)
    d.rounded_rectangle((4, 10, 60, 46), radius=6, fill=blue)
    d.rounded_rectangle((9, 15, 55, 41), radius=3, fill=(22, 26, 51, 255))
    d.rectangle((27, 46, 37, 53), fill=blue)
    d.rounded_rectangle((18, 53, 46, 58), radius=2, fill=blue)
    if connected:  # green dot = a phone is connected
        d.ellipse((38, 0, 62, 24), fill=(46, 204, 113, 255), outline=(255, 255, 255, 255), width=2)
    return img


class TrayApp:
    def __init__(self):
        self.root = tk.Tk()
        self.root.withdraw()  # no main window, only the tray icon
        self.ui_queue: queue.Queue = queue.Queue()  # actions from other threads -> UI thread
        self.connected: dict[str, str] = {}  # fingerprint -> phone name
        self.pair_win = None
        self.dev_win = None
        server.on_event = self.on_server_event
        self.icon = pystray.Icon(APP_NAME, make_icon(False), "Phone Remote", self._build_menu())

    # ----- tray menu -----
    def _build_menu(self):
        later = lambda fn: (lambda: self.ui_queue.put(fn))  # noqa: E731
        return pystray.Menu(
            pystray.MenuItem(lambda item: self.status_text(), None, enabled=False),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Pair new phone...", later(self.open_pair), default=True),
            pystray.MenuItem("Manage phones...", later(self.open_devices)),
            pystray.MenuItem(
                "Start with Windows",
                lambda: set_autostart(not autostart_enabled()),
                checked=lambda item: autostart_enabled(),
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", self.quit),
        )

    def status_text(self) -> str:
        if self.connected:
            return "Connected: " + ", ".join(self.connected.values())
        return "No phone connected"

    def refresh_tray(self) -> None:
        self.icon.icon = make_icon(bool(self.connected))
        self.icon.title = "Phone Remote - " + self.status_text()
        self.icon.update_menu()

    def notify(self, message: str) -> None:
        try:
            self.icon.notify(message, "Phone Remote")
        except Exception:
            logging.exception("notify failed")

    # ----- events from the server thread -----
    def on_server_event(self, kind: str, data: dict) -> None:
        self.ui_queue.put(lambda: self.handle_event(kind, data))

    def handle_event(self, kind: str, data: dict) -> None:
        if kind == "connected":
            self.connected[data["fp"]] = data["name"]
            self.refresh_tray()
            self.notify(f"{data['name']} connected and can view this screen.")
        elif kind == "disconnected":
            self.connected.pop(data["fp"], None)
            self.refresh_tray()
        elif kind == "paired":
            self.close_pair()
            self.notify(f"Paired with {data['name']}.")

    # ----- pairing window -----
    def open_pair(self) -> None:
        if self.pair_win and self.pair_win.winfo_exists():
            self.pair_win.lift()
            return
        payload = server.start_pairing()
        qr = qrcode.QRCode(border=2, box_size=6)
        qr.add_data(payload)
        qr.make(fit=True)
        buf = io.BytesIO()
        qr.make_image(fill_color="black", back_color="white").save(buf, format="PNG")
        buf.seek(0)

        win = tk.Toplevel(self.root)
        self.pair_win = win
        win.title("Pair a new phone")
        set_window_icon(win)
        win.resizable(False, False)
        win.protocol("WM_DELETE_WINDOW", self.close_pair)
        photo = ImageTk.PhotoImage(Image.open(buf))
        label = tk.Label(win, image=photo)
        label.image = photo  # keep a reference or Tk drops the picture
        label.pack(padx=20, pady=(20, 10))
        tk.Label(
            win,
            text='Open the phone app and tap "Scan QR code".\nThis code works once.',
            justify="center",
        ).pack()
        countdown = tk.Label(win, font=("Segoe UI", 10, "bold"))
        countdown.pack(pady=(6, 16))

        def tick():
            if not win.winfo_exists():
                return
            left = int(server.pairing.expires - time.monotonic())
            if not server.pairing.active:
                countdown.config(text="This code is no longer valid.")
                return
            countdown.config(text=f"Expires in {left // 60}:{left % 60:02d}")
            win.after(1000, tick)

        tick()
        win.attributes("-topmost", True)  # show above other windows
        win.after(600, lambda: win.winfo_exists() and win.attributes("-topmost", False))
        win.focus_force()

    def close_pair(self) -> None:
        server.pairing.close()  # closing the window kills the code
        if self.pair_win and self.pair_win.winfo_exists():
            self.pair_win.destroy()
        self.pair_win = None

    # ----- paired phones window -----
    def open_devices(self) -> None:
        if self.dev_win and self.dev_win.winfo_exists():
            self.dev_win.lift()
            return
        win = tk.Toplevel(self.root)
        self.dev_win = win
        win.title("Paired phones")
        set_window_icon(win)
        win.geometry("470x300")

        tree = ttk.Treeview(win, columns=("name", "added", "status"), show="headings",
                            selectmode="browse")
        for col, title, width in (("name", "Phone", 190), ("added", "Paired on", 110),
                                  ("status", "Status", 110)):
            tree.heading(col, text=title)
            tree.column(col, width=width)
        tree.pack(fill="both", expand=True, padx=10, pady=(10, 0))

        def redraw():
            selected = tree.selection()
            tree.delete(*tree.get_children())
            for fp, info in server.devices.items():
                status = "Connected" if fp in self.connected else "Offline"
                tree.insert("", "end", iid=fp, values=(info["name"], info["added"], status))
            if selected and tree.exists(selected[0]):
                tree.selection_set(selected[0])

        def loop():
            if win.winfo_exists():
                redraw()
                win.after(2000, loop)

        def revoke():
            selected = tree.selection()
            if not selected:
                return
            fp = selected[0]
            name = server.devices.name(fp)
            if messagebox.askyesno(
                "Revoke phone",
                f'Remove "{name}"?\nIt will be disconnected and must be paired again.',
                parent=win,
            ):
                server.revoke_device(fp)
                redraw()

        tk.Button(win, text="Revoke selected phone", command=revoke).pack(pady=10)
        loop()
        win.lift()
        win.focus_force()

    # ----- lifecycle -----
    def run_server(self) -> None:
        try:
            asyncio.run(server.serve_forever())
        except Exception as e:
            logging.exception("Agent stopped")
            self.ui_queue.put(lambda: self.fail(str(e)))

    def fail(self, text: str) -> None:
        messagebox.showerror(
            "Phone Remote",
            f"The agent could not start:\n\n{text}\n\n"
            "Is another copy (or server.py in a terminal) already running?",
        )
        self.quit()

    def poll(self) -> None:
        try:
            while True:
                action = self.ui_queue.get_nowait()
                try:
                    action()
                except Exception:
                    logging.exception("UI action failed")
        except queue.Empty:
            pass
        self.root.after(200, self.poll)

    def quit(self) -> None:
        self.icon.stop()
        self.ui_queue.put(self.root.destroy)

    def run(self) -> None:
        threading.Thread(target=self.run_server, daemon=True).start()
        self.icon.run_detached()
        self.root.after(200, self.poll)
        self.root.after(2000, lambda: self.notify("Running in the tray. Right-click the icon."))
        self.root.mainloop()


def main() -> None:
    # Only one copy at a time (two would fight over the network port)
    ctypes.windll.kernel32.CreateMutexW(None, False, "PhoneRemoteAgentMutex")
    if ctypes.windll.kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        return
    TrayApp().run()


if __name__ == "__main__":
    main()
