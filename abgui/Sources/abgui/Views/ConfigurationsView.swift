// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Configurations list. Select a row (or double-click) to inspect its profile XML.
struct ConfigurationsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Resource.ID?
    @State private var profileTarget: Resource?

    var body: some View {
        Table(model.configurations, selection: $selection) {
            TableColumn("Name") { Text($0.attr("name") ?? $0.id) }
            TableColumn("Type") { Text($0.attr("type") ?? "—") }
            TableColumn("Updated") { Text($0.attr("updatedDateTime") ?? "—") }
        }
        .contextMenu(forSelectionType: Resource.ID.self) { _ in
            // (row menu items land in v2 — create/replace/delete)
        } primaryAction: { ids in
            openProfile(ids.first)
        }
        .overlay {
            ListStateOverlay(isLoading: model.isLoading, error: model.loadError,
                             isEmpty: model.configurations.isEmpty,
                             emptyTitle: "No configurations", emptySymbol: "doc.text")
        }
        .navigationTitle("Configurations")
        .toolbar {
            Button {
                openProfile(selection)
            } label: {
                Label("View Profile", systemImage: "doc.plaintext")
            }
            .disabled(selection == nil)
            RefreshButton { await model.loadConfigurations() }
        }
        .sheet(item: $profileTarget) { ProfileView(config: $0) }
        .task {
            if model.configurations.isEmpty { await model.loadConfigurations() }
        }
    }

    private func openProfile(_ id: Resource.ID?) {
        guard let id, let config = model.configurations.first(where: { $0.id == id }) else { return }
        profileTarget = config
    }
}
