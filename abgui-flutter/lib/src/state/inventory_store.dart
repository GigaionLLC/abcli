// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:abgui/src/abctl/abctl_client.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/os_release.dart';
import 'package:abgui/src/models/read_only_kind.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/models/vpp.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'load_token.dart';
import 'providers.dart';

/// One screen's worth of cached rows. The unit of loading, of failure, and of "is this busy".
///
/// There is no app-wide `isLoading` anywhere in this layer, and this enum is why there does not
/// need to be. In the Swift app one shared flag meant a slow Devices fetch spun the Configurations
/// screen, and one shared `loadError` meant an OS Releases failure — raisable from inside a device
/// detail SHEET — rendered on whatever list happened to be behind it.
enum InventoryPane {
  configurations,
  blueprints,
  osReleases,
  devices,
  mdmDevices,
  users,
  userGroups,
  apps,
  packages,
  mdmServers,
  audit,

  /// Apps & Books. A different SERVICE from the Business API with its own credential, but from
  /// this layer's point of view it is one more read-only pane with its own spinner and its own
  /// error slot.
  vpp;

  /// The pane a read-only screen loads into, or null for [ReadOnlyKind.unknown] — which is not a
  /// screen (it exists so a persisted value from another build cannot crash the sidebar) and must
  /// therefore not be able to claim a cache.
  static InventoryPane? forReadOnly(ReadOnlyKind kind) => switch (kind) {
    ReadOnlyKind.devices => InventoryPane.devices,
    ReadOnlyKind.mdmDevices => InventoryPane.mdmDevices,
    ReadOnlyKind.users => InventoryPane.users,
    ReadOnlyKind.userGroups => InventoryPane.userGroups,
    ReadOnlyKind.apps => InventoryPane.apps,
    ReadOnlyKind.packages => InventoryPane.packages,
    ReadOnlyKind.mdmServers => InventoryPane.mdmServers,
    ReadOnlyKind.audit => InventoryPane.audit,
    ReadOnlyKind.unknown => null,
  };
}

/// Whether ONE pane is busy, what went wrong on it last, and when it last read cleanly.
class PaneStatus {
  const PaneStatus({this.isLoading = false, this.error, this.loadedAt});

  static const PaneStatus idle = PaneStatus();

  final bool isLoading;

  /// The message for this pane and no other. A pane's error is only ever written by a load OF
  /// that pane, which is the property the Swift app's shared `loadError` could not have.
  final String? error;

  /// When this pane last completed a clean read. Survives a later failure on purpose: the rows on
  /// screen really were read at that time, and blanking the stamp would make cached data look
  /// freshly fetched.
  final DateTime? loadedAt;

  bool get hasLoaded => loadedAt != null;

  @override
  bool operator ==(Object other) =>
      other is PaneStatus &&
      other.isLoading == isLoading &&
      other.error == error &&
      other.loadedAt == loadedAt;

  @override
  int get hashCode => Object.hash(isLoading, error, loadedAt);

  @override
  String toString() =>
      'PaneStatus(loading: $isLoading, error: $error, loadedAt: $loadedAt)';
}

/// The Apps & Books reads, which are four documents rather than one list.
class VppInventory {
  const VppInventory({
    this.config,
    this.assets = const <VPPAsset>[],
    this.assignments = const <VPPAssignment>[],
    this.users = const <VPPUser>[],
  });

  /// Null until a content token validates. `config` succeeding IS the connection test — the three
  /// lists below tolerate individual endpoint failures, because a tenant with no assignments and
  /// a tenant whose assignments endpoint errored both need the rest of the screen to work.
  final VPPServiceConfig? config;
  final List<VPPAsset> assets;
  final List<VPPAssignment> assignments;
  final List<VPPUser> users;

  bool get isConnected => config != null;
}

