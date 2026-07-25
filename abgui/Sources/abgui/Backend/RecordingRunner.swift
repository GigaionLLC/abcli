// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// An `AbctlRunner` decorator that reports every invocation to a sink, then forwards it
/// untouched to the real runner.
///
/// This is why "show me the CLI command" costs almost nothing here: every abgui action already
/// funnels through the single `AbctlRunner.run` seam, so ONE wrapper captures the whole command
/// surface — including verbs added later, which get recorded without anyone remembering to
/// instrument them. Nothing above this layer knows it is being watched.
///
/// The sinks run off the main thread (they are called from whatever task drove the command), so
/// a UI consumer must hop to the main actor itself — the same contract as
/// `ProcessRunner.onStderrLine`.
struct RecordingRunner: AbctlRunner {
    let wrapped: AbctlRunner
    /// Called with the redacted record the instant the command starts, so the UI can show it
    /// while the child is still running rather than only in hindsight.
    let onStart: @Sendable (CommandRecord) -> Void
    /// Called once with the terminal status, keyed by the record's id.
    let onFinish: @Sendable (UUID, CommandRecord.Status) -> Void

    init(wrapping wrapped: AbctlRunner,
         onStart: @escaping @Sendable (CommandRecord) -> Void,
         onFinish: @escaping @Sendable (UUID, CommandRecord.Status) -> Void) {
        self.wrapped = wrapped
        self.onStart = onStart
        self.onFinish = onFinish
    }

    func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
        // CommandRecord's initializer redacts, so the secret never reaches the sink.
        let record = CommandRecord(argv: args,
                                   cwd: cwd,
                                   stdin: stdin.map { .profile(bytes: $0.count) } ?? .none)
        onStart(record)
        do {
            let result = try await wrapped.run(args, cwd: cwd, stdin: stdin, timeout: timeout)
            onFinish(record.id, result.code == 0 ? .succeeded : .failed(result.code))
            return result
        } catch let error as CancellationError {
            onFinish(record.id, .cancelled) // the user pressed Cancel — not a failure
            throw error
        } catch let error as AbctlError {
            // A timeout is abgui's own guardrail rather than an abctl exit code, so it gets its
            // own status instead of masquerading as one (`exit -1` would read as a real result).
            if case .timedOut = error {
                onFinish(record.id, .timedOut)
            } else {
                onFinish(record.id, .failed(-1))
            }
            throw error
        } catch {
            onFinish(record.id, .failed(-1)) // spawn failure etc. — no exit code exists
            throw error
        }
    }
}
