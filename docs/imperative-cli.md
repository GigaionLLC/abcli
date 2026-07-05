# abctl — imperative CLI + binary release (design & determination)

**The determination:** ship `abctl` as a single Go binary that offers an **imperative plane**
(`create` / `edit` / `delete` / `attach` / `apply -f`, JSON everywhere, named connection contexts)
*alongside* its GitOps engine — reusing the same client, archiving, and baseline machinery. Full
imperative capability is achievable **only on the plane the Apple Business API actually exposes**
(config authoring, blueprint deploy, device assignment); a few device-plane operations are
**architecturally impossible** here and are scoped out honestly rather than faked.

> Determined 2026-07-05, benchmarked against modern device-management CLIs and mapped onto this
> repo's live-verified Apple Business API facts (`docs/endpoints/`).

## Two planes, one binary

A mature device-management CLI typically offers two ways to change state: a **declarative** path
(apply a file of desired state / GitOps) and an **imperative** path (act on one resource now). abctl
does the same:

- **GitOps plane (built):** `seed` → `diff` → `sync --apply` — whole-tree, git-authoritative.
- **Imperative plane:** `get` / `create` / `edit` / `delete` / `attach` / `apply -f` — one resource
  at a time, JSON output. Both planes call the same `ab.Client` + archive engine + baseline.

Full imperative capability where the API allows it: JSON `get`, imperative `POST/PATCH/DELETE` of
`CUSTOM_SETTING` configs, blueprint attach/detach, and (future) bulk device ASSIGN/UNASSIGN.

## Where the API sets the limit (scoped out honestly)

Some device-management platforms verify on-device state via an **on-device agent** and speak a live
**MDM command channel** to each device. abctl is a **pure client of Apple's org-level API** — no
agent, no per-device command channel — so three capabilities are impossible here and are documented
+ excluded from `--help`, never faked:

1. **live device queries** — there is no query engine or agent;
2. **arbitrary per-device MDM commands** (restart / lock / wipe / remove-profile) — that channel
   belongs to the MDM server, not the org API;
3. **on-device install *verification*** ("this profile is confirmed present on device Y") — needs an
   agent.

For "status," abctl ships **honest proxies** — blueprint coverage, device-assignment job status, and
the `CONFIG_SETTINGS_*` audit changelog — labeled *desired-state / assignment / changelog*, **never**
"installed on device."

## Capability map

| Capability | abctl equivalent | Feasible? | Notes |
|---|---|---|---|
| `get <res>` as JSON/YAML | `get {configurations,blueprints,devices,audit,users,usergroups,apps,mdmservers}` | ✅ full | global `-o table\|json\|yaml`, `--filter key=substr` |
| declarative incremental upsert | **`abctl apply -f`** — Configuration/Blueprint docs, upsert-only (no drift-delete) | ✅ | versioned `apiVersion: abctl/v1` spec, round-trippable with the tree |
| full declarative sync (deletes drift) | **`abctl sync --apply`** (built) | ✅ | git-authoritative; `--prune` deletes drift |
| export / sync-back | **`abctl seed`** + scoped **`abctl pull [config <name>]`** | ✅ | seed = whole tenant; pull = one resource (console-edit adoption) |
| raw request passthrough | **`abctl api <path> -X … -F … --input …`** | ✅ | non-GET is write-gated |
| imperative create/edit/delete | **`abctl create\|replace\|edit\|delete config`** | ✅ (CUSTOM_SETTING only) | reuses client + archive-before-overwrite |
| attach to deploy target | **`abctl attach\|detach config <name> --blueprint <bp>`** | ✅ | relationship POST/DELETE (additive/merge) |
| bulk device command targeting | **`abctl assign\|unassign --devices … --server …`** | ⚠️ assignment only | `orgDeviceActivities` ASSIGN/UNASSIGN — **not** restart/lock/wipe |
| async command result | **`abctl status activity <id> [--watch]`** | ⚠️ partial | genuine job status, for device↔server assignment |
| **on-device install status** | `abctl status config <name>` → coverage + device count | ❌ proxy only | desired-state, **not** install confirmation |
| **live device query** | none (closest: `get … --filter`) | ❌ | no agent, no query engine |
| per-device MDM command (lock/wipe/…) | none | ❌ | MDM-server command channel, not the org API |
| user / group create | `get users\|usergroups` (read only) | ❌ writes | `POST /users`,`/userGroups` → `403 does-not-allow-CREATE` |
| named connection contexts | **`abctl context set\|use\|get\|list`** + `--context` | ✅ | `~/.abctl/contexts.yaml`; `.env`/`AB_*` stays the CI path |
| bidirectional sync | imperative write mutates tree+baseline inline; console edit → `pull` + 3-way | ✅ | config GET round-trips **byte-identically** (verified) |

## The imperative command surface

Rules: (a) imperative verbs coexist with the GitOps verbs under one root; (b) **JSON everywhere** via
a global `-o/--output table|json|yaml` (default table); (c) every resource is a versioned spec
(`apiVersion: abctl/v1`, `kind: Configuration|Blueprint`, `spec`) so `get --yaml` is valid
`apply -f`/tree input; (d) **all writes gated** — confirm unless `--yes`/`$ABCTL_APPROVE`,
archive-before-overwrite, `--limit-writes`.

