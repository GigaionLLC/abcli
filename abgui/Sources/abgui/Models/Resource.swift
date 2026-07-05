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
}
