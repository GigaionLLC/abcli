// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A JSON:API resource exactly as abctl emits it: `{type, id, attributes:{…}}`. The open
/// `attributes` bag is a `JSONValue`; typed accessors pull the columns a view renders.
struct Resource: Codable, Identifiable, Equatable {
    let type: String
    let id: String
    let attributes: JSONValue?

    /// A string attribute (e.g. "name", "serialNumber") or nil.
    func attr(_ key: String) -> String? { attributes?.string(key) }

    /// The user's role names joined (roles are a per-user attribute: `roles[].role`).
    func roleNames() -> String {
        guard let roles = attributes?.array("roles") else { return "" }
        return roles.compactMap { $0.string("role") }.joined(separator: ", ")
    }

    /// A best-effort display name from the common name-ish attributes.
    func displayName() -> String {
        for key in ["name", "serverName", "serialNumber"] {
            if let v = attr(key), !v.isEmpty { return v }
        }
        let full = [attr("firstName"), attr("lastName")].compactMap { $0 }.joined(separator: " ")
        return full.isEmpty ? id : full
    }
}
