// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// `auth whoami --json` (abctl P1) — a typed "test connection".
struct WhoamiResult: Codable, Equatable {
    let authenticated: Bool
    let clientID: String
    let apiBase: String
    let tokenExpires: String
    let configurations: Int
    let blueprints: Int

    enum CodingKeys: String, CodingKey {
        case authenticated
        case clientID = "client_id"
        case apiBase = "api_base"
        case tokenExpires = "token_expires"
        case configurations
        case blueprints
    }
}

/// `version --json` (abctl P2) — build identity + the capability tokens abgui gates on.
struct VersionInfo: Codable, Equatable {
    let version: String
    let commit: String?
    let buildTime: String?
    let goVersion: String
    let capabilities: [String]

    func has(_ capability: String) -> Bool { capabilities.contains(capability) }
}
