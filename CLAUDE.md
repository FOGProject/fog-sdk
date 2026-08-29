# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

`fog-sdk` owns three things:

1. **`spec/`** — a pinned snapshot of FOG's OpenAPI document, its provenance
   record, the overlay, and the generator configuration.
2. **The generated clients** — PowerShell via AutoRest, Python via
   openapi-generator (scaffolding only so far).
3. **The hand-written credential and authentication layer** the generated
   clients cannot produce for themselves.

[FogApi](https://github.com/darksidemilk/FogApi) builds on this SDK. It is a
consumer, not a co-owner. The generated surface is the raw one operation per
cmdlet; FogApi is the friendly hand-written module people use day to day.

## Build

```powershell
./make.ps1                    # all stages for the pwsh client
./make.ps1 -Target Compile    # one stage
./make.sh                     # Linux/macOS; finds pwsh and delegates
```

Stages: `Document → Generate → Compile → Merge → Surface → Help → Test`.

**`build-module.ps1` exits 0 when compilation fails.** It once reported success
with 333 compile errors. Never check its exit code — check for the artifact
(`pwsh/src/bin/FogSdk.private.dll`).

**Generating and compiling are different gates.** Generation "worked" for weeks
in the predecessor repo before anyone compiled the output.

**Strip ANSI escapes before grepping a build log.** Whether colour reaches the
log depends on how `pwsh` was invoked, and a pattern spanning a coloured
boundary stops matching — and a gate that stops matching reads as a pass.

**`$LASTEXITCODE` is not set by a PowerShell script invocation**, only by native
commands. `$null -ne 0` is true, so a naive check fails every successful build.

## Naming: everything exports `Fg`

`Get-FgHost`, `New-FgHostTask`, `Connect-FgServer`. Generated and hand-written
alike, no exceptions.

The SDK must never collide with `Get-FogHost` in FogApi or in a user's own
integration. Two modules cannot both export one name, and **`DefaultCommandPrefix`
does not rename binary cmdlets** — 0 of 164 across four configurations — so a
collision cannot be resolved at import time. The prefix is fixed at generation by
`prefix:` in `spec/generators/autorest-readme.md`, and changing it later means
regenerating *and* breaking every script that used the old names.

The module is `FogSdk`; the repo is `fog-sdk`. A hyphenated module name works
(verified) but reads as a cmdlet, and PowerShell's conventional separator is a
dot, not a hyphen.

## Things established by measurement, not assumption

Do not re-derive these. Each cost real time.

- **`--clear-output-folder` spares `custom/`** and wipes `generated/`. Verified
  with sentinel files. So `custom/` is safe for source that exists nowhere else.
- **`Module.AfterCreatePipeline` fires on every cmdlet invocation** with no
  `-HttpPipelinePrepend` argument, and its `SendAsyncStep` can rewrite the
  request host. That is how auth works here and how the base URL compiled in at
  989 call sites is made irrelevant. Verified against a local listener.
- **`SendAsyncStep` takes three arguments**, not four:
  `(HttpRequestMessage request, IEventListener callback, ISendAsync next)`.
- **A plain non-cmdlet helper class in `custom/` compiles fine.** The
  `[cmdletName]_[variantName]` naming in that folder's README applies to
  cmdlets, not to helper types.
- **`info.title` must not collapse to the same identifier as `namespace`.** A
  probe with both set to `Probe` generated `class Probe` inside `namespace
  Probe`, and every `Probe.Runtime.*` reference then failed — 114 errors in code
  nobody wrote. This repo is safe (`FOG Project API` → `FogProjectApi`, namespace
  `FogSdk`) but is one rename from not being.
- **`Get-Acl` then `Set-Acl` fails for a normal user** with
  `SeSecurityPrivilege`, because `Get-Acl` returns the whole security descriptor
  including the SACL. Read and write the Access section only via
  `FileSystemAclExtensions`. FogApi's six-invocation `icacls` fallback exists to
  work around exactly this.
- **A minimal probe document generates in seconds**, versus ~12 minutes for the
  full run. Use one before proposing a document fix or testing generator
  behaviour.

## Authentication

Bearer only. Tokens are issued in the FOG UI, `fog_` prefixed, hashed at rest,
shown once, individually revocable.

- **There is no token endpoint, deliberately** — a token-management REST surface
  would let one API credential mint another. So the SDK cannot mint, refresh, or
  revoke. `Disconnect-FgServer` clears local state only, and says so.
- **Bearer goes on the wire raw**; the legacy `fog-api-token` and
  `fog-user-token` headers are base64. A server-side test pins the distinction,
  because hex is itself valid base64.
- **Bearer short-circuits server-side.** Once presented it decides the request,
  so sending the legacy pair alongside it is dead weight that widens exposure.
- A token carries **no scope**; it acts with its owner's roles. Least privilege
  means a narrowly-roled service account with `uAPIOnly`.

## Credential storage

Windows Credential Manager → macOS Keychain → libsecret → permissioned file,
with DPAPI-NG (`NCryptProtectSecret`, SID descriptor) as an opt-in tier.

Rules with tests behind them:

- **`CRED_PERSIST_LOCAL_MACHINE`, never `ENTERPRISE`.** Enterprise roams the
  credential to the domain profile.
- **`LOCALAPPDATA`, never the roaming `APPDATA`.** FogApi's roaming store
  replicates its plaintext token to the profile share and every machine the user
  signs into, defeating its own file permissions.
- **No secret reaches the pipeline, a log, or `-Debug`.**
- **Never prompt in a non-interactive session.** A prompt there does not fail, it
  hangs until something kills it. Any test that could hang must be bounded by a
  timeout.
- **No LSA private data.** Microsoft: "Do not use the LSA private data functions
  for generic data encryption and decryption." Its DACL admits every local
  administrator and reading requires elevation.

## Tests

```powershell
Invoke-Pester -Path ./pwsh/tests
```

They dot-source `pwsh/src/custom/` directly and stub the generated attributes,
so the suite runs in seconds rather than after a full build. Nothing in it
contacts a FOG server.

**Never point anything at a production FOG server.** `New-FgHostTask` creates
real imaging tasks.

## Licensing

MIT. Every source file carries a licence header, and no file may be copied from
a source without an explicit licence — attribution is not a licence. P/Invoke
declarations transcribed from Microsoft's published documentation are fine; cite
the page in the header.

The generator emits Microsoft-copyright runtime code and its own `license.txt`
into the scaffold. Those are retained verbatim.

## Git

`main` is the default branch, `dev` is the integration branch, features branch
off `dev`. Never create a branch that tracks `origin/main` or `origin/dev` — a
bare `git push` then lands commits directly on the shared branch.

Commits are authored by the human and co-authored by the agent, never the other
way round. No model name anywhere in a commit message, PR title or body, or code
comment.
