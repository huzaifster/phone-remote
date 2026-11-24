"""
Phase 3: secure agent (TLS 1.3, mutual certificates, QR pairing).

Setup:
    pip install websockets cryptography qrcode
Run (same folder as capture.py and security.py):
    python server.py
Then type commands at the  >  prompt:
    pair        show a one-time QR code (valid 2 minutes) to pair a new phone
    devices     list paired phones
    revoke N    remove phone number N (disconnects it immediately)
    quit        stop the agent
"""
import asyncio
import hashlib
import ipaddress
import json
import logging
import socket
import sys
import threading

import qrcode
from websockets.asyncio.server import serve

import capture
import discovery
import power
import security

PORT = 8765
REFRESH_SECONDS = 2.0
PAIR_TIMEOUT = 5  # seconds an unknown device has to send its pairing message

devices = security.DeviceStore()
pairing = security.PairingWindow()
limiter = security.RateLimiter()
active: dict[str, set] = {}  # device fingerprint -> its open websockets
HOST_IP = "127.0.0.1"
LOOP = None  # the agent's asyncio loop, set when the server starts
on_event = None  # the tray app sets this to hear about connections / pairing


def emit(kind: str, **data) -> None:
    if on_event:
        try:
            on_event(kind, data)
        except Exception:
            pass


def clean_name(raw) -> str:
    """A phone's name is typed by the phone, so strip control characters and tidy it up."""
    text = "".join(ch for ch in str(raw) if ch.isprintable())
    text = " ".join(text.split())[:40]
    return text or "Phone"


def start_pairing() -> str:
    """Open a 2-minute pairing window and return the text to put in the QR code."""
    global HOST_IP
    HOST_IP = local_ip()
    token = pairing.open()
    return json.dumps(
        {"v": 1, "ip": HOST_IP, "port": PORT, "fp": security.server_fingerprint(), "token": token},
        separators=(",", ":"),
    )


def revoke_device(fp: str) -> None:
    """Forget a phone and disconnect it immediately if it is connected."""
    devices.remove(fp)
    if LOOP is not None:
        for ws in list(active.get(fp, ())):
            asyncio.run_coroutine_threadsafe(ws.close(1008, "Revoked"), LOOP)


async def broadcast(msg: dict) -> None:
    """Send a message to every connected, paired phone."""
    text = json.dumps(msg)
    for sockets in list(active.values()):
        for ws in list(sockets):
            try:
                await ws.send(text)
            except Exception:
                pass


power_mgr = power.PowerManager(broadcast)
auto_shutdown = power.AutoShutdown(power_mgr, broadcast)

if sys.stdout:
    sys.stdout.reconfigure(encoding="utf-8")


def local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def grab(target: str, restore: bool = False) -> bytes:
    if target == "desktop":
        return capture.capture_desktop()
    hwnd = int(target)
    if hwnd not in {w["hwnd"] for w in capture.list_windows()}:
        raise ValueError("That window is no longer open.")
    data = capture.capture_window(hwnd, restore_if_minimized=restore)
    if data is None:
        if capture.is_minimized(hwnd):
            raise ValueError(
                "Auto-refresh can't capture minimized windows. Tap refresh to capture it once.")
        raise ValueError("That window can't be captured.")
    return data


async def watch(ws, target: str) -> None:
    loop = asyncio.get_running_loop()
    last_hash = None
    while True:
        try:
            data = await loop.run_in_executor(None, grab, target)
        except ValueError as e:
            await ws.send(json.dumps({"type": "error", "message": str(e)}))
            return
        digest = hashlib.md5(data).hexdigest()
        if digest != last_hash:
            last_hash = digest
            await ws.send(data)
        await asyncio.sleep(REFRESH_SECONDS)


async def run_session(ws, fp: str, ip: str) -> None:
    """A fully authenticated, paired phone."""
    name = devices.name(fp)
    print(f"\n[connected] {name} ({ip})")
    sockets = active.setdefault(fp, set())
    sockets.add(ws)
    if len(sockets) == 1:  # first connection from this phone
        emit("connected", fp=fp, name=name)
    loop = asyncio.get_running_loop()
    watch_task = None

    def stop_watching():
        nonlocal watch_task
        if watch_task and not watch_task.done():
            watch_task.cancel()
        watch_task = None

    try:
        await ws.send(json.dumps({"type": "ready"}))
        status = power_mgr.status_message()
        if status:
            await ws.send(json.dumps(status))
        await ws.send(json.dumps(auto_shutdown.status_message()))
        async for raw in ws:
            if not devices.is_paired(fp):  # revoked while connected
                await ws.close(1008, "Revoked")
                return
            try:
                msg = json.loads(raw)
            except (TypeError, json.JSONDecodeError):
                continue
            kind = msg.get("type") if isinstance(msg, dict) else None

            if kind == "list":
                windows = await loop.run_in_executor(None, capture.list_windows)
                payload = [
                    {"id": w["hwnd"], "title": w["title"], "process": w["process"],
                     "minimized": w["minimized"]}
                    for w in windows
                ]
                await ws.send(json.dumps({"type": "windows", "windows": payload}))
            elif kind == "capture":  # one screenshot, only when the phone asks
                stop_watching()
                try:
                    data = await loop.run_in_executor(
                        None, lambda: grab(str(msg.get("target", "desktop")), True))
                    await ws.send(data)
                except ValueError as e:
                    await ws.send(json.dumps({"type": "error", "message": str(e)}))
            elif kind == "watch":
                stop_watching()
                watch_task = asyncio.create_task(watch(ws, str(msg.get("target", "desktop"))))
            elif kind == "stop":
                stop_watching()
            elif kind == "power":
                action = str(msg.get("action"))
                print(f"\n[power] {name} requested: {action}")
                await power_mgr.start(action)
            elif kind == "power_cancel":
                print(f"\n[power] {name} cancelled the pending power action")
                await power_mgr.cancel()
            elif kind == "auto_shutdown":
                try:
                    auto_shutdown.configure(msg.get("enabled") is True, int(msg.get("quiet_minutes", 3)))
                except (TypeError, ValueError):
                    continue
                print(f"\n[auto-shutdown] {name} set enabled={auto_shutdown.enabled}")
                await broadcast(auto_shutdown.status_message())
    finally:
        stop_watching()
        sockets.discard(ws)
        print(f"\n[disconnected] {name}")
        if not sockets:  # that phone has no connections left
            active.pop(fp, None)
            emit("disconnected", fp=fp, name=name)


