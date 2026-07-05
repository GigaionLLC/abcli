// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// A read-only inspector that shows a resource's FULL attributes as pretty JSON — so an
/// operator can see everything Apple Business returns (a user's roles, a group's fields,
/// an app's metadata, an audit event's payload), not just the table columns.
struct ResourceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let resource: Resource

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(title) — read-only", systemImage: "lock")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(prettyJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(resource), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "type: \(resource.type)\nid: \(resource.id)"
    }
}
