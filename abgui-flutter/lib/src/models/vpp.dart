// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';

// Apps & Books (VPP). Almost every field is optional because it is optional AT THE SOURCE:
// Apple's content service omits counts a location does not have, and `name` only exists when
// abctl managed to resolve the adam id through the iTunes lookup. The Swift originals said the
// same thing with `?` on nearly every property.

/// One owned app/book + its license counts (`abctl vpp assets`).
class VPPAsset {
  /// Resolved by abctl via the iTunes lookup (may be absent).
  final String? name;
  final String adamId;
  final String? productType;
  final String? pricingParam;
  final int? availableCount;
  final int? assignedCount;
  final int? retiredCount;
  final int? totalCount;
  final bool? deviceAssignable;
  final bool? revocable;
  final List<String>? supportedPlatforms;

  const VPPAsset({
    this.name,
    this.adamId = '',
    this.productType,
    this.pricingParam,
    this.availableCount,
    this.assignedCount,
    this.retiredCount,
    this.totalCount,
    this.deviceAssignable,
    this.revocable,
    this.supportedPlatforms,
  });

  factory VPPAsset.fromJson(Map<String, dynamic> json) => VPPAsset(
    name: asString(json, 'name'),
    adamId: asStringOr(json, 'adamId', ''),
    productType: asString(json, 'productType'),
    pricingParam: asString(json, 'pricingParam'),
    availableCount: asInt(json, 'availableCount'),
    assignedCount: asInt(json, 'assignedCount'),
    retiredCount: asInt(json, 'retiredCount'),
    totalCount: asInt(json, 'totalCount'),
    deviceAssignable: asBool(json, 'deviceAssignable'),
    revocable: asBool(json, 'revocable'),
    supportedPlatforms: asStringList(json, 'supportedPlatforms'),
  );

  /// An asset is identified by adam id AND pricing param: the same title can be owned twice
  /// under different license terms, and collapsing them would hide one of the two rows.
  String get id => adamId + (pricingParam ?? '');

  @override
  bool operator ==(Object other) =>
      other is VPPAsset &&
      other.name == name &&
      other.adamId == adamId &&
      other.productType == productType &&
      other.pricingParam == pricingParam &&
      other.availableCount == availableCount &&
      other.assignedCount == assignedCount &&
      other.retiredCount == retiredCount &&
      other.totalCount == totalCount &&
      other.deviceAssignable == deviceAssignable &&
      other.revocable == revocable &&
      listEquals(other.supportedPlatforms, supportedPlatforms);

  @override
  int get hashCode => Object.hash(
    name,
    adamId,
    productType,
    pricingParam,
    availableCount,
    assignedCount,
    retiredCount,
    totalCount,
  );
}

/// One license assignment (`abctl vpp assignments`).
class VPPAssignment {
  final String adamId;
  final String? pricingParam;
  final String? serialNumber;
  final String? clientUserId;

  const VPPAssignment({
    this.adamId = '',
    this.pricingParam,
    this.serialNumber,
    this.clientUserId,
  });

  factory VPPAssignment.fromJson(Map<String, dynamic> json) => VPPAssignment(
    adamId: asStringOr(json, 'adamId', ''),
    pricingParam: asString(json, 'pricingParam'),
    serialNumber: asString(json, 'serialNumber'),
    clientUserId: asString(json, 'clientUserId'),
  );

  /// A license is assigned to a DEVICE or a USER, never both, so the id concatenates both
  /// slots — whichever one is filled is what distinguishes this row.
  String get id => adamId + (serialNumber ?? '') + (clientUserId ?? '');

  @override
  bool operator ==(Object other) =>
      other is VPPAssignment &&
      other.adamId == adamId &&
      other.pricingParam == pricingParam &&
      other.serialNumber == serialNumber &&
      other.clientUserId == clientUserId;

  @override
  int get hashCode =>
      Object.hash(adamId, pricingParam, serialNumber, clientUserId);
}

/// One registered VPP user (`abctl vpp users`).
class VPPUser {
  final String clientUserId;
  final String? email;
  final String? status;

  const VPPUser({this.clientUserId = '', this.email, this.status});

  factory VPPUser.fromJson(Map<String, dynamic> json) => VPPUser(
    clientUserId: asStringOr(json, 'clientUserId', ''),
    email: asString(json, 'email'),
    status: asString(json, 'status'),
  );

  String get id => clientUserId;

  @override
  bool operator ==(Object other) =>
      other is VPPUser &&
      other.clientUserId == clientUserId &&
      other.email == email &&
      other.status == status;

  @override
  int get hashCode => Object.hash(clientUserId, email, status);
}

/// `abctl vpp config` — the token validator + limits.
class VPPServiceConfig {
  final String? locationName;
  final String? tokenExpirationDate;
  final Map<String, String>? urls;
  final Map<String, int>? limits;

  const VPPServiceConfig({
    this.locationName,
    this.tokenExpirationDate,
    this.urls,
    this.limits,
  });

  factory VPPServiceConfig.fromJson(Map<String, dynamic> json) {
    final rawUrls = asMap(json, 'urls');
    final rawLimits = asMap(json, 'limits');
    return VPPServiceConfig(
      locationName: asString(json, 'locationName'),
      tokenExpirationDate: asString(json, 'tokenExpirationDate'),
      // Apple's service config is a grab-bag that grows; entries of an unexpected type are
      // dropped rather than failing the document, so a new URL kind cannot hide the limits.
      urls: rawUrls == null
          ? null
          : <String, String>{
              for (final e in rawUrls.entries)
                if (e.value is String) e.key: e.value as String,
            },
      limits: rawLimits == null
          ? null
          : <String, int>{
              for (final e in rawLimits.entries)
                if (e.value is num) e.key: (e.value as num).toInt(),
            },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VPPServiceConfig &&
      other.locationName == locationName &&
      other.tokenExpirationDate == tokenExpirationDate &&
      _mapEquals(other.urls, urls) &&
      _mapEquals(other.limits, limits);

  @override
  int get hashCode => Object.hash(
    locationName,
    tokenExpirationDate,
    urls?.length ?? -1,
    limits?.length ?? -1,
  );
}

bool _mapEquals<V>(Map<String, V>? a, Map<String, V>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