```
# contexts (named connections; solves multi-org)
abctl context set <name> --client-id … --key <path>   # ~/.abctl/contexts.yaml (0600)
abctl context use|get|list|current                    # + global --context / $ABCTL_CONTEXT

# imperative config authoring (CUSTOM_SETTING only)
abctl create  config <name> -f profile.mobileconfig   # POST 201 (validates first)
abctl replace config <name|id> -f profile.mobileconfig # archive live, then PATCH
abctl edit    config <name|id>                        # GET → $EDITOR → validate → PATCH
abctl delete  config <name|id> [--yes]                # archive live, then DELETE

# declarative-incremental bridge
abctl apply  -f a.yml [-f b.yml] [--dry-run]          # upsert; NEVER deletes absent
abctl delete -f a.yml                                 # batch delete what's declared (gated)

# deploy / membership + adoption
abctl attach|detach config <name> --blueprint <bp>
abctl pull [config <name>]                            # adopt a console edit into git

# status (honest proxies — not on-device install)
abctl status config <name>                            # blueprint coverage → device count
abctl status audit [--since 24h --type … --actor …]   # change history

# raw passthrough
abctl api <path> -X POST -F key=val --input body.json -  # non-GET write-gated
```

## Reconciliation — three write sources, one git tree

The rule enforced everywhere: **any successful write updates `state/sync-state.json` to equal live
before returning**, or the next `diff` reports phantom drift.

- **abctl imperative write → tree (decisive choice: imperative writes DO touch the tree by
  default).** `create/replace/edit/delete/attach/detach` perform the same atomic mutation `sync`
  does: archive-before-overwrite → write Apple → update the local `lib/`/`blueprints/` file **and**
  the baseline entry (id + `updatedDateTime` from the write response + hash) → save. The operator
  then commits. Result: **git == baseline == live immediately — no drift window** a later
  `sync --prune` could revert. `--no-write-tree` is the escape for out-of-tree one-offs (warns).
- **Console / website edit → tree.** `abctl pull [config <name>]` (a scoped `seed`) re-materializes
  live → tree + baseline; the existing 3-way newest-wins engine then resolves it (reliable because
  the config GET is byte-identical, verified). `abctl status audit` surfaces that a console change
  happened, when, and by whom — the signal a `pull` is warranted; a scheduled `diff --exit-on-diff`
  (the `cd-drift` job) alerts on it.

Net: **git→Apple** = `sync --apply`; **console→git** = `pull` + 3-way + audit; **imperative→git** =
inline tree+baseline mutation on the write itself.

## Binary release plan

- **Tooling:** GoReleaser v2 (`.goreleaser.yaml` + `.github/workflows/release.yml` on `v*` tags).
  Gate locally: `goreleaser check` → `goreleaser release --snapshot --clean`.
- **Matrix:** one static pure-Go binary (`CGO_ENABLED=0`), `goos [linux,darwin,windows] × goarch
  [amd64,arm64]`, `main ./cmd/abctl`.
- **Version embed (repo gotcha):** ldflags target **`internal/cli.version`** (this repo injects it,
  not the tool default `main.version`).
- **Reproducible:** `-trimpath`, `mod_timestamp: {{ .CommitTimestamp }}`, pinned Go 1.26.
- **Supply chain:** cosign keyless signing of `checksums.txt` (Sigstore + GitHub OIDC) + build
  provenance attestation + per-archive SBOM.
- **Channels:** GitHub Releases (source of truth), a `curl|sh` install script, Homebrew Cask + Scoop
  (once the tap/bucket repos + a token secret exist — templates are in `.goreleaser.yaml`),
  `go install …/cmd/abctl@latest`.
- **Versioning:** SemVer; stay `v0.x` while the write surface stabilizes; cut `v1.0.0` once
  create/replace/delete/attach/assign are live-proven.

## Roadmap

- **Phase 0 — binary + foundation (shipped groundwork):** GoReleaser + release workflow; named
  connection contexts; global `-o/--output`; write-gated `api -X/-F/--input`.
- **Phase 1 — imperative config authoring (shipped):** `create/replace/edit/delete config`;
  `apply -f` / `delete -f`; `pull`.
- **Phase 2 — deploy + assignment:** `attach/detach` + `status config/audit` (shipped); device
  `assign/unassign` + `status activity` **needs a live test device** to confirm the
  `orgDeviceActivities` body + one-blueprint-per-device.
- **Phase 3 — read-side + distribution + 1.0:** read additions (shipped: `get users|usergroups|
  apps|mdmservers` + `--filter`); shell completions/man pages; Homebrew/Scoop live; cut `v1.0.0`.

## Open questions

- `orgDeviceActivities` body shape + pollable id must be confirmed with a **live test device** (Phase 2 blocker).
- Context vs `.env` precedence (explicit `--context`/`$ABCTL_CONTEXT` wins; `.env` stays the CI path) — and whether `abctl context` can import an existing `.env`.
- Imperative write outside any gitops tree: fall back to tenant-only + warning, or require `--no-write-tree`?
- `/v1/apps` scope (full catalog vs Blueprint-linked) — affects `get apps`.
- Supply-chain tier: is cosign-keyless + provenance enough for launch, or full SLSA L3 day one?
