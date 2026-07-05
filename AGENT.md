# AGENT.md — instructions for AI agents working on abctl

`abctl` is a Go CLI + GitOps engine for the **Apple Business API** (built-in MDM:
Configurations + Blueprints), developed by **Gigaion, LLC**. Agent-facing docs live in
this `AGENT.md` plus `docs/`.

## Read first (in order)
1. **[HANDOFF.md](HANDOFF.md)** — current state, what's done, what's next.
2. **[TODO.md](TODO.md)** — the roadmap.
3. **[docs/design-abctl.md](docs/design-abctl.md)** — the design (bidirectional sync, newest-wins, archive-on-overwrite).
4. **[docs/auth.md](docs/auth.md)** + **[docs/endpoints/](docs/endpoints/)** — the *live-verified* API reference.

## Hard rules
- **Read-only by default.** NEVER write to a production tenant without explicit human approval. All
  mutating ops are gated behind `--apply` + confirmation; `--prune` is off by default.
- **Never commit secrets** — `.env`, `secrets/`, private keys, tokens, and the generated `gitops/` tree
  are all gitignored. Keep it that way.
- **Keep it enterprise-grade / open-source-ready:** `gofmt` + `go vet` clean, `golangci-lint` passing,
  and **`make test` (race) green**. Add tests for behavior changes — especially `internal/reconcile`
  (the 3-way / newest-wins matrix) and anything touching auth.
- **The Apple Business API rate-limits hard.** The client backs off (Retry-After aware); do NOT hammer it
  in tight loops. Prefer one `fields[]` list call over N per-item GETs.
- The private key is **download-once** from Apple; treat it accordingly.

## Build / test
```sh
make build      # → bin/abctl (version injected via ldflags)
make test       # go test -race ./...
make lint       # golangci-lint
```

## Architecture (packages)
- `internal/ab` — API client: `auth.go` (ES256, omit kid, token cache, 429 backoff), `client.go`
  (read + write methods, typed errors, pagination).
- `internal/config` — `.env` loader.
- `internal/gitops` — the on-disk desired-state tree (`lib/` profiles, `state/` baseline, `archive/`).
- `internal/hash` — raw SHA-256 drift signal.
- `internal/state` — the committed sync baseline.
- `internal/reconcile` — the 3-way `Plan`; **`apply.go` (executor) is the next thing to build**.
- `internal/cli` — Cobra commands (thin wrappers over the packages above).

## When you change behavior
Update `docs/` + note it. Preserve the read-only-default, gated-write posture in every new command.
