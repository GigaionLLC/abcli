# abctl — imperative CLI + binary release (fleetctl-parity determination)

**The determination:** ship `abctl` as a single Go binary that adds a **fleetctl-style
imperative plane** (`create` / `edit` / `delete` / `attach` / `apply -f`, JSON everywhere,
kubeconfig-style contexts) *on top of* the GitOps engine it already has — reusing the existing
`ab.Client` write methods, the archiving `reconcile.Engine`, and the committed baseline. Full
parity is achievable **only on the plane the Apple Business API actually exposes** (config
authoring, blueprint deploy, device assignment); three fleetctl device-plane features are
**architecturally impossible** here and are scoped out honestly rather than faked.

> Researched 2026-07-05 against fleetctl's own source (`fleetdm/fleet` `cmd/fleetctl/…`) and the
> Fleet docs, mapped onto this repo's live-verified Apple Business API facts (`docs/endpoints/`).

## Why fleetctl is the right north star — and where it can't be followed

Fleet is a **two-plane** system: an org/config REST API **plus** (a) a live MDM command channel
to every device and (b) an on-device osquery agent that *independently verifies* installs. abctl
is a **pure client of the org API** — no server, no agent, no command channel. So:

- **Full parity (the authoring / deploy / assignment plane):** JSON `get`, imperative
  `POST/PATCH/DELETE` of `CUSTOM_SETTING` configs, blueprint attach/detach, bulk device
  ASSIGN/UNASSIGN, and byte-diff bidirectional GitOps. Everything the API can write, abctl can.
- **No parity (the device plane) — scoped out in `--help` + docs, never faked:**
  1. **live query / policies** (osquery SQL) — there is no query engine or agent;
  2. **arbitrary per-device `mdm run-command` / lock / wipe** — that channel belongs to the MDM
     server, not the org API;
  3. **on-device install *verification*** ("Verified" in Fleet = osquery confirmed the profile is
     actually present) — impossible without an agent.
  For "status" abctl ships **honest proxies** (blueprint coverage, `orgDeviceActivities` job
  status, `auditEvents` changelog) — labeled *desired-state / assignment / changelog*, **never**
  "installed on device."

## Parity map: fleetctl → abctl

| fleetctl | abctl equivalent | Feasible? | Notes |
|---|---|---|---|
| `get <res> --json/--yaml` | `get {configurations,blueprints,devices,audit}` (exists) + add `apps`, `users`, `usergroups`, `mdmservers`, `activities` | ✅ full | add global `--output json\|yaml\|table` |
| `apply -f` (incremental upsert) | **`abctl apply -f`** — applies `kind: Configuration\|Blueprint` docs, upsert-only (no drift-delete) | ✅ | new; versioned `apiVersion: abctl/v1` spec |
| `gitops -f` (full sync, deletes drift) | **`abctl sync --apply`** (exists) | ✅ | already the git-authoritative engine; `--prune` deletes drift |
| `generate-gitops` (export / sync-back) | **`abctl seed`** (exists) + new scoped **`abctl pull [config <name>]`** | ✅ | seed = whole tenant; pull = one resource (console-edit adoption) |
| `api` raw passthrough `-X/-F/-H` | extend `abctl api` from GET-only → `-X/--method`, `-F/--field`, `-H/--header` (write-gated) | ✅ | today `runAPI` hard-blocks non-GET |
| imperative create/edit/delete | **`abctl create\|replace\|edit\|delete config`** | ✅ (CUSTOM_SETTING only) | core new surface; reuses client + archive-before-overwrite |
| deploy target attach/detach | **`abctl attach\|detach config <name> --blueprint <bp>`** | ✅ | relationship POST/DELETE (additive/merge) |
| `mdm run-command` (bulk targeting) | **`abctl assign\|unassign --devices … --server <mdm>`** | ⚠️ assignment only | `orgDeviceActivities` ASSIGN/UNASSIGN — **not** restart/lock/wipe/removeProfile |
| `get mdm-command-results --id` | **`abctl status activity <id> [--watch]`** | ⚠️ partial | genuine async job status, but for device↔server assignment |
| **install status (on-device)** | `abctl status config <name>` → blueprint coverage + device count | ❌ proxy only | desired-state/intent, **not** install confirmation |
| **live query / policies** | none (closest: `get … --json` + `--filter`) | ❌ | no agent, no SQL |
| `mdm lock/wipe/clear-passcode` | none | ❌ | MDM-server command channel, not the org API |
| `user create` / user CRUD | `get users\|usergroups` (read only) | ❌ writes | `POST /users`,`/userGroups` → `403 does-not-allow-CREATE` |
| `config set --context` (kubeconfig) | **`abctl context set\|get\|use\|list`** + `--context` | ✅ | new; `~/.abctl/contexts.yaml`; `.env`/`AB_*` stays the CI path |
| bidirectional GitOps (server ⇄ YAML) | imperative write mutates tree+baseline inline; console edit → `pull` + 3-way | ✅ | GET round-trips `CUSTOM_SETTING` **byte-identically** (verified) |
| `create blueprint` | console-only | ❌ | create needs an API-read-only identity member + content |
| `run-script`, `setup`, `preview`, `package`, `updates`, `trigger`, `debug`, `convert` | none | ❌ | server/agent/osquery-specific |

