// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The overview screen: one stat tile per browsable collection, counting the rows in
/// AppModel's caches. Empty caches fill lazily and SEQUENTIALLY on first appearance —
/// one abctl call at a time, never a parallel burst (token reuse + 429 safety). A tile
/// shows an em dash until its cache has actually loaded, so "0" always means a real
/// zero; clicking a tile jumps the sidebar to that screen.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    /// Moves the sidebar selection (RootView owns it).
    let select: (RootView.SidebarItem) -> Void

    /// Tiles whose cache finished loading this session (an empty cache renders "—" until then).
    @State private var loaded: Set<RootView.SidebarItem> = []
    @State private var isRefreshing = false
    /// The first failure of the current load pass (the pass stops there — with a bad
    /// connection every remaining call would fail the same way and burn rate limit).
    @State private var loadFailed: String?
    /// The Refresh-all pass, kept so navigating away cancels it — otherwise it would
    /// keep issuing abctl calls concurrently with the destination screen's own load.
    @State private var refreshTask: Task<Void, Never>?

    /// Sidebar order: the two GitOps collections, then the read-only inventories.
    /// Audit is a time-window event feed, not an inventory, so it has no tile.
    private static let tiles: [RootView.SidebarItem] = [
        .configurations, .blueprints, .devices, .mdmDevices,
        .users, .userGroups, .apps, .packages, .mdmServers,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let loadFailed {
                    Text(loadFailed)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(Self.tiles) { item in
                        tile(item)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Dashboard")
        .toolbar {
            if isRefreshing { ProgressView().controlSize(.small) }
            Button {
                refreshTask = Task { await loadAll(force: true) }
            } label: {
                Label("Refresh all", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
        }
        .task { await loadAll(force: false) }
        .onDisappear { refreshTask?.cancel() }
    }

    /// One clickable stat tile: the kind's symbol, its cached row count, its title.
    private func tile(_ item: RootView.SidebarItem) -> some View {
        Button { select(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(countText(item))
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text(title(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Open \(title(item))")
    }

    /// Tile titles match the sidebar, except .apps drops the "(catalog)" qualifier —
    /// a tile caption has no room for it and the count already implies inventory.
    private func title(_ item: RootView.SidebarItem) -> String {
        item == .apps ? "Apps" : item.title
    }

    /// The cached count, or "—" while the cache hasn't loaded yet.
    private func countText(_ item: RootView.SidebarItem) -> String {
        let items = rows(item)
        if items.isEmpty && !loaded.contains(item) { return "—" }
        return String(items.count)
    }

    /// The AppModel cache backing a tile.
    private func rows(_ item: RootView.SidebarItem) -> [Resource] {
        switch item {
        case .configurations: return model.configurations
        case .blueprints: return model.blueprints
        default: return item.readOnly.map { model.readItems($0) } ?? []
        }
    }

    /// Fill each empty cache in tile order, one abctl call at a time. `force` reloads
    /// everything (the Refresh-all button); otherwise caches a screen already filled
    /// (or an earlier pass loaded) are kept as-is.
    private func loadAll(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        loadFailed = nil
        defer { isRefreshing = false }
        for item in Self.tiles {
            if Task.isCancelled { return } // navigated away — stop spawning abctl calls
            if !force, loaded.contains(item) || !rows(item).isEmpty {
                loaded.insert(item) // a cache its own screen already filled counts as loaded
                continue
            }
            switch item {
            case .configurations: await model.loadConfigurations()
            case .blueprints: await model.loadBlueprints()
            default:
                guard let kind = item.readOnly else { continue }
                await model.loadReadOnly(kind)
            }
            // Cancelled mid-call (tile click / navigation): the shared loadError now
            // belongs to the destination screen's load — don't read or misattribute it.
            if Task.isCancelled { return }
            if let error = model.loadError {
                loadFailed = error // stop the pass on the first failure (see above)
                return
            }
            loaded.insert(item)
        }
    }
}
