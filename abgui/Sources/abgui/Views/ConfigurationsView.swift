// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Configurations list + lifecycle (v2): create, edit (→ replace), delete, and blueprint
/// membership. Double-click opens the read-only profile; the toolbar drives writes, each
/// behind abgui's own confirm (abctl is invoked with --yes).
struct ConfigurationsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Resource.ID?
    @State private var profileTarget: Resource?
    @State private var editorTarget: EditorTarget?
    @State private var membershipTarget: Resource?
    @State private var confirmDelete = false

    enum EditorTarget: Identifiable {
        case create
        case edit(Resource)
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let resource): return resource.id
            }
        }
    }

    private var selectedResource: Resource? {
        guard let selection else { return nil }
        return model.configurations.first { $0.id == selection }
    }

    var body: some View {
        Table(model.configurations, selection: $selection) {
            TableColumn("Name") { Text($0.attr("name") ?? $0.id) }
            TableColumn("Type") { Text($0.attr("type") ?? "—") }
            TableColumn("Updated") { Text($0.attr("updatedDateTime") ?? "—") }
        }
        .contextMenu(forSelectionType: Resource.ID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let config = model.configurations.first(where: { $0.id == id }) {
                profileTarget = config
            }
        }
        .overlay {
            ListStateOverlay(isLoading: model.isLoading, error: model.loadError,
                             isEmpty: model.configurations.isEmpty,
                             emptyTitle: "No configurations", emptySymbol: "doc.text")
        }
        .navigationTitle("Configurations")
        .toolbar {
            Button { editorTarget = .create } label: { Label("New", systemImage: "plus") }
            Button {
                if let config = selectedResource { editorTarget = .edit(config) }
            } label: { Label("Edit", systemImage: "pencil") }
                .disabled(selection == nil)
            Button {
                membershipTarget = selectedResource
            } label: { Label("Membership", systemImage: "square.stack.3d.up") }
                .disabled(selection == nil)
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection == nil)
            RefreshButton { await model.loadConfigurations() }
        }
        .sheet(item: $profileTarget) { ProfileView(config: $0) }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .create: ConfigEditorView(existing: nil)
            case .edit(let config): ConfigEditorView(existing: config)
            }
        }
        .sheet(item: $membershipTarget) { MembershipSheet(config: $0) }
        .confirmationDialog("Delete this configuration?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = selection { Task { _ = await model.deleteConfiguration(id: id) } }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This archives the live profile, then deletes it from Apple Business.")
        }
        .task {
            if model.configurations.isEmpty { await model.loadConfigurations() }
        }
    }
}
