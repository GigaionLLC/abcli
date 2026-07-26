# abctl — design & architecture

`abctl` is a GitOps CLI and reconcile engine for the **Apple Business API** (built-in MDM:
**Configurations** + **Blueprints**), developed by **Gigaion, LLC**. It keeps a git-declarative
desired state in sync with a live Apple Business tenant — read-only by default, every write gated.

For current build status see [HANDOFF.md](../HANDOFF.md); for the roadmap see [TODO.md](../TODO.md);
for the verified API reference see [auth.md](auth.md) and [endpoints/](endpoints/); for the app-provisioning
decision and API-option research see [app-provisioning-research.md](app-provisioning-research.md).

### Product boundary: Apple Business itself, not an external MDM

`abctl` automates the modern Apple Business and Apple School/Business Manager APIs and the built-in
Apple Business device-management service. “Support all APIs” always means all applicable, supported APIs
inside that boundary; it does not mean implementing every protocol Apple publishes for MDM vendors.

- Use the Apple Business API for organization devices, device-management services, Blueprints,
  configurations, apps, packages, users/groups, audit events, and built-in-MDM enrolled-device posture.
- Use modern adjacent Apple services only when they complement Apple Business without taking ownership away
  from its built-in device-management service (for example, the read-only GDMF software-release catalog).
- Do **not** implement the legacy Device Assignment/DEP server protocol. Automated Device Enrollment remains
  a current Apple feature; “legacy” describes the DEP name/API lineage, not a feature Apple is about to remove.
  That protocol exists so a third-party MDM server can fetch assigned devices and host/assign enrollment
  profiles. Implementing it would turn `abctl` into an MDM server, with different credentials, device command
  channels, enrollment hosting, and security/lifecycle duties. The modern Apple Business API surfaces already
  cover the assignment and built-in-MDM workflows this project needs.
