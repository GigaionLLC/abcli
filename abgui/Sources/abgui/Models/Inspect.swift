// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// Typed payloads for the singular `get …` / `status …` inspection commands (abctl
// Phase A surface; shapes defined by internal/cli/inspect.go, get.go, manage.go).
// Each entity still travels as an open `Resource` attribute bag — these structs exist
// only where abctl wraps resources in a composite object ({device, assignedServer,
// appleCare}, blueprint relationships, the status-device report) that a bare
// `Resource`/`[Resource]` can't express. Plain-resource details (user, app, package,
// activity) decode straight to `Resource` and need nothing here.

/// `get device <x> [--applecare] --json` — the org device, its assigned MDM server,
/// and AppleCare coverage records.
struct DeviceDetail: Decodable, Equatable {
    let device: Resource
    let assignedServer: Resource?   // null unless the device status is ASSIGNED
    let appleCare: [Resource]?      // key absent without --applecare; [] = no coverage records
}

/// `get mdmdevice <x> --json` — the built-in-MDM device + its last-reported posture
/// details (a second resource whose attributes carry osVersion, isFileVaultEnabled,
/// isFirewallEnabled, storage*Capacity, lock/erase/lost-mode, lastCheckInDateTime).
struct MDMDeviceDetail: Decodable, Equatable {
    let device: Resource
    let details: Resource
}

/// `get usergroup <x> [--members] --json` — the group plus member emails.
struct UserGroupDetail: Decodable, Equatable {
    let group: Resource
    let members: [String]?  // key absent without --members; sorted emails (member id fallback)
}

/// `get mdmserver <x> [--devices] --json` — the server plus its assigned devices.
struct MDMServerDetail: Decodable, Equatable {
    let server: Resource
    let devices: [String]?  // key absent without --devices; sorted serials (device id fallback)
    let deviceCount: Int?   // key absent without --devices
}

/// `get blueprint <x> --json` — the blueprint + member counts, the app ids (to
/// cross-reference `get apps`), the built-in-MDM Apps & Books license signal, and
/// all six member collections resolved to human names.
struct BlueprintDetail: Decodable, Equatable {
    let blueprint: Resource
    let configs: Int
    let apps: Int
    let devices: Int
    let appIds: [String]
    let appLicenseDeficient: Bool
    /// Relationship → resolved member names (configs/apps/packages/groups → name,
    /// devices → serial, users → email). Keys are Apple's relationship names.
    let relationships: [String: [String]]

    /// The six relationship keys in abctl's display order (internal/cli/get.go blueprintRels).
    static let relationshipOrder = ["configurations", "apps", "packages", "orgDevices", "users", "userGroups"]
}

/// `status device <x> --json` — one device end-to-end: assigned MDM server and
/// blueprint/config membership (desired-state / assignment intent) plus last-reported
/// built-in-MDM posture. NOT live on-device verification (the API can't report it).
struct DeviceStatusReport: Decodable, Equatable {
    let device: Resource
    let assignedServer: Resource?          // null when unassigned
    let blueprints: [BlueprintCoverage]    // [] when no blueprint contains the device
    let mdm: MDMPosture?                   // null = not enrolled in built-in MDM
    let appleCare: [Resource]?             // key absent without --applecare

    /// One blueprint containing the device, with its configuration names.
    struct BlueprintCoverage: Decodable, Equatable {
        let blueprint: String
        let configurations: [String]
    }

    /// The built-in-MDM section: {device, details} when enrolled (details may still be
    /// null if the posture fetch failed), or {error} when listing MDM devices was
    /// denied/unreachable — distinct from "not enrolled".
    struct MDMPosture: Decodable, Equatable {
        let device: Resource?
        let details: Resource?
        let error: String?
    }
}

/// `assign`/`unassign … --yes --json` — the accepted orgDeviceActivity (Apple processes
/// assignment asynchronously; the activity id is what abgui polls via `status activity`).
struct ActivityOutcome: Decodable, Equatable {
    let action: String     // assign | unassign
    let server: String
    let devices: Int
    let activityID: String
    let status: String?    // final status — only present with --wait (abgui polls instead)
    let subStatus: String? // only present with --wait

    enum CodingKeys: String, CodingKey {
        case action, server, devices
        case activityID = "activityId"
        case status, subStatus
    }
}
