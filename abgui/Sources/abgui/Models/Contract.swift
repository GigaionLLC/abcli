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

/// `context list -o json` — the saved connection contexts + which one is current.
struct ContextList: Codable, Equatable {
    let current: String
    let contexts: [String]
}

/// `context get [name] -o json` — one context's fields. Only the client id + key PATH are
/// ever surfaced (abctl never prints key material), so there is no key-bytes field here.
struct ContextDetail: Codable, Equatable {
    let name: String
    let context: ContextFields

    struct ContextFields: Codable, Equatable {
        let clientID: String
        let keyPath: String
        let apiBase: String?

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case keyPath = "key"
            case apiBase = "api_base"
        }
    }
}
