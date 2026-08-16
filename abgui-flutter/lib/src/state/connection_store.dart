// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:abgui/src/models/contract.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'load_token.dart';
import 'providers.dart';

/// Whether abctl answered, and what it said when it did.
///
/// A sealed family rather than a bag of nullable fields: [ConnectionConnected] OWNS a
/// [VersionInfo] and [ConnectionFailed] owns a message, so no view can render a version that was
/// never read or a banner with no text in it. Ported from the Swift `AppModel.Connection` enum.
sealed class Connection {
  const Connection();

  /// True only for [ConnectionConnected] — the gate every screen that needs a live tenant asks.
  bool get isConnected => this is ConnectionConnected;
}

/// Nothing has been checked yet: the state at launch, before the first `version` call.
final class ConnectionUnknown extends Connection {
  const ConnectionUnknown();

  @override
  bool operator ==(Object other) => other is ConnectionUnknown;

  @override
  int get hashCode => (ConnectionUnknown).hashCode;
}

final class ConnectionChecking extends Connection {
  const ConnectionChecking();

  @override
  bool operator ==(Object other) => other is ConnectionChecking;

  @override
  int get hashCode => (ConnectionChecking).hashCode;
}

/// abctl ran. [identity] is nullable on purpose: `version` needs no credentials while `whoami`
/// reaches Apple for a token, so a first run with nothing configured yet is CONNECTED to the CLI
/// and unauthenticated to the tenant — two different facts that a single boolean would collapse
/// into "broken", sending a new user hunting for a bug instead of to the Settings screen.
final class ConnectionConnected extends Connection {
  const ConnectionConnected(this.version, this.identity);

  final VersionInfo version;
  final WhoamiResult? identity;

  bool get isAuthenticated => identity?.authenticated ?? false;

  @override
  bool operator ==(Object other) =>
      other is ConnectionConnected &&
      other.version == version &&
      other.identity == identity;

  @override
  int get hashCode => Object.hash(version, identity);
}

final class ConnectionFailed extends Connection {
  const ConnectionFailed(this.message);

  /// Shown verbatim in a banner — [loadErrorText]'s output, which for an abctl failure is abctl's
  /// own stderr and for a missing binary is every path that was searched.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is ConnectionFailed && other.message == message;

  @override
  int get hashCode => message.hashCode;
}

/// The abctl context every command is scoped by, as `--context <name>`.
///
/// **Why this is its own notifier and not a field on [ConnectionStore].** The client is built FROM
/// this value, and [ConnectionStore] is built from the client; a store that both owns the value and
/// consumes the client would be a cycle in Riverpod's graph, and Riverpod asserts on those (it is
/// right to: the value would be read from a provider that is mid-build). Keeping the two scoping
/// values — this and the GitOps workspace — as leaves that depend on NOTHING is what lets every
/// store reach the client without one.
///
/// Empty means "whatever abctl's own current context is", and empty is the DEFAULT rather than a
/// missing value to be filled in. This release cannot run `abctl context use`, which writes
/// `~/.abctl/contexts.yaml`; selecting a saved connection scopes abgui's own commands and changes
/// nothing about the operator's store or about what the CLI does in their terminal. See
/// `AbctlArgs.contextSuffixed` for why empty must not become an empty flag.
class ActiveContextStore extends Notifier<String> {
  @override
  String build() => '';

  void select(String name) {
    if (name == state) return;
    state = name;
  }
}

/// Verifies the embedded abctl and reports what the tenant said.
class ConnectionStore extends Notifier<Connection> {
  /// Its OWN generation. A check started by switching context must not be undone by one a
  /// reconnect button started a moment later, and neither may be invalidated by a resource list
  /// loading somewhere else in the app — see [LoadGeneration].
  final LoadGeneration _checks = LoadGeneration('connection.check');

  @override
  Connection build() => const ConnectionUnknown();

  /// Verify the embedded abctl runs, read its version, then ask the tenant who we are.
  ///
  /// `whoami` failing is NOT a failed connection (see [ConnectionConnected.identity]); only
  /// `version`, which touches nothing but the binary, decides connected/failed.
  Future<void> check() async {
    final token = _checks.begin();
    state = const ConnectionChecking();
    final client = ref.read(abctlClientProvider);
    try {
      final version = await client.version();
      WhoamiResult? identity;
      try {
        identity = await client.whoami();
      } catch (_) {
        identity = null;
      }
      if (token.isStale) return;
      state = ConnectionConnected(version, identity);
    } catch (error) {
      // A superseded check must not publish its failure either: it was asking about a tenant that
      // is no longer on screen, and a red banner naming the previous one is worse than none.
      if (token.isStale) return;
      state = ConnectionFailed(loadErrorText(error));
    }
  }

  /// Scope abgui's commands to a saved context and re-check against it.
  ///
  /// The in-flight check is orphaned first: it was answering a question about a different tenant,
  /// and letting it land would put that tenant's version and identity under the new context's name.
  Future<void> useContext(String name) async {
    if (name == ref.read(activeContextProvider)) return;
    _checks.invalidate();
    ref.read(activeContextProvider.notifier).select(name);
    state = const ConnectionUnknown();
    await check();
  }
}
