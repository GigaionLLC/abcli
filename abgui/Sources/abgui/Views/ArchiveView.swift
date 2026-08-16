// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The rollback browser: every pre-overwrite live version abctl archived, with one-click
/// restore (→ `replace`, which archives the current live version first — a real undo).
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ArchiveEntry.ID?
    @State private var confirmRestore = false
    @State private var viewTarget: ArchiveEntry?

    private var selected: ArchiveEntry? {
        guard let selection else { return nil }
        return model.archiveEntries.first { $0.id == selection }
    }

    var body: some View {
        content
            .navigationTitle("Archive")
            .toolbar {
                if model.repoRoot != nil {
                    Button { viewTarget = selected } label: { Label("View", systemImage: "eye") }
                        .toolbarLabel("Show the archived profile exactly as it was before abctl overwrote or deleted it.")
                        .disabled(selection == nil)
                    Button { confirmRestore = true } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                        .toolbarLabel("Put this archived version back on Apple Business, archiving the CURRENT live version first — a reversible undo.")
                        .disabled(selection == nil || model.isWriting)
                    Button { model.loadArchive() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .toolbarLabel("Re-scan gitops/archive/ on disk. Reads local files only.")
                }
            }
            .confirmationDialog("Restore this archived version?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Restore") {
                    if let entry = selected { Task { _ = await model.restore(entry) } }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Replaces the live profile with this archived copy. The current live version is archived first, so this is reversible.")
            }
            .sheet(item: $viewTarget) { ArchiveFileView(entry: $0) }
            .task(id: model.repoRoot) {
                if model.repoRoot != nil { model.loadArchive() }
            }
    }

    @ViewBuilder private var content: some View {
        if model.repoRoot == nil {
            ContentUnavailableView {
                Label("No GitOps workspace", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose a workspace in Diff / Drift to browse its archive.")
            }
        } else {
            // A VStack, not two bare siblings. This branch emitted the Table and the error Text
            // as an unwrapped pair into a slot that takes ONE view, so the error composited over
            // the middle of the table instead of sitting under it — the same class of layout
            // fault as the safe-area insets, and it only ever showed up when a write had failed.
            VStack(spacing: 0) {
                Table(model.archiveEntries, selection: $selection) {
                    TableColumn("Configuration") { Text($0.configName) }
                    TableColumn("Archived") { Text($0.archivedAt) }
                    TableColumn("Reason") { Text($0.reason) }
                }
                .overlay {
                    if model.archiveEntries.isEmpty {
                        ContentUnavailableView("No archived versions", systemImage: "clock.arrow.circlepath",
                                               description: Text("abctl archives a live profile before each overwrite or delete."))
                    }
                }
                if let error = model.writeError(.archive) {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding([.horizontal, .vertical], 8)
                }
            }
        }
    }
}

/// A read-only sheet showing an archived profile's XML (from the local file).
struct ArchiveFileView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ArchiveEntry

    /// Read ONCE into state, not inside `body`.
    ///
    /// The profile was previously loaded by a synchronous `String(contentsOf:)` in the view
    /// body — up to Apple's 1 MiB cap, on the main actor, re-executed on every body evaluation
    /// rather than once per file. The same class of mistake as rebuilding the whole transcript
    /// per log line: work that looks free because it is written as an expression.
    @State private var contents: String?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entry.configName) — \(entry.archivedAt)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if let contents {
                ScrollView([.horizontal, .vertical]) {
                    Text(contents)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if failed {
                ContentUnavailableView("Couldn't read this archived file", systemImage: "exclamationmark.triangle",
                                       description: Text(entry.fileURL.lastPathComponent))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task(id: entry.fileURL) {
            // Off the main actor: a large archived profile on a slow volume should not
            // stall the window while the sheet is opening.
            let url = entry.fileURL
            let loaded = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
            contents = loaded
            failed = loaded == nil
        }
    }
}
