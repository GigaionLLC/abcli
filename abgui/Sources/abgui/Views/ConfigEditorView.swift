// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Create a new configuration, or edit an existing one's profile XML and save (→ replace).
/// This is abgui's "edit": fetch → edit in-app → `replace config -f - --yes`. Every write
/// is gated by abctl (--yes); this sheet's Save button IS the human confirmation.
struct ConfigEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// nil → create; non-nil → edit that config.
    let existing: Resource?

    @State private var name = ""
    @State private var xml = ""
    @State private var loading = false
    @State private var loadError: String?

    private var isEdit: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Create") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
            Divider()

            if !isEdit {
                TextField("Name (e.g. WiFi-Corp)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .padding([.horizontal, .top])
            }

            editor

            if let error = model.lastWriteError {
                Text(error).foregroundStyle(.red).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom])
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .task {
            if isEdit { await loadXML() }
        }
    }

    private var title: String {
        if let existing { return "Edit \(existing.attr("name") ?? existing.id)" }
        return "New Configuration"
    }

    @ViewBuilder private var editor: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
        } else {
            TextEditor(text: $xml)
                .font(.system(.footnote, design: .monospaced))
                .padding(4)
        }
    }

    private var canSave: Bool {
        guard !model.isWriting, !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return isEdit || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadXML() async {
        guard let existing else { return }
        loading = true
        loadError = nil
        do {
            xml = try await model.profile(for: existing.id)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func save() async {
        let ok: Bool
        if let existing {
            ok = await model.replaceConfiguration(id: existing.id, xml: xml)
        } else {
            ok = await model.createConfiguration(name: name, xml: xml)
        }
        if ok { dismiss() }
    }
}
