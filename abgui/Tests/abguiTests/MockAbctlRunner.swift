// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
@testable import abgui

/// A deterministic, offline `AbctlRunner`: returns canned results keyed by the first one
/// or two argv tokens (e.g. "version", "auth whoami", "get configurations"). No binary,
/// no credentials — the seam that makes the whole client layer unit-testable.
struct MockAbctlRunner: AbctlRunner {
    var responses: [String: AbctlResult]

    func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
        let twoKey = args.prefix(2).joined(separator: " ")
        if let hit = responses[twoKey] { return hit }
        if let first = args.first, let hit = responses[first] { return hit }
        return AbctlResult(stdout: Data(), stderr: "no mock for \(args.joined(separator: " "))", code: 1)
    }

    static func ok(_ stdout: String) -> AbctlResult {
        AbctlResult(stdout: Data(stdout.utf8), stderr: "", code: 0)
    }
}
