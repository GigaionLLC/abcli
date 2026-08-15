// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import AppKit

/// "Here is the abctl command this button will run." A monospaced, selectable line with a copy
/// button — the GUI teaching its own CLI, sitting next to the controls that compose it.
///
/// It is reference material, not a control: quiet, uncoloured, and never the thing the eye lands
/// on first. The text comes from `CommandFormatter`, the same function that renders the progress
/// logs and the Command Log, and `argv` must come from an `AbctlClient` argv builder — a preview
/// that re-spells the flags by hand is exactly the drift this whole surface exists to prevent.
struct CommandPreview: View {
    let argv: [String]
    var cwd: URL? = nil
    var stdin: CommandRecord.Stdin = .none
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Equivalent CLI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                CommandCopyButton(text: script, help: copyHelp)
            }
            // Shown as it actually executes (`-f -` and all) — the copy button is where the
            // paste-able rewrite lives, so what is displayed stays literally true.
            Text(CommandFormatter.line(argv))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    /// The copy form: the `cd` that makes a tree-relative command correct plus, for a
    /// stdin-fed profile, a real file path in place of `-f -`.
    private var script: String {
        CommandFormatter.script(argv: argv, cwd: cwd, stdin: stdin)
    }

    private var copyHelp: String {
        cwd == nil ? "Copy this command to the clipboard."
                   : "Copy this command, with the cd into the workspace, to the clipboard."
    }

    /// One quiet line underneath: the caller's explanation, which directory the command is
    /// relative to, and — when abgui pipes the profile in — why `-f -` can't be pasted as-is.
    private var detail: String? {
        var parts: [String] = []
        if let caption, !caption.isEmpty { parts.append(caption) }
        if let cwd { parts.append("Runs in \(cwd.lastPathComponent); the copied form includes the cd.") }
        if case .profile = stdin {
            parts.append("abgui sends the profile on stdin (-f -); the copied form reads it from a file instead.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The session's abctl transcript: every command abgui ran, newest first, in a form that can be
/// pasted into Terminal. abgui is a thin facade over the CLI, so this page is both an audit trail
/// ("what did it just do to my tenant?") and the migration path for an administrator who would
/// rather script it.
struct CommandLogView: View {
    @Environment(AppModel.self) private var model

    /// Newest first on screen — the command you are looking for is almost always the last one
    /// you triggered. `AppModel.commands` is stored oldest-first, and the Copy All script keeps
    /// that order: a transcript only reproduces the session if it runs in the order it ran.
    private var rows: [CommandRecord] { Array(model.commands.reversed()) }

    var body: some View {
        content
            .navigationTitle("Command Log")
            .toolbar {
                CommandCopyButton(text: Self.combinedScript(model.commands),
                                  title: "Copy All as Script",
                                  showsTitle: true,
                                  help: "Copy every recorded command, oldest first, as one paste-able shell snippet.")
                    .disabled(model.commands.isEmpty)
                Button { model.clearCommands() } label: { Label("Clear", systemImage: "trash") }
                    .toolbarLabel("Clear this session's command list from the screen. Nothing on Apple Business or on disk is deleted.")
                    .disabled(model.commands.isEmpty)
                    .help("Forget the recorded commands. This empties abgui's list only — nothing on the tenant or on disk changes.")
            }
    }

    @ViewBuilder private var content: some View {
        if model.commands.isEmpty {
            ContentUnavailableView {
                Label("No commands yet", systemImage: "terminal")
            } description: {
                Text("Every abctl command abgui runs is recorded here — with its working directory, "
                     + "exit code and duration — so you can reproduce it in a terminal. "
                     + "Run a diff, a validate or a sync and it will show up.")
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Non-literal String on purpose: a Text string LITERAL is parsed as Markdown,
                // which would eat the **** in the redaction example.
                Text(explainer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 6)
                CommandTimingPanel(records: model.commands)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                // ScrollView + VStack, NOT List. These rows wrap: monospaced command text with
                // .fixedSize(vertical:) inside a .frame(maxWidth: .infinity). A macOS List asks a
                // self-sizing row for its height at an unbounded width, and that combination
                // cycles — the window stops rendering and the app has to be relaunched (it hangs
                // rather than crashing, so there is no report to find afterwards). Every other
                // wrapping surface here (ApplySheet's results and log panes, DiffView's plan rows)
                // uses this pattern for the same reason; the two List screens pass a collection
                // directly and have fixed-height rows. `commands` is capped at 200, so a plain
                // VStack is cheap and keeps this identical to the panes that are known to work.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { record in
                            CommandLogRow(record: record)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
                // Indicators stay hidden until you scroll on macOS, which makes a full log look
                // like it has nothing below the fold.
                .scrollIndicators(.visible)
            }
        }
    }

    /// Scoped deliberately to what redaction actually guarantees. Credentials are the only thing
    /// stripped: a recorded command still names the tenant's client id, the private key's path,
    /// device serial numbers, user email addresses and the workspace path — so promising that
    /// "anything here is safe to paste into a ticket" would be endorsing sending tenant
    /// identifiers and end-user PII to a third party on the strength of a narrower guarantee.
    private var explainer: String {
        "abgui is a front end for abctl: these are the exact commands it ran, newest first. "
            + "Credentials are redacted before a command is recorded (--vpp-token ****). Commands "
            + "still name your connection, configurations and devices, so review one before sharing "
            + "it. A -f - means abgui piped the profile in on stdin; copying a command rewrites that "
            + "to a file path so it runs unattended."
    }

    /// Every recorded command as one snippet, oldest first — a transcript, not a list. When all
    /// of them shared a working directory the `cd` is hoisted to a single line at the top;
    /// otherwise each command keeps its own, because a tree-relative abctl command run from the
    /// wrong directory doesn't fail, it silently works on someone else's gitops/ tree.
    static func combinedScript(_ records: [CommandRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let dirs = Set(records.compactMap(\.cwd))
        if dirs.count == 1, let shared = dirs.first, records.allSatisfy({ $0.cwd != nil }) {
            let commands = records.map { CommandFormatter.script(argv: $0.argv, cwd: nil, stdin: $0.stdin) }
            return (["cd \(CommandFormatter.quote(shared.path))"] + commands).joined(separator: "\n\n")
        }
        return records.map(\.script).joined(separator: "\n\n")
    }
}

/// Where the time goes, per verb — the view that turns a chronological log into an answer.
///
/// The chronological rows below tell you what a run did. This tells you which operation is slow,
/// whether it is slow every time or once, and whether one is STILL RUNNING — the three questions
/// you actually ask when the app feels stuck. Nothing here is newly measured: every invocation is
/// already timed at the single `AbctlRunner.run` seam; this only adds them up.
private struct CommandTimingPanel: View {
    let records: [CommandRecord]
    @State private var expanded = false

    private var rows: [CommandTiming] { CommandTiming.rollUp(records) }
    private var running: [CommandRecord] { records.filter { $0.status == .running } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.verb)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minWidth: 150, alignment: .leading)
                            Text(detail(for: row))
                                .font(.caption2)
                                .foregroundStyle(row.slowest >= CommandRecord.slowThreshold ? Color.orange : .secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(headline).font(.caption)
            }

            // In-flight commands tick, because "how long has this been going?" is the whole
            // question when the app looks hung — and a static "running" cannot answer it. The
            // timeline drives ONLY this strip, so nothing else re-renders on the tick.
            if !running.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(running) { record in
                            let seconds = record.elapsed(asOf: context.date)
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("\(CommandTiming.verbKey(record.argv)) — running \(DurationText.short(seconds))")
                                    .font(.caption2)
                                    .foregroundStyle(seconds >= CommandRecord.slowThreshold ? Color.orange : .secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var headline: String {
        let finished = rows.reduce(0) { $0 + $1.runs }
        guard let slowest = rows.first, slowest.slowest > 0 else {
            return "Timing — no completed commands yet"
        }
        return "Timing — \(finished) command(s), slowest: \(slowest.verb) at \(DurationText.short(slowest.slowest))"
    }

    private func detail(for row: CommandTiming) -> String {
        var parts: [String] = []
        if row.runs > 0 {
            parts.append("\(row.runs)×")
            parts.append("slowest \(DurationText.short(row.slowest))")
            if row.runs > 1 { parts.append("avg \(DurationText.short(row.average))") }
        }
        if row.running > 0 { parts.append("\(row.running) running") }
        if row.failures > 0 { parts.append("\(row.failures) failed") }
        return parts.joined(separator: " · ")
    }
}

/// One recorded invocation: how it ended, what it was, and enough context to tell two otherwise
/// identical lines apart. The command itself is monospaced and selectable and wraps rather than
/// truncating — a `sync` line with a dozen flags is precisely the one worth reading in full.
private struct CommandLogRow: View {
    let record: CommandRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 16)
                // Symbol + tint are the entire outcome for this row, so it has to be spoken.
                .accessibilityLabel(Text(record.statusText))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.commandLine)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(record.isFailure ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            CommandCopyButton(text: record.script,
                              help: record.cwd == nil
                                  ? "Copy this command to the clipboard."
                                  : "Copy this command, with the cd into the workspace, to the clipboard.")
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy command") { CommandClipboard.copy(record.commandLine) }
            Button("Copy with cd") { CommandClipboard.copy(record.script) }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch record.status {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle").foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "xmark.circle").foregroundStyle(Color.red)
        case .timedOut:
            // abgui's own watchdog fired — a distinct outcome from a non-zero exit, since the
            // command may well still have changed something before we stopped waiting.
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Color.red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(Color.secondary)
        }
    }

    /// Time · outcome · duration · workspace · stdin. The workspace is load-bearing, not
    /// decoration: the same `abctl sync` line means something different in another folder.
    private var metadata: String {
        var parts = [record.startedAt.formatted(date: .omitted, time: .standard), record.statusText]
        if let duration = record.durationText { parts.append(duration) }
        if let cwd = record.cwd { parts.append(cwd.lastPathComponent) }
        if case .profile(let bytes) = record.stdin { parts.append("profile on stdin (\(bytes) bytes)") }
        return parts.joined(separator: " · ")
    }
}

/// The copy affordance shared by the preview, the log rows and the toolbar. It copies the SCRIPT
/// form — the one carrying the `cd` and the stdin note — because a command copied without its
/// working directory doesn't fail, it quietly runs somewhere else. Clicking flips it to a
/// checkmark for a moment: without that, a copy button gives no evidence it did anything.
struct CommandCopyButton: View {
    /// `@autoclosure @escaping`, so the string is built when the button is CLICKED rather than on
    /// every view update. The toolbar's "Copy All as Script" concatenates every recorded command;
    /// evaluating that eagerly rebuilt the whole transcript on each render of the page.
    private let makeText: () -> String
    var title = "Copy"
    var showsTitle = false
    var help = "Copy to the clipboard."

    init(text: @autoclosure @escaping () -> String,
         title: String = "Copy",
         showsTitle: Bool = false,
         help: String = "Copy to the clipboard.") {
        self.makeText = text
        self.title = title
        self.showsTitle = showsTitle
        self.help = help
    }

    /// When the last copy happened; nil once the confirmation has been withdrawn. A Date (not a
    /// Bool) so a second click re-arms the `.task(id:)` timer instead of inheriting the first
    /// click's remaining time.
    @State private var copiedAt: Date?

    private var copied: Bool { copiedAt != nil }

    var body: some View {
        styled
            .help(help)
            // Icon-only in most placements, and VoiceOver would otherwise read the symbol name.
            .accessibilityLabel(Text(copied ? "Copied" : title))
            .task(id: copiedAt) {
                guard copiedAt != nil else { return }
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                copiedAt = nil
            }
    }

    /// Bordered where it is a real toolbar action; plain and unobtrusive where it sits inside
    /// reference material, which must not look like the primary thing to click.
    @ViewBuilder private var styled: some View {
        if showsTitle {
            button
        } else {
            button
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
    }

    private var button: some View {
        Button {
            CommandClipboard.copy(makeText())
            copiedAt = Date()
        } label: {
            if showsTitle {
                Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
    }
}

/// The one place abgui writes to the pasteboard. `clearContents()` first is mandatory — without
/// it the new string is added alongside whatever types are already on the board, and a paste can
/// come back as the previous copy.
enum CommandClipboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        _ = board.setString(text, forType: .string)
    }

    /// Select a file in Finder. Here rather than at the callsites so the Logs screen and the
    /// transcript panes reveal identically.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
