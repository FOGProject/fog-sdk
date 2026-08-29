# fog-sdk

Generated API clients for [FOG Project](https://fogproject.org), in PowerShell
and Python, plus the hand-written authentication layer they need.

> **Status: under construction.** Nothing here is published yet.

## What this is

FOG 1.6 serves its own OpenAPI document from `/fog/system/openapi`, describing
the routes and models *that server* exposes — including any a plugin has added.
This repo pins a snapshot of that document and generates clients from it.

```
spec/        FOG's OpenAPI document, its provenance, the overlay, generator config
pwsh/        PowerShell client (AutoRest) + the credential layer
python/      Python client (openapi-generator)
```

## What this is not

This is not `FogApi`. [FogApi](https://github.com/darksidemilk/FogApi) is the
friendly, hand-written PowerShell module people actually use day to day —
`Get-FogHost`, `Send-FogImage`, and ~227 workflow functions built on top of a
FOG server. It builds *on* this SDK.

The SDK is the raw generated surface: every operation the server exposes, one
cmdlet each, named mechanically.

## Naming: everything here is `Fg`

Every cmdlet this SDK exports uses the `Fg` noun prefix.

```powershell
Get-FgHost          # SDK: raw, generated, one operation
Get-FogHost         # FogApi: friendly, hand-written
```

That is deliberate. The SDK must be safe to import alongside FogApi, or
alongside your own integration that already defines `Get-FogHost`. Two modules
cannot both export one name, and `DefaultCommandPrefix` does not rename binary
cmdlets — so a collision cannot be resolved at import time. A distinct prefix is
the only defence, and it follows the convention generated SDKs already use:
`Az` for Az, `Mg` for Microsoft Graph.

## Authentication

FOG 1.6 issues bearer API tokens from a user's API tab. They are `fog_`
prefixed, hashed at rest, shown once, and individually revocable.

```powershell
Connect-FgServer -Server https://fog.example.org -Token (Read-Host -AsSecureString)
```

The token is held as a `SecureString` and stored in the best credential store
your OS provides — Windows Credential Manager, macOS Keychain, or libsecret —
falling back to a permissioned file only where none is available.
`Get-FgConnection` reports which tier is in use and its scope.

Notes that surprise people, all of them intentional server-side behaviour:

- **There is no token endpoint.** The SDK cannot mint, refresh, or revoke a
  token; FOG deliberately exposes no token-management REST surface, so that one
  API credential cannot mint another. Issue and revoke tokens in the FOG UI.
- **Tokens do not expire**, and carry no scope of their own — a token acts with
  its owner's roles. For least privilege, give it a narrowly-roled service
  account.
- `Disconnect-FgServer` clears local state. It does **not** revoke anything.

**This SDK is bearer-only.** The older `fog-api-token` + `fog-user-token`
header pair still works against a FOG server and is not deprecated — but the
SDK is generated from a 1.6 document and cannot describe a 1.5 server, so
carrying a second credential shape would buy nothing.
[FogApi](https://github.com/darksidemilk/FogApi) serves those users.

## Generating

The generated output is not committed — it is reproducible from `spec/` and a
pinned generator version. See `spec/generators/README.md` for the build, every
generator limit found, and why each is handled where it is.

## Licence

MIT. See [LICENSE](LICENSE).

The generator emits Microsoft-copyright runtime code and its own `license.txt`
into the scaffold; those headers are retained verbatim.
