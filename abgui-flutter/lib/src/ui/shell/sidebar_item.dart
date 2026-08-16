// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/models/read_only_kind.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';

/// The three groups the sidebar draws, in order.
///
/// The Swift original called the third one "Read-only", which named a PROPERTY of the screens
/// rather than what is in them — and it stopped being true the moment Devices grew its gated
/// assignment write. "Inventory" says what the section holds, and the read-only disclosure lives
/// where it belongs: on the screen itself (`NoticeBanner`), where the user is about to act.
enum ShellSection {
  overview('Overview'),
  gitops('GitOps'),
  inventory('Inventory');

  const ShellSection(this.title);

  final String title;

  /// The section's rows, in [ShellDestination] declaration order. Derived rather than listed a
  /// second time: a destination added to the enum and given a section appears in the sidebar
  /// automatically, where a hand-kept list is one edit away from a screen nobody can reach.
  List<ShellDestination> get destinations => ShellDestination.values
      .where((ShellDestination d) => d.section == this)
      .toList(growable: false);
}

/// Every screen the shell can show, in sidebar order.
///
/// Ported from `RootView.SidebarItem`, with the Swift file's two deliberate omissions kept:
///
///  * **Apps & Books (VPP) is not here.** Its comment in RootView says why — content tokens
///    connect external MDM services and must not be offered as a built-in-management option.
///    `InventoryPane.vpp` still exists for the screen that is reachable from Settings.
///  * **`ReadOnlyKind.unknown` is not here.** It is not a screen; it exists so a persisted value
///    from another build cannot crash the sidebar.
///
/// The enum's ORDER is load-bearing twice over: it is the order the sidebar draws, and
/// [RootShell] uses `index` directly as the `IndexedStack` index. Reordering the cases reorders
/// the sidebar and the stack together, which is the only way those two can stay in step.
enum ShellDestination {
  // -- Overview -------------------------------------------------------------------------------
  dashboard(ShellSection.overview),
  systemHealth(ShellSection.overview),
  commandLog(ShellSection.overview),
  runLogs(ShellSection.overview),
  console(ShellSection.overview),
  whatsNew(ShellSection.overview),

  /// **A row the Swift app did not have, and could not have needed.** macOS gives every app a
  /// Settings SCENE for free — `Settings { SettingsView() }` in `App.swift`, opened with ⌘, from
  /// a menu bar AppKit draws. Windows and Linux have neither the scene nor the menu item, so a
  /// screen reachable only that way is a screen that does not exist on two of the three targets.
  /// It is in the sidebar rather than behind a gear in the window chrome because the chrome's one
  /// job is stating the tenant/workspace/direction triple (see `ContextBar`), and because the
  /// context menu there already tells a first-time user to "open Settings" — which has to be a
  /// place they can see.
  settings(ShellSection.overview),

  // -- GitOps ---------------------------------------------------------------------------------
  // Write-capable in the Swift app; in this build these screens read the workspace and compute a
  // plan, and nothing here can apply one — see `GitopsStore`'s class comment.
  configurations(ShellSection.gitops),
  blueprints(ShellSection.gitops),
  diff(ShellSection.gitops),
  archive(ShellSection.gitops),

  // -- Inventory ------------------------------------------------------------------------------
  devices(ShellSection.inventory),
  mdmDevices(ShellSection.inventory),
  osReleases(ShellSection.inventory),
  users(ShellSection.inventory),
  userGroups(ShellSection.inventory),
  apps(ShellSection.inventory),
  packages(ShellSection.inventory),
  mdmServers(ShellSection.inventory),
  audit(ShellSection.inventory);

  const ShellDestination(this.section);

  final ShellSection section;

  /// Stable token for persistence and for keying [ShellStatus] reports. The enum NAME, not the
  /// index: an index changes the moment a screen is inserted, and a persisted "screen 12" would
  /// then reopen on a different pane.
  String get id => name;