## The imperative command surface

Design rules: (a) imperative verbs coexist with the GitOps verbs under one root; (b) **JSON
everywhere** via a global `--output json|yaml|table` (default table on a TTY, JSON when piped);
(c) every resource is a versioned spec (`apiVersion: abctl/v1`, `kind: Configuration|Blueprint`,
`spec`) so `get --yaml` output is valid `apply -f`/gitops-tree input (round-trippable); (d) **all
writes gated exactly like `sync`** — confirm-unless-`--yes` (+ `$ABCTL_APPROVE`),
archive-before-overwrite, `--limit-writes`.

```
# contexts (kubeconfig-style; solves multi-org — today config is a single .env)
abctl context set <name> --client-id … --key <path> --api-base …   # ~/.abctl/contexts.yaml (0600)
abctl context use|get|list|current                                 # + global --context / $ABCTL_CONTEXT

# imperative config authoring (CUSTOM_SETTING only — reuses ab.Client.{Create,Update,Delete}Configuration)
abctl create  config <name> -f profile.mobileconfig [--platforms …]   # POST 201 (validates first)
abctl replace config <name|id> -f profile.mobileconfig                 # PATCH 200
abctl edit    config <name|id>                                        # GET → $EDITOR → validate → PATCH
abctl delete  config <name|id> [--yes]                                # DELETE 204 (refuses non-CUSTOM_SETTING)

# declarative-incremental bridge (fleetctl `apply -f`; distinct from full `sync`)
abctl apply  -f a.yml [-f b.yml] [--dry-run]     # upsert Configuration|Blueprint docs; NEVER deletes absent
abctl delete -f a.yml                            # batch delete what's declared (gated)

# deploy / membership (reuses Add/RemoveBlueprintMembers)
abctl attach config <name> --blueprint <bp>      # POST relationships/configurations (additive)
abctl detach config <name> --blueprint <bp>      # DELETE relationship

# device assignment (needs a NEW client method: POST/GET /v1/orgDeviceActivities)
abctl assign   --devices S1,S2 --server <mdmServerId>   # ASSIGN_DEVICES (bulk) → prints activity id
abctl unassign --devices …     --server …               # UNASSIGN_DEVICES
abctl status activity <id> [--watch]                    # the one genuine async job status

# status — HONEST proxies only (never on-device install verification)
abctl status config <name>        # blueprint coverage → targeted device count ("desired-state, NOT install")
abctl status audit [--since 24h --type CONFIG_SETTINGS_UPDATED --actor …]   # auditEvents changelog

# raw passthrough (extend today's GET-only `api`)
abctl api <path> -X POST -F key=val -F body@file.json -H 'K:V'   # non-GET write-gated
```

## Reconciliation — how three write sources converge on GitOps

The load-bearing rule, enforced everywhere: **any successful write updates
`state/sync-state.json` to equal live before returning**, or the next `diff` reports phantom drift.

- **abctl imperative write → tree (decisive choice: imperative writes DO touch the local tree by
  default).** When `create/replace/edit/delete/attach/detach` run inside a gitops working tree they
  perform the same atomic three-part mutation `sync` does: (1) archive-before-overwrite the live
  version; (2) write Apple; (3) mutate the local `lib/`/`blueprints/` file **and** the baseline
  entry (id + `updatedDateTime` from the write response, hash of the XML) and save. Then the
  operator commits. Result: **git == baseline == live immediately — no drift window** a later
  `sync --prune` could revert. `--no-write-tree` is the escape for genuine out-of-tree one-offs
  (prints a warning). This is *better* than fleetctl, which writes the server then re-materializes
  via `generate-gitops` (a drift window) — abctl closes it inline because it owns both the client
  and the tree.
- **Apple console / website edit → tree.** abctl can't observe these until it pulls, so:
  `abctl pull [config <name>]` (a scoped `seed`) re-materializes live → tree + baseline; then the
  existing 3-way newest-wins engine resolves it (`diff` shows a Conflict; `sync` pulls the newer
  console edit into git, archiving the git side). Reliable because the `CUSTOM_SETTING` GET is
  **byte-identical** (verified), so drift is a hash comparison, not a guess. `auditEvents`
  (`CONFIG_SETTINGS_*`, actor filter) is the provenance signal that a console edit happened and a
  pull is warranted; a scheduled `diff --exit-on-diff` (exit 3) alerts on it (already built as
  `cd-drift`).

