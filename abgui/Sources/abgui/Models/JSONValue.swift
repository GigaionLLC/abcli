// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A resilient decoder for Apple's open JSON:API attribute bags: whatever fields Apple
/// adds still decode, and per-screen typed structs pull the columns a view needs. Keeps
/// abgui from breaking when Apple grows an `attributes` object.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognized JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a):  try c.encode(a)
        case .null:          try c.encodeNil()
        }
    }

    /// The string at `key` if this is an object with a string there — the common lookup
    /// for a table column (name, type, serialNumber, …).
    func string(_ key: String) -> String? {
        if case .object(let o) = self, case .string(let s)? = o[key] { return s }
        return nil
    }

    /// The array at `key` if this is an object with an array there (e.g. a user's `roles`).
    func array(_ key: String) -> [JSONValue]? {
        if case .object(let o) = self, case .array(let a)? = o[key] { return a }
        return nil
    }
}
