// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Stable `abctl get os-releases -o json` contract.
struct OSRelease: Codable, Identifiable, Hashable {
    let platform: String
    let productVersion: String
    let build: String
    let postingDate: String
    let expirationDate: String?
    let supportedDevices: [String]?
    let catalog: String
    let expired: Bool

    var id: String { "\(catalog):\(platform):\(build)" }
}
