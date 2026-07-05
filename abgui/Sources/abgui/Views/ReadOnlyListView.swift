// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// A small pill that marks a screen as read-only.
struct ReadOnlyBadge: View {
    var body: some View {
        Label("Read-only", systemImage: "lock")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary))
    }
}

/// A generic browser for any live, READ-ONLY Apple Business resource. Deliberately has NO
/// write actions — only Refresh + Details — and shows a read-only banner + badge so it's
/// obvious nothing here mutates the tenant. Double-click (or Details) opens the full JSON.
struct ReadOnlyListView: View {
    @Environment(AppModel.self) private var model
    let kind: ReadOnlyKind
    @State private var selection: Resource.ID?
    @State private var detail: Resource?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            banner
            Table(of: Resource.self, selection: $selection) {
                TableColumnForEach(kind.columns) { column in
                    TableColumn(column.header) { (row: Resource) in Text(column.value(row)) }
                }
            } rows: {
                ForEach(model.readItems(kind)) { TableRow($0) }
            }
            .contextMenu(forSelectionType: Resource.ID.self) { _ in
            } primaryAction: { ids in
                openDetail(ids.first)
            }
            .overlay {
                ListStateOverlay(isLoading: model.isLoading, error: model.loadError,
                                 isEmpty: model.readItems(kind).isEmpty,
                                 emptyTitle: "No \(kind.title.lowercased())", emptySymbol: kind.symbol)
            }
        }
        .navigationTitle(kind.title)
        .toolbar {
            ReadOnlyBadge()
            if kind == .audit {
                Picker("Since", selection: $model.auditSince) {
                    Text("24h").tag("24h")
                    Text("7d").tag("7d")
                    Text("30d").tag("30d")
                    Text("90d").tag("90d")
                }
                .pickerStyle(.menu)
                .frame(width: 86)
            }
            Button { openDetail(selection) } label: { Label("Details", systemImage: "eye") }
                .disabled(selection == nil)
            Button { Task { await model.loadReadOnly(kind) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .sheet(item: $detail) { ResourceDetailView(title: kind.title, resource: $0) }
        .task(id: taskID) { await model.loadReadOnly(kind) }
    }

    // Re-run the load when the resource changes, or (for audit) the since-window changes.
    private var taskID: String { kind == .audit ? "\(kind.id):\(model.auditSince)" : kind.id }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
            Text("Read-only").fontWeight(.semibold)
            Text("·").foregroundStyle(.tertiary)
            Text(kind.note)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    private func openDetail(_ id: Resource.ID?) {
        guard let id, let resource = model.readItems(kind).first(where: { $0.id == id }) else { return }
        detail = resource
    }
}