async def handle_pairing(ws, ip: str) -> None:
    """An unknown device gets ONE chance to send a valid one-time token."""
    try:
        msg = json.loads(await asyncio.wait_for(ws.recv(), PAIR_TIMEOUT))
    except Exception:
        limiter.fail(ip)
        await ws.close(1008, "Not paired")
        return

    valid = (
        isinstance(msg, dict)
        and msg.get("type") == "pair"
        and pairing.check(str(msg.get("token", "")))
    )
    if not valid:
        limiter.fail(ip)
        await ws.send(json.dumps({"type": "error", "message": "Pairing failed"}))
        await ws.close(1008, "Pairing failed")
        return

    name = clean_name(msg.get("name", "Phone"))
    cert_pem, key_pem, fp = security.issue_client_cert(name)
    devices.add(fp, name)
    await ws.send(json.dumps({"type": "paired", "cert": cert_pem, "key": key_pem}))
    print(f"\n[paired] New device added: {name}")
    emit("paired", name=name)
    await ws.close()


async def handler(ws) -> None:
    ip = ws.remote_address[0]
    if not ipaddress.ip_address(ip).is_private or limiter.locked(ip):
        await ws.close(1008, "Not allowed")
        return

    # The phone app never sends an Origin header; web pages in a browser always do.
    # Refusing those means a website can't even try to talk to this agent.
    request = getattr(ws, "request", None)
    if request is not None and request.headers.get("Origin"):
        limiter.fail(ip)
        await ws.close(1008, "Not allowed")
        return

    ssl_obj = ws.transport.get_extra_info("ssl_object")
    der = ssl_obj.getpeercert(binary_form=True) if ssl_obj else None

    if der:  # phone presented a certificate signed by our CA
        fp = security.fingerprint(der)
        if devices.is_paired(fp):
            await run_session(ws, fp, ip)
        else:  # valid certificate but revoked / unknown
            limiter.fail(ip)
            await ws.close(1008, "Not paired")
    else:
        await handle_pairing(ws, ip)


# ---------- console commands ----------
def show_pairing_qr() -> None:
    payload = start_pairing()
    qr = qrcode.QRCode(border=1)
    qr.add_data(payload)
    qr.make(fit=True)
    qr.print_ascii(invert=True)
    print("Scan this with the phone app within 2 minutes. It works once.")
    print("(If it won't scan: make the terminal bigger, or zoom out with Ctrl + mouse wheel.)")


def console(loop) -> None:
    print(__doc__.split("Then type commands")[1].split('"""')[0].strip("\n:"))
    while True:
        try:
            cmd = input("> ").strip().lower()
        except EOFError:
            return
        if cmd == "pair":
            show_pairing_qr()
        elif cmd == "devices":
            for i, (fp, info) in enumerate(devices.items(), 1):
                online = " (connected)" if fp in active else ""
                print(f"{i}. {info['name']}  added {info['added']}{online}")
            if not devices.items():
                print("No paired devices.")
        elif cmd.startswith("revoke"):
            try:
                fp, info = devices.items()[int(cmd.split()[1]) - 1]
            except (IndexError, ValueError):
                print("Usage: revoke N   (see numbers with 'devices')")
                continue
            revoke_device(fp)
            print(f"Revoked {info['name']}.")
        elif cmd == "quit":
            loop.call_soon_threadsafe(loop.stop)
            return
        elif cmd:
            print("Commands: pair, devices, revoke N, quit")


async def run_discovery() -> None:
    try:
        await discovery.advertise(local_ip, security.server_fingerprint(), PORT)
    except Exception:
        logging.exception("Network discovery stopped (the phone can still use the saved address)")


async def serve_forever() -> None:
    """The agent itself (used by both the terminal version and the tray app)."""
    global HOST_IP, LOOP
    security.ensure_identity()
    HOST_IP = local_ip()
    LOOP = asyncio.get_running_loop()
    watcher_task = asyncio.create_task(auto_shutdown.run())  # noqa: F841 (keep a reference)
    discovery_task = asyncio.create_task(run_discovery())  # noqa: F841
    async with serve(handler, "0.0.0.0", PORT, ssl=security.make_ssl_context(), max_size=64 * 1024):
        print(f"Secure agent listening on {HOST_IP}:{PORT}")
        print(f"PC fingerprint: {security.server_fingerprint()[:16]}...\n")
        await asyncio.Future()


async def main() -> None:
    """Terminal version: agent + typed commands."""
    threading.Thread(target=console, args=(asyncio.get_running_loop(),), daemon=True).start()
    await serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, RuntimeError):
        pass
