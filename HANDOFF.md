# HANDOFF — abctl

Everything a new maintainer or agent needs to pick up `abctl`. Roadmap: [TODO.md](TODO.md) ·
architecture: [docs/design-abctl.md](docs/design-abctl.md) · verified API reference:
[docs/auth.md](docs/auth.md) + [docs/endpoints/](docs/endpoints/) · app-provisioning research:
[docs/app-provisioning-research.md](docs/app-provisioning-research.md).

## What it is
A Go CLI + GitOps engine (by **Gigaion, LLC**) that syncs Apple Business built-in-MDM **Configurations**
(`CUSTOM_SETTING` `.mobileconfig` profiles) and **Blueprints** with a git-declarative desired state:
read-only by default, gated writes, bidirectional sync with newest-wins + archive-on-overwrite.

## Current state
**Built and live-verified (read-only):**
- **Auth** — ES256 client-assertion, `kid` omitted, `aud = …/v2/token`, `exp < iat+180d`, token cache,
  429/5xx backoff (Retry-After aware).
- **Read commands** — `auth whoami`; `get configurations|configuration|blueprints|blueprint|devices|audit`
  (table + `--json`); `get configuration --profile` (raw XML); `api` GET passthrough.
- **Plan (Phase 1)** — `seed` (live → `gitops/` tree + committed baseline via one `fields[]` list call),
  `validate` (pluggable via `$ABCTL_VALIDATOR`, else a built-in check), `diff` + `sync --dry-run` (the full
  3-way plan: git ↔ baseline ↔ live).
- **Engineering baseline** — Cobra CLI (help/completion/version), AGPL-3.0-or-later, race-tested unit + `httptest`
  suite (`internal/reconcile` 3-way matrix, ES256 sign/verify, client pagination/429/403, gitops, config,
  hash), Makefile, `.golangci.yml` (golangci-lint v2), version via ldflags.
- **CI** — GitHub Actions: build/vet/race-test on **Linux + macOS**, golangci-lint v2, and a **gated,
  read-only live integration test** (`internal/ab/integration_test.go`, `-tags=integration`) that self-skips
  when the `AB_*` repo secrets are absent.

**Built and unit-tested (Phase 2 — gated apply, config scope):**
- **Apply engine** — `internal/reconcile/apply.go` (`Engine` + injectable `Applier` / `Archiver` /
  `FileStore` interfaces) executes the plan: create / update / pull / delete-git / prune with
  **archive-before-overwrite**, **newest-wins** conflict resolution (git commit/mtime vs live
  `updatedDateTime`), a `--limit-writes` circuit breaker, per-item error isolation, and an exact baseline
  update. Fully unit-tested with fakes — **no live tenant or devices required**.
- **`internal/archive`** — files the pre-overwrite live version to
  `gitops/archive/<name>/<UTC-ts>--<reason>.mobileconfig` + a JSON sidecar. Timestamps are Windows-safe
  (no colons); reasons: `replaced` | `overwritten-by-newer` | `pruned`.
- **`sync --apply`** — wired in `internal/cli`: dry-run default, plan-first, interactive confirm unless
  `--yes` (or `$ABCTL_APPROVE` for CI), `--prune` off by default, `--limit-writes N`, `--platforms`. The
  config write methods (`Create/Update/DeleteConfiguration`) now return the server `updatedDateTime` so the
  baseline stays byte-exact without an extra GET.
- **Blueprint config-membership GitOps** — `diff`/`sync` also reconcile each blueprint's CUSTOM_SETTING
  config membership (git-authoritative): `gitops.LoadBlueprints` parses `blueprints/*.yml` (yaml.v3),
  `ab.FetchBlueprints` resolves live membership to names, `reconcile.ComputeBlueprints` +
  `Engine.ApplyBlueprints` plan/execute **attach** (git→ABM, always) / **detach** (ABM→git removal, gated
  `--prune`), reporting `blueprint-new` / `blueprint-adopt` for unmatched blueprints. Applies in two phases
  (configs first, so a just-created config resolves to an id for attach); `--limit-writes` is one shared
  budget. Never detaches a native/console config it doesn't own. Unit-tested, adversarially reviewed (7
  findings fixed), and **verified live end-to-end (2026-07-05)** via the real CLI: `seed` a `testuser1`
  blueprint → add a config to the manifest → `sync --apply` attaches it (blueprint shows 2 configs) → remove
  it → `sync --apply` (no `--prune`) leaves it (detach gated) → `sync --apply --prune` detaches it (1 config).

