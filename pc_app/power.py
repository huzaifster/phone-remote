"""
Phase 4 + 6: power commands and the "shut down when finished" watcher (Windows).
Needs psutil (already installed for capture.py).
"""
import asyncio
import subprocess
import time

import psutil

COUNTDOWN_SECONDS = 30  # manual shutdown / restart / sleep
AUTO_COUNTDOWN_SECONDS = 60  # extra warning when the watcher triggers a shutdown
SAMPLE_SECONDS = 5

# --- What counts as "still busy". Tune these for your PC. ---
NET_BUSY_BYTES_PER_SEC = 100 * 1024  # downloading faster than ~100 KB/s
DISK_BUSY_BYTES_PER_SEC = 3 * 1024 * 1024  # installing / extracting (~3 MB/s of disk activity)
CPU_BUSY_PERCENT = 25

NO_WINDOW = 0x08000000  # don't flash a console window


def _run(args: list[str]) -> None:
    subprocess.run(args, creationflags=NO_WINDOW, capture_output=True)


class PowerManager:
    def __init__(self, notify):
        self.notify = notify  # async function that sends a dict to all connected phones
        self.pending = None  # {"action": ..., "ends_at": ...} while a countdown is running
        self._sleep_task = None

    def status_message(self):
        if not self.pending:
            return None
        left = max(0, round(self.pending["ends_at"] - time.monotonic()))
        return {"type": "power", "action": self.pending["action"], "seconds": left}

    async def start(self, action: str, seconds: int = COUNTDOWN_SECONDS,
                    reason: str = "Phone Remote request") -> bool:
        if action not in ("shutdown", "restart", "sleep") or self.pending:
            return False
        loop = asyncio.get_running_loop()
        token = {"action": action, "ends_at": time.monotonic() + seconds}
        self.pending = token

        if action in ("shutdown", "restart"):
            flag = "/s" if action == "shutdown" else "/r"
            comment = f"{reason}. To cancel, use the phone app or run: shutdown /a"
            await loop.run_in_executor(None, _run, ["shutdown", flag, "/t", str(seconds), "/c", comment])
        else:
            self._sleep_task = asyncio.create_task(self._sleep_after(seconds))

        asyncio.create_task(self._expire(token, seconds))
        await self.notify(self.status_message())
        return True

    async def cancel(self) -> None:
        if not self.pending:
            return
        action = self.pending["action"]
        self.pending = None
        if action == "sleep":
            if self._sleep_task:
                self._sleep_task.cancel()
        else:
            await asyncio.get_running_loop().run_in_executor(None, _run, ["shutdown", "/a"])
        await self.notify({"type": "power_cancelled"})

    async def _sleep_after(self, seconds: int) -> None:
        await asyncio.sleep(seconds)
        self.pending = None
        # Note: if Windows hibernation is enabled, this hibernates instead of sleeping.
        await asyncio.get_running_loop().run_in_executor(
            None, _run, ["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"]
        )

    async def _expire(self, token: dict, seconds: int) -> None:
        """If the PC is still on well after the countdown (e.g. cancelled at the PC itself),
        clear the pending state so phones don't show a stale countdown."""
        await asyncio.sleep(seconds + 10)
        if self.pending is token:
            self.pending = None
            await self.notify({"type": "power_cancelled"})


class AutoShutdown:
    """Shuts the PC down once downloads/installs have gone quiet.

    It only arms itself after it has SEEN activity, so enabling it before a download starts
    won't shut the PC down immediately."""

    def __init__(self, power: PowerManager, notify):
        self.power = power
        self.notify = notify
        self.enabled = False
        self.quiet_minutes = 3
        self.state = "off"  # off | waiting | busy | quiet
        self.seen_busy = False
        self.quiet_since = None
        self._last_time = None
        self._last_net = 0
        self._last_disk = 0

    def configure(self, enabled: bool, quiet_minutes: int) -> None:
        self.quiet_minutes = max(1, min(30, quiet_minutes))
        if enabled and self.enabled:
            return  # only the wait time changed, keep current progress
        self.enabled = enabled
        self.seen_busy = False
        self.quiet_since = None
        self._last_time = None
        self.state = "waiting" if enabled else "off"

    def status_message(self) -> dict:
        quiet_seconds = 0 if self.quiet_since is None else int(time.monotonic() - self.quiet_since)
        return {
            "type": "auto_status",
            "enabled": self.enabled,
            "state": self.state,
            "quiet_minutes": self.quiet_minutes,
            "quiet_seconds": quiet_seconds,
        }

    def _is_busy(self) -> bool:
        now = time.monotonic()
        net = psutil.net_io_counters().bytes_recv
        disk_io = psutil.disk_io_counters()
        disk = (disk_io.read_bytes + disk_io.write_bytes) if disk_io else 0
        cpu = psutil.cpu_percent(None)

        busy = cpu > CPU_BUSY_PERCENT
        if self._last_time is not None:
            dt = now - self._last_time
            if dt > 0:
                busy = busy or (net - self._last_net) / dt > NET_BUSY_BYTES_PER_SEC
                busy = busy or (disk - self._last_disk) / dt > DISK_BUSY_BYTES_PER_SEC
        self._last_time, self._last_net, self._last_disk = now, net, disk
        return busy

    async def run(self) -> None:
        psutil.cpu_percent(None)  # first call is meaningless; prime it
        while True:
            await asyncio.sleep(SAMPLE_SECONDS)
            if not self.enabled:
                continue
            try:
                now = time.monotonic()
                if self._is_busy():
                    self.seen_busy = True
                    self.quiet_since = None
                    self.state = "busy"
                elif not self.seen_busy:
                    self.state = "waiting"
                else:
                    if self.quiet_since is None:
                        self.quiet_since = now
                    self.state = "quiet"
                    if now - self.quiet_since >= self.quiet_minutes * 60 and not self.power.pending:
                        print("\n[auto-shutdown] Activity has finished. Shutting down.")
                        self.enabled = False  # one-shot: if you cancel, it won't fire again
                        self.state = "off"
                        await self.power.start(
                            "shutdown", AUTO_COUNTDOWN_SECONDS,
                            reason="Downloads/installs finished")
                await self.notify(self.status_message())
            except Exception as e:  # never let the watcher die silently
                print(f"[auto-shutdown] error: {e}")
