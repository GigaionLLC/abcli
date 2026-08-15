// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A typed error mapped from abctl's exit code + stderr (see docs/abgui-design.md §2.5).
enum AbctlError: Error, LocalizedError {
    case cli(String)          // exit 1: runtime error / aborted write — carries stderr
    case usage(String)        // any other non-0/non-3 exit — likely an argv bug in abgui
    case decode(Error)        // exit 0 but stdout did not decode
    case changesPending       // exit 3: a NORMAL "drift/plan pending" state, not a failure
    case timedOut(seconds: Int, lastOutput: String) // outstayed its timeout — carries what abctl last printed

    var errorDescription: String? {
        switch self {
        case .cli(let s):   return s.isEmpty ? "abctl reported an error." : s
        case .usage(let s): return "unexpected abctl exit: \(s)"
        case .decode(let e): return "could not decode abctl output: \(e.localizedDescription)"
        case .changesPending: return "changes pending."
        case .timedOut(let seconds, let lastOutput):
            // Timeouts are almost always the network round-trip to Apple, so name the likely
            // causes and show whatever abctl managed to print before it hung.
            let waited = seconds >= 1 ? "\(seconds)s" : "under a second"
            var msg = "abctl ran for \(waited) without finishing and was stopped. It reaches Apple's API "
                + "(api-business.apple.com and account.apple.com) for live data, so this is usually a slow or "
                + "blocked network (VPN/proxy/firewall), a rate-limited token, or credentials that aren't set. "
                + "This limit is abgui's command guardrail, not an Apple timeout; large tenants can spend several "
                + "minutes fetching per-profile detail before writes begin. "
                + "Check the connection dot in the sidebar; for diff/apply, also confirm the chosen folder "
                + "contains a gitops/ tree."
            let tail = lastOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { msg += "\n\nLast output from abctl:\n\(tail)" }
            return msg
        }
    }
}

/// One `sync --apply` run: the decoded per-item result PLUS the raw termination facts. The two
/// are inseparable because abctl's exit code carries a verdict the result document does not
/// (see `AbctlClient.syncApplyRun`), and stderr carries the sentence explaining it.
struct ApplyRun {
    let result: ApplyResult
    let code: Int32
    let stderr: String
}

/// The facade: one Swift method per abctl verb. Owns argv, JSON decoding, and exit-code
/// mapping so views never touch `Process`. This v0 covers the read + version surface;
/// write verbs land in v2 (all gated by `--yes` behind an in-app confirm).
struct AbctlClient {
    let runner: AbctlRunner
    /// Threaded as `--context <ctx>` on every call when non-nil.
    var context: String?
    /// The GitOps workspace (dir containing `gitops/`). Used as cwd for the tree-relative
    /// verbs (diff / sync) — a context is a connection, not a repo location.
    var repoRoot: URL?

    private static let decoder = JSONDecoder()
    private static let planTimeout: Duration = .seconds(600)
    private static let applyTimeout: Duration = .seconds(1_200)
    /// The fan-out reads outgrow the plain 60s read budget, so they get double:
    /// `status device` (one relationship call per blueprint + the MDM inventory list),
    /// `get usergroup --members` (one API call per member), and `get mdmserver
    /// --devices` (walks the whole org device inventory to resolve serials).
    private static let fanOutTimeout: Duration = .seconds(120)
    /// `validate` only reads local files, but a big lib/ plus a slow external
    /// `$ABCTL_VALIDATOR` still deserves more than the plain read budget.
    private static let validateTimeout: Duration = .seconds(120)
    /// Membership verbs (attach / detach / adopt) are multi-call: resolve the blueprint, list
    /// configurations for name↔id, read the blueprint's current members, then write. The plain
    /// 60s read budget killed `adopt` mid-flight on a real tenant and left the manifest
    /// unwritten while reporting only "abctl ran for 60s" — a timeout is indistinguishable from
    /// a broken feature. The per-call cost is fixed on the abctl side (see `liveConfigIndex`);
    /// this is the headroom for a slow network or a large tenant on top of that.
    private static let membershipTimeout: Duration = .seconds(180)

