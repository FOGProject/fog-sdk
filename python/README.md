# fogsdk (Python) — rough draft

A generated Python client for FOG, from the same `spec/` snapshot the
PowerShell client uses, plus the hand-written credential layer that shares a
store with it.

**Rough draft**: the client is `openapi-generator`'s vanilla output — no
FOG-specific naming and no opinion about how anyone would want to use it.

Package name on PyPI is `fogsdk`, following the same decision that made the
PowerShell module `FogSdk` rather than `FogApi`: this is the SDK, not the
friendly module built on it.

## Build

```powershell
./make.ps1 -Client python                # from the repo root
python/builders/make.ps1 -Target Verify  # or one stage
```

Stages: `Generate → Restore → Verify`.

- **Generate** — openapi-generator, pinned, into `python/src/` (gitignored).
- **Restore** — creates `python/.venv` and installs the generated
  `requirements.txt`. A repo-local venv, never your global site-packages:
  installing pydantic and urllib3 system-wide would be a rude side effect of
  running a build.
- **Verify** — imports **every** generated module, not just the package. A name
  collision or a bad enum shows up there and would not show up in a file count.

### Prerequisites

Node, and **Java** — openapi-generator is a JAR and the npm package only wraps
it. That is the one hard prerequisite the PowerShell client does not share.

Two version knobs, and they are not the same number: `-GeneratorVersion` is
openapi-generator (7.25.0), `-CliVersion` is the npm wrapper (2.41.0), which is
versioned separately. Pinning the npm package to a generator version fails with
`ETARGET`.

## What it produces

57 API modules, 170 model modules, all importing cleanly.

Methods are `<group>_<action>`: `host_list`, `host_get`, `host_create_task`,
`host_cancel_task`. That is the generator composing names mechanically from
`operationId`, and it is why this is a draft — nobody would choose
`host_create_task` for "start imaging this machine".

## Authentication works out of the box, unlike the PowerShell client

```python
import fogsdk

cfg = fogsdk.Configuration(host="https://fog.example.org/fog", access_token="fog_...")
with fogsdk.ApiClient(cfg) as client:
    hosts = fogsdk.HostApi(client).host_list()
```

This is a real difference between the two generators, not a detail.
**openapi-generator wired FOG's security schemes**: set `access_token` and
`bearerAuth` activates, sending `Authorization: Bearer <token>` raw. Verified
against a local listener — correct path, bearer not base64, zero legacy
`fog-api-token` / `fog-user-token` headers.

AutoRest could not do this. It knows three security schemes, all Azure's, and
does not support AND-ed requirements, so the PowerShell client needed an entire
hand-written pipeline layer to send one header. Here it is a constructor
argument.

## The credential layer

`fogsdk_auth/` is hand-written and lives **outside `src/`**, because `src/` is
the generator's scaffold and is wiped on every run.

It implements the same contract as the PowerShell SDK, so a token stored by
either is readable by the other:

```
target  : fog-sdk:<host>, lower-cased
payload : {"v":1,"server":...,"authKind":"bearer","token":...,"user":...}
```

Both reach the same OS store — Windows Credential Manager, macOS Keychain,
libsecret — via `keyring`, and fall back to the same file, in the same place,
with the same permissions, where none is available. That fallback matters more
than it sounds: a headless FOG server has no D-Bus session, which for an admin
working over SSH is the common case rather than an edge case.

The contract is asserted by `pwsh/tests/Interop.Tests.ps1`, which round-trips a
credential in both directions and checks the payloads are byte-identical. The
two SDKs share no code, so that test is the only thing preventing silent drift.

**One asymmetry, stated rather than papered over:** Python has no
`SecureString`. The token is a plain `str` in the process for as long as it is
held. Mitigation is limited to short-lived references and never logging it.

### Connecting

```python
from fogsdk_auth import connect
import fogsdk

with connect("fog.example.org") as client:
    hosts = fogsdk.HostApi(client).host_list()
```

`connect()` resolves in the same order as `Connect-FgServer`:

1. what you passed
2. the environment — `FOG_SDK_SERVER` / `FOG_SDK_TOKEN`
3. the credential store
4. an error

**It never prompts.** The PowerShell side has a hard no-prompt guarantee for
non-interactive sessions because a prompt there hangs rather than fails; a
library has no business prompting in any session. A token from the environment
is never persisted — setting a variable should not write a secret to the
machine.

`keyring` is a **required** dependency (`fogsdk_auth/requirements.txt`), not an
optional one. Its defensive import in `credentials.py` is a runtime fallback
for a headless server with no D-Bus session. Without it installed on Windows,
PowerShell picks Credential Manager while Python falls back to the file tier,
and the two stop sharing a store **without saying so** — a token saved by one
is simply invisible to the other.

## What else is deliberately missing

- **A friendly surface.** `host_create_task` is what the generator emits.
- **Packaging.** `pyproject.toml` and `setup.py` are the generator's own and
  have not been reviewed. Nothing has been published.
- **Tests for the client.** `python/src/test/` is the generator's empty
  scaffold. The credential layer is covered by the interop test above.

## Why a second client at all

`spec/` is the shared truth: one snapshot of FOG's OpenAPI document, one
provenance record, one set of upstream fixes. Every client generates from it.

Each of the defects found while getting the PowerShell client to build was a
defect in the document, not in the generator, and every one of them would have
broken a Python client the same way — bare-array responses, anonymous request
bodies, `operationId`s with no verb separator. The document is fixed once,
upstream, and every language benefits.

Read `spec/generators/README.md` before starting anything here. It records
which generator behaviours are input-driven and which are hard limits.

## Layout

```
python/
  builders/     ours: generate, restore, verify
  fogsdk_auth/  ours: the credential layer
  resources/    ours: anything shipped with the package
  src/          the generator's scaffold, regenerated freely, gitignored
  .venv/        created by Restore, gitignored
```

Anything hand-written lives **beside** `src/`, never inside it — `src/` is
wiped on every generation.