/// Every read-only cache, keyed by pane.
///
/// There is deliberately no `==` here. Riverpod compares the SLICES a widget selected
/// (`paneStatusProvider`, `paneResourcesProvider`), never the whole cache, so a value-equality
/// walk over five thousand devices on every notification would buy nothing and cost exactly what
/// this layer is built to avoid. The lists are immutable and replaced wholesale, so identity is a
/// correct — and O(1) — test for "did this pane's rows change".
class Inventory {
  /// The two maps are copied into unmodifiable views rather than stored as handed in, which is why
  /// this constructor is not `const`. A state object that shares a mutable map with the code that
  /// built it is not immutable at all: the "previous" state a widget already decided was unchanged
  /// would change underneath it the next time a pane loaded.
  Inventory({
    Map<InventoryPane, List<Resource>> resources =
        const <InventoryPane, List<Resource>>{},
    Map<InventoryPane, PaneStatus> statuses =
        const <InventoryPane, PaneStatus>{},
    this.osReleases = const <OSRelease>[],
    this.vpp,
    this.auditSince = defaultAuditSince,
  }) : _resources = Map<InventoryPane, List<Resource>>.unmodifiable(resources),
       _statuses = Map<InventoryPane, PaneStatus>.unmodifiable(statuses);

  /// abctl's own window spelling. A week is long enough to cover "what changed since I last
  /// looked" without asking Apple for a year of events on first paint.
  static const String defaultAuditSince = '7d';

  final Map<InventoryPane, List<Resource>> _resources;
  final Map<InventoryPane, PaneStatus> _statuses;

  /// Apple's GDMF feed — not a tenant read, and not `Resource`-shaped, hence its own slot.
  final List<OSRelease> osReleases;

  final VppInventory? vpp;

  /// The audit window (`7d`, `24h`, an ISO date), passed to abctl verbatim: abctl — not abgui —
  /// owns what a valid window is.
  final String auditSince;

  /// The rows for a pane, empty until it has loaded. The SAME list object is returned until that
  /// pane loads again, which is what makes a `select` on it stable.
  List<Resource> resources(InventoryPane pane) =>
      _resources[pane] ?? const <Resource>[];

  PaneStatus status(InventoryPane pane) => _statuses[pane] ?? PaneStatus.idle;

  /// The Swift `readItems(_:)`, minus the switch: an unknown kind has no pane and no rows.
  List<Resource> readOnly(ReadOnlyKind kind) {
    final pane = InventoryPane.forReadOnly(kind);
    return pane == null ? const <Resource>[] : resources(pane);
  }

  Inventory withResources(InventoryPane pane, List<Resource> rows) => Inventory(
    resources: <InventoryPane, List<Resource>>{..._resources, pane: rows},
    statuses: _statuses,
    osReleases: osReleases,
    vpp: vpp,
    auditSince: auditSince,
  );

  Inventory withStatus(InventoryPane pane, PaneStatus status) => Inventory(
    resources: _resources,
    statuses: <InventoryPane, PaneStatus>{..._statuses, pane: status},
    osReleases: osReleases,
    vpp: vpp,
    auditSince: auditSince,
  );

  Inventory copyWith({
    List<OSRelease>? osReleases,
    VppInventory? vpp,
    String? auditSince,
  }) => Inventory(
    resources: _resources,
    statuses: _statuses,
    osReleases: osReleases ?? this.osReleases,
    vpp: vpp ?? this.vpp,
    auditSince: auditSince ?? this.auditSince,
  );

  /// Forget Apps & Books entirely — the "disconnect" the VPP screen offers. Separate from
  /// [copyWith] because that one cannot express "set this back to null".
  Inventory withoutVpp() => Inventory(
    resources: _resources,
    statuses: _statuses,
    osReleases: osReleases,
    auditSince: auditSince,
  );
}

