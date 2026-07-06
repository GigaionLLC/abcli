# abgui — design plan

`abgui` is a native **Swift / SwiftUI** macOS application that puts a graphical control plane on top of
[`abctl`](design-abctl.md), the GitOps CLI for the **Apple Business API** (built-in MDM: **Configurations**
+ **Blueprints**), developed by **Gigaion, LLC**. abgui is **frontend-only**: it shells out to `abctl`,
passes the global `-o json` / `--json`, decodes stdout, logs stderr, and branches on the exit code. Every
Apple Business behavior — ES256 client-assertion signing, pagination, the 3-way reconcile engine, the
`gitops/` tree, archive-on-overwrite, secrets — stays in `abctl`. abgui owns windows, tables, forms, and a
subprocess/decoding layer, and **re-implements none of the API**.

> ### 🤖 Built by AI
> **abgui is designed, written, tested, and documented end-to-end by an autonomous AI coding agent
> (Anthropic's Claude), directed by Gigaion, LLC** — the same "AI-built, human-directed, openly disclosed"
> approach Gigaion uses across its open-source projects. This document is the design plan; treat it as a
> buildable blueprint, not a substitute for your own review before pointing it at a production tenant.

> **Status:** design only — no code yet. This plan pins abgui to the *current, source-verified* `abctl`
> contract (see [design-abctl.md](design-abctl.md) and the JSON-contract table in §3), and marks every
> `abctl` change abgui would like as a **proposed addition** — abgui never assumes a feature `abctl` does
> not already ship.

---

## 1. Overview — goals / non-goals

abgui exists to give operators a fast, native window onto a tenant that `abctl` already manages: browse the
live inventory, **see the GitOps plan/drift visually**, and drive gated writes through `abctl`'s own
archive-on-overwrite engine — without touching a terminal. It is deliberately a **thin shell over a mature
CLI**, not a second implementation of the API.

**Goals**

- **Native macOS, SwiftUI.** A real `.app` with a Dock icon, `NavigationSplitView` sidebar, `Table`-based
  list screens, and an inspector. No Electron, no web view, no bundled runtime.
- **`abctl`-as-backend, always.** Every read is `abctl … -o json`; every write is a gated `abctl` mutation
  (`--yes`) — abgui inherits `abctl`'s safety guarantees (read-only default, write gating, archive) for
  free.
- **The GitOps story is the hero.** A visual 3-way diff/plan view, a per-config drift badge, and an
  archive/rollback browser — capabilities no comparable single-tenant GUI offers.
- **Reuse `abctl` contexts as the tenant switcher.** No second credential store; the connection picker is a
  front-end over `~/.abctl/contexts.yaml`. The **Settings** window (⌘,) also *writes* contexts — enter a
  Client ID + EC private key and it runs `context set … --key <path> --use`, so a Finder-launched app (which
  inherits no `AB_*` env) can authenticate without a shell. A pasted PEM is written to a `0600` file under
  `~/Library/Application Support/abgui/keys/`; `abctl` reads the key by **path only**, so key material never
  touches argv, logs, or `contexts.yaml`. See `SettingsView` + `CredentialStore`.
- **Unsigned, zero-cost distribution.** Ad-hoc-signed universal `.app`, shipped as a zip, launchable with
  one documented `xattr` command — no Apple Developer account.
- **Self-contained `.app` — abctl embedded (decided).** The GUI ships as one bundle with a universal `abctl`
  inside (`Contents/Resources/abctl`); installing abgui installs everything, with no separate CLI install and
  no `PATH` dependency. The embedded CLI is version-locked to the exact commit the GUI was built from.

**Non-goals (v1)**

- **Not cross-platform.** macOS-only; a SwiftUI/AppKit app is intrinsically Apple. No Windows/Linux GUI.
- **No re-implemented API or auth.** abgui never mints an ES256 token, never reads the private key, never
  calls `api-business.apple.com` directly.
- **No new Apple capabilities of its own.** Anything `abctl` cannot do (ADE device→MDM-server assignment,
  AppleCare lookup, activity polling, Apple School Manager, MDM analytics, third-party MDM sync) is **out of
  scope for abgui until `abctl` gains it** — these are backend workstreams, not GUI features. See §4 and
  §10.
- **Not signed/notarized, not sandboxed, no auto-update** in v1 (all deferred — see §6, §10).
- **Not the Mac App Store.** Sandboxing is impossible here (§6), so App Store distribution is off the table
  by design.

---

## 2. Architecture — the abgui ⇄ abctl boundary

### 2.1 The boundary in one diagram

```
┌──────────────────────────────────────────────────────────────┐
│                          abgui.app                            │  SwiftUI · macOS 14+
│                                                               │  @Observable · Table · Split
│   Views (Sidebar / Table / Inspector / Diff / Console)        │
│        │  bind                                                │
│        ▼                                                      │
│   ViewModels  (@Observable, @MainActor)                       │
│        │  typed calls: configurations(), diff(), sync(...)    │
│        ▼                                                      │
│   AbctlClient  (facade: one Swift method per abctl verb)      │
│        │  builds argv, decodes JSON, maps exit codes          │
│        ▼                                                      │
│   AbctlRunner  (protocol)  ── ProcessRunner (actor) ──┐       │
│                             └ MockAbctlRunner (tests) │       │
└───────────────────────────────────────────────────────┼──────┘
                argv + "-o json" + "--context <ctx>"      │  posix_spawn
                cwd = repo root (for seed/diff/sync/…)     │
                stdout → JSON   stderr → log   exit code   ▼
                                              ┌────────────────────┐
                                              │   abctl  (Go)      │  Contents/Resources/abctl
                                              │   universal binary │  (lipo arm64+amd64)
                                              └─────────┬──────────┘
                        reads (never exposes the key material)     │  ES256 client-assertion
              ~/.abctl/contexts.yaml (key PATH only) ·  gitops/    │  HTTPS
                                              ┌─────────▼──────────┐
                                              │  Apple Business    │  api-business.apple.com/v1
                                              └────────────────────┘
```

The load-bearing invariant is `abctl`'s **three-stream contract**: **stdout** carries the machine payload
(JSON / YAML / table / profile XML / raw API body), **stderr** carries human status lines and confirm
prompts, and the **exit code** carries success / drift / failure. abgui parses stdout, logs stderr, and
branches on the code — it captures the two streams **separately** and never parses stderr as data.

### 2.2 The fork: how abgui talks to abctl

| Option | What it is | Pros | Cons | Verdict |
|---|---|---|---|---|
| **(A) Shell-out per action** | Spawn `abctl` once per user action; read stdout to completion; decode. | Matches `abctl`'s stateless CLI exactly; trivially testable (mock the runner); no protocol to version; per-action `--yes` auditability; process crash can't corrupt shared state. | Process-spawn cost per call (~tens of ms — negligible at human interaction rates); no cross-call token reuse (abctl re-mints per run, but caches within a run). | **Recommended for v1.** |
| **(B) Persistent `abctl` subprocess protocol** | Long-lived `abctl` child speaking a line/NDJSON request-response protocol over stdin/stdout. | Amortizes token mint; enables streaming progress. | **`abctl` has no such mode today** — it is a one-shot CLI; this is a large new backend surface (a REPL/daemon protocol, framing, lifecycle) that duplicates HTTP-server concerns. | Deferred; only if profiling shows spawn cost matters. |
| **(C) `abctl serve` local daemon** | A local HTTP/JSON daemon exposing the engine. | Cleanest streaming/multiplex story; reusable by other frontends. | Biggest new `abctl` surface (a server, a port/socket, auth to the daemon itself, lifecycle/supervision); over-engineered for a single-user desktop app. | Deferred; revisit only if a web UI or multi-client need appears. |

**Rationale for (A):** `abctl` is a stateless, exit-code-driven CLI whose entire contract is stdout/stderr +
code. Shelling out per action is a *direct* mapping of that contract, needs **zero new backend work**, and
is the most testable (inject a `MockAbctlRunner`). Options B and C only pay off under load abgui will never
see (a human clicks a few times a second) and each demands a substantial new `abctl` mode. Ship A; keep the
runner behind a `protocol` (below) so B could slot in later without touching view-models.

### 2.3 The typed Swift command-wrapper layer

Three layers, so views never touch `Process`:

```swift
// 1) The transport — the only thing that knows about Process.
struct AbctlResult { let stdout: Data; let stderr: String; let code: Int32 }

protocol AbctlRunner {                                   // mockable seam (see §7 testing)
    func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult
}

// 2) The facade — one Swift method per abctl verb; owns argv, JSON decode, exit-code mapping.
struct AbctlClient {
    let runner: AbctlRunner
    var context: String?                                 // → threaded as --context on every call
    var repoRoot: URL?                                   // → cwd for seed/diff/sync/apply/pull

    func configurations(type: String?) async throws -> [Resource]
    func configuration(_ id: String) async throws -> Resource
    func profileXML(_ id: String) async throws -> String            // get configuration --profile
    func blueprints() async throws -> [Resource]
    func devices() async throws -> [Resource]
    func audit(since: String) async throws -> [Resource]
    func users() async throws -> [Resource]                          // + usergroups/apps/mdmservers
    func statusConfig(_ id: String) async throws -> Coverage
    func contextList() async throws -> ContextList                   // -o json (no --json flag)
    func plan() async throws -> Plan                                 // diff --json  ==  sync --dry-run --json
    func drift() async throws -> Plan                                // diff --exit-on-diff --json → maps exit 3
    // writes — every one passes --yes:
    func createConfig(name: String, xml: Data) async throws -> WriteOutcome     // -f - --yes (stdin)
    func replaceConfig(_ id: String, xml: Data) async throws -> WriteOutcome    // -f - --yes (the GUI 'edit')
    func deleteConfig(_ id: String) async throws -> WriteOutcome
    func attach(config: String, blueprint: String) async throws -> WriteOutcome
    func detach(config: String, blueprint: String) async throws -> WriteOutcome
    func applySpec(file: URL, dryRun: Bool) async throws -> Plan
    func syncApply(prune: Bool, limitWrites: Int?) async throws -> ApplyResult  // --apply --yes --json
    func api(path: String, method: String, fields: [String], input: Data?) async throws -> Data
}
```

**Decoding the open payload.** `abctl` marshals JSON:API `Resource = {type,id,attributes}` where
`attributes` is a raw passthrough of Apple's fields. Model it with a recursive `JSONValue` for the open part
plus per-screen typed structs for the columns a view renders:

```swift
struct Resource: Codable, Identifiable {
    let type: String
    let id: String
    let attributes: JSONValue           // recursive enum: .object/.array/.string/.number/.bool/.null
}
struct ConfigurationRow: Decodable { let name: String; let type: String; let updatedDateTime: String? }
struct DeviceRow:        Decodable { let serialNumber: String; let productFamily: String?; let deviceModel: String? }
```

`JSONValue` keeps abgui resilient to Apple adding attribute fields; the typed structs give strongly-typed
columns. The **same** `JSONDecoder` used in the app is used in the golden-fixture tests (§7), so an Apple
schema change breaks a test, not the UI.

### 2.4 Threading / async

- **`ProcessRunner` is an `actor`, never on `@MainActor`.** `Process` blocks; keep it off the main thread.
- **Drain both pipes concurrently with the wait.** A full 64 KB pipe buffer deadlocks if you
  `waitUntilExit()` before reading. Use a `TaskGroup`: `async let` both `readToEnd()` (or
  `FileHandle.bytes` for long `get devices` / `sync` outputs), then `waitUntilExit()`.
- **Cancellation:** `withTaskCancellationHandler { … } onCancel: { process.terminate() }` (SIGTERM);
  escalate to SIGKILL after a grace window. SwiftUI `.task {}` cancellation on view teardown thus kills a
  runaway child.
- **Timeouts:** race the wait against `Task.sleep(for:)`; tune per command (short for `version`, longer for
  network round-trips and `sync`).
- **Publishing:** decode off-main, then hop to `@MainActor` to write into `@Observable` view-model state
  that `.task {}` / `.refreshable` drives.
- **`cwd` matters.** Read-only API commands ignore the working directory, but `seed` / `diff` / `sync` /
  `apply` / `pull` resolve the `gitops/` tree **relative to cwd** (a context is a *connection*, not a repo).
  abgui sets `currentDirectoryURL` to the selected repo root for those verbs.

### 2.5 Error + exit-code handling

Map **termination status**, not a boolean "did it error":

| exit | meaning | abgui result |
|---|---|---|
| `0` | success | `.ok(stdout)` → decode JSON |
| `3` | **changes pending / drift** (`--exit-on-diff`) | `.changesPending(plan)` — a **normal** state; render a "drift" badge, **not** an error |
| `1` | runtime error / aborted write | `.cliError(stderr)` — surface the stderr text (e.g. `API 403 (grant 'View/Manage Blueprints' …)`) |
| other (incl. `2`) | usage / unexpected | `.usage(stderr)` — an argv bug in abgui; assert in dev builds |

Two realities abgui bakes in, straight from `abctl`'s source:

- **On failure there is no JSON on stdout.** `main` prints `Error: <message>` to **stderr**, empty stdout,
  exit `1`. abgui therefore falls back to showing the stderr text until the structured-error-envelope
  proposal (P3, §3) lands. The one exception is `api`, which prints Apple's error body to stdout.
- **Exit code `2` is documented but not currently emitted** — cobra usage/unknown-flag errors map to exit
  `1` in `main.go`, so a malformed invocation is today indistinguishable by code from a runtime failure.
  abgui treats *anything non-0/non-3* as failure and surfaces stderr; proposal N-usage (§3) asks `abctl` to
  actually emit `2` so abgui can distinguish its own argv bugs.
- **Partial apply:** `sync --apply --json` prints the full result JSON (with per-item `status:"error"`)
  **and** exits `1` when any item failed — abgui gets both, and renders per-item outcomes even on a nonzero
  code.
- **Empty lists serialize as `[]`** (fixed — N3): every `get … -o json` list returns a JSON array even when
  empty, so abgui needs no null-guard. (Older `abctl` builds returned `null`; the version guard (P2) covers
  that if abgui ever runs against one.)

---

## 3. The abctl ⇄ abgui contract

### 3.1 Commands abgui invokes, and how it gets JSON

The **JSON switch is uneven** across `abctl` and abgui must follow the code's actual behavior, not the
help text:

| Purpose | Command abgui runs | JSON via | Payload |
|---|---|---|---|
| Config list | `get configurations -o json` | `-o json` | `[]Resource` |
| Config detail | `get configuration <id> -o json` | `-o json` | `Resource` (XML at `attributes.customSettingsValues.configurationProfile`) |
| Config profile (editor pane) | `get configuration <id> --profile` | — | raw `.mobileconfig` XML on stdout |
| Blueprints / devices / audit | `get blueprints\|devices\|audit --since 7d -o json` | `-o json` | `[]Resource` |
| Users / groups / apps / servers | `get users\|usergroups\|apps\|mdmservers -o json` | `-o json` | `[]Resource` |
| Coverage | `status config <id> -o json` | `-o json` | `{config, blueprints:[{blueprint,devices}], targeted_devices}` |
| Connection switcher | `context list -o json` / `context get <n> -o json` | **`-o json` only** (no `--json` flag) | `{current, contexts:[…]}` / `{name, context:{…}}` |
| Active context | `context current` | — | plain text name |
| **Plan / diff** | `diff --json` **==** `sync --dry-run --json` | **`--json` only** (ignores `-o`) | `{configs:[…], blueprints:[…]}` |
| **Drift signal** | `diff --exit-on-diff --json` | `--json` | plan on stdout, **exit 3** = drift badge |
| Raw request | `api <path> [-X GET]` | n/a | response body on stdout, `HTTP <n>` on stderr |

**Rule abgui hard-codes:** `-o json` for `get`/`status`/`context`; **`--json`** (never `-o`) for
`diff`/`sync`; `diff`/`sync` have **no YAML**.

**The plan shape** (identical for `diff --json` and `sync --dry-run --json`) is the machine-readable input to
the diff view:

```json
{ "configs":    [ { "name": "WiFi-Corp.mobileconfig", "action": "update-abm",   "detail": "changed in git → PATCH ABM" } ],
  "blueprints": [ { "blueprint": "Fleet-A", "bp_id": "…", "action": "attach-config",
                    "config": "WiFi-Corp.mobileconfig", "config_id": "…", "detail": "in git, not attached → attach" } ] }
```

`configs[].action` ∈ `create-abm | update-abm | pull-git | pull-new-git | delete-abm | delete-git | conflict`.
`blueprints[].action` ∈ `attach-config | detach-config | blueprint-new | blueprint-adopt` (the last two are
report-only advisories `sync` never applies). `sync --apply --json` returns a **different, execution-result**
shape (`{configs:{outcomes:[…],writes,errors,skipped}, blueprints:{…}}`, `status ∈ done|skipped|error`).

### 3.2 How abgui drives writes non-interactively

Every mutating command proceeds **only** if `--yes` is set **or** `$ABCTL_APPROVE` is truthy; otherwise it
reads a literal `yes` from **stdin** and, with the GUI's empty stdin, **aborts with exit 1**. **abgui shows
its own confirmation dialog, then passes `--yes` on every mutating call** (per-action auditability — preferred
over a blanket `ABCTL_APPROVE=1` on the child env).

| Write | abgui invocation | Note |
|---|---|---|
| Create | `create config <name> -f - --yes` (XML on stdin) | `-f -` avoids a temp file |
| Replace / **"edit"** | `replace config <id> -f - --yes` (edited XML on stdin) | archives live, then PATCH |
| Delete | `delete config <id> --yes` | archives, then DELETE |
| Attach / detach | `attach\|detach config <id> --blueprint <bp> --yes` | membership |
| Apply spec | `apply -f <spec.yml> --yes` (`--dry-run` to preview) | upsert-only; never deletes |
| Full reconcile | `sync --apply --yes --json [--prune] [--limit-writes N]` | `--prune` and `--limit-writes` are explicit dialog toggles |
| Raw write | `api <path> -X POST -F k=v --yes` | body via `-F` or `--input -` |

> **`edit config` is not GUI-drivable** — it opens `$EDITOR` interactively. abgui implements "edit" as
> **fetch (`get configuration <id> --profile`) → edit in an in-app text pane → `replace config <id> -f - --yes`**
> (XML piped on stdin). abgui never invokes `abctl edit`.

### 3.3 Proposed `abctl` additions (marked prereq vs nice-to-have)

None of these block v1 read-only browse (which runs entirely on today's `-o json`), but they materially clean
up the write and status surfaces.

> ✅ **Already shipped (done ahead of any Swift code):** **P1** (`auth whoami --json`), **P5** (`context`
> JSON casing), **P7** (`diff`/`sync` honor `-o json`/`-o yaml`), **P4** (`--json` per-item outcome on
> `create`/`replace`/`delete`/`attach`/`detach`), and **N3** (empty lists serialize as `[]`) are implemented
> and unit-tested in `abctl` — the GUI contract is de-risked before the frontend exists. The remaining items
> below are still proposed.

**Prerequisites** (small; unblock a clean GUI):

| # | Addition | Why abgui needs it |
|---|---|---|
| ✅ **P1** | `auth whoami --json` → `{authenticated, client_id, api_base, token_expires, configurations, blueprints}` | **Shipped.** A clean, typed "test connection" for the login/status screen (exit 0 + `authenticated:true`). |
| **P2** | `abctl version -o json` → `{version, commit, capabilities:[…]}` | Detect the binary, its version, and which flags exist, to enable/disable UI and enforce a **minimum abctl version**. Without it abgui parses the cobra `--version` text. |
| **P3** | Structured error envelope on `--json` failure: `{"error":{"code","message","exitCode"}}` on **stdout** | So abgui never string-matches stderr for errors. |
| ✅ **P4** | `--json` per-item output on single writes → `{action,name,id,status,updatedDateTime,archive,blueprint,treeUpdated}` | **Shipped** on `create/replace/delete/attach/detach`: the write's new `id` + archived-copy path arrive as JSON on stdout, so abgui needn't re-list after a create. |
| ✅ **P5** | `context get -o json` key-casing fix (`json:` tags → lowercase `client_id/key/api_base/scope`) | **Shipped.** Now consistent snake_case, not Go field names. |
| **P6** | `get blueprint --json` include member counts `{configs:N, devices:N}` | The JSON branch returns a bare `Resource`; counts are computed only in the table branch, so a JSON-driven detail screen has none. |
| ✅ **P7** | Honor `-o json`/`-o yaml` uniformly for `diff`/`sync` | **Shipped.** `diff -o json` / `sync -o yaml` now emit the structured plan instead of silently printing a table. |

**Nice-to-have** (improve UX; not blocking):

| # | Addition | Payoff |
|---|---|---|
| **N1** | `sync --apply --stream` emitting **NDJSON** per-item outcome events | Live progress list during long applies instead of a spinner. |
| **N2** | `validate --json` → `{profiles, ok, failed:[{file,reason}]}` | Inline per-file validation errors before apply. |
| ✅ **N3** | List results serialize as `[]` not `null` when empty | **Shipped.** Removes a null-guard from every list view. |
| **N4** | Real exit code `2` on usage errors (currently mapped to `1`) | Lets abgui distinguish its own argv bugs from tenant errors. |
| **N5** | Uniform `--filter k=substr` across list commands; `--filter` on `get devices`; `-o csv` | Push simple search server-of-the-shell; native CSV export (also reusable in CI). |

P1/P4/P5/P7 and N3 have landed. Until **P2** (version/capabilities) lands, abgui reads the version from the
cobra `--version` text; the remaining proposals (P3 error envelope, P6 blueprint counts, N-series) are
graceful-degradation niceties, not blockers.

---

## 4. Feature set — screens mapped to abctl backing

Legend: **v1** read-only browse + GitOps view · **v2** writes · **v3** GitOps sync · **later** (needs new
`abctl` backend work).

### 4.1 Parity + differentiator screens (all backed by existing `abctl`)

| Screen / panel | abctl backing | Phase | Notes |
|---|---|---|---|
| **Connection / tenant switcher** | `context list\|get\|current -o json`, global `--context` | v1 | Reuses `abctl` contexts; structurally cannot leak a key (path only). |
| **Dashboard tiles** (counts by family, connection badge) | `get devices --json` + `auth whoami` (exit 0) | v1 | Aggregated client-side; no `abctl` aggregation command. |
| **Configurations list + detail** | `get configurations --json`, `get configuration <id> [--profile]` | v1 | Detail shows the raw `.mobileconfig` XML in a read-only pane. |
| **Blueprints list + detail** | `get blueprints --json`, `get blueprint <id>` | v1 | Member counts need **P6** (else counts are blank in JSON). |
| **Devices inventory** | `get devices --json` | v1 | **Filter/sort client-side** — `get devices` has no `--filter` and no server query engine. |
| **Users / User Groups / Apps / MDM Servers** | `get users\|usergroups\|apps\|mdmservers --json [--filter k=v]` | v1 | Identity is read-only via the API by design. |
| **Audit viewer** (time-range) | `get audit --since 24h\|7d\|90d --json`, `status audit --json` | v1 | Strong match; better than the reference app. |
| **Coverage inspector** ("which blueprints carry this / devices targeted") | `status config <id> -o json` | v1 | Change-verification proxy. |
| **Raw API console** (GET) | `api <path>` | v1 | Power-user runner + response viewer; also the escape hatch for endpoints `abctl` doesn't model. |

### 4.2 GitOps differentiators (the hero — no reference-app analog)

| Feature | abctl backing | Phase | Why it beats the reference app |
|---|---|---|---|
| **Diff / plan view** (3-way) | `diff --json` / `sync --dry-run --json` | v1 | Visualizes git ↔ baseline ↔ live before any write. |
| **Drift dashboard** (per-config in-sync/drifted badge) | `diff --exit-on-diff --json` → exit 3 | v1 | Byte-level SHA-256 drift as a compliance indicator. |
| **Config lifecycle editor** (create/replace/delete) | `create/replace/delete config … -f - --yes` | v2 | Edit `.mobileconfig` in-app with automatic pre-overwrite archiving. |
| **Blueprint membership editor** (drag configs onto blueprints) | `attach`/`detach … --yes`; declarative `sync` (detach gated by `--prune`) | v2 | Never touches console-only configs it doesn't own. |
| **Declarative spec apply / preview** | `apply -f <spec.yml> [--dry-run] --yes` | v2 | Import/preview `abctl/v1` resource specs (upsert-only). |
| **Validation** | `validate` (`--json` via **N2**) | v2 | Lint profiles before apply. |
| **Apply / converge with gating** | `sync --apply --yes --json [--prune] [--limit-writes N]` | v3 | abgui shows its own confirm, exposes `--prune`/`--limit-writes` as visible toggles / circuit breaker. |
| **Streaming apply progress** | `sync --apply --stream` (**N1**) | v3 | Live per-item outcome list. |
| **Archive / rollback browser** | `gitops/archive/<name>/<ts>--<reason>.mobileconfig` (+ `.json` sidecar); restore via `replace config -f - --yes` | v3 | One-click restore of a prior live version — a true undo history. |
| **Seed / adopt-from-live** | `seed`, `pull [config <name>]` | v3 | Bootstrap the git tree, or adopt an individual console edit. |

### 4.3 Deferred — needs new `abctl` backend work first (out of GUI scope)

These are the reference app's ADE/analytics territory. They are **not GUI-only features**: each requires new
`abctl` write endpoints or polling, so they are a separate backend workstream, **not** launch parity.

| Deferred feature | Missing `abctl` backend | Phase |
|---|---|---|
| Bulk device → MDM-server assignment / unassignment | writes to `mdmServers/{id}/relationships/devices` | later |
| AppleCare coverage lookup | a `/devices/{id}/appleCare` command (or raw `api` probe) | later |
| Activity / progress tracking | `orgDeviceActivities` polling | later |
| Apple School Manager (dual-platform) | ASM scopes + ADE endpoints | later |
| MDM enrollment analytics | an aggregation surface | later |
| Third-party MDM inventory sync | out of scope — `abctl` is deliberately Apple-only | not planned |

Until then, the **raw API console** (v1) is the escape hatch for power users to probe these endpoints.

---

## 5. Monorepo layout

`abgui/` is a top-level SwiftPM **executable** package, a peer of `cmd/`, `internal/`, `docs/`, `scripts/`.
The two toolchains are isolated **automatically and bidirectionally**: Go tooling (`go build/vet/test ./...`,
`gofmt -l .`, `golangci-lint run ./...`) walks only `.go` files and `go.mod`, so a Swift-only directory is
invisible to it; the Swift toolchain keys off `Package.swift` / `.swift` and never reads Go. **No lint/format
exclusions are needed on either side**, and `.golangci.yml` stays unchanged.

```
abgui/
├── Package.swift                 # SwiftPM manifest — one executable target, ZERO external deps
├── README.md                     # scope + AI-authorship/Gigaion disclosure; "see ../LICENSE, ../NOTICE"
├── Sources/
│   └── abgui/
│       ├── App.swift             # @main SwiftUI App
│       ├── Backend/
│       │   ├── AbctlRunner.swift # protocol + actor ProcessRunner (separate stdout/stderr, cwd, timeout)
│       │   ├── AbctlClient.swift # typed verb wrappers (§2.3)
│       │   └── AbctlVersion.swift# parses version, enforces minimumAbctl
│       ├── Models/               # Codable: Resource, JSONValue, Plan, ApplyResult, Coverage, ContextList
│       └── Views/                # Sidebar, Table screens, Inspector, DiffView, ArchiveBrowser, ApiConsole
├── Tests/
│   └── abguiTests/               # decode + exit-code-mapping tests against golden fixtures (no display)
├── Resources/
│   └── AppIcon.icns              # prebuilt (commit the .icns; optionally keep AppIcon.iconset/ source)
└── Packaging/
    └── Info.plist                # .app bundle template — @VERSION@ substituted at assembly
```

Choices:

- **No external Swift dependencies.** Shell out to `abctl`, decode with Foundation `JSONDecoder`, build UI
  with SwiftUI — mirroring the Go side's "prefer stdlib" rule. No `Package.resolved` churn. (If a dep is ever
  added, commit `Package.resolved` — the Swift analogue of `go.sum`.)
- **Target name `abgui`** keeps the trio consistent: module `abcli` → binary `abctl` → app `abgui`.
- **`Packaging/Info.plist` is a template** for manual `.app` assembly, kept out of `Sources/` so it isn't
  confused with an in-binary SwiftPM resource.

**`.gitignore`** — append a clearly-labeled block; leave the existing secrets/Go blocks and `.golangci.yml`
untouched:

```gitignore
# --- Swift / macOS GUI (abgui) build artifacts — NEVER COMMIT ---
abgui/.build/
abgui/.swiftpm/
*.app
DerivedData/
.DS_Store
```

The assembled bundle lands under the already-ignored `bin/` (`bin/abgui.app`, `bin/abgui-<ver>-macos.zip`);
`*.app` is belt-and-suspenders. **The GUI build touches no tenant secrets**, so nothing here affects the
tenant-safety posture. Optional `.gitattributes`: `*.swift text eol=lf linguist-language=Swift`.

**Swift lint** uses the toolchain-bundled `swift-format` (no extra dependency), scoped to `abgui/Sources`
`abgui/Tests` — it keys off `.swift`, so it can never reach Go.

---

## 6. Unsigned distribution

### 6.1 What "unsigned" really means

**On Apple Silicon a truly unsigned Mach-O will not execute** — the kernel requires at least an **ad-hoc**
signature (the linker auto-applies one at build). So "unsigned distribution" here means **ad-hoc signed
(`codesign -s -`), just not Developer ID-signed or notarized** — free, no Apple Developer account.

**The real distribution blocker is the `com.apple.quarantine` xattr** (mark-of-the-web), not the signature.
A quarantined, non-notarized app is blocked on first launch; a self-compiled or `git clone`'d one runs with
no prompt. **macOS 15 Sequoia removed the Control-click → "Open" bypass**, so the reliable path is a documented
`xattr` strip.

### 6.2 SwiftPM → unsigned universal `.app`

SwiftPM has **no `application` product type** — `swift build` emits a bare Mach-O, not a `.app`, and a bare
executable tends to launch as a background/accessory process with no Dock presence. So abgui hand-assembles
a real bundle. `swift build --arch arm64 --arch x86_64` yields a **universal** Swift binary in one shot;
`abctl` (Go) is built `GOARCH=arm64` + `amd64` and combined with `lipo`.

```bash
set -euo pipefail
APP="bin/abgui.app"
swift build -c release --arch arm64 --arch x86_64            # universal Swift exe
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp abgui/.build/apple/Products/Release/abgui "$APP/Contents/MacOS/abgui"
sed "s/@VERSION@/$VERSION/g" abgui/Packaging/Info.plist > "$APP/Contents/Info.plist"
cp abgui/Resources/AppIcon.icns "$APP/Contents/Resources/"
cp bin/abctl LICENSE NOTICE     "$APP/Contents/Resources/"   # universal abctl + attribution travel along
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Ad-hoc sign INSIDE-OUT (nested tool first). Avoid deprecated --deep; sign each Mach-O explicitly.
codesign -s - --force "$APP/Contents/Resources/abctl"
codesign -s - --force "$APP/Contents/MacOS/abgui"
codesign -s - --force "$APP"
```

`Info.plist` essentials: `CFBundleIdentifier=com.gigaion.abgui`, `CFBundleExecutable=abgui`,
`CFBundlePackageType=APPL`, `CFBundleName`, `CFBundleShortVersionString`/`CFBundleVersion=@VERSION@`,
`LSMinimumSystemVersion=14.0`, `NSHighResolutionCapable=true`, `CFBundleIconFile=AppIcon`, plus a
`GIEmbeddedAbctlVersion=@VERSION@` provenance key. **Do not** set `LSUIElement` (abgui is a normal foreground
app) and **do not** add sandbox entitlements. Icon without Xcode: `sips` to resize a 1024px master into an
`AppIcon.iconset/`, then `iconutil -c icns`.

**Minimum macOS: 14 Sonoma** — unlocks `@Observable` (clean SwiftUI state without Combine),
`NavigationSplitView`, `Table` (ideal for the list-heavy screens), `.inspector`, and `FileHandle.bytes`.
Building SwiftUI needs the macOS SDK from **Xcode _or_ the Command Line Tools** — CI needs a Mac runner with
CLT, but not the Xcode IDE. This is the one hard platform dependency added to the otherwise-Go monorepo.

### 6.3 Where `abctl` comes from — decided: embedded, always

**abgui ships as a full, self-contained `.app` with a universal `abctl` embedded inside it** —
`abgui.app/Contents/Resources/abctl` (arm64 + x86_64 fused with `lipo`), ad-hoc-signed during assembly.
Installing abgui installs everything: **one** download, works offline, and the CLI is **version-locked** to
the GUI by construction (§7.4). abgui resolves it at runtime via
`Bundle.main.url(forResource: "abctl", withExtension: nil)` — an **absolute, bundled path**, never a `PATH`
lookup (Finder-launched apps get a minimal `PATH` with no `/opt/homebrew/bin` anyway). This is the product
model and is not configurable in a normal install.

*Developer-only override (not a distribution mode):* a hidden Settings "Path to `abctl`" field lets someone
hacking on abgui point it at a locally-built CLI; it defaults to — and falls back to — the embedded binary,
and never changes the fact that every release `.app` is fully self-contained. Build-from-source is likewise
a dev workflow only. **Do not rely on bare `PATH` discovery** for the override — require an explicit path.

### 6.4 Why it must NOT be sandboxed (and needs no Hardened Runtime)

- A sandboxed app cannot `posix_spawn`/`Process`-exec an arbitrary tool, and any child would inherit the
  sandbox.
- The sandbox confines reads to the app container — it **cannot read `~/.abctl/contexts.yaml` or the EC key
  at its arbitrary stored path**.
- abgui both execs `abctl` **and** relies on `abctl` reading `~/.abctl` + the key path — sandboxing breaks
  both. Since abgui is not App Store-bound, simply **omit** `com.apple.security.app-sandbox`. Skip Hardened
  Runtime too (only relevant for notarization, which v1 does not do).

### 6.5 Exact steps a user runs

Ship a **zip/tarball** (`ditto -c -k --sequesterRsrc --keepParent`) plus a `HOW-TO-RUN-UNSIGNED.txt`:

```
1. Unzip and move abgui.app to /Applications.
2. Strip the download quarantine (covers the nested abctl too):
      xattr -dr com.apple.quarantine /Applications/abgui.app
3. Double-click abgui.app — it launches immediately.

If you skip step 2, first launch is blocked; then use:
   System Settings → Privacy & Security → Security → "abgui was blocked…" → Open Anyway → authenticate → Open.
This is expected for an unsigned build; a signed + notarized build (a later, opt-in step) would not need it.
```

---

## 7. Build + CI / release

### 7.1 Script glue

Rather than dilute the reconcile engine `scripts/pipeline.sh` (which carries tenant credentials), add a
**parallel `scripts/build-gui.sh`** that adopts its idioms (`set -euo pipefail`, colored `log`/`warn`/`die`,
`have()`, repo-root locate, a single `VERSION` source, `is_ci` awareness) but stays separate — GUI packaging
is macOS-only and **credential-free**. It owns the platform guard, builds a universal `abctl` with the **same
`VERSION`/ldflags** the Makefile and GoReleaser use, builds the universal Swift app, assembles the unsigned
`.app`, and zips it.

```bash
require_macos() { [ "$(uname -s)" = Darwin ] || die "abgui builds on macOS only"; have swift || die "no swift toolchain"; }
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
LDFLAGS="-s -w -X github.com/GigaionLLC/abcli/internal/cli.version=$VERSION"

build_universal_abctl() {                      # the exact abctl the .app ships, stamped identically
  GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "$LDFLAGS" -o bin/abctl-arm64 ./cmd/abctl
  GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "$LDFLAGS" -o bin/abctl-amd64 ./cmd/abctl
  lipo -create -output bin/abctl bin/abctl-arm64 bin/abctl-amd64
}
# subcommands: build (swift debug) · app (assemble §6.2) · run (app + open) · test (swift test) · zip · clean
```

### 7.2 Makefile targets

Append; leave the existing Go targets and `.PHONY` intact. They delegate to the script, which owns the macOS
guard — so `make build`/`make test` on Linux/Windows CI are unaffected:

```make
# --- GUI (abgui) — macOS only; all logic in scripts/build-gui.sh ---
.PHONY: gui gui-app gui-run gui-test gui-clean
gui:       ; ./scripts/build-gui.sh build   ## compile the Swift app (debug)
gui-app:   ; ./scripts/build-gui.sh app     ## assemble the unsigned universal abgui.app (embeds abctl)
gui-run:   ; ./scripts/build-gui.sh run     ## build + launch locally
gui-test:  ; ./scripts/build-gui.sh test    ## swift test
gui-clean: ; ./scripts/build-gui.sh clean   ## remove Swift build products + the .app
```

### 7.3 CI — a macOS job gated on GUI changes

New `.github/workflows/gui.yml` on `macos-latest`, gated on `paths: ['abgui/**', 'scripts/build-gui.sh',
'.github/workflows/gui.yml']` (mirrors how CD gates on `gitops/**`). A GUI app can't fully launch headless,
so the smoke test is: `swift test` (Backend/Models decode + exit-code logic, no display), `lipo -info` (prove
the bundle is universal), and running the **embedded** `abctl --version` (prove path resolution + the ad-hoc
signature actually execs on Apple Silicon).

```yaml
name: GUI
on:
  pull_request: { paths: ['abgui/**','scripts/build-gui.sh','.github/workflows/gui.yml'] }
  push:         { branches: [main], paths: ['abgui/**','scripts/build-gui.sh','.github/workflows/gui.yml'] }
  workflow_dispatch:
permissions: { contents: read }
jobs:
  build-gui:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version-file: go.mod, cache: true }        # to compile the embedded abctl
      - run: make gui-test
      - run: make gui-app
      - run: |
          lipo -info bin/abgui.app/Contents/MacOS/abgui         # expect: arm64 x86_64
          bin/abgui.app/Contents/Resources/abctl --version      # embedded CLI execs, exit 0
      - uses: actions/upload-artifact@v4
        with: { name: abgui-app, path: bin/abgui.app, if-no-files-found: error }
```

> **Keep this job non-required.** A `paths`-filtered job that doesn't run can leave a required PR check
> pending forever; gate any required variant behind a `dorny/paths-filter` step in an always-running job.

### 7.4 Release — beside the GoReleaser flow

GoReleaser runs on `ubuntu` and builds only the Go binaries — it **cannot** produce a Swift `.app`. Add a
second job to `release.yml` on the same `v*` tag that builds the `.app` on macOS and uploads it to the release
GoReleaser just created:

```yaml
  gui-release:
    needs: goreleaser                       # goreleaser creates the GitHub Release first
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }             # full history → matching git describe
      - uses: actions/setup-go@v5
        with: { go-version-file: go.mod, cache: true }
      - run: ./scripts/build-gui.sh zip      # → bin/abgui-<ver>-macos.zip + the run-note
      - env: { GH_TOKEN: '${{ secrets.GITHUB_TOKEN }}' }
        run: gh release upload "${GITHUB_REF_NAME}" bin/abgui-*-macos.zip docs/HOW-TO-RUN-UNSIGNED.txt --clobber
```

**Versioning: version-locked** — a single monorepo tag governs both, because the `.app` embeds the exact
`abctl` built from the same commit, so compatibility is guaranteed by construction and matches "abgui is a
frontend to *this* abctl." One `git describe` value stamps **both** the embedded `abctl` ldflags **and** the
`Info.plist` (`CFBundleShortVersionString`/`CFBundleVersion` + the `GIEmbeddedAbctlVersion` provenance key).
A runtime `AbctlVersion` guard (`static let minimumAbctl`) covers the dev PATH-fallback case where an older
external `abctl` might be resolved. **GitLab** mirrors this: a `gui` build job and a tag-gated `gui-release`
job on a macOS runner (SaaS `saas-macos-*` or self-hosted), gated with `rules: changes: [abgui/**]` /
`rules: if: $CI_COMMIT_TAG =~ /^v\d/`; note the macOS-runner requirement in [cicd.md](cicd.md).

**Testing** (all via `swift test`, no IDE):

1. Inject a `MockAbctlRunner` returning canned `(stdout, stderr, code)` keyed by argv — deterministic,
   offline, no credentials.
2. Golden-JSON fixtures captured from real `abctl … -o json`, decoded through the **same** `JSONDecoder` the
   app uses, so an Apple schema change breaks a test, not the UI.
3. Exit-code tests: `3 → .changesPending`; `1 + stderr → .cliError`; `0 + malformed stdout → decode error
   surfaced cleanly`.
4. View-model unit tests over pixel snapshots (a data app's logic is in state transforms).
5. One integration smoke test: exec the **bundled** `abctl --version`/`--help` to prove path resolution, the
   ad-hoc signature, and the pipe plumbing.

---

## 8. Security

abgui inherits `abctl`'s tenant-safety posture rather than re-implementing it — that is the point of the
frontend/backend split.

- **Never displays private keys — by construction.** The context store holds only a **filesystem path** to
  the EC key (`Context.KeyPath`), never key material. The connection picker (`context list`/`get -o json`)
  can surface `client_id` / key **path** / `api_base` / `scope` and nothing more. A native file-picker
  chooses a `.pem`; abgui passes only the **path** to `abctl --key`. abgui never reads the key, never mints
  a token, never touches ES256 (all in `abctl`'s `internal/ab/auth.go`).
- **Reuses `abctl`'s write gating verbatim.** Every mutation is read-only-by-default in the engine; abgui
  shows its **own** confirmation dialog, then invokes with `--yes` (per-action, auditable) — it never
  bypasses the gate and never relies on the empty-stdin prompt. `--prune` (deletes/detaches) and
  `--limit-writes N` (circuit breaker) are **explicit, off-by-default toggles** in the apply dialog,
  mirroring the CLI defaults.
- **Archive / rollback as first-class UI.** Because `abctl` archives every live config to
  `gitops/archive/<name>/<ts>--<reason>.mobileconfig` (+ `.json` sidecar) before any overwrite/delete, abgui
  surfaces this as an **undo/history panel**: browse prior live versions and restore one via
  `replace config -f - --yes`. abgui treats `archive/` as read-mostly local state and **never** offers to
  commit it (it can carry tenant secrets and is gitignored even after the rest of `gitops/` is adopted).
- **No secrets in logs.** abgui captures stderr as a **log stream** for a diagnostics pane, but the tokens
  and key never appear there (`abctl` never logs them). abgui must not echo the bearer token in the UI; if
  expiry is ever needed, prefer the structured `whoami --json` field (P1) over scraping `auth token` text.
- **Subprocess hygiene.** Resolve `abctl` to an **absolute** path (bundled `Resources/abctl` or an explicit
  Settings override), never via a mutable PATH. Pass arguments as an **argv array** (`Process.arguments`) —
  no shell interpolation, so profile names / paths can't inject. Set an explicit `cwd`, a minimal
  environment, and a per-command timeout; terminate (SIGTERM→SIGKILL) on cancellation. Write profile XML to
  the child's **stdin** (`-f -`) rather than temp files, so edited profiles never touch disk.
- **Not sandboxed on purpose** (§6.4) — a deliberate, documented trade to allow subprocess exec and
  `~/.abctl` reads; acceptable because abgui is a locally-installed operator tool, not App Store software.

---

## 9. Phased roadmap

| Phase | Theme | Deliverable | abctl deps |
|---|---|---|---|
| **v0** | Skeleton | SwiftPM package, `AbctlRunner`/`AbctlClient`, `MockAbctlRunner`, bundle assembly (`build-gui.sh app`), unsigned `.app` that launches and runs the bundled `abctl --version`. CI `gui.yml`. | none |
| **v1** | Read-only browse + GitOps view | Context switcher; Configurations/Blueprints/Devices/Users/Groups/Apps/MDM-Servers lists; config detail + profile XML pane; audit viewer; coverage inspector; dashboard tiles; **diff/plan view**; **drift badges**; raw API console (GET). | none (P1/P2/P6 improve polish) |
| **v2** | Writes | Config lifecycle editor (create / GUI-"edit" via replace / delete); blueprint membership editor (attach/detach); `apply -f` preview+apply; validate; raw API console writes (gated). All via `--yes` behind abgui's confirm. | P4 (write ids), N2 (validate JSON) recommended |
| **v3** | GitOps sync | `sync --apply` with the gating dialog (`--prune`/`--limit-writes` toggles); seed / pull adopt-from-live; archive/rollback browser; streaming apply progress. | N1 (`--stream`) for live progress |
| **later** | Backend-gated / distribution | ADE device→MDM-server assignment, AppleCare, activities, ASM, analytics, CSV — each **behind new `abctl` backend work**; optional Developer ID signing + notarization; optional in-app auto-update. | new `abctl` endpoints (§4.3) |

Gate every feature that depends on a proposed addition on the capability reported by `version -o json` (P2),
so abgui **degrades gracefully** against an older `abctl` instead of breaking.

---

## 10. Risks + open decisions for the human

- **Exit-code `2` is documented but not emitted.** The design docs say "2 = usage," but `main.go` maps only
  `Code:1`/`Code:3`; cobra usage errors become exit `1`. abgui treats non-0/non-3 as failure today —
  **decide** whether to implement proposal N4 (emit real `2`) so abgui can flag its own argv bugs.
- ~~`whoami` has no JSON~~ — **resolved (P1 shipped):** `auth whoami --json` is the typed "test connection."
- ~~single-write commands emit no stdout id~~ — **resolved (P4 shipped):** `create`/`replace`/`delete`/
  `attach`/`detach --json` return the id + archived-copy path, so no re-list after a write.
- **abctl delivery model — DECIDED: embedded.** abgui ships as a full self-contained `.app` with a universal
  `abctl` bundled inside (§6.3); the bundled binary is always primary and the app is not dependent on any
  externally-installed CLI. The dev-only Settings path override exists but is not a distribution mode. No open
  question remains here.
- **Approval model.** Per-call `--yes` (recommended, auditable) vs a blanket `ABCTL_APPROVE=1` on the child
  env (simpler, but weakens the gate for any nested command). **Decide.**
- **Diff fidelity.** The current plan carries `{action, detail}` only. A rich **side-by-side** XML diff would
  need a new `--json` field carrying desired/live bodies (or a dedicated `diff config <name> --json`) —
  larger than the listed prereqs. **Decide** whether v1's action-level diff suffices.
- **Streaming vs end-of-run apply.** Is end-of-run JSON acceptable for v3, or is NDJSON (`--stream`, N1)
  required before shipping the apply screen, given `--limit-writes` batching over many configs/blueprints?
- **ADE scope.** Pursuing the reference app's flagship bulk device→MDM-server assignment means a real
  `abctl` backend project (`mdmServers/{id}/relationships/devices` writes + `orgDeviceActivities` polling) —
  **not** a GUI-only feature. **Decide** if it's on the roadmap at all, and likewise **Apple School Manager**
  (needs ASM scopes + ADE endpoints) and **AppleCare/analytics** (first-class `abctl` commands vs the raw
  `api` console).
- **CSV export.** Add `-o csv` to `abctl` (reusable in CI, N5) vs format from JSON in the frontend. **Decide.**
- **macOS floor.** 14 Sonoma (recommended — `@Observable`/`Table`/`NavigationSplitView`) vs 13 Ventura for
  older-Mac reach. **Confirm** the audience's oldest supported Mac.
- **Distribution channel.** Zip/tarball (pairs cleanly with the `xattr -dr` instruction) vs DMG (nicer UX
  but reliably applies quarantine). **Decide** the documented user steps.
- **Signing trajectory.** Ship unsigned + un-notarized now (recommended pre-1.0, zero-cost) vs invest in
  Developer ID signing + notarization (needs an Apple Developer account + CI secrets) before first GUI
  release. Note: ad-hoc signatures change on every rebuild, so any future auto-update must re-run the
  quarantine step. **Decide** whether in-app auto-update is ever in scope.
- **CI provisioning.** Confirm the Mac CI runner has the Command Line Tools / macOS SDK — building SwiftUI
  headlessly requires it even without the Xcode IDE.
- **NOTICE scope.** The root `NOTICE` names only `abctl`. Since the repo now ships two components, broaden
  its first line (e.g. `abctl and abgui — Copyright 2026 Gigaion, LLC`) so the single root `NOTICE`
  legitimately covers the GUI.

---

## License

[AGPL-3.0-or-later](../LICENSE) — Copyright © 2026 **Gigaion, LLC**. See [../NOTICE](../NOTICE). Add the two-line
SPDX header (`// Copyright 2026 Gigaion, LLC` / `// SPDX-License-Identifier: AGPL-3.0-or-later`) to every `.swift`
file, and ship `LICENSE` + `NOTICE` inside the `.app` and the release zip.