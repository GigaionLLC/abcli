// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// A toolbar refresh button that runs an async action.
struct RefreshButton: View {
    let action: () async -> Void
    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }
}

/// The overlay a list screen shows when it has no rows: a spinner while loading, the
/// error if one occurred, else an empty-state. Renders nothing once data is present.
struct ListStateOverlay: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    let emptyTitle: String
    let emptySymbol: String

    var body: some View {
        if isLoading && isEmpty {
            ProgressView()
        } else if let error, isEmpty {
            ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
        }
    }
}
