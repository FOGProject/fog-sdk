"""Hand-written runtime pieces for the fog-sdk Python client.

Deliberately OUTSIDE python/src/, which is the generator's scaffold and is
wiped on every run. Anything hand-written lives beside it, never inside it.
"""

from .client import (  # noqa: F401
    ENV_SERVER,
    ENV_TOKEN,
    connect,
    disconnect,
    get_connection,
)
from .credentials import (  # noqa: F401
    PAYLOAD_VERSION,
    CredentialError,
    StoreTier,
    build_payload,
    clear_secret,
    load_secret,
    parse_payload,
    save_secret,
    select_tier,
    store_file,
    store_target,
)