**Live-verified this session (2026-07-05) — client write + blueprint membership:**
- **Config CRUD** — `TestLiveWriteRoundTrip` ran live and passed: create→download→update→delete of a
  throwaway unattached `zz-*` config; byte-identical GET round-trip; `updatedDateTime` returned in the write
  response. See "Live tenant status" above.
- **Blueprint membership** — `TestLiveBlueprintMembership` ran live and passed (config relation, via a
  throwaway user). Confirmed create-needs-member+content and that `relationships` POST **merges**.

**Built and unit-tested (2026-07-09 — the API v2.0/v2.1 surface, branch `feature/abm-api-v2-surface`):**
Apple shipped API **v2.0 (2026-04-14)** and **v2.1 (2026-06-03)**; every endpoint contract below was pinned
verbatim from developer.apple.com's docs JSON (`applebusinessapi` slug). ⚠️ Two changelogs exist — the
developer.apple.com API changelog (v2.1) and the business.apple.com *Partner Guides* changelog (1.5.x);
only the first governs this API.
- **Detail reads** (`internal/ab/detail.go`, `internal/cli/inspect.go`): `get device` (assigned server via
  `orgDevices/{id}/assignedServer`, 404 = unassigned; `--applecare` via `…/appleCareCoverage`),
  `get mdmdevices|mdmdevice` (`/v1/mdmDevices` + `…/{id}/details` — built-in-MDM last-reported posture incl.
  FileVault/firewall/check-in/storage/lock/erase/lost-mode + `enrolledUserId`), `get user|usergroup
  [--members]|app|package|mdmserver [--devices]`, `get blueprint` resolving all six relationship collections,
  `status device <serial>` (blueprints containing it → their configs → posture), `-o csv` on list commands.
- **Writes, gated** (`internal/ab/manage.go`, `internal/cli/manage.go`): blueprint create/edit/delete
  (create **INLINES members** — a member-less POST 409s, live-verified 2026-07-05), `attach|detach` for
  `config|app|package|device|user|group`, `assign|unassign --server [--wait]` via `POST orgDeviceActivities`
  (`ASSIGN_DEVICES`/`UNASSIGN_DEVICES`), `status activity`, and MDM-server create/edit/delete (v2.1; Apple
  409s delete while devices are assigned).
- **GitOps membership for all six collections** — blueprint manifests take optional `apps:/packages:/
  devices:/users:/groups:` keys (absent = unmanaged, never touched; present = reconciled, detach gated
  `--prune`); git-only blueprints plan a real CREATE with resolvable members riding inside the POST (one
  write converges the blueprint); GitOps never deletes a blueprint; `seed --blueprint-membership` adopts
  live membership. Ambiguous member display names fail closed.
- **abgui Phase B** — Dashboard (stat tiles), Enrolled Devices screen, entity detail sheets (device/user/
  group/app/package/mdmserver/blueprint), search + sort + CSV export on every list, gated multi-select
  device Assign/Unassign sheet. Go↔Swift JSON contract reviewed (0 mismatches); macOS CI is the compile gate.
- **Upcoming visibility update (working tree, not committed)** — read-only GDMF OS-release client +
  `get os-releases`, opt-in `status device --releases` catalog comparison, six-hour/ETag cache, richer
  activity completion/result-log output with guarded CSV download, audit actor/type filters, and abgui OS
  Releases / device comparison / assignment-result / System Health / What's New surfaces. See
  `docs/upcoming-release.md`; macOS compile/visual QA and live GDMF/device-assignment checks remain release gates.
- **Users remain API-read-only** — no user/group write endpoints exist in v2.x (verified against the docs
  index); user lifecycle stays portal/SCIM-only and the tools say so.

