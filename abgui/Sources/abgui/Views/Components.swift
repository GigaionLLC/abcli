// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

extension View {
    /// Make a toolbar control READ as what it does: show its title next to the icon, and give it
    /// a tooltip saying what pressing it will actually do.
    ///
    /// macOS renders a bare `Label` inside a `.toolbar` as its icon alone, and SwiftUI supplies
    /// no tooltip of its own — so an unannotated toolbar is a row of anonymous glyphs with
    /// nothing to hover for. That is not a cosmetic problem in this app: `checkmark.shield`
    /// (validate local files) and `checkmark.circle` (write the live tenant) are near-identical
    /// at toolbar size, and a `trash` means "delete from Apple Business" on one screen and
    /// "clear this session's log" on another. The word is the affordance; `help` carries the
    /// consequence, and should say plainly when a button reaches the tenant.
    func toolbarLabel(_ help: String) -> some View {
        labelStyle(.titleAndIcon).help(help)
    }
}

/// A toolbar refresh button that runs an async action. `help` names WHAT is being re-fetched —
/// every screen has a Refresh, and they do not refresh the same thing.
struct RefreshButton: View {
    let help: String
    let action: () async -> Void

    init(help: String = "Re-fetch this screen's data.", action: @escaping () async -> Void) {
        self.help = help
        self.action = action
    }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .toolbarLabel(help)
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
