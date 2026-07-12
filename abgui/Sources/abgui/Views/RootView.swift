// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The app shell: a sidebar grouped into Overview (the dashboard), GitOps (write-capable)
/// and Read-only sections, a detail pane, and a live connection footer.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .dashboard

    /// A sidebar entry. (Named SidebarItem, not Section, to avoid shadowing SwiftUI.Section.)
    enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
        // Overview — the stat-tile dashboard (the landing screen)
        case dashboard, systemHealth, whatsNew
        // GitOps — write-capable
        case configurations, blueprints, diff, archive
        // Read-only — live views abgui never mutates
        case devices, mdmDevices, users, userGroups, apps, packages, mdmServers, audit, osReleases
        case appsBooks // Apps & Books (VPP) — a separate service; routes to VPPView

        var id: String { rawValue }

        /// The read-only resource kind, or nil for the GitOps sections.
        var readOnly: ReadOnlyKind? {
            switch self {
            case .devices: return .devices
            case .mdmDevices: return .mdmDevices
            case .users: return .users
            case .userGroups: return .userGroups
            case .apps: return .apps
            case .packages: return .packages
            case .mdmServers: return .mdmServers
            case .audit: return .audit
            default: return nil
            }
        }

        var title: String {
            if let kind = readOnly { return kind.title }
            switch self {
            case .dashboard: return "Dashboard"
            case .systemHealth: return "System Health"
            case .whatsNew: return "What’s New"
            case .configurations: return "Configurations"
            case .blueprints: return "Blueprints"
            case .diff: return "Diff / Drift"
            case .archive: return "Archive"
            case .osReleases: return "OS Releases"
            case .appsBooks: return "Apps & Books"
            default: return rawValue
            }
        }

        var symbol: String {
            if let kind = readOnly { return kind.symbol }
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .systemHealth: return "stethoscope"
            case .whatsNew: return "sparkles"
            case .configurations: return "doc.text"
            case .blueprints: return "square.stack.3d.up"
            case .diff: return "arrow.triangle.branch"
            case .archive: return "clock.arrow.circlepath"
            case .osReleases: return "apple.logo"
            case .appsBooks: return "cart"
            default: return "circle"
            }
        }

        static let gitopsItems: [SidebarItem] = [.configurations, .blueprints, .diff, .archive]
        // .appsBooks is intentionally omitted: content tokens connect external MDM services
        // and must not be exposed as a built-in-management GUI option. The legacy view remains
        // quarantined reference code pending a pre-1.0 removal decision.
        static let readOnlyItems: [SidebarItem] = [.devices, .mdmDevices, .osReleases, .users, .userGroups, .apps, .packages, .mdmServers, .audit]
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Overview") {
                    Label(SidebarItem.dashboard.title, systemImage: SidebarItem.dashboard.symbol)
                        .tag(SidebarItem.dashboard)
                    Label(SidebarItem.systemHealth.title, systemImage: SidebarItem.systemHealth.symbol)
                        .tag(SidebarItem.systemHealth)
                    Label(SidebarItem.whatsNew.title, systemImage: SidebarItem.whatsNew.symbol)
                        .tag(SidebarItem.whatsNew)
                }
                Section("GitOps") {
                    ForEach(SidebarItem.gitopsItems) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Read-only") {
                    ForEach(SidebarItem.readOnlyItems) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .navigationTitle("abgui")
            .navigationSplitViewColumnWidth(min: 190, ideal: 214)
            .safeAreaInset(edge: .bottom) { ConnectionFooter() }
        } detail: {
            NavigationStack {
                detail
            }
        }
        .task {
            model.restoreWorkspace() // reopen the last-used GitOps folder
            await model.check()
        }
    }

    @ViewBuilder private var detail: some View {
        if let kind = selection?.readOnly {
            ReadOnlyListView(kind: kind)
        } else {
            switch selection {
            case .dashboard: DashboardView(select: { selection = $0 })
            case .systemHealth: SystemHealthView()
            case .whatsNew: WhatsNewView()
            case .configurations: ConfigurationsView()
            case .blueprints: BlueprintsView()
            case .diff: DiffView()
            case .archive: ArchiveView()
            case .appsBooks: VPPView()
            case .osReleases: OSReleasesView()
            default: ContentUnavailableView("Select a section", systemImage: "sidebar.left")
            }
        }
    }
}