**App-provisioning architecture research (2026-07-15; documented, not yet device-live-verified):**
- Apple Business became a free service with included device management on 2026-04-14; this did **not** make
  VPP newly free or require Apple to be an organization-wide "primary MDM." The supported `abctl` path is a
  portal-acquired app → `/v1/apps` → Blueprint `apps` plus `orgDevices`/`users`/`userGroups` relationships.
- Provisioning has separate acquisition, license-allocation, installation, and observation stages. Apple
  Business automates the last three through a Blueprint, but no published API acquires licenses or changes an
  app's automatic/manual installation setting. Detailed installed/pending/failed status remains in the portal;
  the API exposes only coarse `appLicenseDeficient` plus enrolled-device posture.
- Apps & Books v2 can associate a license to a literal serial or MDM-defined `clientUserId`, but association is
  **not installation**; an external MDM must then send `AppManaged` or `InstallApplication`. A secondary
  organizational unit and its own content token permit an isolated external-MDM lane, but that remains outside
  `abctl`'s product boundary. Never race the primary OU token with built-in management.
- Apple Business API **v2.2 shipped 2026-07-15** with read-only organizational-unit list/detail/user-
  relationship endpoints. They do not create OUs, transfer licenses, or manage content tokens, and are not yet
  implemented or live-verified here.

Full endpoint flows, identity mapping, coexistence rules, alternatives, evidence labels, and the safe first
device test are in [docs/app-provisioning-research.md](docs/app-provisioning-research.md). The quarantined VPP
protocol implementation remains documented separately in [docs/vpp-design.md](docs/vpp-design.md).

**Pre-sync verification + source-of-truth clarity (2026-07-25, working tree — not committed):**
- **`abctl validate` is now credential-free** and lives in `internal/cli/validate.go`: it roots the tree with the
  new `config.TreeDir(explicitContext)` (resolved `EnvDir` → nearest `.env` → cwd) instead of `config.Load()`, so
  checking local files works offline, in CI, and before a tenant is ever configured. `config.Load`/`Resolve` are
  unchanged for every other caller.
- **What it checks:** every `lib/` profile is parsed as an XML plist by a small `encoding/xml` walker (no new
  module deps) — `Configuration`/`PayloadContent`/`PayloadIdentifier` structure, the 1 MiB Apple cap,
  binary-plist / signed (DER) / malformed XML, and an identifier declared by two files (both are flagged);
  plus tree issues from `LoadBlueprints()` — a `configurations:` entry with no file in `lib/`
  (`missing-config`), an empty `lib/`, and files sync ignores. Warnings never fail a run. File selection goes
  through `Tree.LoadDesired`, so validate and sync can't disagree about which files are profiles.
- **`--json`** (and `-o json|yaml`; `-o csv` still rejected) emits the machine report. **Exit codes are
  unchanged** — 1 when `ok:false` — and the report prints on **stdout before** that exit so a GUI can decode it.
  `$ABCTL_VALIDATOR` keeps its stream-and-propagate behavior on the human path; on `--json` it runs *alongside*
  the built-in pass into `validator`/`validatorCommand`/`validatorExitCode`/`validatorOutput` (16 KiB cap) and a
  non-zero exit fails the report. New capability token `validate-json`.
