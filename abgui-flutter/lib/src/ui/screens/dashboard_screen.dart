// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The overview: one stat tile per collection, counting the rows in the inventory caches.
///
/// **The load is SEQUENTIAL, and that is the whole design.** Nine collections means nine abctl
/// invocations, each of which mints or reuses an Apple Business token and issues at least one
/// API call. Fired as a burst, a first run on a large tenant walks straight into Apple's rate
/// limiter and comes back with nine 429s instead of nine counts — and the retry a user then
/// presses makes it worse. So the pass is a plain `for` loop that awaits each read, and it STOPS
/// on the first failure: with a bad credential or no network, every remaining call would fail
/// identically, and spending eight more requests to learn that costs the user their rate budget
/// for the next minute.
///
/// A tile shows an em dash until its cache has actually loaded, so a displayed `0` always means a
/// real zero rather than "not asked yet" — the one thing a dashboard must never blur.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/read_only_kind.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/screens/inventory_chrome.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key, required this.onOpen});

  /// Moves the shell's selection to a pane. A tile is a way IN to a screen, not a screen of its
  /// own — the count is only useful if the rows behind it are one click away.
  final void Function(InventoryPane pane) onOpen;

  /// Sidebar order: the two GitOps collections, then the live inventories. Audit is a time-window
  /// event feed rather than an inventory — "how many audit events" is a question about the
  /// selected window, not about the tenant — so it has no tile, exactly as in the Swift original.
  /// OS Releases is Apple's feed, not this organization's, and is left off for the same reason.
  static const List<InventoryPane> tiles = <InventoryPane>[
    InventoryPane.configurations,
    InventoryPane.blueprints,
    InventoryPane.devices,
    InventoryPane.mdmDevices,
    InventoryPane.users,
    InventoryPane.userGroups,
    InventoryPane.apps,
    InventoryPane.packages,
    InventoryPane.mdmServers,
  ];

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  /// Panes whose cache finished loading this session. Held separately from "the cache is
  /// non-empty" because those are different facts: an organization with no packages loads
  /// successfully and stays empty, and its tile must read `0`, not `—`.
  final Set<InventoryPane> _loaded = <InventoryPane>{};

  bool _isRefreshing = false;

  /// The first failure of the current pass. The pass stopped there; the tiles after it are
  /// honestly still unknown.
  String? _failure;

  /// The pass's cancellation, so a disposed dashboard stops issuing abctl calls instead of
  /// racing the screen that replaced it.
  ///
  /// Note what this does NOT cover, because the shell keeps opened screens alive in an
  /// `IndexedStack`: navigating away does not dispose this screen, so a pass in flight keeps
  /// running behind the screen the user just opened. That is deliberate — the counts finish
  /// rather than restarting from nothing on every visit — and it stays safe because each pane
  /// carries its own generation: the destination screen's own read supersedes the pass's read of
  /// the same pane, so the overlap is one extra call, not the nine-way burst this file is about.
  CancelToken? _pass;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_loadAll(force: false)),
    );
  }

  @override
  void dispose() {
    _pass?.cancel();
    super.dispose();
  }

  Future<void> _loadAll({required bool force}) async {
    if (_isRefreshing) return;
    final cancel = CancelToken();
    _pass = cancel;
    setState(() {
      _isRefreshing = true;
      _failure = null;
    });
    try {
      for (final InventoryPane pane in DashboardScreen.tiles) {
        if (cancel.isCancelled || !mounted) return;
        if (!force &&
            (_loaded.contains(pane) ||
                ref.read(paneStatusProvider(pane)).hasLoaded)) {
          // A pane its own screen already filled counts as loaded: re-reading it would spend an
          // Apple call to redraw a number that is already correct.
          _loaded.add(pane);
          continue;
        }
        await ref.read(inventoryProvider.notifier).load(pane, cancel: cancel);
        if (cancel.isCancelled || !mounted) return;
        // Read the failure of the pane we JUST ran, from that pane's own status slot. The Swift
        // version had to write a comment explaining that the error it surfaced might belong to
        // something else entirely, because every load reported into one shared slot.
        final String? error = ref.read(paneStatusProvider(pane)).error;
        if (error != null) {
          setState(() => _failure = error);
          return;
        }
        setState(() => _loaded.add(pane));
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The one screen that legitimately watches the whole cache: it draws every pane at once, so
    // there is no narrower slice to select and nothing to be gained by watching nine.
    final Inventory inventory = ref.watch(inventoryProvider);
    final String? failure = _failure;

    return InventoryScreenFrame(
      title: 'Dashboard',
      symbol: 'square.grid.2x2',
      status: _isRefreshing ? 'reading…' : null,
      toolbar: <Widget>[
        ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Refresh all',
          tooltip:
              'Re-count every collection, one request at a time. Stops at the '
              'first failure.',
          onPressed: _isRefreshing
              ? null
              : () => unawaited(_loadAll(force: true)),
        ),
      ],
      banner: failure == null
          ? null
          : NoticeBanner(
              tone: AbSeverity.danger,
              icon: Icons.warning_amber_rounded,
              text: 'Stopped after the first failure',
              detail: failure,
              trailing: ToolbarButton(
                icon: abIcon('arrow.clockwise'),
                label: 'Retry',
                tooltip: 'Run the counting pass again from the start.',
                weight: AbToolbarWeight.titled,
                onPressed: _isRefreshing
                    ? null
                    : () => unawaited(_loadAll(force: true)),
              ),
            ),
      child: GridView.builder(
        padding: const EdgeInsets.all(AbSpace.lg),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
          mainAxisExtent: 96,
          crossAxisSpacing: AbSpace.md,
          mainAxisSpacing: AbSpace.md,
        ),
        itemCount: DashboardScreen.tiles.length,
        itemBuilder: (BuildContext context, int index) {
          final InventoryPane pane = DashboardScreen.tiles[index];
          return _StatTile(
            title: dashboardTitle(pane),
            symbol: dashboardSymbol(pane),
            count: _countText(inventory, pane),
            isLoading: inventory.status(pane).isLoading,
            onOpen: () => widget.onOpen(pane),
          );
        },
      ),
    );
  }

  /// The cached count, or an em dash while the cache has not loaded. See [_loaded]: the dash and
  /// the zero are different claims and must not be able to swap places.
  String _countText(Inventory inventory, InventoryPane pane) {
    final List<Resource> rows = inventory.resources(pane);
    if (rows.isEmpty &&
        !_loaded.contains(pane) &&
        !inventory.status(pane).hasLoaded) {
      return '—';
    }
    return '${rows.length}';
  }
}

