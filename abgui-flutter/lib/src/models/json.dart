// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Typed readers for the JSON abctl prints. Every model in this directory decodes through
// these instead of casting `json['x'] as String`, for the same reason the Swift originals
// used `decodeIfPresent` almost everywhere: abgui ships its own abctl, but a user can point
// the app at an older binary, and abctl's documents gain keys over time. A verification
// screen that renders a slightly thinner report is worth having; one that blanks because a
// key moved is not.
//
// A raw cast is the opposite bargain — it turns an absent or retyped key into a throw at the
// point of decode, which in a GUI reads as "the app is broken" with nothing pointing at the
// real cause (a version skew between the app and the embedded CLI). So nothing here throws:
// a missing key, an explicit null, and a value of the wrong type all answer the same way —
// null, or the caller's fallback.
//
// That is deliberately MORE tolerant than Swift's `decodeIfPresent`, which throws when a key
// is present with the wrong type. The extra tolerance costs nothing and closes the last route
// from "abctl started emitting a number where it emitted a string" to a dead screen.

/// The decoded document as an object, or an empty map when the payload is not one.
///
/// `jsonDecode` is typed `dynamic`, so this is the one place a top-level array-vs-object
/// surprise is absorbed rather than propagated into every `fromJson`.
Map<String, dynamic> asJsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry('$k', v));
  return const <String, dynamic>{};
}

/// The string at [key], or null when absent, null, or not a string.
///
/// Non-strings answer null on purpose: abctl's attribute bags carry booleans and numbers
/// (`isCustomApp`, `totalMemberCount`), and a column that prints one of those as text would
/// be inventing a rendering Apple never promised. The Swift accessor drew the same line.
String? asString(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String ? value : null;
}

/// The string at [key], or [fallback]. Used wherever the Swift decoder wrote
/// `decodeIfPresent(String.self, forKey:) ?? "…"`.
String asStringOr(Map<String, dynamic> json, String key, String fallback) =>
    asString(json, key) ?? fallback;

/// The integer at [key]. Accepts any JSON number (a count that arrives as `3.0` is still 3)
/// but never a numeric string — a quoted count is a contract change, not a value to guess at.
int? asInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

/// The integer at [key], or [fallback].
int asIntOr(Map<String, dynamic> json, String key, int fallback) =>
    asInt(json, key) ?? fallback;

/// The boolean at [key], or null. Numbers are NOT coerced: abctl emits real JSON booleans,
/// and treating `0`/`1` as one would quietly accept a document that had changed shape.
bool? asBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is bool ? value : null;
}

/// The boolean at [key], or [fallback].
bool asBoolOr(Map<String, dynamic> json, String key, bool fallback) =>
    asBool(json, key) ?? fallback;

/// The raw array at [key], or null when absent/not an array.
///
/// Null and `[]` stay distinguishable, which several abctl payloads depend on: `appleCare` is
/// absent without `--applecare` and empty when there are no coverage records, and the two mean
/// different things ("not asked for" vs "asked, none exist").
List<dynamic>? asList(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is List ? value : null;
}

/// The object at [key], or null when absent/not an object.
Map<String, dynamic>? asMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry('$k', v));
  return null;
}

/// The object at [key], or an empty map — for a nested model whose own decoder is defensive
/// enough that "absent" and "empty" render the same way.
Map<String, dynamic> asMapOr(Map<String, dynamic> json, String key) =>
    asMap(json, key) ?? const <String, dynamic>{};

/// The array of strings at [key], or null when absent. Non-string elements are dropped rather
/// than failing the whole list: losing one odd element beats losing the collection.
List<String>? asStringList(Map<String, dynamic> json, String key) {
  final raw = asList(json, key);
  if (raw == null) return null;
  return raw.whereType<String>().toList(growable: false);
}

/// The array of strings at [key], or [fallback] (defaults to empty).
List<String> asStringListOr(
  Map<String, dynamic> json,
  String key, [
  List<String> fallback = const <String>[],
]) => asStringList(json, key) ?? fallback;

/// The array of objects at [key], or null when absent. Non-object elements are dropped for
/// the same reason [asStringList] drops non-strings.
List<Map<String, dynamic>>? asMapList(Map<String, dynamic> json, String key) {
  final raw = asList(json, key);
  if (raw == null) return null;
  return raw.whereType<Map>().map((e) => asJsonMap(e)).toList(growable: false);
}

/// The array of objects at [key], or empty. The shape behind every
/// `decodeIfPresent([Row].self, forKey:) ?? []` in the Swift models.
List<Map<String, dynamic>> asMapListOr(Map<String, dynamic> json, String key) =>
    asMapList(json, key) ?? const <Map<String, dynamic>>[];

/// Element-wise list equality, with null tolerated on either side.
///
/// The Swift models are `struct`s, so `Equatable`/`Hashable` came free and views could compare
/// two decoded documents to decide whether anything changed. Dart's `==` on `List` is identity,
/// so every ported model spells its own `==` — and each one needs this. Null is not equal to
/// empty on purpose: `members: null` (the flag was not passed) and `members: []` (nobody is in
/// the group) are different answers and must not compare equal.
bool listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Structural equality over decoded JSON (maps, lists, scalars, nulls).
///
/// The open attribute bags are compared by value so a `Resource` behaves like the Swift struct
/// it replaces — Dart's `==` on `Map`/`List` is identity, which would make two identically
/// decoded resources unequal and quietly break any de-duplication or diffing built on them.
bool deepJsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!deepJsonEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepJsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// A hash consistent with [deepJsonEquals]. Containers hash on their size and their keys only:
/// cheap, order-independent for maps, and never contradicting equality (which is the one rule
/// a hash has to keep).
int deepJsonHash(Object? value) {
  if (value is Map) {
    return Object.hash(
      'map',
      value.length,
      Object.hashAllUnordered(value.keys.map((k) => '$k')),
    );
  }
  if (value is List) return Object.hash('list', value.length);
  return value.hashCode;
}