  /// The live resource this screen browses, or null for the Overview and GitOps screens.
  ///
  /// Delegating title, symbol and columns to [ReadOnlyKind] is what stops the sidebar and the
  /// screen from ever disagreeing about what a pane is called — the Swift app made the same
  /// choice for the same reason.
  ReadOnlyKind? get readOnly => switch (this) {
    ShellDestination.devices => ReadOnlyKind.devices,
    ShellDestination.mdmDevices => ReadOnlyKind.mdmDevices,
    ShellDestination.users => ReadOnlyKind.users,
    ShellDestination.userGroups => ReadOnlyKind.userGroups,
    ShellDestination.apps => ReadOnlyKind.apps,
    ShellDestination.packages => ReadOnlyKind.packages,
    ShellDestination.mdmServers => ReadOnlyKind.mdmServers,
    ShellDestination.audit => ReadOnlyKind.audit,
    _ => null,
  };

  /// The cache this screen loads into, or null when it owns no pane (the Overview screens read
  /// process-local state, and Archive reads the run-log directory).
  ///
  /// This is what makes the status pip possible at all: a destination that names its pane can be
  /// asked how that pane's last load went, from anywhere in the app.
  InventoryPane? get pane {
    final ReadOnlyKind? kind = readOnly;
    if (kind != null) return InventoryPane.forReadOnly(kind);
    return switch (this) {
      ShellDestination.configurations => InventoryPane.configurations,
      ShellDestination.blueprints => InventoryPane.blueprints,
      ShellDestination.osReleases => InventoryPane.osReleases,
      _ => null,
    };
  }

  /// The screen that browses [pane], or null when nothing does.
  ///
  /// The INVERSE of [pane], and derived from it rather than written out a second time: the
  /// Dashboard's tiles are `InventoryPane` values (a tile is a count of a cache) while the shell
  /// navigates by destination, so something has to bridge them. A hand-kept second table would be
  /// the copy that goes stale — a pane whose screen was renamed would open the wrong one, which is
  /// far worse than opening none. `InventoryPane.vpp` correctly answers null here: Apps & Books
  /// has a cache and no sidebar row, exactly as the enum's comment says.
  static ShellDestination? forPane(InventoryPane pane) {
    for (final ShellDestination destination in values) {
      if (destination.pane == pane) return destination;
    }
    return null;
  }

  String get title =>
      readOnly?.title ??
      switch (this) {
        ShellDestination.dashboard => 'Dashboard',
        ShellDestination.systemHealth => 'System Health',
        ShellDestination.commandLog => 'Command Log',
        ShellDestination.runLogs => 'Logs',
        ShellDestination.console => 'Console',
        ShellDestination.whatsNew => 'What’s New',
        ShellDestination.settings => 'Settings',
        ShellDestination.configurations => 'Configurations',
        ShellDestination.blueprints => 'Blueprints',
        ShellDestination.diff => 'Diff / Drift',
        ShellDestination.archive => 'Archive',
        ShellDestination.osReleases => 'OS Releases',
        _ => name,
      };

  /// The SF Symbol name, translated to a glyph by `sf_icons.dart`. Kept as a string here for the
  /// reason `ReadOnlyKind.symbol` gives: the names are DATA carried over from the macOS app, and
  /// the one translation table is the only place a name becomes an `IconData`.
  String get symbol =>
      readOnly?.symbol ??
      switch (this) {
        ShellDestination.dashboard => 'square.grid.2x2',
        ShellDestination.systemHealth => 'stethoscope',
        ShellDestination.commandLog => 'terminal',
        ShellDestination.runLogs => 'doc.text.magnifyingglass',
        ShellDestination.console => 'chevron.left.forwardslash.chevron.right',
        ShellDestination.whatsNew => 'sparkles',
        ShellDestination.settings => 'gearshape',
        ShellDestination.configurations => 'doc.text',
        ShellDestination.blueprints => 'square.stack.3d.up',
        ShellDestination.diff => 'arrow.triangle.branch',
        ShellDestination.archive => 'clock.arrow.circlepath',
        ShellDestination.osReleases => 'apple.logo',
        _ => 'circle',
      };
}

/// What one screen's own load is doing, seen from the sidebar.
///
/// **The point of this type is that an error on one screen is visible from every other screen.**
/// In the Swift app a failed load painted a message on the pane that failed and nowhere else, so
/// a user who kicked off Devices, navigated to Blueprints and came back had no way to know their
/// device list was a stale cache behind a failure. The pip is small, but it is the only surface
/// that reports every pane at once.
///
/// The four states come straight out of `PaneStatus` and need no clock, which matters: anything
/// derived from "how long ago" would have to tick, and a ticking sidebar is a rebuild per second
/// of every row in the app's most-visible chrome.
enum SidebarPip {
  /// Nothing to say: never asked, or last read cleanly.
  quiet,