/// A tile's caption. Read-only panes take their name from [ReadOnlyKind] so the tile, the sidebar
/// and the screen header cannot disagree — except Apps, which drops the "(catalog)" qualifier the
/// way the Swift dashboard did: a tile caption has no room for it and the count already implies
/// an inventory.
String dashboardTitle(InventoryPane pane) => switch (pane) {
  InventoryPane.configurations => 'Configurations',
  InventoryPane.blueprints => 'Blueprints',
  InventoryPane.apps => 'Apps',
  _ => _kindFor(pane)?.title ?? pane.name,
};

String dashboardSymbol(InventoryPane pane) => switch (pane) {
  InventoryPane.configurations => 'doc.text',
  InventoryPane.blueprints => 'square.stack.3d.up',
  _ => _kindFor(pane)?.symbol ?? 'circle',
};

/// The inverse of [InventoryPane.forReadOnly]. Kept here rather than pushed into the model
/// because the dashboard is its only caller, and a reverse map in the model would be one more
/// pair of switches to keep in step for no other reader's benefit.
ReadOnlyKind? _kindFor(InventoryPane pane) => switch (pane) {
  InventoryPane.devices => ReadOnlyKind.devices,
  InventoryPane.mdmDevices => ReadOnlyKind.mdmDevices,
  InventoryPane.users => ReadOnlyKind.users,
  InventoryPane.userGroups => ReadOnlyKind.userGroups,
  InventoryPane.apps => ReadOnlyKind.apps,
  InventoryPane.packages => ReadOnlyKind.packages,
  InventoryPane.mdmServers => ReadOnlyKind.mdmServers,
  InventoryPane.audit => ReadOnlyKind.audit,
  _ => null,
};

/// One clickable count.
///
/// The number is monospaced and tabular (via [MonoText]) for the same reason every other figure
/// in this app is: nine tiles in a grid are read as a column, and proportional digits make
/// `1,204` and `984` look the same length.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.title,
    required this.symbol,
    required this.count,
    required this.isLoading,
    required this.onOpen,
  });

  final String title;
  final String symbol;
  final String count;
  final bool isLoading;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return Semantics(
      button: true,
      label: '$title, $count',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Open $title',
        child: Material(
          color: ab.raised,
          borderRadius: BorderRadius.circular(AbSpace.radius),
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(AbSpace.radius),
            child: Container(
              padding: const EdgeInsets.all(AbSpace.md),
              decoration: BoxDecoration(
                border: Border.all(color: ab.line),
                borderRadius: BorderRadius.circular(AbSpace.radius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(abIcon(symbol), size: 16, color: ab.dim),
                      const Spacer(),
                      // The pane's own spinner, on the pane's own tile. During the opening pass
                      // exactly one tile spins at a time, which is what makes the sequencing
                      // visible instead of merely true.
                      if (isLoading)
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: ab.accent,
                          ),
                        ),
                    ],
                  ),
                  MonoText(
                    count,
                    size: 24,
                    color: ab.text,
                    weight: FontWeight.w600,
                  ),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: ab.dim),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
