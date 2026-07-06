// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Runs the embedded abctl as a subprocess. An `actor` so it never blocks the main
/// thread, and it drains stdout/stderr concurrently with the wait so a full pipe buffer
/// can never deadlock the child.
actor ProcessRunner: AbctlRunner {
    let executable: URL
    /// Called with each stderr line as abctl prints it (progress narration). The closure runs
    /// off the main thread, so a UI consumer must hop to the main actor itself. nil = no streaming.
    let onStderrLine: (@Sendable (String) -> Void)?

    init(executable: URL, onStderrLine: (@Sendable (String) -> Void)? = nil) {
        self.executable = executable
        self.onStderrLine = onStderrLine
    }

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

        // If the caller's Task is cancelled (e.g. a Cancel button), terminate the child so it
        // doesn't linger; its pipes then close, the drains reach EOF, and we unwind below.
        return try await withTaskCancellationHandler {
            // Watchdog: if the child outstays `timeout`, terminate it. That closes its pipes
            // (so the drains below reach EOF) and lets waitUntilExit return — a wedged or
            // network-hung abctl can never freeze the caller forever. Cancelled on success.
            let watchdog = Task {
                try await Task.sleep(for: timeout)
                process.terminate()
            }

            // Drain both pipes concurrently, THEN wait — reading first avoids the classic
            // 64 KB-pipe-buffer deadlock. stderr streams line-by-line to `onStderrLine`.
            async let out = Self.readToEnd(outPipe.fileHandleForReading)
            async let err = Self.streamToEnd(errPipe.fileHandleForReading, onLine: onStderrLine)
            let stdout = await out
            let stderr = await err
            process.waitUntilExit()

            // The watchdog ran to completion iff it fired (timeout); if it was still sleeping
            // we cancel it and its sleep throws — telling success from timeout precisely.
            watchdog.cancel()
            var timedOut = false
            do { try await watchdog.value; timedOut = true } catch { timedOut = false }

            if Task.isCancelled { throw CancellationError() }
            if timedOut {
                // Hand back what abctl printed before it hung (usually the most diagnostic
                // thing) plus how long we waited, so the UI shows an actionable message.
                throw AbctlError.timedOut(seconds: Int(timeout.components.seconds),
                                          lastOutput: String(decoding: stderr, as: UTF8.self))
            }
            return AbctlResult(
                stdout: stdout,
                stderr: String(decoding: stderr, as: UTF8.self),
                code: process.terminationStatus
            )
        } onCancel: {
            process.terminate()
        }
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

    /// Read a pipe to EOF while emitting each complete line to `onLine` as it arrives (so a UI
    /// can show live progress), returning the full accumulated data. Runs off the main thread.
    private static func streamToEnd(_ handle: FileHandle, onLine: (@Sendable (String) -> Void)?) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var all = Data()
                var pending = Data()
                let emit: (Data) -> Void = { lineData in
                    guard let onLine,
                          let s = String(data: lineData, encoding: .utf8) else { return }
                    let trimmed = s.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onLine(trimmed) }
                }
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF
                    all.append(chunk)
                    guard onLine != nil else { continue }
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        emit(pending.subdata(in: pending.startIndex..<nl))
                        pending.removeSubrange(pending.startIndex...nl)
                    }
                }
                if onLine != nil, !pending.isEmpty { emit(pending) } // trailing partial line
                continuation.resume(returning: all)
            }
        }
    }
}
