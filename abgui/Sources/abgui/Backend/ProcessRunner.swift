// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Runs the embedded abctl as a subprocess. An `actor` so it never blocks the main
/// thread, and it drains stdout/stderr concurrently with the wait so a full pipe buffer
/// can never deadlock the child.
actor ProcessRunner: AbctlRunner {
    let executable: URL

    init(executable: URL) { self.executable = executable }

    func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        try process.run()

        // Write stdin (e.g. profile XML for `create -f -`) then close so abctl sees EOF.
        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
        }
        try? inPipe.fileHandleForWriting.close()

        // Watchdog: if the child outstays `timeout`, terminate it. That closes its pipes
        // (so the drains below reach EOF) and lets waitUntilExit return — a wedged or
        // network-hung abctl can never freeze the caller forever. Cancelled on success.
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }

        // Drain both pipes concurrently, THEN wait — reading first avoids the classic
        // 64 KB-pipe-buffer deadlock for large `get devices` / `sync` outputs.
        async let out = Self.readToEnd(outPipe.fileHandleForReading)
        async let err = Self.readToEnd(errPipe.fileHandleForReading)
        let stdout = await out
        let stderr = await err
        process.waitUntilExit()

        // The watchdog ran to completion iff it fired (timeout); if it was still sleeping
        // we cancel it and its sleep throws — telling success from timeout precisely.
        watchdog.cancel()
        var timedOut = false
        do { try await watchdog.value; timedOut = true } catch { timedOut = false }
        if timedOut {
            // Hand back what abctl printed before it hung (usually the most diagnostic thing)
            // plus how long we waited, so the UI can show an actionable message, not just "timed out".
            throw AbctlError.timedOut(seconds: Int(timeout.components.seconds),
                                      lastOutput: String(decoding: stderr, as: UTF8.self))
        }

        return AbctlResult(
            stdout: stdout,
            stderr: String(decoding: stderr, as: UTF8.self),
            code: process.terminationStatus
        )
    }

    /// Read a pipe to EOF off the actor (and off the main thread).
    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}