Net: **git→Apple** = `sync --apply` (unchanged); **Apple/console→git** = `pull` + 3-way + audit;
**abctl-imperative→git** = inline tree+baseline mutation on the write itself (zero drift window).

## Binary release plan

- **Tooling:** **GoReleaser v2** (use `homebrew_casks:`, not the deprecated `brews:`). A
  `.goreleaser.yaml` at repo root + `.github/workflows/release.yml` on `v*` tags. Gate locally
  with `goreleaser check` → `goreleaser release --snapshot --clean`.
- **Matrix:** one static pure-Go binary (`CGO_ENABLED=0`), `goos [linux,darwin,windows] × goarch
  [amd64,arm64]`, `main ./cmd/abctl`.
- **Version embed (repo-specific gotcha):** GoReleaser defaults to `main.version`, but this repo
  injects **`internal/cli.version`** (see `cli.go` + Makefile). ldflags **must** be
  `-s -w -X github.com/GigaionLLC/abcli/internal/cli.version={{ .Version }}`. Optionally add
  `commit`/`date` vars for a richer `abctl version`.
- **Reproducible:** `-trimpath`, `mod_timestamp: {{ .CommitTimestamp }}`, inject `{{ .CommitDate }}`
  (never wall-clock `{{ .Date }}`), pin Go 1.26 in CI.
- **Supply chain:** cosign keyless `sign-blob` over `checksums.txt` (Sigstore + GitHub OIDC) +
  `actions/attest-build-provenance` (SLSA-style, `gh attestation verify`), Syft SBOM per archive.
- **Channels (the fleetctl-parity set):** GitHub Releases (source of truth) · `curl|sh` install
  script · **Homebrew Cask** (`GigaionLLC/homebrew-tap`) · **Scoop** (`GigaionLLC/scoop-bucket`) ·
  `go install …/cmd/abctl@latest` (dev). Optional later: npm shim + multi-arch GHCR container
  (for the CD workflows to pull a pinned image instead of `make build`).
- **Versioning:** SemVer; stay `v0.x` while the write surface stabilizes (first live write was
  2026-07-05); cut `v1.0.0` once create/replace/delete/attach/assign are live-proven.

## Roadmap (phased, prioritized)

- **Phase 0 — ship the binary + foundation (no new Apple writes). HIGH.**
  `.goreleaser.yaml` + `release.yml` → cut **v0.1.0** from the current feature set (auth, get*,
  seed/validate/diff/sync, GET-only api) to get an installable, signed binary out. Add
  kubeconfig-style **contexts**, the global **`--output`**, and the **write-gated `api -X/-F/-H`**.
- **Phase 1 — imperative config authoring (the core ask). HIGH → v0.2.0.**
  `create|replace|edit|delete config` (reusing the client + archive engine, inline tree+baseline
  mutation), `apply -f` / `delete -f`, and `pull` for console-edit adoption.
- **Phase 2 — deploy + assignment. MEDIUM → v0.3.0.**
  `attach|detach config --blueprint`; a **new client method** for `orgDeviceActivities` +
  `assign|unassign` + `status activity`; `status config` (coverage) + `status audit`. *Blocked on a
  live test device* to confirm the `orgDeviceActivities` body shape + one-blueprint-per-device.
- **Phase 3 — parity glue + distribution + 1.0. MEDIUM→LOW → v0.4.0 → v1.0.0.**
  `get apps|users|usergroups|mdmservers|activities`; client-side `--filter` (the honest "query"
  proxy); completions + man pages; Homebrew/Scoop live; the explicit `--help` scope-out block for
  the impossible trio; **v1.0.0** once the write verbs are live-proven.

## Open questions

- **`orgDeviceActivities`** is not yet in `ab.Client`: the exact POST body (activityType +
  device/server referencing) and whether a pollable id comes back must be confirmed **with a live
  test device** (Phase 2 blocker; ties to the still-open one-blueprint-per-device question).
- **Context vs `.env` precedence** (explicit `--context`/`$ABCTL_CONTEXT` overrides `.env`; `.env`
  stays the CI path) — and whether `abctl context` can import an existing `.env`.
- **`abctl edit`** on raw `.mobileconfig`: unchanged = no-op, invalid = abort/keep-live, non-CUSTOM_SETTING = block with guidance.
- **Imperative write outside any gitops tree** (no `gitops/`): fall back to pure-imperative + warning, or require `--no-write-tree`?
- **Does `apply -f` ever delete?** Plan says no (deletion stays with `sync`/`delete -f`), preserving the fleetctl incremental-vs-full distinction.
- **`/v1/apps` scope** (full Apps & Books catalog vs Blueprint-linked only) — affects a future `get apps`.
- **Supply-chain tier:** is cosign-keyless + build-provenance enough for launch, or is full SLSA L3 needed day one?
