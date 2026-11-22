"""
Phase 3 security helpers: certificates, paired-device list, pairing token, rate limiting.

Setup:
    pip install cryptography qrcode

Files are stored in  C:\\Users\\<you>\\.phone_remote\\
    ca.key / ca.pem        private CA that signs each phone's certificate
    server.key / server.pem  this PC's identity (its fingerprint goes in the QR code)
    devices.json           the phones allowed to connect
    master.dpapi           random secret that locks ca.key and server.key; it is encrypted
                           with Windows DPAPI, so only THIS Windows account on THIS PC can read it

The private keys (ca.key, server.key) are stored encrypted. A copy of the folder taken to
another PC or Windows account is unreadable. The folder is also restricted to your account.
Limit: a program running as you can still ask Windows to decrypt your data.
"""
import datetime
import hashlib
import hmac
import json
import logging
import os
import secrets
import ssl
import subprocess
import time
from pathlib import Path

import win32crypt  # Windows DPAPI

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

DATA_DIR = Path.home() / ".phone_remote"
DATA_DIR.mkdir(exist_ok=True)
CA_CERT, CA_KEY = DATA_DIR / "ca.pem", DATA_DIR / "ca.key"
SERVER_CERT, SERVER_KEY = DATA_DIR / "server.pem", DATA_DIR / "server.key"
MASTER_FILE = DATA_DIR / "master.dpapi"
_ENTROPY = b"PhoneRemote key protection v1"
_NO_WINDOW = 0x08000000  # don't flash a console window

_master_password: bytes | None = None


# ---------- protecting the key files (Windows DPAPI) ----------
def _dpapi_protect(data: bytes) -> bytes:
    return win32crypt.CryptProtectData(data, "PhoneRemote", _ENTROPY, None, None, 0)


def _dpapi_unprotect(blob: bytes) -> bytes:
    return win32crypt.CryptUnprotectData(blob, _ENTROPY, None, None, 0)[1]


def _write_private(path: Path, data: bytes) -> None:
    """Write via a temporary file so a crash can't leave a half-written key."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def _password() -> bytes:
    """The secret that locks the key files. Created on first use, kept only in DPAPI-encrypted form."""
    global _master_password
    if _master_password is not None:
        return _master_password
    if MASTER_FILE.exists():
        try:
            secret = _dpapi_unprotect(MASTER_FILE.read_bytes())
        except Exception as e:
            raise RuntimeError(
                "Phone Remote cannot unlock its security keys. They were created under a "
                "different Windows account or on another PC.\n\n"
                f"To start fresh, close this app, delete the folder {DATA_DIR} and open it again. "
                "You will need to pair your phones again."
            ) from e
    else:
        secret = secrets.token_bytes(32)
        _write_private(MASTER_FILE, _dpapi_protect(secret))
    _master_password = secret.hex().encode()
    return _master_password


def _is_encrypted(pem: bytes) -> bool:
    return b"ENCRYPTED PRIVATE KEY" in pem


def _save_key(path: Path, key) -> None:
    pem = key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8,
                            serialization.BestAvailableEncryption(_password()))
    _write_private(path, pem)


def _load_key(path: Path):
    data = path.read_bytes()
    return serialization.load_pem_private_key(data, password=_password() if _is_encrypted(data) else None)


def _lock_down_folder() -> None:
    """Allow only the current Windows account to open the data folder."""
    try:
        user = f"{os.environ['USERDOMAIN']}\\{os.environ['USERNAME']}"
        grant = subprocess.run(
            ["icacls", str(DATA_DIR), "/grant:r", f"{user}:(OI)(CI)F"],
            creationflags=_NO_WINDOW, capture_output=True)
        if grant.returncode != 0:  # never remove access unless our own access is confirmed
            raise RuntimeError(grant.stdout.decode(errors="replace").strip())
        result = subprocess.run(
            ["icacls", str(DATA_DIR), "/inheritance:r"],
            creationflags=_NO_WINDOW, capture_output=True)
        if result.returncode != 0:
            raise RuntimeError(result.stdout.decode(errors="replace").strip())
    except Exception:
        logging.warning("Could not restrict the data folder to this account", exc_info=True)


# ---------- certificates ----------
def _new_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _key_pem(key) -> bytes:
    return key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())


def _name(cn: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def _build_cert(subject, public_key, issuer, signing_key, days, *, ca=False, usage=None):
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=days))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
    )
    if usage:
        builder = builder.add_extension(x509.ExtendedKeyUsage([usage]), critical=False)
    return builder.sign(signing_key, hashes.SHA256())


def ensure_identity() -> None:
    """Create the CA and the server certificate on first run, and protect the private keys."""
    _lock_down_folder()
    if not CA_CERT.exists():
        key = _new_key()
        cert = _build_cert(_name("PhoneRemote CA"), key.public_key(),
                           _name("PhoneRemote CA"), key, 3650, ca=True)
        _save_key(CA_KEY, key)
        CA_CERT.write_bytes(cert.public_bytes(Encoding.PEM))
    if not SERVER_CERT.exists():
        key = _new_key()
        cert = _build_cert(_name("PhoneRemote PC"), key.public_key(),
                           _name("PhoneRemote PC"), key, 1825,
                           usage=ExtendedKeyUsageOID.SERVER_AUTH)
        _save_key(SERVER_KEY, key)
        SERVER_CERT.write_bytes(cert.public_bytes(Encoding.PEM))
    # Keys made by an older version are plain text: encrypt them in place.
    # (The certificates don't change, so phones that are already paired keep working.)
    for path in (CA_KEY, SERVER_KEY):
        if path.exists() and not _is_encrypted(path.read_bytes()):
            _save_key(path, _load_key(path))
            logging.info("Encrypted %s", path.name)


def fingerprint(der: bytes) -> str:
    return hashlib.sha256(der).hexdigest()


def server_fingerprint() -> str:
    cert = x509.load_pem_x509_certificate(SERVER_CERT.read_bytes())
    return fingerprint(cert.public_bytes(Encoding.DER))


def issue_client_cert(device_name: str) -> tuple[str, str, str]:
    """Create a certificate + key for a new phone. Returns (cert_pem, key_pem, fingerprint).
    The private key is NOT stored on the PC; it is sent once to the phone."""
    ca_cert = x509.load_pem_x509_certificate(CA_CERT.read_bytes())
    ca_key = _load_key(CA_KEY)
    key = _new_key()
    cert = _build_cert(_name(device_name), key.public_key(), ca_cert.subject, ca_key, 730,
                       usage=ExtendedKeyUsageOID.CLIENT_AUTH)
    return (
        cert.public_bytes(Encoding.PEM).decode(),
        _key_pem(key).decode(),
        fingerprint(cert.public_bytes(Encoding.DER)),
    )


def make_ssl_context() -> ssl.SSLContext:
    """TLS 1.3 only. Phones may present a certificate signed by our CA (optional only
    so that a NEW phone can connect once to pair; the server enforces the rest)."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(str(SERVER_CERT), str(SERVER_KEY), password=_password())
    ctx.load_verify_locations(cafile=str(CA_CERT))
    ctx.verify_mode = ssl.CERT_OPTIONAL
    return ctx


