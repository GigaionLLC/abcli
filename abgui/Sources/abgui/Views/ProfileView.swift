// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// A sheet showing a configuration's raw `.mobileconfig` XML (read-only in v1; the
/// in-app editor + `replace` lands in v2).
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let config: Resource

    @State private var xml = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(config.attr("name") ?? config.id).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView("Couldn't load profile", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            ScrollView([.horizontal, .vertical]) {
                Text(xml.isEmpty ? "(empty)" : xml)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            xml = try await model.profile(for: config.id)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
