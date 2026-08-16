// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';
import 'json_value.dart';

/// A JSON:API resource exactly as abctl emits it: `{type, id, attributes:{…}}`. The open
/// `attributes` bag is a [JSONValue]; typed accessors pull the columns a view renders.
///
/// `type` and `id` are non-optional in the Swift original, so a payload missing either threw.
/// Here they default to the empty string: a resource abctl declined to fully describe is still
/// a row the list can show (and every accessor below already copes with an empty id), whereas
/// a throw would take out the whole list for one malformed member.
class Resource {
  final String type;
  final String id;
  final JSONValue? attributes;

  const Resource({this.type = '', this.id = '', this.attributes});

  factory Resource.fromJson(Map<String, dynamic> json) => Resource(
    type: asStringOr(json, 'type', ''),
    id: asStringOr(json, 'id', ''),
    // Absent and explicitly-null both land as null; the accessors treat them alike.
    attributes: json.containsKey('attributes') && json['attributes'] != null
        ? JSONValue.fromJson(json['attributes'])
        : null,
  );

  /// Decodes a `[{…}, {…}]` list response — the shape of every plural `get …` verb.
  static List<Resource> listFromJson(Object? decoded) {
    if (decoded is! List) return const <Resource>[];
    return decoded
        .whereType<Map>()
        .map((e) => Resource.fromJson(asJsonMap(e)))
        .toList(growable: false);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'id': id,
    if (attributes != null) 'attributes': attributes!.toJson(),
  };

  /// A string attribute (e.g. "name", "serialNumber") or null.
  String? attr(String key) => attributes?.string(key);

  /// The user's role names joined (roles are a per-user attribute: `roles[].role`).
  String roleNames() {
    final roles = attributes?.array('roles');
    if (roles == null) return '';
    return roles
        .map((role) => role.string('role'))
        .whereType<String>()
        .join(', ');
  }

  /// A best-effort display name from the common name-ish attributes.
  String displayName() {
    for (final key in const ['name', 'serverName', 'serialNumber']) {
      final value = attr(key);
      if (value != null && value.isNotEmpty) return value;
    }
    final full = [
      attr('firstName'),
      attr('lastName'),
    ].whereType<String>().join(' ');
    return full.isEmpty ? id : full;
  }

  @override
  bool operator ==(Object other) =>
      other is Resource &&
      other.type == type &&
      other.id == id &&
      other.attributes == attributes;

  @override
  int get hashCode => Object.hash(type, id, attributes);

  @override
  String toString() => 'Resource($type/$id)';
}
