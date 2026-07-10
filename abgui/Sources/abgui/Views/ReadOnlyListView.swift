// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// A small pill that marks a screen as read-only. The Devices screen overrides the
/// text to disclose its one gated write (Assign to MDM…) instead of claiming purity.
struct ReadOnlyBadge: View {
    var text = "Read-only"
    var body: some View {
        Label(text, systemImage: "lock")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary))
    }
}

/// A generic browser for any live, READ-ONLY Apple Business resource. Shows a read-only
/// banner + badge so it's obvious nothing here mutates the resource rows; the ONE gated
/// exception is the Devices screen, whose Assign to MDM… button opens AssignSheet for
/// the multi-selected rows (device→server assignment is the API's only device write).
/// Double-click (or Details) opens the kind's typed detail sheet (InspectSheets.swift),
/// falling back to the raw-JSON inspector.
struct ReadOnlyListView: View {
    @Environment(AppModel.self) private var model
    let kind: ReadOnlyKind
    @State private var selection = Set<Resource.ID>()
    @State private var detail: Resource?
    @State private var searchText = ""
    @State private var sortHeader: String?    // nil = default API order
    @State private var sortAscending = true
    @State private var showExporter = false
    @State private var showAssign = false     // the Devices-only AssignSheet

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            banner
            columnHeader
            Divider()
            // A List (not a dynamic Table) so it builds on macOS 14.0 — TableColumnForEach
            // needs 14.4. Even-width columns via ForEach keep it grid-like and read-only.
            List(displayedRows, selection: $selection) { row in
                HStack(spacing: 12) {
                    ForEach(kind.columns) { column in
                        Text(column.value(row))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .contextMenu(forSelectionType: Resource.ID.self) { _ in
            } primaryAction: { ids in
                openDetail(ids.first)
            }
            .overlay {
                ListStateOverlay(isLoading: model.isLoading, error: model.loadError,
                                 isEmpty: displayedRows.isEmpty,
                                 emptyTitle: searchText.isEmpty ? "No \(kind.title.lowercased())" : "No matches",
                                 emptySymbol: kind.symbol)
            }
        }
        .navigationTitle(kind.title)
        .searchable(text: $searchText, prompt: "Search")
        .toolbar {
            ReadOnlyBadge(text: readOnlyLabel)
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
            Button { openDetail(selection.first) } label: { Label("Details", systemImage: "eye") }
                .disabled(selection.count != 1)
            if kind == .devices {
                Button { showAssign = true } label: { Label("Assign to MDM…", systemImage: "server.rack") }
                    .disabled(selection.isEmpty)
            }
            Button { showExporter = true } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                .disabled(displayedRows.isEmpty)
            Button { Task { await model.loadReadOnly(kind) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .fileExporter(isPresented: $showExporter, document: csvDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: "abgui-\(kind.rawValue)-export.csv") { _ in }
        .sheet(item: $detail) { detailSheet(for: $0) }
        .sheet(isPresented: $showAssign) { AssignSheet(serials: selectedSerials) }
        .task(id: taskID) { await model.loadReadOnly(kind) }
        // The view instance is reused across sidebar switches, so drop the previous
        // kind's search text, sort, and selection — its rows don't exist here.
        .onChange(of: kind) { _, _ in
            searchText = ""
            sortHeader = nil
            sortAscending = true
            selection = []
        }
    }

    /// The rows currently on screen: the cached API rows, filtered by the search text
    /// (case-insensitive substring across every column's display value), then sorted by
    /// the clicked column (stable — index-tiebroken; nil = the API's own order).
    private var displayedRows: [Resource] {
        var rows = model.readItems(kind)
        if !searchText.isEmpty {
            rows = rows.filter { row in
                kind.columns.contains { $0.value(row).localizedCaseInsensitiveContains(searchText) }
            }
        }
        if let header = sortHeader, let column = kind.columns.first(where: { $0.header == header }) {
            rows = rows.enumerated().sorted { a, b in
                let order = column.value(a.element).localizedStandardCompare(column.value(b.element))
                if order != .orderedSame {
                    return sortAscending ? order == .orderedAscending : order == .orderedDescending
                }
                return a.offset < b.offset
            }.map(\.element)
        }
        return rows
    }

    /// The serials AssignSheet acts on: every selected row, from the full cache (a row
    /// selected before narrowing the search stays selected — the sheet lists exactly
    /// what will be sent, so nothing acts invisibly). Serial falls back to the device
    /// id, which abctl's resolver also accepts.
    private var selectedSerials: [String] {
        model.readItems(kind)
            .filter { selection.contains($0.id) }
            .map { $0.attr("serialNumber") ?? $0.id }
    }

    /// The badge/banner wording: every screen is read-only, but Devices carries the one
    /// gated write (Assign to MDM…), so its pill discloses that instead of contradicting it.
    private var readOnlyLabel: String {
        kind == .devices ? "Read-only · assignment gated" : "Read-only"
    }

    /// The current filtered+sorted rows as a CSV document (what Export CSV writes).
    /// The em dash is the SCREENS' missing-value placeholder; abctl's `-o csv` emits an
    /// empty field there, so the export maps it back to "" and the two tools' CSVs match.
    private var csvDocument: CSVDocument {
        let columns = kind.columns
        return CSVDocument(headers: columns.map(\.header),
                           rows: displayedRows.map { row in
                               columns.map { column in
                                   let value = column.value(row)
                                   return value == "—" ? "" : value
                               }
                           })
    }

    /// First click on a column sorts ascending; clicking it again flips the direction.
    private func toggleSort(_ header: String) {
        if sortHeader == header {
            sortAscending.toggle()
        } else {
            sortHeader = header
            sortAscending = true
        }
    }

    /// The kind-appropriate detail sheet: a typed inspector where one exists
    /// (InspectSheets.swift), else the raw-JSON fallback (audit events).
    @ViewBuilder
    private func detailSheet(for resource: Resource) -> some View {
        switch kind {
        case .devices: DeviceDetailSheet(resource: resource)
        case .mdmDevices: MDMDeviceDetailSheet(resource: resource)
        case .users: UserDetailSheet(resource: resource)
        case .userGroups: UserGroupDetailSheet(resource: resource)
        case .apps: AppDetailSheet(resource: resource)
        case .packages: PackageDetailSheet(resource: resource)
        case .mdmServers: MDMServerDetailSheet(resource: resource)
        default: ResourceDetailView(title: kind.title, resource: resource)
        }
    }

    // Re-run the load when the resource changes, or (for audit) the since-window changes.
    private var taskID: String { kind == .audit ? "\(kind.id):\(model.auditSince)" : kind.id }

    // Each header is a click target that sorts by its column (with an asc/desc chevron).
    private var columnHeader: some View {
        HStack(spacing: 12) {
            ForEach(kind.columns) { column in
                Button { toggleSort(column.header) } label: {
                    HStack(spacing: 4) {
                        Text(column.header.uppercased())
                            .font(.caption.weight(.semibold))
                        if sortHeader == column.header {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sort by \(column.header)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
            Text(readOnlyLabel).fontWeight(.semibold)
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
