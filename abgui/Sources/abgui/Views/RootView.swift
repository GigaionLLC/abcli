// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The app shell: a sidebar grouped into GitOps (write-capable) and Read-only sections,
/// a detail pane, and a live connection footer.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section? = .configurations

    enum Section: String, CaseIterable, Identifiable, Hashable {
        // GitOps — write-capable
        case configurations, blueprints, diff, archive
        // Read-only — live views abgui never mutates
        case devices, users, userGroups, apps, packages, mdmServers, audit

        var id: String { rawValue }

        /// The read-only resource kind, or nil for the GitOps sections.
        var readOnly: ReadOnlyKind? {
            switch self {
            case .devices: return .devices
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
            case .configurations: return "Configurations"
            case .blueprints: return "Blueprints"
            case .diff: return "Diff / Drift"
            case .archive: return "Archive"
            default: return rawValue
            }
        }

        var symbol: String {
            if let kind = readOnly { return kind.symbol }
            switch self {
            case .configurations: return "doc.text"
            case .blueprints: return "square.stack.3d.up"
            case .diff: return "arrow.triangle.branch"
            case .archive: return "clock.arrow.circlepath"
            default: return "circle"
            }
        }

        static let gitopsSections: [Section] = [.configurations, .blueprints, .diff, .archive]
        static let readOnlySections: [Section] = [.devices, .users, .userGroups, .apps, .packages, .mdmServers, .audit]
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("GitOps") {
                    ForEach(Section.gitopsSections) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Read-only") {
                    ForEach(Section.readOnlySections) { item in
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
        .task { await model.check() }
    }

    @ViewBuilder private var detail: some View {
        if let kind = section?.readOnly {
            ReadOnlyListView(kind: kind)
        } else {
            switch section {
            case .configurations: ConfigurationsView()
            case .blueprints: BlueprintsView()
            case .diff: DiffView()
            case .archive: ArchiveView()
            default: ContentUnavailableView("Select a section", systemImage: "sidebar.left")
            }
        }
    }
}
