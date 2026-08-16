// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';

// The identity/version/context payloads. These are the documents abgui reads BEFORE it can do
// anything else, which is why every field here has a total default rather than a throw: the
// connection banner and the Settings screen have to be able to say what they did get back.
// A `whoami` that answers with half a document is a diagnosis; a decode failure is not.

/// `auth whoami --json` (abctl P1) — a typed "test connection".
class WhoamiResult {
  final bool authenticated;
  final String clientID;
  final String apiBase;
  final String tokenExpires;
  final int configurations;
  final int blueprints;

  const WhoamiResult({
    this.authenticated = false,
    this.clientID = '',
    this.apiBase = '',
    this.tokenExpires = '',
    this.configurations = 0,
    this.blueprints = 0,
  });

  /// The wire keys are snake_case here and camelCase almost everywhere else in abctl's
  /// output; that inconsistency is the contract, so it is spelled out rather than derived.
  factory WhoamiResult.fromJson(Map<String, dynamic> json) => WhoamiResult(
    authenticated: asBoolOr(json, 'authenticated', false),
    clientID: asStringOr(json, 'client_id', ''),
    apiBase: asStringOr(json, 'api_base', ''),
    tokenExpires: asStringOr(json, 'token_expires', ''),
    configurations: asIntOr(json, 'configurations', 0),
    blueprints: asIntOr(json, 'blueprints', 0),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'authenticated': authenticated,
    'client_id': clientID,
    'api_base': apiBase,
    'token_expires': tokenExpires,
    'configurations': configurations,
    'blueprints': blueprints,
  };

  @override
  bool operator ==(Object other) =>
      other is WhoamiResult &&
      other.authenticated == authenticated &&
      other.clientID == clientID &&
      other.apiBase == apiBase &&
      other.tokenExpires == tokenExpires &&
      other.configurations == configurations &&
      other.blueprints == blueprints;

  @override
  int get hashCode => Object.hash(
    authenticated,
    clientID,
    apiBase,
    tokenExpires,
    configurations,
    blueprints,
  );
}

/// `version --json` (abctl P2) — build identity + the capability tokens abgui gates on.
class VersionInfo {
  final String version;
  final String? commit;
  final String? buildTime;
  final String goVersion;
  final List<String> capabilities;

  const VersionInfo({
    this.version = '',
    this.commit,
    this.buildTime,
    this.goVersion = '',
    this.capabilities = const <String>[],
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) => VersionInfo(
    version: asStringOr(json, 'version', ''),
    commit: asString(json, 'commit'),
    buildTime: asString(json, 'buildTime'),
    goVersion: asStringOr(json, 'goVersion', ''),
    // An absent capability list must read as "this build claims nothing", never as a
    // decode failure: `has()` is what gates features, so the safe answer is no.
    capabilities: asStringListOr(json, 'capabilities'),
  );

  bool has(String capability) => capabilities.contains(capability);

  @override
  bool operator ==(Object other) =>
      other is VersionInfo &&
      other.version == version &&
      other.commit == commit &&
      other.buildTime == buildTime &&
      other.goVersion == goVersion &&
      listEquals(other.capabilities, capabilities);

  @override
  int get hashCode =>
      Object.hash(version, commit, buildTime, goVersion, capabilities.length);
}

/// `context list -o json` — the saved connection contexts + which one is current.
class ContextList {
  final String current;
  final List<String> contexts;

  const ContextList({this.current = '', this.contexts = const <String>[]});

  factory ContextList.fromJson(Map<String, dynamic> json) => ContextList(
    current: asStringOr(json, 'current', ''),
    contexts: asStringListOr(json, 'contexts'),
  );

  @override
  bool operator ==(Object other) =>
      other is ContextList &&
      other.current == current &&
      listEquals(other.contexts, contexts);

  @override
  int get hashCode => Object.hash(current, contexts.length);
}

/// `context get [name] -o json` — one context's fields. Only the client id + key PATH are
/// ever surfaced (abctl never prints key material), so there is no key-bytes field here.
class ContextDetail {
  final String name;
  final ContextFields context;

  const ContextDetail({this.name = '', this.context = const ContextFields()});

  factory ContextDetail.fromJson(Map<String, dynamic> json) => ContextDetail(
    name: asStringOr(json, 'name', ''),
    context: ContextFields.fromJson(asMapOr(json, 'context')),
  );

  @override
  bool operator ==(Object other) =>
      other is ContextDetail && other.name == name && other.context == context;

  @override
  int get hashCode => Object.hash(name, context);
}

/// The stored fields of one connection context.
class ContextFields {
  final String clientID;

  /// A filesystem PATH to the EC private key — never key material. abctl passes the path on
  /// argv precisely so the key itself cannot leak through a process listing or an error
  /// string, and this type exists to keep that property visible.
  final String keyPath;
  final String? apiBase;

  const ContextFields({this.clientID = '', this.keyPath = '', this.apiBase});

  factory ContextFields.fromJson(Map<String, dynamic> json) => ContextFields(
    clientID: asStringOr(json, 'client_id', ''),
    keyPath: asStringOr(json, 'key', ''),
    // Absent means "abctl's built-in Apple Business base"; the UI shows nothing rather
    // than inventing a URL that a copied command would then contradict.
    apiBase: asString(json, 'api_base'),
  );

  @override
  bool operator ==(Object other) =>
      other is ContextFields &&
      other.clientID == clientID &&
      other.keyPath == keyPath &&
      other.apiBase == apiBase;

  @override
  int get hashCode => Object.hash(clientID, keyPath, apiBase);
}
