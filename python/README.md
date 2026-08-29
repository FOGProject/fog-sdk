# fogsdk (Python) — in progress

The generated client is not written yet; the credential layer is — see below.
`fog-sdk` generates one client per language from a single shared `spec/`, and
`python/` mirrors `pwsh/`.

## Why a second client at all

`spec/` is the shared truth: one snapshot of FOG's OpenAPI document, one
provenance record, one set of upstream fixes. Every client generates from it.
Each of the defects found while getting the PowerShell client to build was a
defect in the document, not in the generator, and every one of them would have
broken a Python client the same way — bare-array responses, anonymous request
bodies, `operationId`s with no verb separator.

That is the argument for the layout: the document is fixed once, upstream, and
every language benefits.

## Intended shape

Mirrors `pwsh/`:

```
python/
  build.ps1 (or a Makefile)   ours: version, invoke the generator, package
  resources/                  ours: anything shipped with the package
  src/                        the generator's scaffold, self-contained
```

Our tooling sits outside the generator's output, so regeneration never
overwrites something hand-written. `src/` is regenerated freely; anything we
maintain lives beside it, not inside it.

## Before starting

Read `spec/generators/README.md` first. It records which generator behaviours
are inputs-driven and which are hard limits — several cost real time to find,
and at least three will apply to any generator, not just AutoRest:

- a bare top-level array response cannot be modelled
- `multipart/form-data` may not be generatable at all
- the base URL is baked in from `servers[0].url`, so generating from a live
  server's document is how a client learns which server it talks to

Package name on PyPI is `fogsdk`, following the same decision that made the
PowerShell module `FogSdk` rather than `FogApi`: this is the SDK, not the
friendly module built on it. `fogapi` would invite exactly the confusion the
naming split exists to avoid.

## What is written already

`fogsdk_auth/` — the credential layer, hand-written and **outside `src/`**,
because `src/` is the generator's scaffold and is wiped on every run.

It implements the same contract as the PowerShell SDK so a token stored by
either is readable by the other:

```
target  : fog-sdk:<host>, lower-cased
payload : {"v":1,"server":...,"authKind":"bearer","token":...,"user":...}
```

Both reach the same OS store — Windows Credential Manager, macOS Keychain,
libsecret — via `keyring`, and fall back to the same file, in the same place,
with the same permissions, where none is available. `keyring` is an optional
import: a headless FOG server usually has no D-Bus session, which is the common
case for this client rather than an edge case.

The contract is asserted by `pwsh/tests/Interop.Tests.ps1`, which round-trips a
credential in both directions and checks the payloads are byte-identical. The
two SDKs share no code, so that test is the only thing preventing silent drift.

**One asymmetry, stated rather than papered over:** Python has no
`SecureString`. The token is a plain `str` in the process for as long as it is
held. Mitigation is limited to short-lived references and never logging it.
