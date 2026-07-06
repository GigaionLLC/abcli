# HANDOFF — abctl

Everything a new maintainer or agent needs to pick up `abctl`. Roadmap: [TODO.md](TODO.md) ·
architecture: [docs/design-abctl.md](docs/design-abctl.md) · verified API reference:
[docs/auth.md](docs/auth.md) + [docs/endpoints/](docs/endpoints/).

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

**Built but NOT yet driven live / still gated out:**
- **The `sync --apply` orchestration** — the apply *engine* (plan→confirm→Apply→save baseline) is unit-tested
  with fakes and calls the now-live-verified client methods, but the **full CLI apply flow has not itself
  been driven against a real tenant** (would need a seeded `gitops/` tree). The pieces are proven; the
  end-to-end CLI run is the remaining live check.
- **Blueprint create/update/delete + device/user/group membership** — still out of the engine. Create needs
  an identity member (console-managed) + content; device membership needs a real test device to confirm the
  reassignment / one-blueprint-per-device question (`testuser1` has 0 devices). Config-membership reconcile
  (above) is wired; these remain future work.

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
**Phase 2 gated apply (config scope) is built + unit-tested; exercising it live is blocked on tenant setup.**
Full breakdown in **[TODO.md](TODO.md)**. Short version:
1. **Enable Included MDM** in the Apple Business console, then **run the first live config write** — either
   `abctl sync --apply` against a seeded tree, or the opt-in `TestLiveWriteRoundTrip` — to confirm the
   create/update/delete path + byte-identical GET round-trip end-to-end, then stop. (Blocked today by the
   403 above.)
2. **Phase 3 CI/CD — SHIPPED.** Three GitOps workflows in `.github/workflows/cd-{plan,apply,drift}.yml`
   (guide: [docs/cicd.md](docs/cicd.md)): PR → `sync --dry-run` plan comment; gated `sync --apply` on merge
   behind a protected `production` environment (serialized, `ABCTL_APPROVE=1`, commits the baseline back with
   `[skip ci]`); daily `--exit-on-diff` drift alert. Config now falls back to env vars (`AB_*`) when there's
   no `.env`, so CI needs no `.env` file. All self-skip without secrets. To activate: adopt (un-ignore +
   commit) `gitops/`, set the `AB_*` Actions secrets, and create the `production` environment with reviewers.
   Remaining Phase 3: a *scheduled apply* that auto-commits pulled console edits back to git (needs `abctl`
   to run `git add/commit` itself — the merge-apply job already commits the baseline back, just not on a timer).
3. **Blueprint membership + device moves** — blocked twice over (Included-MDM 403 **and** 0 devices). Needs
   a throwaway test device before `relationships` replace-vs-merge can be confirmed safely; do NOT probe it
   against real users/groups.

## Verified API facts (from live testing — trust these)
- Auth omits `kid`; `aud = …/oauth2/v2/token`; `exp` strictly `< iat + 180d`; bearer TTL 60 min.
- Only `CUSTOM_SETTING` configs are API-writable. `customSettingsValues.configurationProfile` is **raw XML**
  (not base64); `GET` round-trips it **byte-identically** → drift = raw SHA-256.
- The API validates uploads (malformed → `400 PARAMETER_ERROR.INVALID`; valid → `201`). Config CRUD:
  `POST 201` / `PATCH 200` / `DELETE 204`, `Content-Type: application/json`.
- **Blueprint create requires ≥1 `orgDevices`/`users`/`userGroups` member** (configs alone →
  `409 …MISSING_MEMBERS`). ⇒ there is **no harmless empty test Blueprint**; blueprint/membership ops always
  target real devices/users. Config CRUD on **unattached** configs deploys to nobody and is the safe test path.
- `relationships` replace-vs-merge is **unconfirmed** → always converge membership via explicit per-member
  POST / DELETE-with-body.
- The API rate-limits aggressively — back off (the client is Retry-After aware); avoid rapid loops. Prefer
  one `fields[]` list call over N per-item GETs.

## Safety contract (do not break)
Read-only by default. Every write is gated behind `--apply` + confirmation. `--prune` is off by default.
Dry-run first, always. Never commit secrets. Keep `make test` green.
