// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Turns a typed command line into argv, the way a shell would.
///
/// The console hands what you type straight to the same `AbctlRunner` seam the buttons use — no
/// shell is involved, so quoting has to be honoured HERE or a configuration named
/// `Corp WiFi.mobileconfig` arrives as two arguments and the command fails for a reason that
/// looks nothing like the cause.
enum CommandLineParser {
    /// Split on whitespace, respecting single and double quotes and backslash escapes. A leading
    /// `abctl` is dropped: people paste whole command lines, and the binary is implied.
    ///
    /// Deliberately NOT a shell: no globbing, no `$VAR`, no pipes or redirection. Those would be
    /// promises this cannot keep — there is no shell behind them — and a `$TOKEN` that silently
    /// expanded would put a secret on argv, which is the one thing this app never does.
    static func tokenize(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false // distinguishes a real empty argument ("") from no argument at all

        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                started = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                started = true
                continue
            }
            if ch.isWhitespace {
                if started { out.append(current) }
                current = ""
                started = false
                continue
            }
            current.append(ch)
            started = true
        }
        if started { out.append(current) }

        if let first = out.first, first.lowercased() == "abctl" { out.removeFirst() }
        return out
    }

    /// Verbs that change the live tenant. Used only to WARN — the gate itself stays abctl's job,
    /// and this list being wrong must never be what decides whether a write happens.
    static let writeVerbs: Set<String> = [
        "create", "replace", "edit", "delete", "attach", "detach",
        "assign", "unassign", "apply", "sync",
    ]

    /// True when the command would write to Apple Business AND carries its own approval. abgui
    /// shows its own confirmation before running one of these, because a typed `--yes` is the
    /// only path in the app that reaches a tenant write without a button having asked first.
    static func isApprovedTenantWrite(_ argv: [String]) -> Bool {
        guard let verb = argv.first?.lowercased(), writeVerbs.contains(verb) else { return false }
        // `sync` only writes with --apply; a bare `sync` is a dry run.
        if verb == "sync" && !argv.contains("--apply") { return false }
        // `api` is excluded from writeVerbs entirely: its method lives in a flag, and abctl
        // gates any non-GET itself.
        return argv.contains("--yes")
    }

    /// True for a write verb typed WITHOUT approval. Worth saying out loud: abctl will ask on
    /// stdin, the console gives it none, and the command aborts having changed nothing. That is
    /// a safe outcome but a confusing one if you expected it to run.
    static func isUnapprovedWrite(_ argv: [String]) -> Bool {
        guard let verb = argv.first?.lowercased(), writeVerbs.contains(verb) else { return false }
        if verb == "sync" && !argv.contains("--apply") { return false }
        return !argv.contains("--yes")
    }
}
