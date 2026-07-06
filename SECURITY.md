# Security Policy

## Reporting a vulnerability
Please report security issues **privately** (email the maintainers) rather than opening a public issue,
and allow reasonable time for a fix before disclosure.

## How abctl handles secrets
- Authentication uses an **ES256 client assertion** (a P-256 private key) exchanged for a short-lived
  (60-minute) bearer token. **Neither the key nor the token is ever logged.**
- The private key and `.env` are kept **out of version control** (gitignored `secrets/` + `.env`); the
  cached bearer is written `0600` to a stable per-credential file under the user cache dir (`~/Library/
  Caches/abctl/` on macOS, falling back to `~/.abctl/`), keyed by client id — so it persists regardless of
  working directory (a GUI has no control over its cwd) instead of re-minting a token on every call.
- The JWT deliberately omits `kid` (Apple resolves the key by client ID + signature).

## Operating posture
- `abctl` targets a **production** MDM tenant. It is **read-only by default**; all mutating operations
  are gated behind explicit flags (`--apply`) plus confirmation, with a dry-run plan shown first.
- Destructive pruning is off by default and separately opt-in (`--prune`).
