# Contributing to abctl

`abctl` is a GitOps CLI for the Apple Business API (built-in MDM: Configurations + Blueprints).

## Development
- Go 1.26+.
- `make build` · `make test` (race) · `make vet` · `make lint` (needs `golangci-lint`).
- **No production credentials are needed to build or test** — the suite mocks the API with `httptest` and never calls Apple.

## Guidelines
- Preserve the tenant-safety posture: **read-only by default**; every write is gated behind an explicit flag + confirmation.
- Add or adjust tests for behavior changes — especially the reconcile 3-way / newest-wins logic (`internal/reconcile`).
- Keep `gofmt` + `go vet` clean and pass `golangci-lint`.
- **Never commit** secrets, tokens, or a real `.env`/private key.
- Prefer stdlib; add a dependency only with a clear reason.

## Commits / PRs
- Focused commits with a clear rationale ("why", not just "what").
