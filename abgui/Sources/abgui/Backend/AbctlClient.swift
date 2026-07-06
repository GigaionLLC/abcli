// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A typed error mapped from abctl's exit code + stderr (see docs/abgui-design.md §2.5).
enum AbctlError: Error, LocalizedError {
    case cli(String)          // exit 1: runtime error / aborted write — carries stderr
    case usage(String)        // any other non-0/non-3 exit — likely an argv bug in abgui
    case decode(Error)        // exit 0 but stdout did not decode
    case changesPending       // exit 3: a NORMAL "drift/plan pending" state, not a failure
    case timedOut             // the child outstayed its timeout and was terminated

    var errorDescription: String? {
        switch self {
        case .cli(let s):   return s.isEmpty ? "abctl reported an error." : s
        case .usage(let s): return "unexpected abctl exit: \(s)"
        case .decode(let e): return "could not decode abctl output: \(e.localizedDescription)"
        case .changesPending: return "changes pending."
        case .timedOut: return "abctl timed out and was stopped."
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
    /// Resolved against the workspace (cwd), where the `gitops/` tree lives.
    func plan() async throws -> Plan {
        try await decodeJSON(Plan.self, ["diff", "--json"], cwd: repoRoot)
    }

    /// Reconcile the tenant to the workspace's git desired state (gated; abgui confirms
    /// first, so --yes). `--prune` allows deletes/detaches; `--limit-writes` caps writes.
    func syncApply(prune: Bool, limitWrites: Int?) async throws -> ApplyResult {
        var args = ["sync", "--apply", "--yes", "--json"]
        if prune { args.append("--prune") }
        if let limitWrites, limitWrites > 0 { args += ["--limit-writes", String(limitWrites)] }
        return try await decodeJSON(ApplyResult.self, args, cwd: repoRoot, timeout: .seconds(180))
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

    // MARK: plumbing

    private func argv(_ base: [String]) -> [String] {
        guard let context, !context.isEmpty else { return base }
        return base + ["--context", context]
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