/// The read caches, one independent load per pane.
///
/// Every verb reached from here is a live GET, Apple's GDMF feed, or the Apps & Books read API.
/// This release ships no mutating verb at all — `AbctlClient` has no method for one and
/// `AbctlArgs` has no builder that can emit one — so there is nothing here that could change a
/// tenant even by mistake.
class InventoryStore extends Notifier<Inventory> {
  /// One generation PER PANE, created on first use. This is the structural half of per-pane
  /// isolation: the other half is that a pane's status is only ever written under its own token,
  /// so a load of Devices cannot clear the Users spinner even at the exact instant the two
  /// overlap.
  final Map<InventoryPane, LoadGeneration> _generations =
      <InventoryPane, LoadGeneration>{};

  @override
  Inventory build() => Inventory();

  LoadGeneration _generationFor(InventoryPane pane) => _generations.putIfAbsent(
    pane,
    () => LoadGeneration('inventory.${pane.name}'),
  );

  /// Load one pane. [cancel] lets a screen stop its own fetch when the user navigates away;
  /// a cancelled load reports nothing, because the user asked for it.
  ///
  /// Calling this for [InventoryPane.vpp] is a programming error — Apps & Books needs a content
  /// token that this signature has nowhere to carry — and it is one the analyzer cannot catch, so
  /// it throws rather than quietly loading nothing. Use [loadVpp].
  Future<void> load(InventoryPane pane, {CancelToken? cancel}) {
    if (pane == InventoryPane.vpp) {
      throw ArgumentError.value(
        pane,
        'pane',
        'Apps & Books needs a content token — call loadVpp(contentToken:)',
      );
    }
    return _run(pane, (client) => _fetch(pane, client, cancel));
  }

  /// Load a read-only screen. A no-op for [ReadOnlyKind.unknown], which is not a screen.
  Future<void> loadReadOnly(ReadOnlyKind kind, {CancelToken? cancel}) async {
    final pane = InventoryPane.forReadOnly(kind);
    if (pane == null) return;
    await load(pane, cancel: cancel);
  }

  /// Validate an Apps & Books content token and read the inventory behind it.
  ///
  /// [contentToken] is a PARAMETER and is never stored in this state. It is a bearer credential
  /// for a different service, and state is the one place in the app it would end up copied into a
  /// UI object, a `toString()`, or a screenshot. abctl takes it on argv (its own interface), where
  /// `CommandFormatter.redactedFlags` already strips it from every recorded and displayed line.
  Future<void> loadVpp({required String contentToken, CancelToken? cancel}) {
    if (contentToken.isEmpty) {
      state = state.withStatus(
        InventoryPane.vpp,
        const PaneStatus(error: 'Enter an Apps & Books content token.'),
      );
      return Future<void>.value();
    }
    return _run(
      InventoryPane.vpp,
      (client) => _fetchVpp(client, contentToken, cancel),
    );
  }

  /// Forget the Apps & Books session (the token was never held, so there is nothing to wipe but
  /// the rows it read).
  void disconnectVpp() {
    _generationFor(InventoryPane.vpp).invalidate();
    state = state.withoutVpp().withStatus(InventoryPane.vpp, PaneStatus.idle);
  }

  /// Change the audit window. It does NOT refetch: the screen that owns the control decides when
  /// to spend an API call, and a store that reloaded on every keystroke of a text field would
  /// spend one per character.
  void setAuditSince(String since) {
    if (since == state.auditSince) return;
    state = state.copyWith(auditSince: since);
  }

