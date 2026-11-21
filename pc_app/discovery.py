"""
Announces this PC on the local network (mDNS / Bonjour) so the phone can find it
even when the router gives the PC a new IP address.

Only the first 16 characters of the PC's public certificate fingerprint are announced.
The phone still only trusts the exact PC it paired with (full fingerprint check in TLS),
so a fake announcement can't trick it.

Needs:  pip install zeroconf
"""
import asyncio
import logging
import socket

from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

SERVICE_TYPE = "_phoneremote._tcp.local."
CHECK_SECONDS = 15


def _info(fp_prefix: str, ip: str, port: int) -> ServiceInfo:
    return ServiceInfo(
        SERVICE_TYPE,
        f"PhoneRemote-{fp_prefix}.{SERVICE_TYPE}",
        addresses=[socket.inet_aton(ip)],
        port=port,
        properties={"fp": fp_prefix},
        server=f"phoneremote-{fp_prefix}.local.",
    )


async def advertise(get_ip, fingerprint: str, port: int) -> None:
    """Runs forever: registers the service and re-registers it whenever the IP changes."""
    fp_prefix = fingerprint[:16]
    aiozc = AsyncZeroconf()
    current = None
    try:
        while True:
            ip = get_ip()
            if not ip.startswith("127."):  # ignore "no network" until we have a real address
                if current is None:
                    await aiozc.async_register_service(_info(fp_prefix, ip, port), allow_name_change=True)
                    current = ip
                    logging.info("Announcing on the network as %s", ip)
                elif ip != current:
                    await aiozc.async_update_service(_info(fp_prefix, ip, port))
                    current = ip
                    logging.info("IP changed, now announcing %s", ip)
            await asyncio.sleep(CHECK_SECONDS)
    finally:
        await aiozc.async_unregister_all_services()
        await aiozc.async_close()
