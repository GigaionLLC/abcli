// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';

/// Stable `abctl get os-releases -o json` contract.
///
/// `expirationDate` and `supportedDevices` are optional at the source: Apple's GDMF feed omits
/// an expiry for a release that has none, and lists supported devices only for the catalogs
/// that carry them. Everything else is always present, and defaults here rather than throwing
/// so one malformed row cannot empty the whole table.
class OSRelease {
  final String platform;
  final String productVersion;
  final String build;
  final String postingDate;
  final String? expirationDate;
  final List<String>? supportedDevices;
  final String catalog;
  final bool expired;

  const OSRelease({
    this.platform = '',
    this.productVersion = '',
    this.build = '',
    this.postingDate = '',
    this.expirationDate,
    this.supportedDevices,
    this.catalog = '',
    this.expired = false,
  });

  factory OSRelease.fromJson(Map<String, dynamic> json) => OSRelease(
    platform: asStringOr(json, 'platform', ''),
    productVersion: asStringOr(json, 'productVersion', ''),
    build: asStringOr(json, 'build', ''),
    postingDate: asStringOr(json, 'postingDate', ''),
    expirationDate: asString(json, 'expirationDate'),
    supportedDevices: asStringList(json, 'supportedDevices'),
    catalog: asStringOr(json, 'catalog', ''),
    expired: asBoolOr(json, 'expired', false),
  );

  static List<OSRelease> listFromJson(Object? decoded) {
    if (decoded is! List) return const <OSRelease>[];
    return decoded
        .whereType<Map>()
        .map((e) => OSRelease.fromJson(asJsonMap(e)))
        .toList(growable: false);
  }

  /// Build alone is not unique — the same build appears in more than one catalog, and two
  /// platforms can share one — so the row identity carries all three.
  String get id => '$catalog:$platform:$build';

  @override
  bool operator ==(Object other) =>
      other is OSRelease &&
      other.platform == platform &&
      other.productVersion == productVersion &&
      other.build == build &&
      other.postingDate == postingDate &&
      other.expirationDate == expirationDate &&
      other.catalog == catalog &&
      other.expired == expired &&
      listEquals(other.supportedDevices, supportedDevices);

  @override
  int get hashCode => Object.hash(
    platform,
    productVersion,
    build,
    postingDate,
    expirationDate,
    catalog,
    expired,
    supportedDevices?.length ?? -1,
  );

  @override
  String toString() => 'OSRelease($id)';
}
