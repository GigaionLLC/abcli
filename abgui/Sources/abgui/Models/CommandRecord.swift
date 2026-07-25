// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One abctl invocation abgui made, recorded so an administrator can see — and reproduce —
/// exactly what the GUI did. abgui is a thin facade over the CLI, so every button ultimately
/// IS an abctl command; surfacing it turns the app into documentation for its own backend.
///
/// `argv` is REDACTED at construction: a secret-bearing value can never enter this type, so
/// nothing downstream (the command log, a copy button, a progress line, a screenshot in a
/// support ticket) can leak one. There is deliberately no way to recover the raw argv here.
struct CommandRecord: Identifiable, Hashable, Sendable {
    /// How the invocation ended. `.running` until the child exits.
    enum Status: Hashable, Sendable {
        case running
        case succeeded
        case failed(Int32)
        case cancelled
        case timedOut
    }

    /// What abgui fed the child on stdin. Only the SIZE is kept — never the content — but it is
    /// enough for the copyable form to rewrite `-f -` into a real file path, since a pasted
    /// `-f -` would otherwise sit waiting on an empty terminal forever.
    enum Stdin: Hashable, Sendable {
        case none
        case profile(bytes: Int)
    }

    let id: UUID
    /// Redacted argv, WITHOUT the leading "abctl" (the formatter adds it).
    let argv: [String]
    /// The working directory the command ran in. Load-bearing, not decoration: `diff`/`sync`
    /// resolve the `gitops/` tree relative to it, so a copied command is wrong without the `cd`.
    let cwd: URL?
    let startedAt: Date
    var finishedAt: Date?
    var status: Status
    var stdin: Stdin

    init(argv: [String],
         cwd: URL?,
         stdin: Stdin = .none,
         status: Status = .running,
         startedAt: Date = Date(),
         id: UUID = UUID()) {
        self.id = id
        self.argv = CommandFormatter.redact(argv) // the invariant: never store a secret
        self.cwd = cwd
        self.stdin = stdin
        self.status = status
        self.startedAt = startedAt
    }

    /// Wall-clock time the child ran, once it has finished.
    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    /// The command as a single copy-pasteable line: `abctl sync --apply --yes`.
    var commandLine: String { CommandFormatter.line(argv) }

    /// The full reproduction snippet: `cd` into the workspace, the command, and a note when
    /// abgui piped a profile in on stdin.
    var script: String { CommandFormatter.script(argv: argv, cwd: cwd, stdin: stdin) }

    /// What the GitOps progress logs print when the command starts. The `$` prefix is what makes
    /// these lines read as a shell transcript rather than as more of abctl's narration.
    var startLogLine: String { "$ \(commandLine)" }

    /// The matching completion line: `→ exit 0 in 2.4s`.
    var finishLogLine: String {
        guard let text = durationText else { return "→ \(statusText)" }
        return "→ \(statusText) in \(text)"
    }

    var statusText: String {
        switch status {
        case .running: return "running"
        case .succeeded: return "exit 0"
        case .failed(let code): return "exit \(code)"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed out"
        }
    }

    var durationText: String? {
        guard let duration else { return nil }
        if duration >= 60 {
            let whole = Int(duration.rounded())
            return "\(whole / 60)m \(whole % 60)s"
        }
        return String(format: "%.1fs", duration)
    }

    var isFailure: Bool {
        switch status {
        case .failed, .timedOut: return true
        case .running, .succeeded, .cancelled: return false
        }
    }
}

/// Turns argv into text for humans. This is the ONE place that conversion happens — the live
/// preview in a sheet, the `$ …` lines in the GitOps progress logs, the Command Log page and
/// every copy button all route through here, so what the user is shown BEFORE a run and what
/// is recorded after it cannot drift apart.
enum CommandFormatter {
    /// Flags whose VALUE is a credential. Adding a future secret-bearing flag is one line here.
    /// Deliberately NOT redacted: `--client-id` and `--context` (identifiers the UI already
    /// displays) and `--key` (a filesystem path, not key material) — hiding those would make a
    /// copied command unusable without protecting anything.
    static let redactedFlags: Set<String> = ["--vpp-token"]
    static let redactionPlaceholder = "****"

    /// Replace the value of every credential-bearing flag. Handles both `--flag value` and
    /// `--flag=value`, and is idempotent (re-redacting already-redacted argv is a no-op), so it
    /// is safe to apply defensively at display time as well as at record time.
    static func redact(_ argv: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(argv.count)
        var skipNext = false
        for arg in argv {
            if skipNext {
                skipNext = false
                out.append(redactionPlaceholder)
                continue
            }
            if redactedFlags.contains(arg) {
                out.append(arg)
                skipNext = true // the NEXT token is the secret
                continue
            }
            if let eq = arg.firstIndex(of: "="), redactedFlags.contains(String(arg[arg.startIndex..<eq])) {
                out.append("\(arg[arg.startIndex..<eq])=\(redactionPlaceholder)")
                continue
            }
            out.append(arg)
        }
        return out
    }

    /// `abctl <args>` on one line, POSIX-quoted where a token needs it.
    static func line(_ argv: [String]) -> String {
        (["abctl"] + redact(argv).map(quote)).joined(separator: " ")
    }

    /// The copy-paste form: the `cd` that makes a tree-relative command correct, the command
    /// itself, and — when abgui piped a profile in — a note plus a real path in place of `-f -`.
    static func script(argv: [String], cwd: URL?, stdin: CommandRecord.Stdin) -> String {
        var lines: [String] = []
        if let cwd {
            lines.append("cd \(quote(cwd.path))")
        }
        switch stdin {
        case .none:
            lines.append(line(argv))
        case .profile(let bytes):
            let file = profileFileName(from: argv)
            lines.append(line(rewriteStdinFlag(argv, to: file)))
            lines.append("# abgui sent the profile on stdin (\(bytes) bytes); export it to \(file) first.")
        }
        return lines.joined(separator: "\n")
    }

    /// POSIX single-quoting: leave shell-safe tokens bare so the common case stays readable,
    /// and quote anything else (spaces in a config name, an empty argument, shell metacharacters).
    static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
        if s.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Swap the `-f -` (read stdin) pair for a real path, so the copied line runs unattended.
    private static func rewriteStdinFlag(_ argv: [String], to file: String) -> [String] {
        var out = argv
        for i in out.indices.dropLast() where out[i] == "-f" && out[i + 1] == "-" {
            out[i + 1] = file
            break
        }
        return out
    }

    /// Derive a plausible on-disk name for a stdin-fed profile from the command's positional
    /// argument (`create config <name> -f -` / `replace config <id> -f -`).
    private static func profileFileName(from argv: [String]) -> String {
        let positional = argv.count > 2 && (argv[0] == "create" || argv[0] == "replace") ? argv[2] : "profile"
        var slug = ""
        for ch in positional {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." {
                slug.append(ch)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "profile" }
        if !slug.lowercased().hasSuffix(".mobileconfig") { slug += ".mobileconfig" }
        return "./" + slug
    }
}
