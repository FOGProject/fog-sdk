"""Credential storage for the fog-sdk Python client.

This is the Python half of a contract shared with the PowerShell SDK. The two
share no code; they share a pinned format, and the interop test is what keeps
them honest rather than this docstring.

    target  : fog-sdk:<host>, lower-cased
    account : the FOG username, or 'fog-sdk' when unknown
    payload : {"v":1,"server":...,"authKind":"bearer","token":...,"user":...}

Connect once with either SDK and the other picks the credential up, because
both reach the same OS store: Windows Credential Manager, the macOS Keychain,
or libsecret. Where none is available both fall back to the same file, in the
same place, with the same permissions.

Bearer only, matching the PowerShell side. The SDK is generated from a FOG 1.6
document and cannot describe a 1.5 server, so the legacy fog-api-token +
fog-user-token pair is not carried here.

Honest asymmetry, stated rather than papered over: Python has no SecureString.
The token is a plain ``str`` in this process for as long as it is held.
Mitigation is limited to keeping references short-lived and never logging it.
The PowerShell side can do slightly better; this side cannot, and pretending
otherwise would be worse than saying so.
"""

from __future__ import annotations

import json
import os
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

__all__ = [
    "PAYLOAD_VERSION",
    "StoreTier",
    "CredentialError",
    "store_target",
    "build_payload",
    "parse_payload",
    "select_tier",
    "save_secret",
    "load_secret",
    "clear_secret",
    "store_file",
]

PAYLOAD_VERSION = 1
_DEFAULT_ACCOUNT = "fog-sdk"

try:  # optional: absent on a headless server, which is a common case here
    import keyring as _keyring
    import keyring.errors as _keyring_errors
except Exception:  # pragma: no cover - exercised only where keyring is absent
    _keyring = None
    _keyring_errors = None


class CredentialError(RuntimeError):
    """Raised for a payload this client cannot use, or a store that failed."""


@dataclass(frozen=True)
class StoreTier:
    """Which store was selected, and what its scope is.

    Scope is reported rather than left implicit because it is the thing people
    get wrong: the OS stores are per-user by design, so a credential saved by
    an administrator is not readable by a scheduled task running as another
    account and cannot be copied across. That is least privilege working
    correctly, but it has to be visible.
    """

    tier: str
    scope: str
    note: Optional[str] = None


def store_target(server: str) -> str:
    """``fog-sdk:<host>``, lower-cased. Must match the PowerShell side exactly."""
    host = server
    if "://" in server:
        parsed = urlparse(server)
        host = parsed.hostname or ""
    if not host:
        raise CredentialError(f"Could not read a hostname from {server!r}.")
    return f"fog-sdk:{host.lower()}"


def build_payload(server: str, token: str, user: Optional[str] = None) -> str:
    """Compact JSON, matching New-FogSdkPayload byte for byte.

    Compact deliberately: Windows Credential Manager caps a credential blob at
    2560 bytes and there is no reason to spend any of it on whitespace.
    """
    obj = {"v": PAYLOAD_VERSION, "server": server, "authKind": "bearer", "token": token}
    if user:
        obj["user"] = user
    return json.dumps(obj, separators=(",", ":"))


def parse_payload(payload: str) -> dict:
    obj = json.loads(payload)
    if obj.get("v") != PAYLOAD_VERSION:
        raise CredentialError(f"Unsupported credential payload version: {obj.get('v')}")
    if obj.get("authKind") != "bearer":
        raise CredentialError(
            f"Unsupported authKind {obj.get('authKind')!r}. This SDK is bearer-only."
        )
    return obj


def select_tier() -> StoreTier:
    if _keyring is None:
        return StoreTier("File", "current user on this machine", "keyring is not installed")

    backend = _keyring.get_keyring()
    name = type(backend).__name__

    # keyring falls back to a "fail" or "chainer-with-nothing" backend when no
    # real store is reachable. Treat that as no store rather than discovering
    # it at the first save.
    if "Fail" in name or "Null" in name:
        return StoreTier("File", "current user on this machine", f"no usable keyring backend ({name})")

    if sys.platform == "win32":
        return StoreTier("CredentialManager", "current user on this machine")
    if sys.platform == "darwin":
        return StoreTier("Keychain", "current user login keychain")
    # SecretService needs a running D-Bus session and an unlocked collection.
    # Over SSH to a FOG server -- the common case for this client -- there is
    # usually neither, so this check matters more than the tier order suggests.
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        return StoreTier("File", "current user on this machine", "no D-Bus session")
    return StoreTier("SecretService", "current user login keyring")


def store_file(target: str) -> Path:
    """The fallback file, in the same place the PowerShell side writes it.

    LOCALAPPDATA on Windows, deliberately not the roaming APPDATA: a roaming
    profile replicates the file to the domain profile share and to every
    machine the user signs into, which defeats its permissions before they are
    applied.
    """
    if sys.platform == "win32":
        root = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        directory = Path(root) / "fog-sdk"
    else:
        base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
        directory = Path(base) / "fog-sdk"
    leaf = "".join(c if (c.isalnum() or c in "._-") else "_" for c in target) + ".json"
    return directory / leaf


def _write_file(target: str, payload: str) -> None:
    path = store_file(target)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Create with restrictive permissions BEFORE writing, so the token is never
    # briefly world-readable. os.open with 0o600 is the only way to avoid that
    # window; open() would create with the umask default first.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(payload)
    except Exception:
        os.close(fd)
        raise
    if os.name != "nt":
        os.chmod(path.parent, 0o700)
        os.chmod(path, 0o600)
        # Verify rather than trust: a chmod that silently did nothing looks
        # exactly like one that worked.
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode != 0o600:
            raise CredentialError(f"Expected mode 600 on {path}, got {oct(mode)}")


def save_secret(target: str, payload: str, account: str = _DEFAULT_ACCOUNT,
                tier: Optional[str] = None) -> None:
    tier = tier or select_tier().tier
    if tier == "File":
        _write_file(target, payload)
        return
    if _keyring is None:
        raise CredentialError("keyring is not installed; pass tier='File'.")
    _keyring.set_password(target, account, payload)


def load_secret(target: str, account: str = _DEFAULT_ACCOUNT,
                tier: Optional[str] = None) -> Optional[str]:
    """Return the stored payload, or None. Never raises for 'not stored'."""
    tier = tier or select_tier().tier
    if tier == "File":
        path = store_file(target)
        if not path.exists():
            return None
        return path.read_text(encoding="utf-8")
    if _keyring is None:
        raise CredentialError("keyring is not installed; pass tier='File'.")
    return _keyring.get_password(target, account)


def clear_secret(target: str, account: str = _DEFAULT_ACCOUNT,
                 tier: Optional[str] = None) -> bool:
    """True if something was removed, False if there was nothing to remove."""
    tier = tier or select_tier().tier
    if tier == "File":
        path = store_file(target)
        if not path.exists():
            return False
        path.unlink()
        return True
    if _keyring is None:
        raise CredentialError("keyring is not installed; pass tier='File'.")
    try:
        _keyring.delete_password(target, account)
        return True
    except Exception as exc:  # keyring raises PasswordDeleteError when absent
        if _keyring_errors and isinstance(exc, _keyring_errors.PasswordDeleteError):
            return False
        raise
