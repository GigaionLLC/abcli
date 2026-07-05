// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

@main
struct ABGUIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("abgui") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 900, height: 600)
    }
}
