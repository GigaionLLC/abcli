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

    /// The 3-way plan. `diff --json` prints it and exits 0 — drift is a non-empty plan.
    /// Resolved against the workspace (cwd), where the `gitops/` tree lives. Diff makes live
    /// API calls (and may mint/refresh a token), so it gets a longer budget than a plain read.
    func plan(gitSourceOfTruth: Bool = false, refresh: String = "smart") async throws -> Plan {
        var args = ["diff", "--json"]
        if gitSourceOfTruth { args.append("--git-source-of-truth") }
        args += ["--refresh", refresh]
        return try await decodeJSON(Plan.self, args, cwd: repoRoot, timeout: Self.planTimeout)
    }

    /// Initialize (or refresh) the workspace's GitOps tree from live tenant state: `abctl seed`
    /// downloads live configurations + blueprints into `<workspace>/gitops/` plus a baseline,
    /// creating the tree if it doesn't exist. Reads the tenant and writes LOCAL files only (no
    /// tenant mutation, so no --yes gate). Output is human text, not JSON.
    @discardableResult
    func seed() async throws -> String {
        let result = try await runner.run(argv(["seed"]), cwd: repoRoot, stdin: nil, timeout: .seconds(120))
        try Self.checkExit(result)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Reconcile the tenant to the workspace's git desired state (gated; abgui confirms
    /// first, so --yes). `--prune` allows deletes/detaches; `--limit-writes` caps writes.
    func syncApply(prune: Bool, limitWrites: Int?, gitSourceOfTruth: Bool = false, refresh: String = "smart", verify: String = "targeted") async throws -> ApplyResult {
        var args = ["sync", "--apply", "--yes", "--json"]
        if gitSourceOfTruth { args.append("--git-source-of-truth") }
        if prune { args.append("--prune") }
        args += ["--refresh", refresh, "--verify", verify]
        if let limitWrites, limitWrites > 0 { args += ["--limit-writes", String(limitWrites)] }
        return try await decodeJSON(ApplyResult.self, args, cwd: repoRoot, timeout: Self.applyTimeout)
    }

    /// The raw `.mobileconfig` XML for a config (stdout is XML, not JSON).
    func configurationProfile(_ id: String) async throws -> String {
        let result = try await runner.run(argv(["get", "configuration", id, "--profile"]),
                                          cwd: nil, stdin: nil, timeout: .seconds(60))
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
        try await decodeJSON(WriteOutcome.self, ["attach", "config", configID, "--blueprint", blueprint, "--yes", "--json"])
    }

    /// Detach a config from a blueprint.
    func detach(configID: String, blueprint: String) async throws -> WriteOutcome {
        try await decodeJSON(WriteOutcome.self, ["detach", "config", configID, "--blueprint", blueprint, "--yes", "--json"])
    }

    /// Assign org devices to an MDM server. Apple processes assignment asynchronously —
    /// the outcome carries the activity id to poll via `activityStatus`.
    func assignDevices(serials: [String], server: String) async throws -> ActivityOutcome {
        try await decodeJSON(ActivityOutcome.self, ["assign", "--server", server] + serials + ["--yes", "--json"])
    }

    /// Unassign org devices from an MDM server (async, same activity-id contract).
    func unassignDevices(serials: [String], server: String) async throws -> ActivityOutcome {
        try await decodeJSON(ActivityOutcome.self, ["unassign", "--server", server] + serials + ["--yes", "--json"])
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

    // MARK: plumbing

    private func argv(_ base: [String]) -> [String] {
        guard let context, !context.isEmpty else { return base }
        return base + ["--context", context]
    }

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

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ base: [String], stdin: Data? = nil,
                                          cwd: URL? = nil, timeout: Duration = .seconds(60)) async throws -> T {
        let result = try await runner.run(argv(base), cwd: cwd, stdin: stdin, timeout: timeout)
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
