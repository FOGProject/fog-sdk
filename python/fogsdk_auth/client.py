"""Wire the credential store to the generated client.

Without this, ``fogsdk_auth`` stores a token and ``fogsdk.Configuration`` takes
one as a string, and nothing joins them -- so "connect once with either SDK"
was true of the contract and not of the code.

The resolution order is deliberately the same as ``Connect-FgServer``:

    1. what the caller passed
    2. the environment (FOG_SDK_SERVER / FOG_SDK_TOKEN)
    3. the credential store
    4. an error

**It never prompts.** The PowerShell side has a hard no-prompt guarantee for
non-interactive sessions because a prompt there hangs rather than fails. Here
it is simpler: a library has no business prompting at all, in any session.
"""

from __future__ import annotations

import os
from typing import Any, Optional

from .credentials import (
    CredentialError,
    build_payload,
    clear_secret,
    load_secret,
    parse_payload,
    save_secret,
    select_tier,
    store_target,
)

__all__ = ["ENV_SERVER", "ENV_TOKEN", "connect", "get_connection", "disconnect"]

# The environment half of the cross-language contract. Both SDKs read these
# exact names, and CI is the reason they exist: -NoSave / save=False keeps a
# token out of the store, but something still has to supply it.
ENV_SERVER = "FOG_SDK_SERVER"
ENV_TOKEN = "FOG_SDK_TOKEN"


def _require_fogsdk():
    """Import the generated client, with an error worth reading if it is absent."""
    try:
        import fogsdk  # noqa: F401
    except ImportError as exc:
        raise CredentialError(
            "The generated client is not importable. It is not committed -- "
            "generate it first:\n"
            "    ./make.ps1 -Client python\n"
            f"(underlying error: {exc})"
        ) from exc
    return fogsdk


def _normalise(server: str) -> str:
    """A bare hostname becomes https, matching Connect-FgServer."""
    if "://" not in server:
        return "https://" + server
    return server


def connect(
    server: Optional[str] = None,
    token: Optional[str] = None,
    user: Optional[str] = None,
    save: bool = True,
    tier: Optional[str] = None,
) -> Any:
    """Return a configured ``fogsdk.ApiClient``.

    :param server: hostname or URL. A bare hostname is assumed https.
    :param token: bearer token. Omit to resolve from the environment or store.
    :param user: the FOG username the token belongs to, recorded alongside it.
    :param save: persist the token when it was supplied explicitly. Set False
        for CI, where nothing should touch disk.
    :param tier: force a storage tier. Mostly for tests.

    The returned client is a context manager::

        with connect("fog.example.org") as client:
            hosts = fogsdk.HostApi(client).host_list()
    """
    fogsdk = _require_fogsdk()

    supplied_token = token is not None

    if server is None:
        server = os.environ.get(ENV_SERVER)
    if token is None:
        token = os.environ.get(ENV_TOKEN)

    if server is None:
        raise CredentialError(
            f"No server given and {ENV_SERVER} is not set. Pass server=, or set the environment variable."
        )

    server = _normalise(server)
    target = store_target(server)
    tier_name = tier or select_tier().tier

    if token is None:
        stored = load_secret(target, account=user or "fog-sdk", tier=tier_name)
        if stored:
            payload = parse_payload(stored)
            token = payload["token"]
            if user is None:
                user = payload.get("user")
        else:
            raise CredentialError(
                f"No token for {server}. Nothing is stored in the {tier_name} store "
                f"({select_tier().scope}), {ENV_TOKEN} is not set, and no token= was passed.\n"
                "This does not prompt: a library has no business doing that, and in a "
                "scheduled task a prompt hangs rather than fails.\n"
                "Issue a token from the API tab of a FOG user with API access enabled."
            )

    if supplied_token and save:
        save_secret(target, build_payload(server, token, user), account=user or "fog-sdk", tier=tier_name)

    cfg = fogsdk.Configuration(host=server.rstrip("/") + "/fog", access_token=token)
    return fogsdk.ApiClient(cfg)


def get_connection(server: Optional[str] = None, tier: Optional[str] = None) -> dict:
    """Report what is stored and which store holds it. Never the token.

    Mirrors Get-FgConnection, including reporting the store's scope: the OS
    stores are per-user by design, so a credential saved by one account is not
    readable by another, and that has to be visible rather than discovered.
    """
    t = select_tier() if tier is None else select_tier()
    info = {
        "Tier": tier or t.tier,
        "Scope": t.scope,
        "Note": t.note,
        "Server": None,
        "User": None,
        "AuthKind": None,
        "HasStoredToken": False,
    }
    if server:
        server = _normalise(server)
        stored = load_secret(store_target(server), tier=tier or t.tier)
        info["Server"] = server
        if stored:
            payload = parse_payload(stored)
            info["HasStoredToken"] = True
            info["User"] = payload.get("user")
            info["AuthKind"] = payload.get("authKind")
    return info


def disconnect(server: str, forget: bool = False, tier: Optional[str] = None) -> bool:
    """Forget the stored token for a server.

    Returns True if something was removed.

    This does **not** revoke anything. FOG deliberately exposes no
    token-management REST surface, so that one API credential cannot mint or
    destroy another; revocation is a UI action under the owning user's API tab.
    A token forgotten here stays valid until someone revokes it there.

    There is no session to clear, unlike the PowerShell side: the client object
    holds the configuration, so dropping the client is the disconnect.
    """
    if not forget:
        return False
    server = _normalise(server)
    return clear_secret(store_target(server), tier=tier or select_tier().tier)
