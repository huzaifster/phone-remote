"""
Phase 1: window listing + screenshot capture (Windows only, no networking).

Setup:
    pip install mss pywin32 pillow psutil

Usage:
    python capture.py list              # show open windows
    python capture.py desktop           # save desktop screenshot
    python capture.py window 2          # save screenshot of window #2 from the list

Test screenshots are saved to ./test_output for this phase only.
In the final agent they will stay in memory and never touch the disk.
"""
import ctypes
import io
import sys
import time
from ctypes import wintypes

import mss
import psutil
import win32con
import win32gui
import win32process
import win32ui
from PIL import Image

# Make coordinates real pixels on high-DPI screens (must run before any window calls)
ctypes.windll.user32.SetProcessDPIAware()

PW_RENDERFULLCONTENT = 0x00000002  # lets PrintWindow capture modern (GPU-drawn) apps
DWMWA_CLOAKED = 14
MAX_WIDTH = 1280
JPEG_QUALITY = 65

SW_SHOWNOACTIVATE = 4  # restore a window without taking focus
SW_SHOWMINNOACTIVE = 7  # minimize it again without changing focus
DWMWA_TRANSITIONS_FORCEDISABLED = 3  # turns off the minimize/restore animation
RESTORE_SETTLE_SECONDS = 0.4  # give the app a moment to redraw after restoring


def _is_cloaked(hwnd: int) -> bool:
    """Windows keeps hidden UWP / other-virtual-desktop windows 'visible' but cloaked."""
    cloaked = ctypes.c_int(0)
    ctypes.windll.dwmapi.DwmGetWindowAttribute(
        wintypes.HWND(hwnd), DWMWA_CLOAKED, ctypes.byref(cloaked), ctypes.sizeof(cloaked)
    )
    return cloaked.value != 0


def _process_name(hwnd: int) -> str:
    try:
        _, pid = win32process.GetWindowThreadProcessId(hwnd)
        return psutil.Process(pid).name()
    except Exception:
        return "unknown"


def list_windows() -> list[dict]:
    """Return real, user-facing top-level windows."""
    results = []

    def callback(hwnd, _):
        if not win32gui.IsWindowVisible(hwnd):
            return
        title = win32gui.GetWindowText(hwnd).strip()
        if not title or title == "Program Manager":
            return
        if _is_cloaked(hwnd):
            return
        ex_style = win32gui.GetWindowLong(hwnd, win32con.GWL_EXSTYLE)
        is_tool = ex_style & win32con.WS_EX_TOOLWINDOW
        is_app = ex_style & win32con.WS_EX_APPWINDOW
        if is_tool and not is_app:
            return
        if win32gui.GetWindow(hwnd, win32con.GW_OWNER) and not is_app:
            return
        results.append(
            {
                "hwnd": hwnd,
                "title": title,
                "process": _process_name(hwnd),
                "minimized": bool(win32gui.IsIconic(hwnd)),
            }
        )

    win32gui.EnumWindows(callback, None)
    return results


def _to_jpeg(img: Image.Image) -> bytes:
    img = img.convert("RGB")
    if img.width > MAX_WIDTH:
        ratio = MAX_WIDTH / img.width
        img = img.resize((MAX_WIDTH, int(img.height * ratio)), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return buf.getvalue()


def capture_desktop() -> bytes:
    """Capture all monitors combined, return JPEG bytes."""
    with mss.mss() as sct:
        shot = sct.grab(sct.monitors[0])  # monitors[0] = virtual screen (all monitors)
        img = Image.frombuffer("RGB", shot.size, shot.bgra, "raw", "BGRX")
        return _to_jpeg(img)


def is_minimized(hwnd: int) -> bool:
    return bool(win32gui.IsIconic(hwnd))


def _set_transitions_disabled(hwnd: int, disabled: bool) -> None:
    value = ctypes.c_int(1 if disabled else 0)
    ctypes.windll.dwmapi.DwmSetWindowAttribute(
        wintypes.HWND(hwnd), DWMWA_TRANSITIONS_FORCEDISABLED,
        ctypes.byref(value), ctypes.sizeof(value),
    )


def capture_window(hwnd: int, restore_if_minimized: bool = False) -> bytes | None:
    """Capture one window. A minimized window has nothing drawn, so if allowed we restore it
    for a moment (no focus change, no animation), capture it, then minimize it again."""
    if not win32gui.IsIconic(hwnd):
        return _grab_window(hwnd)
    if not restore_if_minimized:
        return None
    _set_transitions_disabled(hwnd, True)
    win32gui.ShowWindow(hwnd, SW_SHOWNOACTIVATE)
    time.sleep(RESTORE_SETTLE_SECONDS)
    try:
        return _grab_window(hwnd)
    finally:
        win32gui.ShowWindow(hwnd, SW_SHOWMINNOACTIVE)
        _set_transitions_disabled(hwnd, False)


def _grab_window(hwnd: int) -> bytes | None:
    """Capture one window (even if partly covered)."""
    left, top, right, bottom = win32gui.GetWindowRect(hwnd)
    width, height = right - left, bottom - top
    if width <= 0 or height <= 0:
        return None

    hwnd_dc = win32gui.GetWindowDC(hwnd)
    mfc_dc = win32ui.CreateDCFromHandle(hwnd_dc)
    save_dc = mfc_dc.CreateCompatibleDC()
    bitmap = win32ui.CreateBitmap()
    bitmap.CreateCompatibleBitmap(mfc_dc, width, height)
    save_dc.SelectObject(bitmap)
    try:
        ok = ctypes.windll.user32.PrintWindow(hwnd, save_dc.GetSafeHdc(), PW_RENDERFULLCONTENT)
        if not ok:
            return None
        bits = bitmap.GetBitmapBits(True)
        img = Image.frombuffer("RGB", (width, height), bits, "raw", "BGRX", 0, 1)
        return _to_jpeg(img)
    finally:  # always free GDI handles, otherwise Windows eventually runs out
        win32gui.DeleteObject(bitmap.GetHandle())
        save_dc.DeleteDC()
        mfc_dc.DeleteDC()
        win32gui.ReleaseDC(hwnd, hwnd_dc)


def _save(name: str, data: bytes) -> None:
    import os

    os.makedirs("test_output", exist_ok=True)
    path = os.path.join("test_output", name)
    with open(path, "wb") as f:
        f.write(data)
    print(f"Saved {path} ({len(data) / 1024:.0f} KB)")


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in ("list", "desktop", "window"):
        print(__doc__)
        return

    cmd = sys.argv[1]
    if cmd == "list":
        for i, w in enumerate(list_windows(), 1):
            flag = " [minimized]" if w["minimized"] else ""
            print(f"{i:>2}. {w['title'][:60]}  ({w['process']}){flag}")
    elif cmd == "desktop":
        _save("desktop.jpg", capture_desktop())
    elif cmd == "window":
        windows = list_windows()
        idx = int(sys.argv[2]) - 1
        target = windows[idx]
        data = capture_window(target["hwnd"])
        if data is None:
            print("Could not capture (window is minimized or unavailable).")
        else:
            _save(f"window_{idx + 1}.jpg", data)


if __name__ == "__main__":
    main()