- Do **not** use an Apps and Books content token for the primary organizational unit managed by Apple Business
  built-in device management. Apple documents content tokens as the link to an external MDM and warns that a
  token left with an external service while enabling built-in management can cause license inventory and app
  assignment failures ([Apple: Manage content tokens in Apple Business](https://support.apple.com/guide/business/manage-content-tokens-axme0f8659ec/web)).
  Manage apps through Apple Business API app resources and Blueprint relationships.
- Apple does permit an external management service to use a content token from an **additional organizational
  unit** containing transferred unassigned licenses. This means built-in and external management can coexist
  in isolated pools; it does not authorize `abctl` to manage that external lane. Never let two clients race the
  same token/pool or assume a secondary external pool supplies built-in Blueprint installation.

These are durable exclusions. A future request to “integrate every Apple API” must preserve them unless the
product goal explicitly changes to an external-MDM integration or standalone MDM, which should have a separate
security and ownership model.

> **Ground truth (verified live 2026-07-04).** Auth = OAuth2 client-assertion, **ES256, `kid` omitted**
> (Client ID + signature suffice); `aud = …/oauth2/v2/token`; bearer TTL 60 min. `/v1/configurations`
> is full CRUD, but **only `CUSTOM_SETTING` (raw `.mobileconfig`) is API-writable**;
> `customSettingsValues.configurationProfile` is **raw XML** and `GET` round-trips it byte-for-byte
> (so drift detection is a plain SHA-256). Each config carries `createdDateTime`/`updatedDateTime`.
> `/v1/blueprints` is CRUD + membership via `/relationships/<orgDevices|configurations|…>`
> (per-member POST add / DELETE-with-body). Deploying a profile is **two phases** (create the config
> resource, then attach it to a Blueprint). A blueprint **create requires both a member** (`orgDevices`/
> `users`/`userGroups`) **and content** (`apps`/`packages`/`configurations`). `relationships` POST is
> **additive (merges)** — verified live 2026-07-05 — so converge membership per-member (POST to add,
> DELETE-with-body to remove). The target is a **production** tenant; the private key is download-once.

## 1. Sync model
- **Bidirectional — both sides authoritative.** Edit in git *or* in the Apple Business console; `sync`
  reconciles both directions.
- **Conflict policy = newest-wins.** If the same config changed in *both* places since the last sync, the
  more-recently-edited side wins: compare the live `updatedDateTime` against the git file's **commit time
  when the `gitops/` tree is committed** (authoritative across machines), else its filesystem **mtime**.
  Because the tree is gitignored by default (§4), the mtime path is what's used until you adopt it; on a
  committed tree a *clean* file uses its commit time and a *dirty* (uncommitted) edit uses its mtime, so a
  local edit isn't stamped with a stale commit time. This compares two clocks — keep the hosts roughly
  NTP-synced.
- **Committed baseline** `state/sync-state.json` (committed to git, not ignored) records, per config name
  (the map key), `{id, hash, updatedDateTime}` as of the last successful sync. It is load-bearing: it is
  the only way to tell *which* side changed and to distinguish an add from a delete. A one-way "git wins"
  model wouldn't need it; bidirectional does. (The git-side time used for newest-wins is derived on demand
  from `git log` / mtime — see above — not stored in the baseline.)
- **Archive-on-overwrite** (the audit safety net). Git already versions git-side edits, but a **console**
  edit that loses a conflict (or is pruned) would otherwise vanish. So **before overwriting or deleting any
  live config, download the current live version and commit it to `archive/`** with name + timestamp +
  reason. The result is a permanent, greppable record of every live state that was ever replaced.

## 2. Apple Business constraints that shape the engine
Apple Business's built-in MDM differs from a typical declarative MDM in ways that drive the design:

| # | Constraint | Consequence |
|---|---|---|
| **C1** | A Configuration is **tenant-global**; it deploys only once **attached to a Blueprint** | reconcile has an explicit **Phase 2 membership** pass, separate from config upsert |
| **C2** | A config is **many-to-many** with Blueprints | the business key is the config **`name`** alone; each `.mobileconfig` is stored **once** in `lib/`, referenced by path |
| **C3** | There are **no config-level labels/scoping** | fine-grained targeting = Blueprint `orgDevices`, `users`, and `userGroups` relationships |
| **C4** | The API has **no batch reconcile endpoint** — only per-resource POST/PATCH/DELETE | **`abctl` is the reconcile engine** (client-side plan + apply) |
| **C5** | **Only `CUSTOM_SETTING` is writable**; the ~22 native config types are read-only | manage/prune scope = **only the `CUSTOM_SETTING` configs abctl owns**; never touch native/console-only configs |
| **C6** | A write can be **accepted (`2xx`) and silently not persisted** — Apple answers the `POST`/`PATCH`, then discards a profile that violates its schema (top cause: a top-level `PayloadVersion` ≠ 1) | the executor **reads the config back** after every write and records the baseline from what Apple *stored*, never from what was sent; `validate` fails the profile before it is ever pushed |

Plus: **`relationships` POST is additive (merges) — verified live 2026-07-05** → converge membership via
explicit per-member POST (add) / DELETE-with-body (remove), never a wholesale `relationships` block.

## 3. CLI surface
```
abctl
├── auth whoami                     # mint a token + a cheap GET (verifies auth + tenant reachability)
├── get                             # read-only; table by default, --json for machine output
│   ├── configurations              # (alias: configs)
│   ├── configuration <name|id> [--profile]     # --profile dumps the raw .mobileconfig XML
│   ├── blueprints | blueprint <name|id>        # (alias: bp)
│   ├── devices                     # orgDevices: serial, family, current blueprint
│   └── audit                       # CONFIG_SETTINGS_* audit events
├── seed                            # bootstrap: download the live tenant → gitops/ tree + committed baseline
├── validate                        # validate the gitops/ profiles ($ABCTL_VALIDATOR, else a built-in check)
├── diff [--git-source-of-truth] [--refresh smart|full|metadata-only]
├── sync [--dry-run(default)] [--apply] [--git-source-of-truth] [--prune] [--yes]
│       [--limit-writes N] [--refresh smart|full|metadata-only] [--verify targeted|full|none]
├── api <path>                      # raw authenticated GET (escape hatch)
└── version | completion | help
```
Output/exit: data → stdout, diagnostics → stderr; `--json` for machine mode; exit `0` ok · `1` error ·
`2` usage · **`3` = changes pending** (with `--exit-on-diff`, for CI gating). On `403` from
blueprints/configurations, abctl prints the "grant View/Manage Blueprints + Create/edit device
configurations, then regenerate the key" hint.

## 4. On-disk layout (the `gitops/` tree)
```
gitops/
├── lib/…/<name>.mobileconfig       # the CUSTOM_SETTING sources — each profile stored ONCE, keyed by name
├── state/sync-state.json           # COMMITTED baseline: name → {id, hash, updatedDateTime}
└── archive/<name>/<UTC-timestamp>--<reason>.mobileconfig (+ .json sidecar)
                                    # pre-overwrite live versions (reason: overwritten-by-newer | pruned | replaced)
```
- **Config identity** = `name` (the profile's `PayloadDisplayName`, parsed; falls back to the filename
  stem). Duplicate names across the tree are a hard error. The filename is cosmetic.
- The `gitops/` tree is generated by `seed` and is **gitignored by default** (seeded profiles can carry
  secrets); un-ignore it deliberately once you adopt it as your committed source of truth. **`archive/`
  stays gitignored even then** — it holds pre-overwrite *live* profile bodies that can carry tenant secrets,
  so it is a local / CI-artifact audit trail, never committed to git history (CI uploads it as an expiring
  build artifact). Un-ignore `archive/` only if you explicitly accept committing live secrets.

## 5. Reconcile algorithm (3-way, newest-wins)
Per managed `CUSTOM_SETTING` config, using the committed baseline:
```
gitChanged  = hash(git file) != baseline.hash
liveChanged = live.updatedDateTime > baseline.updatedDateTime  OR  hash(live) != baseline.hash

  gitChanged & !liveChanged   → PUSH    git → live   (PATCH; archive the live version first)
 !gitChanged &  liveChanged   → PULL    live → git   (write the file)
  gitChanged &  liveChanged   → CONFLICT → newest-wins:
        gitTime(git) >= updatedDateTime(live) ? PUSH (archive first) : PULL
        (gitTime = commit time on a clean committed tree, else file mtime — see §1)
 !gitChanged & !liveChanged   → no-op
  in baseline, gone from git   → DELETE from live   (archive first)   [only with --prune]
  in baseline, gone from live  → delete the git file
  new in git,  not in baseline → CREATE on live
  new in live, not in baseline → PULL into git   (captures a console-created config)
```
> **Phase 2 (current) writes only to disk** — Pull/PullNew write `lib/` files, DeleteGit removes them,
> overwrites go to `archive/`, and the baseline is saved to `state/sync-state.json`. It does **not** run
> `git add`/`git commit`; the operator or CI commits the resulting tree. Auto-committing pulled console
> edits (the "someone edited the portal" path) is Phase 3 (see [TODO.md](../TODO.md)).
**Ordering per run:** pre-flight (load tree, parse names, validate, GET live index + blueprint linkages,
build the plan) → config upsert (create/update, **archive before any overwrite**) → attach (per-member
POST) → detach (per-member DELETE-with-body) → target membership (**last**, so new targets never land in a
Blueprint whose content/configs aren't attached yet) → prune (off by default; detach then DELETE; archive first;
only configs abctl owns) → verify (GET round-trip hash + `CONFIG_SETTINGS_*` audit events) → persist (write
pulled files + `archive/`, save `state/sync-state.json`). **Wired today:** config upsert / pull / delete-git
/ prune / persist, Blueprint create/update/delete, and all six membership collections (git-authoritative;
detach gated by `--prune`; content resolves before target membership). App/package/device/user/group
relationship writes are unit-tested but still await their first live device test. Scheduled git-commit glue
remains future work (see [TODO.md](../TODO.md)).

**Drift signal:** raw SHA-256 of the profile XML — Apple stores custom profiles byte-for-byte and `GET`
round-trips them, so a plain hash is an exact drift signal. `updatedDateTime` is the cheap "did the live
side change / who's newer" signal.

> **Qualification (learned the hard way, 2026-07-25).** That is true of a profile Apple *stored*. An
> **out-of-spec profile is not stored at all**: Apple answers the `POST`/`PATCH` with a `2xx` and silently
> discards it, so the live bytes and `updatedDateTime` never move (C6). A hash comparison then reads the
> unchanged live copy as ordinary drift and the loop re-plans the identical change **forever** — observed on
> one profile of 39, its live `updatedDateTime` frozen across every attempt while the other eight edits in the
> same run converged. So: the hash is an exact *drift* signal, never a *proof that a write landed*. That proof
> is the read-back below.

**Write confirmation (read-back-and-confirm).** `Engine.push` (`internal/reconcile/apply.go`) no longer records
the baseline optimistically from the desired bytes (`Hash: hash.Raw(want)`). An optimistic baseline books an
accepted-and-dropped write as a success, so the next `Compute` sees the same drift and pushes again — the
loop above, made invisible. The baseline must describe what Apple **stored**, so after the `POST`/`PATCH` the
executor:
1. **always** re-reads the one config with `Applier.FetchCustomSettingDetail(id)` (the real `*ab.Client` method,
   so no adapter) and compares `stored.ContentHash()` against `hash.Raw(want)` — the same raw-hash signal the
   planner uses, so "match" here means the next `Compute` really will see convergence;
2. treats a write response echoing the pre-apply `updatedDateTime` (`unchangedTimestamp`, compared by instant,
   not by string) as **corroboration, never a verdict on its own**: it is appended to a mismatch's detail, and
   it is the tiebreaker that turns an *unreadable* read-back (fetch failed, no profile XML, no id) from
   "NOT VERIFIED" into "not persisted". It must not short-circuit the read-back, because a no-op `PATCH` whose
   bytes already match what Apple holds cannot bump the timestamp either — and that is reachable, since a
   `Conflict` against a stale baseline resolves to an `Update` that may already agree with live. Failing on the
   hint alone would blame the operator's `PayloadVersion` for a converged profile, forever;
3. on a match, writes `state.Entry{ABMID, Hash: stored.ContentHash(), UpdatedDateTime: stored.Updated}` from the
   **observed** read-back;
4. on a mismatch, reports an **error** naming the top cause (top-level `PayloadVersion` must be exactly `1`) and
   leaves the baseline untouched — with the pre-overwrite `archive/` path attached (`failWithArchive`), because
   that copy is the evidence the live bytes never moved;
5. when the read-back itself fails or returns no profile XML, records `done … — NOT VERIFIED (…)` and still
   leaves the baseline alone. An unhappened read says nothing about the write, so failing the run would cry
   wolf; a stale baseline costs at most one redundant, archived re-write next run, while an optimistic one
   hides a genuinely dropped write.

Rate-limit cost (AGENT.md): exactly **one extra `GET` per config actually written** — never per planned item,
never for pulls, skips or budget-capped items, and never counted as a write.

**Membership convergence:** always GET-current → compute add/remove → per-member POST/DELETE. The
relationship POST is **additive (merges), verified live 2026-07-05** (POST B to `{A}` → `{A,B}`; DELETE A →
`{B}`), so each relationship converges deterministically. Apple documents that multiple Blueprints can target
the same device/user/group; do not assume adding one relationship automatically removes another.

### Refresh and Verification Modes

`diff` and `sync` default to `--refresh=smart`: a cheap Apple metadata list first, baseline hash reuse when
Apple ID + `updatedDateTime` still match, and profile XML detail fetches only when exact comparison,
pull/prune, or archive-before-overwrite safety needs the body. `--refresh=full` re-downloads every live
profile XML; `--refresh=metadata-only` is fastest but depends on a complete baseline cache.

After apply, every mode now answers the same question — *does the tenant match git?* — and only the reads
differ (`verifyApply` in `internal/cli/phase1.go`; the candidate list is `writtenConfigs(res)`, i.e. completed
`Create`/`Update` outcomes only, since pulls, skips and prunes have no desired bytes to read back):

| mode | reads | checks |
|---|---|---|
| `targeted` (default) | blueprint-membership refresh **+ one detail `GET` for each write the apply could not confirm** (`verifyWrittenConfigs`, by the id on the outcome) — normally **zero**, since `reconcile.push` already confirmed each write as it made it | each unconfirmed write's `ContentHash()` vs `hash.Raw(desired)`; no fan-out over the whole tenant |
| `full` | the full live config + blueprint refresh it already performs for id harvesting | the same comparison, against the bytes that refresh already carries (`verifyAgainstLive`) — no extra `GET`s |
| `none` | nothing | nothing — the operator opted out, and no verdict is printed |

A config that cannot be read back (fetch error, absent from the full refresh, no profile XML returned, no id
recorded) counts as a **mismatch**, not as verified: an unverifiable write is not evidence of a good one.
A difference Apple actually showed us prints `post-apply verification FAILED: <name> still differs from desired
on Apple Business`, plus a summary naming the top-level `PayloadVersion` cause. A write that could not be
measured prints `post-apply verification FAILED: <name> could NOT be verified — Apple was not asked, or did not
answer, with a comparable profile`, and deliberately withholds the `PayloadVersion` hint: we have no evidence
the profile is out of spec, only that we never saw it. **The stable marker to grep for is the uppercase word
`FAILED`**, which both carry (`SyncFailure.verdictMarker` in abgui matches the same token). Both fail the run
with exit
`1` — after `finishApply` has rendered the receipt. That ordering is the contract: past `eng.Apply` the tenant
has already been written to, so every failure exit (baseline-save failure, a verification fetch, a mismatch)
still prints the per-item table (or the `--json`/`-o` object, whose shape stays stable) *before* returning the
error. An operator must never learn a write failed without learning **what was written**.

## 6. Package architecture (Go)
Module `github.com/GigaionLLC/abcli`; binary `abctl` (`cmd/abctl`). Requires Go 1.26+.
```
cmd/abctl/            # thin main: wires stdio + exit handling → internal/cli
internal/cli/         # Cobra commands (thin wrappers over the packages below)
internal/ab/          # Apple Business API client:
                      #   auth.go   — ES256 client-assertion (kid omitted), token cache, 429/5xx backoff
                      #   client.go — typed read + write methods, pagination, typed errors
internal/config/      # .env loader (client ID + key path + endpoint overrides)
internal/gitops/      # the on-disk desired-state tree (lib/ profiles, state/ baseline, archive/)
internal/hash/        # raw SHA-256 drift signal
internal/state/       # read/write the committed sync baseline (sync-state.json)
internal/reconcile/   # the engine: config Plan/Apply (3-way, newest-wins, archiving) + blueprint
                      #   ComputeBlueprints/ApplyBlueprints (CRUD + all-six-collection membership reconcile)
internal/archive/     # download-and-file the pre-overwrite live version + JSON sidecar (audit safety net)
```
Built in Phase 2: `internal/archive` (files the pre-overwrite live version + sidecar) and
`internal/reconcile/apply.go` — an `Engine` with injectable `Applier` / `Archiver` / `FileStore` interfaces
so the executor unit-tests against fakes with no live tenant. It archives before every overwrite/delete,
resolves conflicts newest-wins, honors `--prune` / `--limit-writes`, isolates per-item errors, and keeps the
committed baseline byte-exact. The CLI stays a thin consumer of `internal/reconcile` so a future HTTP/UI
layer can reuse the same engine with no logic reimplemented.

Key parsing accepts SEC1 and PKCS#8; the token and key are never logged.

## 7. CI/CD posture
Because the private key targets a production tenant, treat automated writes with care. Implemented as three
GitHub Actions workflows (`.github/workflows/cd-{plan,apply,drift}.yml`) — full setup in
[cicd.md](cicd.md). All self-skip without secrets; CI reads config from the environment (`abctl` falls back
to the `AB_*` process variables when there is no `.env`).
- **On pull request** (`cd-plan.yml`): `validate` + `sync --dry-run` (plan only; exit 3 = changes pending,
  which does **not** fail the check) and post the plan as a PR comment + job summary — no writes.
- **On merge to main** (`cd-apply.yml`): gated `sync --apply` behind a protected `production` environment
  with required reviewers and a serialized concurrency group (`ABCTL_APPROVE=1` passes abctl's own confirm);
  then commit the reconciled baseline back with `[skip ci]`. `--prune` only via an explicit `workflow_dispatch`
  input; `--limit-writes N` as a circuit breaker.
- **Scheduled drift check** (`cd-drift.yml`): a daily `sync --dry-run --exit-on-diff` that **fails to alert**
  when git and the tenant diverge (a console edit, or a due git change). (Auto-committing pulled console
  edits back to git on a timer — the fully-bidirectional scheduled *apply* — remains future work.)
- Secrets come from Actions secrets (or the gitignored `.env` locally); nothing secret-bearing is committed.

## 8. Verified facts settled by live testing (2026-07-04)
- **Auth needs no `kid`** — including any Key ID → `400 invalid_client`; omit it. Client ID + signature suffice.
- **`configurationProfile` is raw XML** (not base64) and `GET` round-trips it byte-identically (e.g. 1690
  bytes in == 1690 bytes out) → drift detection is a raw-byte SHA-256.
- **The API validates uploads** like the console: a malformed profile → `400 PARAMETER_ERROR.INVALID`; a valid
  one → `201`. Config CRUD: `POST 201` / `PATCH 200` / `DELETE 204`, `Content-Type: application/json`.
- **…but that validation is not exhaustive, and what it misses fails SILENTLY (2026-07-25).** Apple can answer a
  write `2xx` and then **not persist the profile**: the stored XML and `updatedDateTime` stay exactly as they
  were, with no error anywhere in the response. The confirmed trigger is a **top-level `PayloadVersion` other
  than `1`** — Apple's top-level profile keys pin it to exactly `1`, because it versions the profile *format*,
  not the operator's content ([Apple: TopLevel](https://developer.apple.com/documentation/devicemanagement/toplevel)).
  A value of `2` reproduces the failure exactly. Consequences, all now implemented: `validate` fails it locally
  (`payload-version`) before anything is pushed; the executor reads every write back (§5); `--verify` re-reads
  the written configs and exits `1`. **Never treat a `2xx` as proof of persistence.**
- **Blueprint create requires BOTH a member AND content (verified live 2026-07-05):** ≥1 member from
  `orgDevices`/`users`/`userGroups` (else `409 …MISSING_MEMBERS`) **and** ≥1 content resource from
  `apps`/`packages`/`configurations` (else `409 …MISSING_RESOURCES`). ⇒ there is **no harmless empty test
  Blueprint**. **Config CRUD on unattached configs deploys to nobody and is the safe test path.** Membership
  can be tested safely with a **throwaway managed user** as the member (0 devices → nothing deploys).
- **`relationships` POST is additive (merges) — CONFIRMED live 2026-07-05** on the `configurations` relation
  (POST B to `{A}` → `{A,B}`; DELETE-with-body A → `{B}`). abctl's `Add/RemoveBlueprintMembers` work.
- **Identity is READ-ONLY via the API — CONFIRMED live 2026-07-05:** `POST /users` and `POST /userGroups`
  both `403 … does not allow 'CREATE'`. Users/groups come from the console / federation / SCIM only.
- **Still open (needs a real test device):** live transport and on-device effects for app/package/device/user/
  group relationship writes. Apple documents multiple Blueprint assignments, so do not implement implicit
  removal from other Blueprints.