  /// A read for this pane is in flight right now.
  loading,

  /// The last read FAILED while rows from an earlier read are still on screen. The screen is
  /// readable but out of date — the distinction `AbTable` already draws when it renders a banner
  /// over stale rows instead of an empty state, mirrored here so it survives navigation.
  stale,

  /// The last read failed with nothing behind it. That screen is empty and broken.
  error;

  /// The pip's colour, through the app's one severity mapping. Colour is never the only channel:
  /// each state also has a distinct SHAPE (see [SidebarItemView._pip]) and a spoken name.
  AbSeverity get severity => switch (this) {
    SidebarPip.quiet => AbSeverity.neutral,
    SidebarPip.loading => AbSeverity.neutral,
    SidebarPip.stale => AbSeverity.drift,
    SidebarPip.error => AbSeverity.danger,
  };

  /// Plain words for a tooltip and for a screen reader. Not the enum names — "stale" is jargon.
  String? get explanation => switch (this) {
    SidebarPip.quiet => null,
    SidebarPip.loading => 'loading',
    SidebarPip.stale => 'showing older data — the last refresh failed',
    SidebarPip.error => 'last load failed',
  };
}

/// Read one destination's pip, subscribing to THAT pane and nothing else.
///
/// Called from inside [SidebarItemView.build], so each row is its own subscriber: a Devices fetch
/// rebuilds the Devices row and leaves the other eighteen alone. Watching a whole store here
/// instead would make every row rebuild on every load in the app — which is affordable today and
/// would stop being affordable the moment a row grows anything expensive.
SidebarPip sidebarPipOf(WidgetRef ref, ShellDestination destination) {
  if (destination == ShellDestination.diff) {
    // The plan is not an inventory pane: it has its own busy flag, its own error slot and its own
    // `LoadGeneration`, and a plan already on screen is exactly the "stale rows" case below.
    final PlanState plan = ref.watch(
      gitopsProvider.select((GitopsState s) => s.plan),
    );
    if (plan.isRunning) return SidebarPip.loading;
    if (plan.error == null) return SidebarPip.quiet;
    return plan.hasPlan ? SidebarPip.stale : SidebarPip.error;
  }

  final InventoryPane? pane = destination.pane;
  if (pane == null) return SidebarPip.quiet;
  final PaneStatus status = ref.watch(paneStatusProvider(pane));
  // Loading wins over a message: the store drops a pane's error as its spinner goes up, so an
  // error surviving alongside `isLoading` would be a state this layer cannot produce.
  if (status.isLoading) return SidebarPip.loading;
  if (status.error == null) return SidebarPip.quiet;
  // `hasLoaded` is the clock-free proxy for "there are rows behind this failure": the store keeps
  // the previous rows AND the stamp when a refresh fails, precisely so the user is not left
  // staring at a blank table because one request timed out.
  return status.hasLoaded ? SidebarPip.stale : SidebarPip.error;
}

/// One sidebar row: icon, title, status pip.
///
/// A `ConsumerWidget` per row rather than one consumer around the whole list — see
/// [sidebarPipOf]. It is also why this file is separate from `sidebar.dart`: the list is layout,
/// the row is a subscription.
class SidebarItemView extends ConsumerWidget {
  const SidebarItemView({
    super.key,
    required this.destination,
    required this.selected,
    required this.onSelect,
    this.collapsed = false,
  });

  final ShellDestination destination;
  final bool selected;
  final ValueChanged<ShellDestination> onSelect;

  /// Icon-rail mode: the glyph and the pip, with the title moved into the tooltip.
  final bool collapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final SidebarPip pip = sidebarPipOf(ref, destination);
    final String? note = pip.explanation;
    final Color ink = selected ? ab.text : ab.dim;

