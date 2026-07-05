// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The raw result of one abctl invocation: the three streams of abctl's contract kept
/// separate — stdout (the machine payload), stderr (human status), and the exit code.
struct AbctlResult: Sendable {
    let stdout: Data
    let stderr: String
    let code: Int32
}

/// The mockable seam. Everything above `AbctlRunner` is pure logic that can be tested
/// with a canned runner and no binary (see `MockAbctlRunner` in the tests).
protocol AbctlRunner: Sendable {
    /// Run abctl with `args`, optionally in `cwd`, optionally feeding `stdin`.
    func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult
}

extension AbctlRunner {
    func run(_ args: [String]) async throws -> AbctlResult {
        try await run(args, cwd: nil, stdin: nil, timeout: .seconds(60))
    }
}
