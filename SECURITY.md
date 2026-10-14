# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub:
**[Security → Report a vulnerability](https://github.com/sunkaramahesh09/airbridge/security/advisories/new)**.

Include what you found, how to reproduce it, and which versions are affected. You should
get a reply within 7 days. Fixes are released as soon as practical, and reporters are
credited unless they prefer otherwise.

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Scope

Especially welcome: weaknesses in the pairing and handshake protocol
(`protocol/SPEC.md`, `docs/security.md`), record encryption, path sanitising of incoming
file names, resume handling, and anything that lets an unpaired device connect or write
files.

The handshake is a custom construction from standard primitives (P-256 ECDH/ECDSA,
HKDF-SHA256, AES-256-GCM) and has **not been independently audited**. Review is appreciated.