    return Tooltip(
      message: note == null
          ? destination.title
          : '${destination.title} — $note',
      child: Semantics(
        button: true,
        selected: selected,
        // The pip is decoration for a screen reader unless it says something; folding it into the
        // one label stops VoiceOver walking "Devices" and "failed" as two unrelated stops.
        label: note == null ? destination.title : '${destination.title}, $note',
        excludeSemantics: true,
        child: Material(
          color: selected ? ab.sunken : Colors.transparent,
          borderRadius: BorderRadius.circular(AbSpace.radius),
          child: InkWell(
            onTap: () => onSelect(destination),
            borderRadius: BorderRadius.circular(AbSpace.radius),
            hoverColor: ab.surface,
            child: SizedBox(
              height: 26,
              child: Row(
                mainAxisAlignment: collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: <Widget>[
                  // The selection bar is FORM, not tint: on a projector, in a screenshot, and to a
                  // reader with no colour vision the sunken fill alone is not a reliable signal.
                  Container(
                    width: 2,
                    height: 26,
                    color: selected ? ab.accent : Colors.transparent,
                  ),
                  SizedBox(width: collapsed ? 8 : AbSpace.sm),
                  Icon(
                    abIcon(destination.symbol),
                    size: 15,
                    color: selected ? ab.accent : ab.dim,
                  ),
                  if (!collapsed) ...<Widget>[
                    const SizedBox(width: AbSpace.sm),
                    Expanded(
                      child: Text(
                        destination.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: ink,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                  _pip(ab, pip),
                  SizedBox(width: collapsed ? 6 : AbSpace.sm),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The pip itself. Three DIFFERENT GLYPHS, not three tints of one dot: a ring for work in
  /// progress, a solid dot for data that is merely old, and a filled error mark for a screen with
  /// nothing on it. Colour reinforces; shape carries.
  ///
  /// Deliberately not a `CircularProgressIndicator` for [SidebarPip.loading]: an indeterminate
  /// spinner asks the engine for a frame every vsync for as long as any pane is loading, and the
  /// live "still working" signal already exists, once, in the run strip's elapsed ticker.
  Widget _pip(AbColors ab, SidebarPip pip) {
    if (pip == SidebarPip.quiet) {
      // A fixed-width blank, not `SizedBox.shrink()`: the titles must not shift sideways by 9px
      // the moment a load starts, which is the same "chrome that moves under the user on an event
      // they did not cause" fault the Swift connection footer had.
      return const SizedBox(width: 9);
    }
    final IconData glyph = switch (pip) {
      SidebarPip.loading => Icons.circle_outlined,
      SidebarPip.stale => Icons.circle,
      SidebarPip.error => Icons.error,
      SidebarPip.quiet => Icons.circle_outlined,
    };
    return Icon(
      glyph,
      size: 9,
      color: pip == SidebarPip.loading ? ab.accent : pip.severity.ink(ab),
    );
  }
}

/// How anything below the shell asks for a different screen.
///
/// It lives beside [ShellDestination] rather than in `root_shell.dart` so that a screen can
/// navigate without importing the shell that contains it — the Swift dashboard took a
/// `select:` closure for the same reason, and the run strip's command line uses this to open the
/// Command Log exactly the way the old connection footer did.
class ShellNavigation extends InheritedWidget {
  const ShellNavigation({
    super.key,
    required this.go,
    required this.current,
    required super.child,
  });

  /// Select a destination. A stable method reference on the shell's state, so
  /// [updateShouldNotify] is almost always false.
  final ValueChanged<ShellDestination> go;

  final ShellDestination current;

  /// For a widget that DRAWS something about the current selection — the run strip's command
  /// line disables itself when there is nowhere to go. Registers a dependency, so the caller
  /// rebuilds when the selection changes.
  static ShellNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellNavigation>();

  /// For a widget that only NAVIGATES, from inside a callback.
  ///
  /// The distinction is load-bearing: [maybeOf] would make its caller rebuild on every
  /// navigation, and a screen that rebuilds on navigation is a screen that can re-run its load —
  /// the exact behaviour the shell's `IndexedStack` and its cached screen instances exist to
  /// prevent. A tap handler needs the value, not a subscription to it.
  static ShellNavigation? readOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShellNavigation>();

  @override
  bool updateShouldNotify(ShellNavigation oldWidget) =>
      oldWidget.current != current || oldWidget.go != go;
}
