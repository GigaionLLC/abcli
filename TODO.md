# abctl — roadmap / TODO

`[x]` done · `[~]` in progress · `[ ]` todo. Context: [HANDOFF.md](HANDOFF.md) ·
design: [docs/design-abctl.md](docs/design-abctl.md).

## Shipped (don't redo)
- [x] **Auth** — ES256, `kid` omitted, token cache, 429/5xx backoff. Live-verified.
- [x] **Read** — `auth whoami`, `get {configurations,configuration,blueprints,blueprint,devices,audit}`
  (table + `--json`), `get configuration --profile`, `api`. Live-verified.
- [x] **Plan (Phase 1)** — `seed`, `validate`, `diff` + `sync --dry-run` (3-way plan). Live-verified.
- [x] **Engineering baseline** — Cobra, AGPL-3.0-or-later, race-tested unit + httptest suite, Makefile, golangci
  (v2), version ldflags.
- [x] **CI** — GitHub Actions: build/vet/race-test on **Linux + macOS**, golangci-lint v2, and a **gated
  read-only live integration test** (`TestLiveReadOnly`, `-tags=integration`) that self-skips without secrets.
- [x] **Phase 2 client write methods** — `Create/Update/DeleteConfiguration`, blueprint member add/remove
  (429-safe `rawWrite`). Not yet wired into an apply engine.

## Next — Phase 2 (gated apply)
- [x] **`internal/archive`** — `Write(root, name, reason, xml, meta, now)` →
  `gitops/archive/<name>/<UTC-ts>--<reason>.mobileconfig` + a JSON sidecar. Windows-safe timestamps (no
  colons); reasons `replaced` | `overwritten-by-newer` | `pruned`.
- [x] **`internal/reconcile/apply.go`** — `Engine` + injectable `Applier` / `Archiver` / `FileStore`
  interfaces + `Apply(plan, desired, live, baseline, opts) → *Result`:
  - `Create` → `POST`; `Update` / git-wins `Conflict` → **archive live, then `PATCH`**; `Pull`/`PullNew` →
    write the git file; `DeleteGit` → remove the git file; `DeleteABM` (only with `--prune`) →
    **archive live, then `DELETE`**. A failed archive **skips** the write it protects.
  - **newest-wins** for `Conflict`: live `updatedDateTime` vs the git commit/mtime (git wins ties); an
    unknown/unparseable timestamp **skips** the conflict rather than guessing.
  - mutates + (caller-)saves the committed baseline; per-item errors are isolated (one failure ≠ abort).
- [x] Wire **`sync --apply`** in `internal/cli`: dry-run default; plan-first; interactive confirm unless
  `--yes` (+ an `$ABCTL_APPROVE` escape for CI); `--prune` off by default; `--limit-writes N` circuit
  breaker; `--platforms` for creates.
- [x] **Unit-test `Apply`** with the injected interfaces + fakes (no production writes): every action,
  both conflict directions + tie + unresolved, prune gate, limit-writes, archive-fail-blocks-write, error
  isolation.
- [x] **First live write — DONE (2026-07-05).** After Included MDM was enabled in the console,
  `TestLiveWriteRoundTrip` passed live against the Gigaion, LLC tenant: create → download → update → download →
  delete a throwaway unattached `zz-*` config, `POST 201` / `PATCH 200` / `DELETE 204` / `GET 404`. Confirmed
  **live**: the raw `.mobileconfig` **GET round-trip is byte-identical** (drift-hash assumption holds), and
  the write response carries `updatedDateTime` (baseline stays exact). The API validator rejects an empty
  `PayloadContent` (`400 PARAMETER_ERROR.INVALID`) — profiles need ≥1 real payload.
- [x] **Live write (upload/download) integration test** — `TestLiveWriteRoundTrip`: create → download (GET
  round-trip, byte-identical hash) → update → delete a throwaway unattached `zz-*` config. Behind its **own**
  build tag (`integration_write`) + an explicit `ABCTL_LIVE_WRITE=1` opt-in, always cleans up, and a
  **strictly-gated** CI job (`integration-write`: `workflow_dispatch` + protected `live-write` environment +
  a dedicated **configurations-write-only** key `AB_*_WRITE`). Never attaches to blueprints/devices.
  *(EXECUTED LIVE 2026-07-05 — passed against the Gigaion, LLC tenant.)*
