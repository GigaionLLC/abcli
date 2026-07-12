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
- [x] **Blueprint create/update/delete + full membership — BUILT 2026-07-09** (unlocked by Apple's API v2.0,
  2026-04-14): imperative `create|edit|delete blueprint` (create INLINES members — Apple 409s a member-less
  create, live-verified 2026-07-05), `attach|detach` extended to `package|device|user|group`, and GitOps
  blueprint manifests now manage **all six collections** (optional `apps:`/`packages:`/`devices:`/`users:`/
  `groups:` keys; an absent key = unmanaged, never touched; git-only blueprints plan a real CREATE with
  resolvable members riding inside the POST). Users/groups themselves remain API-read-only (`POST /users` →
  `403`) — member identities are still console/SCIM-created. **Remaining live checks:** first end-to-end
  sync of the non-config collections against the tenant, and the one-blueprint-per-device reassignment
  question (still needs a real test device).

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
  `orgDeviceActivities` client + `assign|unassign --server [--wait]` + `status activity` are **BUILT
  2026-07-09** (unit-tested; ASSIGN_DEVICES/UNASSIGN_DEVICES body pinned from Apple docs).
  **Remaining, blocked on a live test device:** the first live assign/unassign round-trip.
- [~] **Phase 3 — glue + distribution + 1.0:** `get users|usergroups|apps|mdmservers` + client-side
  `--filter` (done). Remaining: completions/man pages; Homebrew Cask + Scoop live (need the tap/bucket
  repos + a token secret — templates in `.goreleaser.yaml`); **v1.0.0** once the write verbs are
  live-proven against the tenant.

## API v2 surface — shipped 2026-07-09 (branch `feature/abm-api-v2-surface`)
Apple's API v2.0 (2026-04-14) + v2.1 (2026-06-03) releases; endpoint contracts pinned verbatim from
developer.apple.com. Research + roadmap context: the ABMate/portal/API gap analysis (2026-07-09).
- [x] **Detail reads** — `get device <serial>` (assigned MDM server + `--applecare`), `get mdmdevices` /
  `get mdmdevice <serial>` (built-in-MDM enrolled devices + last-reported posture: FileVault, firewall,
  check-in, OS, storage, lock/erase/lost-mode, enrolled user), `get user|usergroup [--members]`,
  `get app|package`, `get mdmserver [--devices]`; `get blueprint` now resolves all six relationship
  collections to names; `status device <serial>` = assigned server + blueprints containing it + their
  configs + posture (labeled desired-state / last-reported).
- [x] **`-o csv`** on list commands (RFC-4180 quoting, spreadsheet formula-injection neutralized).
- [x] **MDM-server lifecycle (v2.1)** — `create|edit|delete mdmserver` (gated; Apple blocks delete while
  devices are assigned — the 409 is surfaced verbatim).
- [ ] **Live-verify the new write verbs** against the tenant (all unit-tested + gated; none has touched
  the tenant yet). Assign/unassign additionally needs the test device (above).
- [~] **abgui Phase B** — Enrolled Devices screen, entity detail inspectors, blueprint relationships,
  dashboard tiles, search/sort/CSV export on every list (in progress on this branch; macOS CI validates).
- Deliberately NOT built: third-party MDM integrations (Jamf/Intune/Kandji/Mosyle) and iTunes-lookup
  enrichment — out of scope per project direction (no third-party integrations).

## Later — enterprise polish
- [ ] **`--platform business|school`** (Apple School Manager uses `api-school` + `school.api`).
- [ ] `log/slog` structured logging + `--verbose`.
- [ ] macOS **Keychain** option for the key (not only a file path).

## Apple Device Services schema gap plan
Source inventory: `micromdm/apple-device-services` (hand-maintained JSON Schemas for ABM, Apps and Books,
legacy Device Assignment/DEP, and GDMF). Treat these schemas as test fixtures pinned to an upstream commit,
not as authoritative runtime API discovery; Apple documentation and live contract tests remain the source of
truth.

### A — finish the already-integrated ABM activity surface
- [x] Extend `status activity` table output with `completedDateTime` and the completed activity `downloadUrl`;
  preserve the full resource in JSON/YAML output.
- [x] Add response fixtures for every documented activity status/substatus.
- [x] Add an explicit, read-only `activity log <id>` (or `status activity <id> --download`) design: default to
  printing metadata/URL, require an explicit output path before downloading the presigned CSV, never execute
  links, and neutralize spreadsheet formulas when rendering it.
- [ ] Vendor the small ABM schema subset used by `orgDevices`, `mdmServers`, and `orgDeviceActivities` under
  testdata and validate request/response fixtures in CI. Pin source commit and retain MIT attribution.
- [ ] Live-verify assign and unassign with a throwaway device, including a partial/error result and the CSV log,
  before declaring the surface complete.

### Explicit non-goal — Apps and Books content-token/VPP client
- Do not enable the hidden VPP commands as a supported feature and do not add a GUI toggle. A content token
  connects an external MDM to an organizational unit; Apple warns that using an external token for the primary
  organization alongside built-in management can cause license inventory and app-assignment failures.
- Keep the existing implementation quarantined as developer/reference code for now. Manage apps through the
  modern Apple Business API catalog and Blueprint app relationships. Revisit removal of the hidden code before
  1.0; revisit product support only if the goal explicitly expands to external-MDM organizational units.

### C — add Apple software-release intelligence (GDMF)
- [x] Add a standalone read-only `internal/gdmf` client for `https://gdmf.apple.com/v2/pmv`, with timeout,
  conditional-cache support, bounded response size, schema-shaped types, and test base-URL override.
- [x] Add `abctl get os-releases` with platform, version/build, device-model, managed/public, RSR, and
  non-expired filters; support table/JSON/YAML/CSV consistently.
- [x] Enrich `get mdmdevice` / `status device` with an opt-in release comparison. Label it as catalog comparison,
  not proof that a particular update is eligible or installed.
- [x] Add stale/malformed catalog handling and fixtures for macOS, iOS, visionOS, RSRs, missing expiration dates,
  and unknown future platforms. GDMF failure must not break ordinary device inspection.
- [x] Add an abgui read-only OS Releases view only after the CLI JSON contract is stable.
- [x] Add abgui device-posture catalog comparison, assignment-result links, System Health, and What's New views.

### Explicit non-goal — legacy Device Assignment (DEP) provider
- Do not implement the Device Assignment/DEP service in `abctl`. Apple still documents Automated Device
  Enrollment, but this protocol is the server side used by third-party MDM products: it requires separate
  credentials/protocol headers and enrollment-profile hosting, device command, and lifecycle responsibilities.
  It does not extend Apple Business built-in MDM.
- `abctl` already uses the appropriate Apple Business API surfaces for organization devices, device-management
  service assignment, Blueprints, and built-in-MDM enrolled-device posture. Keep those as the supported path.
- Reconsider DEP only if the product explicitly expands into building/operating a standalone MDM server; that
  should be a separate project or provider with its own security model, not an `abctl` command namespace.

### Recommended delivery order
1. A (small, completes existing device-assignment UX).
2. C (largest new read-only benefit with no tenant-write risk).

## Guardrails (every task)
Read-only by default · writes gated behind `--apply` + confirm · `--prune` off by default · dry-run first ·
never commit secrets · `make test` green.
