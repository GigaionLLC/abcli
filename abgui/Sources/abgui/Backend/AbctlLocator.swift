// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Finds the abctl binary. In a shipped build it is EMBEDDED in the app bundle at
/// `abgui.app/Contents/Resources/abctl` (a universal binary), resolved by its bundled
/// absolute path — never a `PATH` lookup (Finder-launched apps get a minimal PATH).
/// A developer override, `$ABGUI_ABCTL`, points at a locally-built CLI.
enum AbctlLocator {
    static func resolve() -> URL? {
        if let override = ProcessInfo.processInfo.environment["ABGUI_ABCTL"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return Bundle.main.url(forResource: "abctl", withExtension: nil)
    }
}
