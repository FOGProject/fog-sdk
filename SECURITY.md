# Security Policy

## Scope

`fog-sdk` contains the generated FOG API clients and the credential layer they
use to authenticate. Because it stores and transmits credentials, security
reports about this repository are treated with the same seriousness as reports
against the FOG server itself.

## Supported Versions

| Version | Supported |
| ------- | --------- |
| latest  | yes       |
| older   | no        |

The SDK is generated against a pinned snapshot of a FOG server's OpenAPI
document. See `spec/openapi/PROVENANCE.json` for the exact server commit and
version a given release was generated from.

## Reporting a Vulnerability - Private Disclosure Process

All security vulnerabilities or suspected vulnerabilities should be reported to
FOG Project privately, to minimize attacks against current users before they are
fixed.

Open a **private security advisory**:
https://github.com/FOGProject/fog-sdk/security/advisories/new

**IMPORTANT: Do not file public issues on GitHub for security vulnerabilities.**

Requests will be addressed within 7 business days, including a plan to
investigate and any workarounds available in the meantime.

Do not report non-security-impacting bugs through this channel. Use GitHub
issues instead.

## Credential handling in this SDK

Facts a reporter or auditor should know before filing:

- **API tokens are never written to the pipeline, to logs, or to `-Debug`
  output.** If you find a path that does, that is a vulnerability — report it.
- Tokens are held as `SecureString` in module state and unwrapped only inside
  the request pipeline step.
- At rest, credentials go to the best available OS store: Windows Credential
  Manager, macOS Keychain, or libsecret. A permissioned file is the fallback of
  last resort and is reported as such by `Get-FgConnection`.
- Credential Manager entries are written with `CRED_PERSIST_LOCAL_MACHINE`. They
  are deliberately **not** roaming — a credential replicated to a domain profile
  share is an exposure, not a convenience.
- The OS stores are **per-user by design**. A credential saved by one account is
  not readable by another. This is intended least-privilege behaviour, not a bug.

## What is not a vulnerability here

- A FOG bearer token acting with its owner's full roles. FOG tokens carry no
  scope of their own; least privilege is achieved with a narrowly-roled service
  account. This is documented server-side behaviour.
- The absence of token expiry or a refresh endpoint. FOG deliberately exposes no
  token-management REST surface, so that one API credential cannot mint another.
  Revocation is a UI action.