- **abgui** — `Models/Validation.swift` (defensively decoded mirrors), `AbctlClient.validateProfiles()` (decodes
  stdout *first*, so a failing report is data, not a thrown error), `AppModel.validateProfiles()` +
  `Notice`/`post`/`dismissNotice`/`setGitSourceOfTruth`, and two new views: **Verify Configs** (`ValidateSheet`)
  and `GitSourceOfTruthControl` — a literal **ON**/**OFF** pill whose click only *stages* the change until a
  confirmation dialog spells out what the new mode does, then a `NoticeBanner` announces it. That dialog is
  presented from the **content** view, never from the toolbar item (macOS hosts toolbar items in a separate
  `NSToolbar` hierarchy where presentation is unreliable): the toolbar copy takes `isOn:` as a value, reads no
  environment, and stages into DiffView's `@State`, which `.gitSourceOfTruthConfirmation(pending:)` confirms and
  commits. Diff gains the Verify Configs toolbar button (queued-sheet hand-off into Apply); Apply gains a
  pre-flight row and an "Apply anyway" confirm **only** on a failed report, worded in *problems* — failing
  profiles **+** error-level tree issues **+** a non-zero `$ABCTL_VALIDATOR` exit, which is the third way a
  report goes `ok:false` with every file green. A failed `validateProfiles()` clears the old report rather than
  leaving a stale green light. Verification informs; it never blocks.
- **Tests:** `internal/cli/validate_test.go` (16 cases — per-code failures, duplicate identifiers,
  `missing-config`, warnings not flipping `ok`, empty slices marshaling as `[]`, JSON-still-printed-on-exit-1,
  credential-free `TreeDir`) plus five `ContractTests` additions (golden report, exit-1 decode, undecodable
  stdout → `AbctlError.cli`, argv/cwd, an older payload missing the newer keys). macOS CI is still the Swift
  compile gate.

**abgui shows the abctl commands it runs (2026-07-25, working tree — not committed; Swift only, no Go change):**
- **One recording seam.** `Backend/RecordingRunner.swift` is an `AbctlRunner` decorator
  (`init(wrapping:onStart:onFinish:)`) that `AppModel.makeClient(narrating:)` wraps around `ProcessRunner`, so
  every abctl call is captured at the single chokepoint it already passes through — verbs added later are
  recorded without anyone instrumenting them — and forwarded untouched (result and error unaltered).
  `AppModel` gained `commands` (append order, capped at 200 like the progress logs), `lastCommand`,
  `recordCommandStart` / `recordCommandFinish` (returns the closed record, so the caller prints *its* text) and
  `clearCommands()`. `makeClient(onProgress:)` became `makeClient(narrating:)`: one `Narration`
  (`.silent`/`.progress`/`.apply`) picks abctl's stderr sink and the command sink together via
  `commandSink(into:)`, so `$ abctl diff …`, abctl's narration and `→ exit 0 in 2.4s` land in ONE transcript.
- **One record type, one formatter.** `Models/CommandRecord.swift` holds the record plus `CommandFormatter`
  (`line`, `script(argv:cwd:stdin:)`, `redact`, `quote`) — the only argv→text conversion in the app, shared by
  the previews, the progress logs, the Command Log and every copy button. `Status` is
  `.running/.succeeded/.failed(code)/.cancelled/.timedOut`; the fifth case exists because abgui's own watchdog
  (`AbctlError.timedOut`) is not an abctl exit code and `exit -1` would read as a real result.
- **Secrets can't get in.** `CommandRecord.init` runs `CommandFormatter.redact(_:)` before storing argv (deny-list
  `redactedFlags` = `--vpp-token` today, both `--flag value` and `--flag=value`, value → `****`, idempotent);
  `--client-id`, `--key` (a path) and `--context` stay visible on purpose or the copied command won't run. stdin
  is recorded as a byte count only (`.profile(bytes:)`), and the copy form rewrites `-f -` to
  `./<name>.mobileconfig` plus a `#` note, since a pasted `-f -` waits forever on an empty terminal.
- **Preview/execute parity is structural.** `AbctlClient` grew pure `static` argv builders — `syncApplyArgs`,
  `planArgs`, `validateArgs`, `assignArgs`, `seedArgs` — that the instance methods now call and the sheets
  preview, so a view never re-spells a flag. **No argv changed.** `--context` is appended by the instance
  `argv(_:)` at run time and by `AppModel.previewArgv(_:)` in a preview — one tail per path.
- **Where it shows:** new `Views/CommandLogView.swift` carries `CommandPreview` (a quiet "Equivalent CLI" line +
  copy), `CommandLogView` (new sidebar page — **Overview**, after System Health, symbol `terminal`; newest-first
  rows with status icon/duration/workspace, per-row copy + context menu, **Copy All as Script** and **Clear**,
  `ContentUnavailableView` empty state), `CommandCopyButton` and `CommandClipboard`. `CommandPreview` sits in
  `ApplySheet` (passing the raw prune toggle — `AbctlClient.syncApplyArgs` is the single place git-as-truth
  forces `--prune` on, so the sheet and `AppModel.apply` cannot re-derive it differently), `ValidateSheet`
  (with the workspace cwd) and `AssignSheet`; `ConnectionFooter(showCommandLog:)` shows `lastCommand` and clicks
  through to the log. Read-only lists get no preview by design.
- **Tests:** `Tests/abguiTests/CommandRecordTests.swift` (16 cases — redaction in both spellings, "a raw token
  appears in no rendered form", quoting, `script()`/stdin rewriting, status + duration text, and the decorator's
  status mapping) plus six more `ContractTests`: each builder's argv against what a tapped runner actually
  received (sync/validate/assign, including `--context` appended exactly once), the decorator end-to-end
  (record == argv sent, cwd carried, `.succeeded` keyed to the record id), and two AppModel-level checks —
  ApplySheet's preview INPUTS against the apply path across the toggle matrix, and `previewArgv` threading the
  context exactly as the run does. macOS CI remains the compile gate.

**Built but NOT yet driven live / still gated out:**
- **The all-six-collection `sync --apply` path** — config upsert and configuration-membership orchestration
  ran live on 2026-07-05, but app/package/device/user/group reconciliation has not. The full engine is
  unit-tested; the remaining end-to-end check needs a portal-acquired test app and real enrolled test device.
- **The new v2 write verbs** — blueprint lifecycle, non-config membership sync, assign/unassign, MDM-server
  lifecycle: all unit-tested + gated, none has touched the tenant yet. Assign/unassign and non-config
  membership additionally need a **real test device** (`testuser1` has 0 devices). Apple documents that
  multiple Blueprints can target a device/user/group; live transport behavior still needs confirmation. The
  new read commands are safe to run anytime.

## Build / run / test
```sh
make build      # → bin/abctl (version injected via ldflags)
make test       # go test -race ./...   (the race detector needs a C compiler / CGO)
make lint       # golangci-lint
./bin/abctl --help
```
No production credentials are needed to build or test — the suite mocks the API with `httptest`.

## Credentials (you provide them; never committed)
`.env` and `secrets/` are gitignored and must stay that way.
1. Apple Business → **Settings > API** → create an API account; **download the private key once**.
2. `cp .env.example .env`; set `AB_CLIENT_ID` and `AB_PRIVATE_KEY` (a path to the key file). SEC1 or PKCS#8
   EC P-256 both work — abctl reads either, no conversion needed.
3. `abctl auth whoami` to verify. **No Key ID** — the JWT omits `kid` (a `kid` → `400 invalid_client`).
4. If the account was migrated from ABM/Essentials, grant it **View/Manage Blueprints** +
   **Create/edit device configurations** and regenerate the key (else `403`). If the org's built-in
   ("Included") MDM is not enabled, the Configurations/Blueprints endpoints return
   `403 …INCLUDED_MDM_NOT_ENABLED` — enable it in the console.

## Live tenant status (Gigaion, LLC org)
- **Auth: working** — `auth whoami` mints a token, `GET users` → 200 (`TestLiveReadOnly` passes).
- **Config CRUD: VERIFIED LIVE (2026-07-05).** Included MDM is now enabled in the console, so
  `/configurations` is live. `TestLiveWriteRoundTrip` passed against the tenant — create → download → update
  → download → delete a throwaway unattached `zz-*` config. Confirmed live: the raw `.mobileconfig` **GET
  round-trip is byte-identical** (drift hash is sound) and the **write response returns `updatedDateTime`**
  (baseline stays exact). The API validator rejects an empty `PayloadContent` (`400 PARAMETER_ERROR`) — a
  profile needs ≥1 real payload.
- **Blueprint membership: VERIFIED LIVE (2026-07-05).** Using a **console-created throwaway managed user**
  (`testuser1`; the API can't mint one — `POST /users` and `POST /userGroups` both `403 … does not allow
  'CREATE'`), `TestLiveBlueprintMembership` (`-tags=live_blueprint`, `ABCTL_LIVE_BLUEPRINT=1`) created a test
  blueprint → attached config A → attached config B → detached A → deleted everything. Confirmed:
  - **Blueprint create needs BOTH a member AND content** (`409 MISSING_RESOURCES` if content-only) — the docs
    previously captured only the member half.
  - **`relationships` POST MERGES (additive):** POST B to `{A}` → `{A,B}`; DELETE-with-body A → `{B}`. So
    abctl's `Add/RemoveBlueprintMembers` converge correctly. Blueprint `DELETE` → 204 (immediate).
  - Tested on the `configurations` relation with a member holding **0 devices** (nothing deploys). The
    device-side "does assigning a new Blueprint reassign a device away from its current one?" question still
    needs a real test device.
  - **Persistent test member:** `testuser1` (`testuser1@gigaion.appleid.com`, id `001173-10-501a55ca-…`) is
    intentionally kept in the tenant as the reusable throwaway blueprint member, so `TestLiveBlueprintMembership`
    (defaults to `ABCTL_TEST_USER=testuser1`) can be re-run any time. The stray `zz-abctl-test` custom role has
    been removed. Reminder: the API can't create/delete users or groups — that's console-only.

## What's next
**The native control plane is built; the main gap is a controlled app/device live test.**
Full breakdown in **[TODO.md](TODO.md)**. Short version:
1. **Run the first controlled app-to-device Blueprint test** — acquire one free test app in the portal, use a
   throwaway ADE device enrolled in built-in management, dry-run then attach the app and device, confirm
   `appLicenseDeficient == false` plus the portal/on-device result, then detach and clean up. The native app and
   non-config relationship code is unit-tested but has not yet touched a real managed device.
2. **Phase 3 CI/CD — SHIPPED.** Three GitOps workflows in `.github/workflows/cd-{plan,apply,drift}.yml`
   (guide: [docs/cicd.md](docs/cicd.md)): PR → `sync --dry-run` plan comment; gated `sync --apply` on merge
   behind a protected `production` environment (serialized, `ABCTL_APPROVE=1`, commits the baseline back with
   `[skip ci]`); daily `--exit-on-diff` drift alert. Config now falls back to env vars (`AB_*`) when there's
   no `.env`, so CI needs no `.env` file. All self-skip without secrets. To activate: adopt (un-ignore +
   commit) `gitops/`, set the `AB_*` Actions secrets, and create the `production` environment with reviewers.
   Remaining Phase 3: a *scheduled apply* that auto-commits pulled console edits back to git (needs `abctl`
   to run `git add/commit` itself — the merge-apply job already commits the baseline back, just not on a timer).
3. **Blueprint membership + device moves** — the code side shipped 2026-07-09 (all six collections + assign/
   unassign; see the v2 block above). Apple documents multiple Blueprint targets, resolving the conceptual
   one-Blueprint-only question; the commands still need their first live round-trip on a throwaway device.
4. **Live-verify the v2 write verbs** (blueprint lifecycle / non-config membership / MDM-server lifecycle)
   with throwaway resources, then update this file. The v2 read surface is safe immediately.

## Verified API facts (from live testing — trust these)
- Auth omits `kid`; `aud = …/oauth2/v2/token`; `exp` strictly `< iat + 180d`; bearer TTL 60 min.
- Only `CUSTOM_SETTING` configs are API-writable. `customSettingsValues.configurationProfile` is **raw XML**
  (not base64); `GET` round-trips it **byte-identically** → drift = raw SHA-256.
- The API validates uploads (malformed → `400 PARAMETER_ERROR.INVALID`; valid → `201`). Config CRUD:
  `POST 201` / `PATCH 200` / `DELETE 204`, `Content-Type: application/json`.
- **Blueprint create requires ≥1 `orgDevices`/`users`/`userGroups` member** (configs alone →
  `409 …MISSING_MEMBERS`). ⇒ there is **no harmless empty test Blueprint**; blueprint/membership ops always
  target real devices/users. Config CRUD on **unattached** configs deploys to nobody and is the safe test path.
- `relationships` POST is **additive (merge), confirmed live 2026-07-05 on `configurations`**; DELETE-with-body
  removes only the listed member. Continue converging via explicit per-member POST/DELETE. Transport behavior
  for app/device/user/group relationships remains unit-tested rather than live-verified.
- The API rate-limits aggressively — back off (the client is Retry-After aware); avoid rapid loops. Prefer
  one `fields[]` list call over N per-item GETs.

## Safety contract (do not break)
Read-only by default. Every write is gated behind `--apply` + confirmation. `--prune` is off by default.
Dry-run first, always. Never commit secrets. Keep `make test` green.
