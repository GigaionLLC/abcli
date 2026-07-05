// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One column of a read-only resource table.
struct ColumnSpec: Identifiable {
    let header: String
    let value: (Resource) -> String
    var id: String { header }
}

/// A live, READ-ONLY Apple Business resource abgui can browse but never write. The API
/// exposes these for reading only (users/groups are console/SCIM-managed; apps/packages/
/// mdm-servers/audit are inventory) — so every screen for one is clearly badged read-only.
enum ReadOnlyKind: String, CaseIterable, Identifiable, Hashable {
    case devices
    case users
    case userGroups
    case apps
    case packages
    case mdmServers
    case audit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: return "Devices"
        case .users: return "Users"
        case .userGroups: return "User Groups"
        case .apps: return "Apps & Books"
        case .packages: return "Packages"
        case .mdmServers: return "MDM Servers"
        case .audit: return "Audit"
        }
    }

    var symbol: String {
        switch self {
        case .devices: return "laptopcomputer"
        case .users: return "person.2"
        case .userGroups: return "person.3"
        case .apps: return "bag"
        case .packages: return "shippingbox"
        case .mdmServers: return "server.rack"
        case .audit: return "list.bullet.rectangle"
        }
    }

    /// A one-line note explaining WHY this is read-only / what it is.
    var note: String {
        switch self {
        case .devices: return "Organization devices. Device→MDM-server assignment isn't wired yet."
        case .users: return "Managed users + their roles. Identity is console/SCIM-managed — the API is read-only."
        case .userGroups: return "User groups. Created in the console or via federation/SCIM, not this API."
        case .apps: return "Apps & Books (VPP) licensed to the organization."
        case .packages: return "Custom apps / packages. Needs the built-in-device-management permission."
        case .mdmServers: return "MDM servers registered with Apple Business."
        case .audit: return "Admin API audit events over the selected window."
        }
    }

    var columns: [ColumnSpec] {
        switch self {
        case .devices:
            return [
                ColumnSpec(header: "Serial") { $0.attr("serialNumber") ?? $0.id },
                ColumnSpec(header: "Model") { $0.attr("deviceModel") ?? "—" },
                ColumnSpec(header: "OS") { $0.attr("osVersion") ?? "—" },
                ColumnSpec(header: "Family") { $0.attr("productFamily") ?? "—" },
            ]
        case .users:
            return [
                ColumnSpec(header: "Name") {
                    let n = [$0.attr("firstName"), $0.attr("lastName")].compactMap { $0 }.joined(separator: " ")
                    return n.isEmpty ? ($0.attr("managedAppleId") ?? $0.id) : n
                },
                ColumnSpec(header: "Managed Apple ID") { $0.attr("managedAppleId") ?? $0.attr("email") ?? "—" },
                ColumnSpec(header: "Roles") { let r = $0.roleNames(); return r.isEmpty ? "—" : r },
                ColumnSpec(header: "Status") { $0.attr("status") ?? "—" },
            ]
        case .userGroups:
            return [
                ColumnSpec(header: "Name") { $0.attr("name") ?? $0.id },
                ColumnSpec(header: "Type") { $0.attr("groupType") ?? "—" },
                ColumnSpec(header: "Status") { $0.attr("status") ?? "—" },
            ]
        case .apps:
            return [
                ColumnSpec(header: "Name") { $0.attr("name") ?? $0.id },
                ColumnSpec(header: "Bundle ID") { $0.attr("bundleId") ?? "—" },
                ColumnSpec(header: "Version") { $0.attr("version") ?? "—" },
                ColumnSpec(header: "Custom") { $0.attr("isCustomApp") ?? "—" },
            ]
        case .packages:
            return [
                ColumnSpec(header: "Name") { $0.attr("name") ?? $0.attr("bundleId") ?? $0.id },
                ColumnSpec(header: "Bundle ID") { $0.attr("bundleId") ?? "—" },
                ColumnSpec(header: "Version") { $0.attr("version") ?? "—" },
            ]
        case .mdmServers:
            return [
                ColumnSpec(header: "Name") { $0.attr("serverName") ?? $0.id },
                ColumnSpec(header: "Type") { $0.attr("serverType") ?? "—" },
                ColumnSpec(header: "ID") { $0.id },
            ]
        case .audit:
            return [
                ColumnSpec(header: "Time") { $0.attr("eventTime") ?? $0.attr("createdDateTime") ?? "—" },
                ColumnSpec(header: "Event") { $0.attr("eventType") ?? "—" },
                ColumnSpec(header: "Actor") { $0.attr("actorName") ?? $0.attr("actorId") ?? "—" },
            ]
        }
    }
}
