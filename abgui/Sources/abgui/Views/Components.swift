// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// How much room a toolbar control earns.
///
/// Showing the title on EVERY control was the first attempt, and it traded one problem for
/// another: an unlabelled toolbar is a row of anonymous glyphs with nothing to hover for, but a
/// fully labelled one outgrew the window — at ~1090px the last item was clipped off the right
/// edge with no overflow affordance. Width is finite, so it has to be spent where a word
/// actually resolves an ambiguity.
enum ToolbarWeight {
    /// Title + icon, always. For the control whose consequence you must not misread: `Apply…`
    /// writes the live tenant, and `Verify Configs` sits beside it wearing a near-identical
    /// checkmark glyph. These two are exactly the pair a bare icon cannot distinguish.
    case titled
    /// Icon + tooltip. For controls whose glyph is universally understood — a refresh arrow, a
    /// folder, a trash can — where the title costs width and adds nothing a hover does not.
    case compact
}

extension View {
    /// Make a toolbar control READ as what it does.
    ///
    /// `help` is supplied for BOTH weights and is never optional: macOS renders a bare `Label`
    /// in a `.toolbar` as its icon alone and SwiftUI adds no tooltip of its own, so a control
    /// without one is unidentifiable by any means at all. The tooltip should name the
    /// consequence, and say plainly when the button reaches the tenant — a `trash` means
    /// "delete from Apple Business" on one screen and "clear this session's log" on another.
    func toolbarLabel(_ help: String, weight: ToolbarWeight = .compact) -> some View {
        labelStyle(weight == .titled ? AnyLabelStyle(TitleAndIconLabelStyle())
                                     : AnyLabelStyle(IconOnlyLabelStyle()))
            .help(help)
    }
}

/// Type-erasing wrapper so one modifier can choose between label styles at runtime.
/// `labelStyle` takes a concrete generic type, so a ternary over two different styles needs
/// this rather than being expressible inline.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
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
