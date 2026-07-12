// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct OSReleasesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var catalog = "all"

    private var rows: [OSRelease] {
        model.osReleases.filter { release in
            (catalog == "all" || release.catalog == catalog)
                && (search.isEmpty
                    || release.platform.localizedCaseInsensitiveContains(search)
                    || release.productVersion.localizedCaseInsensitiveContains(search)
                    || release.build.localizedCaseInsensitiveContains(search)
                    || (release.supportedDevices ?? []).contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apple's software-release catalog. This is availability data, not proof that an update is eligible, scheduled, or installed.")
                .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .top])
            Table(rows) {
                TableColumn("Platform", value: \.platform)
                TableColumn("Version", value: \.productVersion)
                TableColumn("Build", value: \.build)
                TableColumn("Catalog") { Text($0.catalog.uppercased()) }
                TableColumn("Posted", value: \.postingDate)
                TableColumn("Expires") { Text($0.expirationDate ?? "—") }
                TableColumn("Devices") { Text(String($0.supportedDevices?.count ?? 0)) }
            }
            .overlay {
                if model.isLoading { ProgressView() }
                else if let error = model.loadError { ContentUnavailableView("Couldn't load releases", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else if rows.isEmpty { ContentUnavailableView.search(text: search) }
            }
        }
        .navigationTitle("OS Releases")
        .searchable(text: $search, prompt: "Platform, version, build, or device")
        .toolbar {
            Picker("Catalog", selection: $catalog) {
                Text("All").tag("all"); Text("Managed").tag("managed")
                Text("Public").tag("public"); Text("Security Responses").tag("rsr")
            }.pickerStyle(.segmented).frame(width: 330)
            Button { Task { await model.loadOSReleases() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .task { await model.loadOSReleases() }
    }
}
