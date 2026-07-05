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

    /// The 3-way plan. `diff --json` prints it and exits 0 — drift is a non-empty plan.
    func plan() async throws -> Plan {
        try await decodeJSON(Plan.self, ["diff", "--json"])
    }

    /// The raw `.mobileconfig` XML for a config (stdout is XML, not JSON).
    func configurationProfile(_ id: String) async throws -> String {
        let result = try await runner.run(argv(["get", "configuration", id, "--profile"]),
                                          cwd: nil, stdin: nil, timeout: .seconds(60))
        try Self.checkExit(result)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    // MARK: plumbing

    private func argv(_ base: [String]) -> [String] {
        guard let context, !context.isEmpty else { return base }
        return base + ["--context", context]
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ base: [String]) async throws -> T {
        let result = try await runner.run(argv(base), cwd: nil, stdin: nil, timeout: .seconds(60))
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
