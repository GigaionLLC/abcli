// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One owned app/book + its license counts (`abctl vpp assets`).
struct VPPAsset: Decodable, Identifiable {
    let adamId: String
    let productType: String?
    let pricingParam: String?
    let availableCount: Int?
    let assignedCount: Int?
    let retiredCount: Int?
    let totalCount: Int?
    let deviceAssignable: Bool?
    let revocable: Bool?
    let supportedPlatforms: [String]?

    var id: String { adamId + (pricingParam ?? "") }
}

/// One license assignment (`abctl vpp assignments`).
struct VPPAssignment: Decodable, Identifiable {
    let adamId: String
    let pricingParam: String?
    let serialNumber: String?
    let clientUserId: String?

    var id: String { adamId + (serialNumber ?? "") + (clientUserId ?? "") }
}

/// One registered VPP user (`abctl vpp users`).
struct VPPUser: Decodable, Identifiable {
    let clientUserId: String
    let email: String?
    let status: String?

    var id: String { clientUserId }
}

/// `abctl vpp config` — the token validator + limits.
struct VPPServiceConfig: Decodable {
    let locationName: String?
    let tokenExpirationDate: String?
    let urls: [String: String]?
    let limits: [String: Int]?
}
