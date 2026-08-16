// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Type an abctl command; the connection is already threaded.
///
/// The GUI will always cover less than the CLI it wraps. Rather than pretend otherwise, this is
/// the escape hatch: the full command surface, run against the SAME tenant and the SAME workspace
/// the buttons use, with `--context` appended for you. No copying a client id into a terminal, no
/// remembering which directory `gitops/` resolves against — the mismatch that made GUI writes
/// land in the wrong tree is exactly what this removes.
struct ConsoleView: View {
    @Environment(AppModel.self) private var model

    @State private var input = ""
    @State private var historyIndex: Int?
    @State private var pendingWrite: [String]?
    @FocusState private var focused: Bool

    private var argv: [String] { CommandLineParser.tokenize(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            explainer
            Divider()
            transcript
            Divider()
            prompt
        }
        .navigationTitle("Console")
        .toolbar {
            Button { model.clearConsole() } label: { Label("Clear", systemImage: "trash") }
                .toolbarLabel("Clear this session's console output. Nothing on Apple Business or on disk is removed.")
                .disabled(model.consoleEntries.isEmpty)
        }
        // A typed `--yes` is the one route in the app that reaches a tenant write without a
        // button having asked first. It still gets asked.
        .confirmationDialog("Run a command that writes to Apple Business?",
                            isPresented: Binding(get: { pendingWrite != nil },
                                                 set: { if !$0 { pendingWrite = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingWrite) { command in
            Button("Run it", role: .destructive) {
                pendingWrite = nil
                submit(force: true)
            }
            Button("Cancel", role: .cancel) { pendingWrite = nil }
        } message: { command in
            Text("\(CommandFormatter.line(command))\n\nThis carries --yes, so abctl will not stop to "
                 + "confirm. It runs against \(model.context.isEmpty ? "your current context" : model.context).")
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Runs the embedded abctl with your connection already applied — `--context` is appended "
                 + "and the command runs in your workspace folder, so tree-relative verbs resolve the same "
                 + "gitops/ tree the rest of the app uses.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("This is not a shell: no pipes, redirection or variable expansion. Quotes and backslashes work.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top])
        .padding(.bottom, 8)
    }

    /// ScrollView + VStack rather than a List: these rows wrap monospaced output at an unbounded
    /// width, which is the combination that hangs a macOS List (see CommandLogView).
    @ViewBuilder private var transcript: some View {
        if model.consoleEntries.isEmpty {
            ContentUnavailableView {
                Label("Nothing run yet", systemImage: "chevron.left.forwardslash.chevron.right")
            } description: {
                Text("Try `get blueprints`, `status config <name>`, or `diff --json`. "
                     + "Reads are unrestricted; anything that writes still needs its own --yes.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.consoleEntries) { entry in
                            ConsoleEntryRow(entry: entry)
                            Divider()
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: .infinity)
                .onChange(of: model.consoleEntries.count) { _, _ in
                    withAnimation { proxy.scrollTo("tail", anchor: .bottom) }
                }
            }
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: "abctl")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("get devices --filter serialNumber=C02", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.upArrow) { recall(-1) }
                    .onKeyPress(.downArrow) { recall(1) }
                if model.isRunningConsole {
                    ProgressView().controlSize(.small)
                }
                Button("Run") { submit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(argv.isEmpty || model.isRunningConsole)
            }
            if CommandLineParser.isUnapprovedWrite(argv) {
                // Worth saying BEFORE they press Run: abctl asks on stdin, the console gives it
                // none, so the command aborts having changed nothing. Safe, but baffling if you
                // expected it to run.
                Label("This writes to Apple Business, so abctl will ask to confirm — and there's no "
                      + "terminal here to answer. Add --yes to run it.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.35))
        .onAppear { focused = true }
    }

    private func submit(force: Bool = false) {
        let command = argv
        guard !command.isEmpty, !model.isRunningConsole else { return }
        if !force, CommandLineParser.isApprovedTenantWrite(command) {
            pendingWrite = command
            return
        }
        let line = input
        input = ""
        historyIndex = nil
        Task { await model.runConsole(line) }
    }

    /// Shell-style recall: up walks back through what you typed, down walks forward and out.
    private func recall(_ delta: Int) -> KeyPress.Result {
        let history = model.consoleHistory
        guard !history.isEmpty else { return .ignored }
        let next: Int
        switch (historyIndex, delta) {
        case (nil, -1): next = history.count - 1
        case (nil, _):  return .ignored
        case (let current?, _): next = current + delta
        }
        if next < 0 { return .handled }
        if next >= history.count {   // walked off the end — back to an empty prompt
            historyIndex = nil
            input = ""
            return .handled
        }
        historyIndex = next
        input = history[next]
        return .handled
    }
}

/// One command and its three streams. stdout and stderr stay visually distinct because abctl
/// puts the machine payload on one and the human narration on the other — merging them is how a
/// JSON document becomes unparseable and a hundred lines of progress become "the error".
private struct ConsoleEntryRow: View {
    let entry: AppModel.ConsoleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$ " + entry.commandLine)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(entry.isFailure ? Color.red : .secondary)
                    .fixedSize()
                CommandCopyButton(text: copyText, help: "Copy this command and its output.")
            }
            if let failure = entry.failedToStart {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            stream(entry.stdout, tint: .primary)
            stream(entry.stderr, tint: .secondary)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func stream(_ text: String, tint: Color) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            ScrollView(.horizontal) {
                Text(trimmed)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.visible)
        }
    }

    private var status: String {
        if entry.failedToStart != nil { return "did not run" }
        let code = entry.exitCode == 0 ? "exit 0" : "exit \(entry.exitCode)"
        return "\(code) · \(DurationText.short(entry.duration))"
    }

    private var copyText: String {
        var parts = ["$ abctl " + entry.commandLine]
        if !entry.stdout.isEmpty { parts.append(entry.stdout) }
        if !entry.stderr.isEmpty { parts.append(entry.stderr) }
        parts.append("(\(status))")
        return parts.joined(separator: "\n")
    }
}