# ---------- paired devices ----------
class DeviceStore:
    def __init__(self):
        self._path = DATA_DIR / "devices.json"
        self._devices = json.loads(self._path.read_text()) if self._path.exists() else {}

    def _save(self):
        self._path.write_text(json.dumps(self._devices, indent=2))

    def add(self, fp: str, name: str):
        self._devices[fp] = {"name": name, "added": datetime.date.today().isoformat()}
        self._save()

    def remove(self, fp: str):
        self._devices.pop(fp, None)
        self._save()

    def is_paired(self, fp: str) -> bool:
        return fp in self._devices

    def name(self, fp: str) -> str:
        return self._devices.get(fp, {}).get("name", "Unknown")

    def items(self) -> list[tuple[str, dict]]:
        return list(self._devices.items())


# ---------- one-time pairing token ----------
class PairingWindow:
    DURATION = 120  # seconds
    MAX_BAD_TOKENS = 3

    def __init__(self):
        self.token = None
        self.expires = 0.0
        self.bad = 0

    def open(self) -> str:
        self.token = secrets.token_urlsafe(32)
        self.expires = time.monotonic() + self.DURATION
        self.bad = 0
        return self.token

    def close(self):
        self.token = None

    @property
    def active(self) -> bool:
        return self.token is not None and time.monotonic() < self.expires

    def check(self, candidate: str) -> bool:
        """Single use: a correct token closes the window immediately."""
        if not self.active:
            return False
        if hmac.compare_digest(candidate.encode(), self.token.encode()):
            self.close()
            return True
        self.bad += 1
        if self.bad >= self.MAX_BAD_TOKENS:
            self.close()
        return False


# ---------- rate limiting ----------
class RateLimiter:
    def __init__(self, max_failures=5, lock_seconds=600):
        self.max_failures = max_failures
        self.lock_seconds = lock_seconds
        self._fails: dict[str, list[float]] = {}
        self._locked_until: dict[str, float] = {}

    def locked(self, ip: str) -> bool:
        return time.monotonic() < self._locked_until.get(ip, 0.0)

    def fail(self, ip: str):
        now = time.monotonic()
        recent = [t for t in self._fails.get(ip, []) if now - t < self.lock_seconds] + [now]
        self._fails[ip] = recent
        if len(recent) >= self.max_failures:
            self._locked_until[ip] = now + self.lock_seconds
            self._fails[ip] = []
            print(f"[security] Locked out {ip} for {self.lock_seconds // 60} minutes")
