// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The app shell: a sidebar of sections + a detail pane, with a live connection footer.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section? = .configurations

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case configurations = "Configurations"
        case blueprints = "Blueprints"
        case devices = "Devices"
        case diff = "Diff / Drift"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .configurations: return "doc.text"
            case .blueprints: return "square.stack.3d.up"
            case .devices: return "laptopcomputer"
            case .diff: return "arrow.triangle.branch"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .navigationTitle("abgui")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { ConnectionFooter() }
        } detail: {
            NavigationStack {
                detail
            }
        }
        .task { await model.check() }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .configurations: ConfigurationsView()
        case .blueprints: BlueprintsView()
        case .devices: DevicesView()
        case .diff: DiffView()
        case nil: ContentUnavailableView("Select a section", systemImage: "sidebar.left")
        }
    }
}
