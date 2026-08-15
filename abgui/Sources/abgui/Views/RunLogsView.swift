// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The log viewer: every run abgui has recorded, readable in the app.
///
/// The transcripts have always been written to `~/Library/Logs/abgui/`, but reaching them meant
/// knowing that, and knowing Finder. That is a fine ask of the developer and a poor one of the
/// administrator standing in front of a sync that failed — so the logs come to them: pick a run,
/// read what abctl actually printed, and copy or save it for a bug report.
///
/// Everything here is filesystem-only. No abctl, no network, no credentials — which matters,
/// because a broken connection is exactly when someone needs this screen.
struct RunLogsView: View {
    @Environment(AppModel.self) private var model

    @State private var logs: [RunLogFile] = []
    @State private var selection: RunLogFile.ID?
    @State private var contents: String?
    @State private var loadFailed = false
    @State private var showExporter = false
    @State private var copiedField: String?

    private var selected: RunLogFile? { logs.first { $0.id == selection } }

    var body: some View {
        content
            .navigationTitle("Logs")
            .toolbar {
                Button { copy(contents ?? "", field: "log") } label: {
                    Label("Copy Log", systemImage: "doc.on.doc")
                }
                .toolbarLabel("Copy the whole transcript to the clipboard, ready to paste into a bug report.")
                .disabled(contents == nil)

                Button { showExporter = true } label: { Label("Save a Copy…", systemImage: "square.and.arrow.down") }
                    .toolbarLabel("Write this transcript somewhere you choose, to attach to an email or ticket.")
                    .disabled(contents == nil)

                Button { reveal() } label: { Label("Reveal", systemImage: "folder") }
                    .toolbarLabel("Show this log file in Finder.")
                    .disabled(selected == nil)

                RefreshButton(help: "Re-scan ~/Library/Logs/abgui for run logs.") { reload() }
            }
            .fileExporter(isPresented: $showExporter,
                          document: TextDocument(text: contents ?? ""),
                          contentType: .plainText,
                          defaultFilename: selected?.name ?? "abgui.log") { _ in }
            .task { reload() }
            .onChange(of: selection) { _, _ in loadSelected() }
    }

    @ViewBuilder private var content: some View {
        if logs.isEmpty {
            ContentUnavailableView {
                Label("No run logs yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("abgui writes a transcript for every diff, seed and sync — what it ran, what "
                     + "abctl printed, how long each step took and how the run ended. "
                     + "Run one from Diff / Drift and it will appear here.")
            } actions: {
                Button("Refresh") { reload() }
            }
        } else {
            HStack(spacing: 0) {
                list.frame(width: 300)
                Divider()
                detail
            }
        }
    }

    /// Rows are deliberately FIXED height — one line each, no wrapping. A macOS `List` asks a
    /// self-sizing row for its height at an unbounded width and that combination can cycle until
    /// the window stops rendering (see CommandLogView for the same note); the full, wrapping text
    /// lives in the reading pane, which is not a List.
    private var list: some View {
        List(logs, selection: $selection) { log in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: log))
                        .foregroundStyle(tint(for: log))
                        .accessibilityLabel(Text(log.outcome ?? "unfinished"))
                    Text(log.verb).font(.body.weight(.medium))
                    Spacer(minLength: 0)
                    if let duration = log.duration {
                        Text(duration).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(started(log)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(log.outcome ?? "no footer — the run did not finish")
                    .font(.caption2)
                    .foregroundStyle(log.isFailure || log.isUnfinished ? Color.red : .secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .tag(log.id)
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 8) {
                header(selected)
                Divider()
                if let contents {
                    // ScrollView + one selectable monospaced Text: the transcript is read
                    // top-to-bottom and copied whole, and a per-line view would break both
                    // selection across lines and the copy this screen exists for.
                    ScrollView([.vertical, .horizontal]) {
                        Text(contents)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    .scrollIndicators(.visible)
                } else if loadFailed {
                    ContentUnavailableView("Couldn't read this log", systemImage: "exclamationmark.triangle",
                                           description: Text("The file may have been pruned or moved. Refresh to re-scan."))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("Select a run", systemImage: "sidebar.left",
                                   description: Text("Pick a log on the left to read what that run did."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func header(_ log: RunLogFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(log.name)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("\(started(log)) · \(log.sizeText)\(log.duration.map { " · \($0)" } ?? "")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Said HERE, next to the copy button, not buried in a help page: this is the moment
            // someone is about to paste a transcript into an email. Credentials are the only
            // thing redaction guarantees — the file still names the tenant and its resources.
            Text("Safe to share with the developer, with one caveat: logs contain no credentials, "
                 + "but they do name your organization, configurations, blueprints, device serials "
                 + "and user email addresses. Read before sending.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let copiedField {
                Text("Copied the \(copiedField) to the clipboard.")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func started(_ log: RunLogFile) -> String {
        (log.startedAt ?? log.modifiedAt).formatted(date: .abbreviated, time: .standard)
    }

    private func symbol(for log: RunLogFile) -> String {
        if log.isUnfinished { return "clock.badge.questionmark" }
        return log.isFailure ? "xmark.circle" : "checkmark.circle"
    }

    private func tint(for log: RunLogFile) -> Color {
        if log.isUnfinished { return .orange }
        return log.isFailure ? .red : .green
    }

    private func reload() {
        logs = RunLogIndex.scan()
        // Keep the current selection if it survived the re-scan; otherwise open the newest, which
        // is the run someone almost always came here to read.
        if selection == nil || !logs.contains(where: { $0.id == selection }) {
            selection = logs.first?.id
        }
        loadSelected()
    }

    private func loadSelected() {
        guard let selected else { contents = nil; loadFailed = false; return }
        contents = RunLogIndex.contents(of: selected.url)
        loadFailed = contents == nil
    }

    private func copy(_ text: String, field: String) {
        guard !text.isEmpty else { return }
        CommandClipboard.copy(text)
        copiedField = field
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedField == field { copiedField = nil }
        }
    }

    private func reveal() {
        guard let selected else { return }
        CommandClipboard.reveal(selected.url)
    }
}

/// A plain-text document for `fileExporter`, so "Save a Copy…" can write the transcript anywhere
/// the user picks — the route to an email attachment or a ticket upload.
struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
