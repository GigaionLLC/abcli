// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Port note (rule 5): the Swift `JSONValue` is a six-case Codable enum
// (string/number/bool/object/array/null). Here it is a thin wrapper around the already-decoded
// `Object?` that `jsonDecode` hands back, because that is what keeps the CALL SITES simple —
// and the call sites are the whole reason the type exists.
//
// Nothing in abgui ever pattern-matches all six cases: the views ask "the string at this key"
// (`Resource.attr`) or "the array at this key" (`Resource.roleNames`), which is exactly the
// pair of accessors the Swift enum grew. A sealed hierarchy would add six classes and a
// `switch` at every use to answer the same two questions, and re-wrapping every nested value
// on decode would cost a full copy of every attribute bag for no reader that wants it.
//
// The behaviour that matters is preserved exactly: a lookup whose value is not a string
// answers null (see `string`), so a boolean `isCustomApp` still renders as the table's em dash
// instead of the text "false", and unknown keys survive a round trip untouched.

import 'json.dart';

/// A resilient container for Apple's open JSON:API attribute bags: whatever fields Apple adds
/// still decode, and per-screen accessors pull the columns a view needs. Keeps abgui from
/// breaking when Apple grows an `attributes` object.
class JSONValue {
  /// The decoded JSON, verbatim: a `Map`, `List`, `String`, `num`, `bool`, or null.
  final Object? raw;

  const JSONValue(this.raw);

  /// Decoding is the identity function — see the port note above.
  factory JSONValue.fromJson(Object? value) => JSONValue(value);

  /// True when the value is JSON `null` (distinct from "this key is absent", which the
  /// containing model represents with a null `JSONValue?`).
  bool get isNull => raw == null;

  /// The string at [key] if this is an object with a string there — the common lookup for a
  /// table column (name, type, serialNumber, …).
  String? string(String key) {
    final object = raw;
    if (object is Map) {
      final value = object[key];
      if (value is String) return value;
    }
    return null;
  }

  /// The array at [key] if this is an object with an array there (e.g. a user's `roles`).
  List<JSONValue>? array(String key) {
    final object = raw;
    if (object is Map) {
      final value = object[key];
      if (value is List) {
        return value.map(JSONValue.new).toList(growable: false);
      }
    }
    return null;
  }

  /// The object at [key] wrapped for further lookups, or null.
  JSONValue? object(String key) {
    final object = raw;
    if (object is Map) {
      final value = object[key];
      if (value is Map) return JSONValue(value);
    }
    return null;
  }

  /// Re-encodable as-is; the wrapper never rewrites what it was handed.
  Object? toJson() => raw;

  @override
  bool operator ==(Object other) =>
      other is JSONValue && deepJsonEquals(raw, other.raw);

  @override
  int get hashCode => deepJsonHash(raw);

  @override
  String toString() => 'JSONValue($raw)';
}
