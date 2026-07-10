// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Blueprints list. Details (or double-click) opens the blueprint inspector with the
/// six name-resolved member collections (InspectSheets.swift).
struct BlueprintsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Resource.ID?
    @State private var detail: Resource?

    var body: some View {
        Table(model.blueprints, selection: $selection) {
            TableColumn("Name") { Text($0.attr("name") ?? $0.id) }
            TableColumn("Status") { Text($0.attr("status") ?? "—") }
            TableColumn("ID") { Text($0.id).font(.system(.body, design: .monospaced)) }
        }
        .contextMenu(forSelectionType: Resource.ID.self) { _ in
        } primaryAction: { ids in
            openDetail(ids.first)
        }
        .overlay {
            ListStateOverlay(isLoading: model.isLoading, error: model.loadError,
                             isEmpty: model.blueprints.isEmpty,
                             emptyTitle: "No blueprints", emptySymbol: "square.stack.3d.up")
        }
        .navigationTitle("Blueprints")
        .toolbar {
            Button { openDetail(selection) } label: { Label("Details", systemImage: "eye") }
                .disabled(selection == nil)
            RefreshButton { await model.loadBlueprints() }
        }
        .sheet(item: $detail) { BlueprintDetailSheet(resource: $0) }
        .task {
            if model.blueprints.isEmpty { await model.loadBlueprints() }
        }
    }

    private func openDetail(_ id: Resource.ID?) {
        guard let id, let blueprint = model.blueprints.first(where: { $0.id == id }) else { return }
        detail = blueprint
    }
}
