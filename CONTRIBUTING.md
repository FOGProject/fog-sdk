# Contributing to fog-sdk

Thanks for considering a contribution.

This repository follows the FOG Project's general contribution guidelines. Read
those first: https://github.com/FOGProject/fogproject/blob/master/CONTRIBUTING.md

What follows is only what is different about this repo.

## What this repo is

`fog-sdk` owns three things:

1. **`spec/`** — the pinned snapshot of FOG's OpenAPI document, its provenance
   record, the overlay, and the generator configuration.
2. **The generated clients** — PowerShell (AutoRest) and Python
   (openapi-generator), generated from that document.
3. **The hand-written credential and authentication layer** the generated
   clients cannot produce for themselves.

`FogApi` builds on this SDK. It is a consumer, not a co-owner.

## The generated code is not committed

Generated client output is gitignored. Only the generator configuration, build
scripts, and hand-written code are tracked. Do not commit generated output, and
do not hand-edit it — a regeneration will discard the edit.

If generated output is wrong, the fix is almost always in the OpenAPI document
upstream in `FOGProject/fogproject`, not in a post-processing step here. Several
defects found while building this SDK were document defects that would have
broken any generator.

## Naming: everything exports `Fg`

Every cmdlet this SDK exports — generated or hand-written — uses the `Fg` noun
prefix: `Get-FgHost`, `Connect-FgServer`.

This is deliberate and not negotiable in a PR. The SDK must never collide with
`Get-FogHost` in `FogApi` or in a user's own integration. Two modules cannot both
export one name, and `DefaultCommandPrefix` cannot rename binary cmdlets, so
there is no way to resolve a collision at import time. The prefix is the only
defence and it is fixed at generation.

## Credentials

Changes touching the credential layer need to hold these, and there are tests
asserting each:

- No secret reaches the pipeline, a log, or `-Debug` output.
- **Bearer only.** The SDK is generated from a 1.6 document and cannot describe
  a 1.5 server, so it does not carry the legacy `fog-api-token` +
  `fog-user-token` pair. Those headers still work against a FOG server and are
  not deprecated — FogApi serves those users. Do not add a second credential
  shape here without changing the Python contract to match.
- Bearer goes on the wire **raw**, not base64. The legacy headers are base64
  and bearer is not; a server-side test pins the distinction, because hex is
  itself valid base64 and the two would otherwise be indistinguishable.
- Windows Credential Manager writes use `CRED_PERSIST_LOCAL_MACHINE`, never
  `ENTERPRISE`.
- Nothing prompts in a non-interactive session. A prompt there does not fail, it
  hangs until something kills it.
- Every cmdlet the SDK exports is `Verb-Fg*`, hand-written ones included.

## Licensing

This repo is MIT. Every source file must carry a licence header, and no file may
be copied from a source without an explicit licence — attribution is not a
licence. P/Invoke declarations transcribed from Microsoft's published API
documentation are fine; cite the documentation page in the header.

Note the generator emits Microsoft-copyright runtime code and its own
`license.txt` into the scaffold. Those headers are retained verbatim.