- [x] **Blueprint config-membership GitOps — WIRED.** `diff`/`sync` now reconcile each blueprint's
  CUSTOM_SETTING config membership (git-authoritative): `gitops.LoadBlueprints` reads `blueprints/*.yml`
  (yaml.v3), `ab.FetchBlueprints` resolves live membership to config names, `reconcile.ComputeBlueprints`
  plans **attach** (config in git, not ABM) / **detach** (in ABM, not git — gated `--prune`) / reports
  `blueprint-new` (git-only; create needs a console member) + `blueprint-adopt` (ABM-only; run `seed`), and
  `Engine.ApplyBlueprints` executes it (attach always, detach gated, `--limit-writes` shared with configs).
  Never touches native/console configs it doesn't own. Verified live 2026-07-05 (merge-additive) + unit-tested.
- [ ] Blueprint **create/update/delete** and **device/user/group membership** — still out. Create needs an
  identity member (console-managed) + content; device membership needs a **real test device** to confirm the
  reassignment / one-blueprint-per-device question (`testuser1` has 0 devices). Identity is API-read-only
  (`POST /users`,`/userGroups` → `403 does-not-allow-CREATE`), so members are always console-created.

## Phase 3 — CI/CD
- [x] **Live tests in CI** — read-only (`integration`) + gated write round-trip (`integration-write`) jobs
  ship; both self-skip without the repo's `AB_*` secrets.
- [x] **CD workflows** (`.github/workflows/cd-{plan,apply,drift}.yml`, guide in [docs/cicd.md](docs/cicd.md)):
  PR → `sync --dry-run` plan comment (exit-3 tolerated); gated `sync --apply` on merge behind a protected
  `production` environment + serialized concurrency + baseline commit-back; daily `--exit-on-diff` drift
  alert. Config reads from env vars in CI (no `.env`). All self-skip without secrets.
- [ ] A scheduled bidirectional **apply** that also **pulls console edits into git as commits** on a timer
  (the drift check *detects* it read-only; auto-committing the pulled edits back needs `abctl` to run
  `git add/commit` itself — still future; the merge-apply job commits the baseline back but not on a schedule).

## Imperative CLI + binary release — determined + built 2026-07-05
Full design + capability map + reconciliation model in **[docs/imperative-cli.md](docs/imperative-cli.md)**.
Same binary, two planes (GitOps + an imperative plane); full capability on the authoring/deploy/
assignment plane the API exposes; live device query / per-device MDM command / on-device install
verification are architecturally impossible and are scoped out honestly (no agent, no command channel).
- [x] **Phase 0 — foundation:** global `-o/--output json|yaml|table`; named-connection **contexts**
  (`abctl context …`, `~/.abctl/contexts.yaml`, `--context`/`$ABCTL_CONTEXT`, `.env` stays the CI
  path); `api` extended to write-gated `-X/-F/--input`; GoReleaser v2 (`.goreleaser.yaml` +
  `release.yml`, ldflags → `internal/cli.version`, cosign + provenance + SBOM). Cut **v0.1.0** to ship.
- [x] **Phase 1 — imperative config authoring:** `create|replace|edit|delete config` (reuse client +
  archive engine, inline tree+baseline mutation, `--no-write-tree` escape); `apply -f`/`delete -f`
  (incremental, versioned `abctl/v1` spec); `pull [config <name>]` for console-edit adoption.
- [~] **Phase 2 — deploy + assignment:** `attach|detach config --blueprint` (done); `status config`
  (coverage) + `status audit` (done — labeled desired-state/changelog, never install-verified).
  **Remaining, blocked on a live test device:** a `orgDeviceActivities` client method +
  `assign|unassign` + `status activity` (body shape + one-blueprint-per-device still unconfirmed).
- [~] **Phase 3 — glue + distribution + 1.0:** `get users|usergroups|apps|mdmservers` + client-side
  `--filter` (done). Remaining: completions/man pages; Homebrew Cask + Scoop live (need the tap/bucket
  repos + a token secret — templates in `.goreleaser.yaml`); **v1.0.0** once the write verbs are
  live-proven against the tenant.

## Later — enterprise polish
- [ ] **`--platform business|school`** (Apple School Manager uses `api-school` + `school.api`).
- [ ] `log/slog` structured logging + `--verbose`.
- [ ] macOS **Keychain** option for the key (not only a file path).

## Guardrails (every task)
Read-only by default · writes gated behind `--apply` + confirm · `--prune` off by default · dry-run first ·
never commit secrets · `make test` green.