  /// The one load path: take a token, raise this pane's spinner, run, publish under the token.
  ///
  /// Every write to `state` here is scoped to [pane], and every one of them is guarded by
  /// `token.isStale`. Those two rules together are what make "loading one pane must not clear or
  /// flag another" a property of the code rather than a thing to be careful about.
  Future<void> _run(
    InventoryPane pane,
    Future<Inventory Function(Inventory)> Function(AbctlClient client) body,
  ) async {
    final token = _generationFor(pane).begin();
    final previous = state.status(pane);
    // The error is dropped as the spinner goes up: a stale message under a live spinner reads as
    // "this failed" while the fetch that might fix it is still running.
    state = state.withStatus(
      pane,
      PaneStatus(isLoading: true, loadedAt: previous.loadedAt),
    );
    try {
      final publish = await body(ref.read(abctlClientProvider));
      if (token.isStale) return;
      state = publish(
        state,
      ).withStatus(pane, PaneStatus(loadedAt: DateTime.now()));
    } on AbctlCancelled {
      // The user navigated away or pressed Cancel. Not a failure, so nothing is said — but the
      // spinner still has to come down, and only if we still own the pane.
      if (token.isStale) return;
      state = state.withStatus(pane, PaneStatus(loadedAt: previous.loadedAt));
    } catch (error) {
      if (token.isStale) return;
      // The rows already on screen are kept, along with the time they were read: they are still
      // the last thing the tenant said, and blanking a table because a refresh failed throws away
      // the only data the user has.
      state = state.withStatus(
        pane,
        PaneStatus(error: loadErrorText(error), loadedAt: previous.loadedAt),
      );
    }
  }

  /// Fetch, and return HOW to publish the result rather than publishing it. The staleness check
  /// then lives at exactly one callsite ([_run]) instead of once per case below, where the twelfth
  /// case added by the next person is the one that forgets it.
  Future<Inventory Function(Inventory)> _fetch(
    InventoryPane pane,
    AbctlClient client,
    CancelToken? cancel,
  ) async {
    switch (pane) {
      case InventoryPane.configurations:
        final rows = await client.configurations(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.blueprints:
        final rows = await client.blueprints(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.devices:
        final rows = await client.devices(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.mdmDevices:
        final rows = await client.mdmDevices(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.users:
        final rows = await client.users(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.userGroups:
        final rows = await client.userGroups(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.apps:
        final rows = await client.apps(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.packages:
        final rows = await client.packages(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.mdmServers:
        final rows = await client.mdmServers(cancel: cancel);
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.audit:
        // Read from state at call time, not from a captured copy: the window the user selected
        // just before pressing Refresh is the one they expect to be asked about.
        final rows = await client.audit(
          since: state.auditSince,
          cancel: cancel,
        );
        return (Inventory inventory) => inventory.withResources(pane, rows);
      case InventoryPane.osReleases:
        final rows = await client.osReleases(cancel: cancel);
        return (Inventory inventory) => inventory.copyWith(osReleases: rows);
      case InventoryPane.vpp:
        throw ArgumentError.value(pane, 'pane', 'handled by loadVpp');
    }
  }

  /// Apps & Books, in the Swift original's order: `config` decides connected/failed, then the
  /// three collections are best-effort. An assignments endpoint that errors leaves the assets
  /// table on screen instead of taking the whole screen down with it.
  Future<Inventory Function(Inventory)> _fetchVpp(
    AbctlClient client,
    String contentToken,
    CancelToken? cancel,
  ) async {
    final config = await client.vppConfig(token: contentToken, cancel: cancel);
    final assets = await _tolerate(
      () => client.vppAssets(token: contentToken, cancel: cancel),
      const <VPPAsset>[],
    );
    final assignments = await _tolerate(
      () => client.vppAssignments(token: contentToken, cancel: cancel),
      const <VPPAssignment>[],
    );
    final users = await _tolerate(
      () => client.vppUsers(token: contentToken, cancel: cancel),
      const <VPPUser>[],
    );
    return (Inventory inventory) => inventory.copyWith(
      vpp: VppInventory(
        config: config,
        assets: assets,
        assignments: assignments,
        users: users,
      ),
    );
  }

  /// Run a secondary read whose failure must not fail the pane — but let a CANCELLATION through,
  /// because "the user pressed Cancel" has to reach [_run]'s cancel path rather than being
  /// swallowed into an empty table that looks like an answer.
  static Future<T> _tolerate<T>(Future<T> Function() read, T fallback) async {
    try {
      return await read();
    } on AbctlCancelled {
      rethrow;
    } catch (_) {
      return fallback;
    }
  }
}
