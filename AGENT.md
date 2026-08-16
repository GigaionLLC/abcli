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
- **Product boundary:** automate modern Apple Business/School Manager APIs and Apple Business built-in MDM,
  not third-party MDM services. A request to implement “all Apple APIs” does **not** authorize legacy Device
  Assignment/DEP server support or the Apps and Books content-token/VPP client. DEP/ADE server APIs make the
  product an MDM server; content tokens connect an external MDM and can conflict with built-in-management app
  inventory. Keep DEP out of scope and keep the existing VPP code hidden with no GUI enable flag unless a human
  explicitly changes the product goal to external MDM support. See `docs/design-abctl.md`.

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

## The GUI (two trees, one of them frozen)
- **`abgui-flutter/`** — the cross-platform desktop app (macOS/Windows/Linux). **All GUI work goes here.**
  Dart package name is `abgui`, so imports are `package:abgui/...`. Build: `make gui-check` / `gui-test`
  (anywhere, or `./tool/flutter.sh` in Docker) and `make gui-macos|gui-windows|gui-linux` (each on its own
  platform — Flutter does not cross-compile desktop).
- **The SwiftUI app is gone.** It was deleted at v0.4.28 once the Flutter app reached parity. If you need the
  original — it remains the historical reference for behaviour — read it out of git history at tag `v0.4.27`
  (`git show v0.4.27:abgui/...`). Do not resurrect it.
- Read **[docs/abgui-flutter-port.md](docs/abgui-flutter-port.md)** before touching either. It records what
  the port must not get wrong, what regresses, and the cutover checklist.
- **The safety-critical rule for the port:** `abctl_args.dart` and its contract test come BEFORE any UI, and
  `sync --apply` is not armed in the Flutter app until the `--prune` coupling, the decode-before-exit-code
  rule, and the previewed-argv-equals-executed-argv invariant each have a Dart test.
  The Swift `ContractTests.swift` was the specification; its assertions now live in
  `abgui-flutter/test/abctl_args_contract_test.dart` and `test/write_safety_test.dart`, which are the
  specification now. A source-scanning test also forbids `--prune` outside `abctl_args.dart`, so the
  invariant survives its author.

## When you change behavior
Update `docs/` + note it. Preserve the read-only-default, gated-write posture in every new command.
