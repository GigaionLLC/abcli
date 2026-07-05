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
                        .disabled(selection == nil)
                    Button { confirmRestore = true } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                        .disabled(selection == nil || model.isWriting)
                    Button { model.loadArchive() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
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
            if let error = model.lastWriteError {
                Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal)
            }
        }
    }
}

/// A read-only sheet showing an archived profile's XML (from the local file).
struct ArchiveFileView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ArchiveEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entry.configName) — \(entry.archivedAt)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text((try? String(contentsOf: entry.fileURL, encoding: .utf8)) ?? "(couldn't read this archived file)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