    // MARK: reads

    func version() async throws -> VersionInfo {
        try await decodeJSON(VersionInfo.self, ["version", "-o", "json"])
    }

    func whoami() async throws -> WhoamiResult {
        try await decodeJSON(WhoamiResult.self, ["auth", "whoami", "-o", "json"])
    }

    func configurations() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "configurations", "-o", "json"])
    }

    func blueprints() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "blueprints", "-o", "json"])
    }

    func devices() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "devices", "-o", "json"])
    }

    // Read-only inventory / identity / Apps & Books — all live GETs, never writable.
    func users() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "users", "-o", "json"])
    }
    func userGroups() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "usergroups", "-o", "json"])
    }
    func apps() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "apps", "-o", "json"])
    }
    func packages() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "packages", "-o", "json"])
    }
    func mdmServers() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "mdmservers", "-o", "json"])
    }
    func audit(since: String) async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "audit", "--since", since, "-o", "json"])
    }
    func osReleases() async throws -> [OSRelease] {
        try await decodeJSON([OSRelease].self, ["get", "os-releases", "-o", "json"])
    }
    /// Built-in-MDM device inventory: devices enrolled in the BUILT-IN device management
    /// service, with last-reported posture attributes (not live device queries).
    func mdmDevices() async throws -> [Resource] {
        try await decodeJSON([Resource].self, ["get", "mdmdevices", "-o", "json"])
    }

    // MARK: singular inspection reads — the `get <one>` / `status device` detail
    // commands (abctl Phase A). Composite payloads decode via Models/Inspect.swift;
    // the JSON shapes are defined by the Go side (internal/cli/inspect.go, get.go).

    /// One org device + its assigned MDM server; `appleCare` also fetches coverage
    /// records (one extra API call, so it stays behind an explicit button).
    func deviceDetail(_ serialOrID: String, appleCare: Bool = false) async throws -> DeviceDetail {
        var args = ["get", "device", serialOrID]
        if appleCare { args.append("--applecare") }
        args.append("--json")
        return try await decodeJSON(DeviceDetail.self, args)
    }

    /// One built-in-MDM device + its last-reported posture details.
    func mdmDeviceDetail(_ serialOrID: String) async throws -> MDMDeviceDetail {
        try await decodeJSON(MDMDeviceDetail.self, ["get", "mdmdevice", serialOrID, "--json"])
    }

    /// One user — a plain Resource (read-only; identity is not API-writable).
    func userDetail(_ emailOrID: String) async throws -> Resource {
        try await decodeJSON(Resource.self, ["get", "user", emailOrID, "--json"])
    }

    /// One user group; `members` resolves member emails (one API call per member,
    /// so it stays behind an explicit affordance — and gets the fan-out budget).
    func userGroupDetail(_ nameOrID: String, members: Bool = false) async throws -> UserGroupDetail {
        var args = ["get", "usergroup", nameOrID]
        if members { args.append("--members") }
        args.append("--json")
        return try await decodeJSON(UserGroupDetail.self, args,
                                    timeout: members ? Self.fanOutTimeout : .seconds(60))
    }

    /// One owned app (Apps & Books) — a plain Resource.
    func appDetail(_ nameOrID: String) async throws -> Resource {
        try await decodeJSON(Resource.self, ["get", "app", nameOrID, "--json"])
    }

    /// One package (custom app/pkg) — a plain Resource.
    func packageDetail(_ nameOrID: String) async throws -> Resource {
        try await decodeJSON(Resource.self, ["get", "package", nameOrID, "--json"])
    }

    /// One MDM server; `devices` lists its assigned device serials (a whole-inventory
    /// walk on the CLI side, so it gets the fan-out budget).
    func mdmServerDetail(_ nameOrID: String, devices: Bool = false) async throws -> MDMServerDetail {
        var args = ["get", "mdmserver", nameOrID]
        if devices { args.append("--devices") }
        args.append("--json")
        return try await decodeJSON(MDMServerDetail.self, args,
                                    timeout: devices ? Self.fanOutTimeout : .seconds(60))
    }

    /// One blueprint with member counts + all six name-resolved member collections.
    func blueprintDetail(_ nameOrID: String) async throws -> BlueprintDetail {
        try await decodeJSON(BlueprintDetail.self, ["get", "blueprint", nameOrID, "--json"])
    }

    /// One device end-to-end: MDM server + blueprint/config membership (desired state)
    /// and built-in-MDM posture (last reported). Fans out per-blueprint relationship
    /// calls, hence the longer budget. (The CLI also takes --applecare here, but the
    /// GUI fetches coverage via `deviceDetail(appleCare:)` instead, so it isn't threaded.)
    func deviceStatus(_ serialOrID: String) async throws -> DeviceStatusReport {
        try await decodeJSON(DeviceStatusReport.self, ["status", "device", serialOrID, "--json"],
                             timeout: Self.fanOutTimeout)
    }

    /// Poll one assign/unassign activity — a plain Resource whose attributes carry
    /// status / subStatus / createdDateTime.
    func activityStatus(_ id: String) async throws -> Resource {
        try await decodeJSON(Resource.self, ["status", "activity", id, "--json"])
    }

    // Apps & Books (VPP) — read-only, via `abctl vpp …`. The content token is passed as
    // --vpp-token (a separate credential from the Business API context).
    func vppConfig(token: String) async throws -> VPPServiceConfig {
        try await decodeJSON(VPPServiceConfig.self, ["vpp", "config", "-o", "json", "--vpp-token", token])
    }
    func vppAssets(token: String) async throws -> [VPPAsset] {
        try await decodeJSON([VPPAsset].self, ["vpp", "assets", "-o", "json", "--vpp-token", token])
    }
    func vppAssignments(token: String) async throws -> [VPPAssignment] {
        try await decodeJSON([VPPAssignment].self, ["vpp", "assignments", "-o", "json", "--vpp-token", token])
    }
    func vppUsers(token: String) async throws -> [VPPUser] {
        try await decodeJSON([VPPUser].self, ["vpp", "users", "-o", "json", "--vpp-token", token])
    }

    /// Validate the workspace's `gitops/` profiles + blueprint references. Local-only — it
    /// reads files, so no tenant calls and no credentials are required (it is the one verb
    /// that works before a connection exists). `validate` exits 1 when the report says
    /// `ok:false` and STILL prints the report on stdout, so the payload is decoded BEFORE
    /// the exit code is mapped: a failing report is data to render, not an error to throw.
    func validateProfiles() async throws -> ValidationReport {
        let result = try await runner.run(argv(Self.validateArgs()), cwd: repoRoot, stdin: nil,
                                          timeout: Self.validateTimeout)
        do {
            return try Self.decoder.decode(ValidationReport.self, from: result.stdout)
        } catch {
            // Nothing decodable on stdout means the RUN failed (no gitops/ tree, a bad flag,
            // an abctl too old to know --json), so abctl's own stderr is the better message;
            // fall back to the decode error only when it somehow exited 0.
            try Self.checkExit(result)
            throw AbctlError.decode(error)
        }
    }

    /// The 3-way plan. `diff --json` prints it and exits 0 — drift is a non-empty plan.
    /// Resolved against the workspace (cwd), where the `gitops/` tree lives. Diff makes live
    /// API calls (and may mint/refresh a token), so it gets a longer budget than a plain read.
    func plan(gitSourceOfTruth: Bool = false, refresh: String = "smart") async throws -> Plan {
        try await decodeJSON(Plan.self, Self.planArgs(gitSourceOfTruth: gitSourceOfTruth, refresh: refresh),
                             cwd: repoRoot, timeout: Self.planTimeout)
    }

    /// Initialize (or refresh) the workspace's GitOps tree from live tenant state: `abctl seed`
    /// downloads live configurations + blueprints into `<workspace>/gitops/` plus a baseline,
    /// creating the tree if it doesn't exist. Reads the tenant and writes LOCAL files only (no
    /// tenant mutation, so no --yes gate). Output is human text, not JSON.
    @discardableResult
    func seed() async throws -> String {
        let result = try await runner.run(argv(Self.seedArgs()), cwd: repoRoot, stdin: nil, timeout: .seconds(120))
        try Self.checkExit(result)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Reconcile the tenant to the workspace's git desired state (gated; abgui confirms
    /// first, so --yes). `prune` is the raw "allow deletes/detaches" toggle — `syncApplyArgs`
    /// forces it on under git-as-truth, so callers pass what the user chose and nothing more;
    /// `--limit-writes` caps writes.
    ///
    /// Decodes stdout BEFORE mapping the exit code — the same rule `validateProfiles()` follows,
    /// and for the same reason. `sync --apply --json` prints the COMPLETE ApplyResult (with a
    /// per-item `status:"error"` and a detail naming each failure) and only THEN returns
    /// `ExitError{1}` (internal/cli/phase1.go), and `cmd/abctl/main.go` exits SILENTLY for an
    /// ExitError. Running that through the shared `decodeJSON` — which calls `checkExit` first —
    /// threw the structured truth away and raised `.cli(stderr)`: a hundred lines of "building
    /// plan: …" narration presented to the user as "the error". A partially-failed apply is
    /// DATA to render, not an error to throw; only a run that produced no result document at
    /// all falls through to the exit-code mapping. Every other verb keeps today's mapping, so
    /// `decodeJSON`/`checkExit` are deliberately untouched.
    func syncApply(prune: Bool, limitWrites: Int?, gitSourceOfTruth: Bool = false, refresh: String = "smart", verify: String = "targeted") async throws -> ApplyResult {
        try await syncApplyRun(prune: prune, limitWrites: limitWrites, gitSourceOfTruth: gitSourceOfTruth,
                               refresh: refresh, verify: verify).result
    }

    /// The same run, with the exit code and stderr KEPT alongside the decoded result. abctl can
    /// print a complete, every-item-`done` result document and still exit non-zero — post-apply
    /// verification re-reads what it wrote and fails the run when Apple did not persist it
    /// (`internal/cli/phase1.go` → `finishApply`), and Apple answers `2xx` to a PATCH it then
    /// silently drops. Reporting that as a clean sync would be the same class of bug as showing
    /// narration as the error, so the caller gets both halves and `SyncFailure` decides.
    func syncApplyRun(prune: Bool, limitWrites: Int?, gitSourceOfTruth: Bool = false,
                      refresh: String = "smart", verify: String = "targeted") async throws -> ApplyRun {
        let args = Self.syncApplyArgs(prune: prune, limitWrites: limitWrites,
                                      gitSourceOfTruth: gitSourceOfTruth,
                                      refresh: refresh, verify: verify)
        let result = try await runner.run(argv(args), cwd: repoRoot, stdin: nil, timeout: Self.applyTimeout)
        do {
            let decoded = try Self.decoder.decode(ApplyResult.self, from: result.stdout)
            return ApplyRun(result: decoded, code: result.code, stderr: result.stderr)
        } catch {
            // Nothing decodable on stdout means abctl never got as far as applying (bad
            // credentials, no gitops/ tree, an Apple 403 while building the plan), so its own
            // stderr is the better message; fall back to the decode error only if it exited 0.
            try Self.checkExit(result)
            throw AbctlError.decode(error)
        }
    }

    /// Run an operator-typed command and hand back all three streams verbatim.
    ///
    /// It goes through the SAME seam as every button: `argv(_:)` appends `--context`, the run
    /// happens in the workspace, and `RecordingRunner` records and redacts it — so a typed
    /// command reaches the same tenant, resolves the same `gitops/` tree, and appears in the
    /// Command Log exactly like one abgui issued itself. Threading credentials by hand is the
    /// thing this replaces; that is the whole point of the console.
    ///
    /// Unlike every other method here it does NOT map the exit code to an error: a non-zero exit
    /// is a RESULT to display, not a failure to swallow. `abctl diff --exit-on-diff` returning 3
    /// is the plainest example — that is drift, not breakage.
    func runConsole(_ base: [String], timeout: Duration = .seconds(600)) async throws -> AbctlResult {
        try await runner.run(argv(base), cwd: repoRoot, stdin: nil, timeout: timeout)
    }

    /// The raw `.mobileconfig` XML for a config (stdout is XML, not JSON).
    func configurationProfile(_ id: String) async throws -> String {
        let result = try await runner.run(argv(["get", "configuration", id, "--profile"]),
                                          cwd: repoRoot, stdin: nil, timeout: .seconds(60))
        try Self.checkExit(result)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    // MARK: writes — every one passes --yes (abgui shows its OWN confirm first) and --json.

    /// Create a CUSTOM_SETTING config from profile XML (POST). XML goes on stdin (`-f -`).
    func createConfiguration(name: String, xml: Data) async throws -> WriteOutcome {
        try await decodeJSON(WriteOutcome.self, ["create", "config", name, "-f", "-", "--yes", "--json"], stdin: xml)
    }

    /// Replace a config's profile (archive live, then PATCH). This is the GUI "edit".
    func replaceConfiguration(id: String, xml: Data) async throws -> WriteOutcome {
        try await decodeJSON(WriteOutcome.self, ["replace", "config", id, "-f", "-", "--yes", "--json"], stdin: xml)
    }

    /// Delete a config (archive live, then DELETE).
    func deleteConfiguration(id: String) async throws -> WriteOutcome {
        try await decodeJSON(WriteOutcome.self, ["delete", "config", id, "--yes", "--json"])
    }

    /// Attach a config to a blueprint (additive membership).
    func attach(configID: String, blueprint: String) async throws -> WriteOutcome {
        try await decodeJSON(WriteOutcome.self, ["attach", "config", configID, "--blueprint", blueprint, "--yes", "--json"],
                             timeout: Self.membershipTimeout)
    }

    /// Detach a config from a blueprint.
    func detach(configID: String, blueprint: String) async throws -> WriteOutcome {
        try await decodeJSON(WriteOutcome.self, ["detach", "config", configID, "--blueprint", blueprint, "--yes", "--json"],
                             timeout: Self.membershipTimeout)
    }

    /// Record an already-attached member in the blueprint's git manifest. LOCAL ONLY — it writes
    /// `gitops/blueprints/<bp>.yml` and never the tenant, which is why it carries no `--yes`
    /// (there is nothing to gate) and why it must run in the workspace like every tree verb.
    func adoptMember(kind: String, name: String, blueprint: String) async throws -> WriteOutcome {
        try await decodeJSON(WriteOutcome.self, Self.adoptArgs(kind: kind, name: name, blueprint: blueprint),
                             timeout: Self.membershipTimeout)
    }

    /// Assign org devices to an MDM server. Apple processes assignment asynchronously —
    /// the outcome carries the activity id to poll via `activityStatus`.
    func assignDevices(serials: [String], server: String) async throws -> ActivityOutcome {
        try await decodeJSON(ActivityOutcome.self, Self.assignArgs(serials: serials, server: server, unassign: false))
    }

    /// Unassign org devices from an MDM server (async, same activity-id contract).
    func unassignDevices(serials: [String], server: String) async throws -> ActivityOutcome {
        try await decodeJSON(ActivityOutcome.self, Self.assignArgs(serials: serials, server: server, unassign: true))
    }

    // MARK: connection contexts (~/.abctl/contexts.yaml — the credential store)
    //
    // These MANAGE the context store, so they are never threaded with --context (which
    // SELECTS a context to resolve). The private key is always passed as a file PATH — key
    // material never touches argv, so it can't leak via a process listing or an error string.

    func contextList() async throws -> ContextList {
        try await decodeControl(ContextList.self, ["context", "list", "-o", "json"])
    }

    func contextDetail(_ name: String?) async throws -> ContextDetail {
        var args = ["context", "get"]
        if let name, !name.isEmpty { args.append(name) }
        args += ["-o", "json"]
        return try await decodeControl(ContextDetail.self, args)
    }

    /// Create or update a context (client id + key path + optional API base), optionally
    /// making it current. `keyPath` is a filesystem path to the EC private key.
    func saveContext(name: String, clientID: String, keyPath: String, apiBase: String?, makeCurrent: Bool) async throws {
        var args = ["context", "set", name, "--client-id", clientID, "--key", keyPath]
        if let apiBase, !apiBase.isEmpty { args += ["--api-base", apiBase] }
        if makeCurrent { args.append("--use") }
        try await runControl(args)
    }

    func useContext(_ name: String) async throws { try await runControl(["context", "use", name]) }
    func deleteContext(_ name: String) async throws { try await runControl(["context", "delete", name]) }

    // MARK: argv builders — the preview/execute parity seam
    //
    // The verbs abgui PREVIEWS (ApplySheet, ValidateSheet, AssignSheet) build their argv from
    // these same pure functions the methods above run, so the command an administrator reads
    // before pressing a gated button is byte-for-byte the command that executes. Re-spelling a
    // flag in a view is the one way that guarantee breaks — hence `static` and pure, so a view
    // has no excuse to hand-roll one. There is a contract test asserting the parity.
    //
    // These deliberately do NOT carry the `--context` suffix: at run time `argv(_:)` appends it
    // from this client's context, and a preview appends it from the model's via
    // `AppModel.previewArgv(_:)`. One tail, added in one place per path.

    /// `sync --apply` — the gated converge. `--yes` is baked in because abgui shows its OWN
    /// confirmation first; the flag ordering is part of the contract test, so keep it.
    ///
    /// `prune` is the RAW "allow deletes / detaches" toggle: git-as-truth forces pruning ON here,
    /// inside the one function that spells the flags, rather than at each callsite. That rule used
    /// to live in `AppModel.apply` AND again in ApplySheet's preview expression — two copies of
    /// the condition governing the most destructive flag this command has, where the preview
    /// silently stops matching the run the moment one of them changes.
    static func syncApplyArgs(prune: Bool, limitWrites: Int?, gitSourceOfTruth: Bool,
                              refresh: String, verify: String) -> [String] {
        var args = ["sync", "--apply", "--yes", "--json"]
        if gitSourceOfTruth { args.append("--git-source-of-truth") }
        // Desired state without deletes/detaches would only ever be half-applied, so git-as-truth
        // implies --prune whatever the toggle says.
        if prune || gitSourceOfTruth { args.append("--prune") }
        args += ["--refresh", refresh, "--verify", verify]
        if let limitWrites, limitWrites > 0 { args += ["--limit-writes", String(limitWrites)] }
        return args
    }

    /// `diff --json` — the 3-way plan, resolved against the workspace cwd.
    static func planArgs(gitSourceOfTruth: Bool, refresh: String) -> [String] {
        var args = ["diff", "--json"]
        if gitSourceOfTruth { args.append("--git-source-of-truth") }
        args += ["--refresh", refresh]
        return args
    }

    /// `validate --json` — local files only, so this is the one previewable command that needs
    /// no credentials.
    static func validateArgs() -> [String] { ["validate", "--json"] }

    /// `assign` / `unassign` — one builder, because the two verbs differ only in that word and
    /// splitting them would be two chances to get the gated device write's argv wrong.
    static func assignArgs(serials: [String], server: String, unassign: Bool) -> [String] {
        [unassign ? "unassign" : "assign", "--server", server] + serials + ["--yes", "--json"]
    }

    /// `seed` — initialize the workspace tree from the tenant (reads live, writes local files).
    static func seedArgs() -> [String] { ["seed"] }

    /// `adopt` — record a live blueprint member in the git manifest. No `--yes`: this writes
    /// local files only, so there is no tenant change to confirm.
    static func adoptArgs(kind: String, name: String, blueprint: String) -> [String] {
        ["adopt", kind, name, "--blueprint", blueprint, "--json"]
    }

    /// The `--context` tail every run appends. `static` so a PREVIEW can build the same tail from
    /// the model's context without a client (`AppModel.previewArgv`) instead of re-spelling the
    /// flag: the empty-means-omit rule then exists once, and a preview cannot name a different
    /// tenant than the run it is advertising.
    static func contextSuffixed(_ base: [String], context: String?) -> [String] {
        guard let context, !context.isEmpty else { return base }
        return base + ["--context", context]
    }

    // MARK: plumbing

    private func argv(_ base: [String]) -> [String] { Self.contextSuffixed(base, context: context) }

    /// Run a context-store command (raw argv, no --context threading, no repo cwd).
    @discardableResult
    private func runControl(_ args: [String]) async throws -> AbctlResult {
        let result = try await runner.run(args, cwd: nil, stdin: nil, timeout: .seconds(30))
        try Self.checkExit(result)
        return result
    }

    private func decodeControl<T: Decodable>(_ type: T.Type, _ args: [String]) async throws -> T {
        let result = try await runControl(args)
        do {
            return try Self.decoder.decode(T.self, from: result.stdout)
        } catch {
            throw AbctlError.decode(error)
        }
    }

    /// Runs in the WORKSPACE unless a caller overrides `cwd`.
    ///
    /// abctl resolves the `gitops/` tree against its process working directory (a context is a
    /// connection, not a repo location — internal/config/context.go), so a tree-mutating verb run
    /// from anywhere else updates a different tree, or none. `attach`/`create`/`replace`/`delete`
    /// all write the tree inline; run from the app bundle's cwd (`/`) they silently failed to,
    /// while `diff` — which DID pass the workspace — read the real one. The tenant changed, git
    /// did not, and the resulting `detach-config` row came back on every refresh with nothing in
    /// the GUI able to clear it.
    ///
    /// Defaulting the whole surface to the workspace (rather than adding `cwd:` at each write
    /// callsite) is deliberate: the next verb someone adds cannot forget it. Read verbs are
    /// unaffected by cwd except that a workspace-local `.env` now resolves the same way it
    /// already did for diff/sync/seed — one tenant per workspace, not one per verb.
    private func decodeJSON<T: Decodable>(_ type: T.Type, _ base: [String], stdin: Data? = nil,
                                          cwd: URL? = nil, timeout: Duration = .seconds(60)) async throws -> T {
        let result = try await runner.run(argv(base), cwd: cwd ?? repoRoot, stdin: stdin, timeout: timeout)
        try Self.checkExit(result)
        do {
            return try Self.decoder.decode(T.self, from: result.stdout)
        } catch {
            throw AbctlError.decode(error)
        }
    }

    /// Map the termination status to a typed outcome (docs/abgui-design.md §2.5).
    static func checkExit(_ r: AbctlResult) throws {
        switch r.code {
        case 0: return
        case 3: throw AbctlError.changesPending
        case 1: throw AbctlError.cli(r.stderr)
        default: throw AbctlError.usage(r.stderr)
        }
    }
}
