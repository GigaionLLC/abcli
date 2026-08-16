// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The application widget and the one table that says which screen each sidebar row opens.
///
/// **Why the routing table lives here and not in `RootShell`.** The shell owns layout, selection
/// and the guarantee that nothing is ever replaced by a spinner; it takes a [ShellScreenBuilder]
/// precisely so it can be pumped in a test with nineteen stand-in screens and assert that
/// contract without spawning a single abctl process. Keeping the real table outside it is what
/// makes that possible — and it means the set of screens can grow without touching the file that
/// holds the layout invariants.
///
/// There is no `Navigator` route table. This app has ONE window with a persistent sidebar, and
/// every destination is an `IndexedStack` slot that keeps its state; routes would give each
/// screen a lifecycle tied to a navigation stack, which is the thing the shell deliberately does
/// not have. Dialogs (the resource inspector, the profile viewer, Validate) are pushed onto the
/// root navigator by the screens that own them, which is the only navigation here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/screens/archive_screen.dart';
import 'package:abgui/src/ui/screens/blueprints_screen.dart';
import 'package:abgui/src/ui/screens/command_log_screen.dart';
import 'package:abgui/src/ui/screens/configurations_screen.dart';
import 'package:abgui/src/ui/screens/console_screen.dart';
import 'package:abgui/src/ui/screens/dashboard_screen.dart';
import 'package:abgui/src/ui/screens/diff_screen.dart';
import 'package:abgui/src/ui/screens/os_releases_screen.dart';
import 'package:abgui/src/ui/screens/read_only_screen.dart';
import 'package:abgui/src/ui/screens/run_logs_screen.dart';
import 'package:abgui/src/ui/screens/settings_screen.dart';
import 'package:abgui/src/ui/screens/system_health_screen.dart';
import 'package:abgui/src/ui/screens/whats_new_screen.dart';
import 'package:abgui/src/ui/shell/root_shell.dart';
import 'package:abgui/src/ui/shell/sidebar_item.dart';
import 'package:abgui/src/ui/theme.dart';

/// The window.
///
/// Both themes are built up front and Flutter picks between them from [Settings.themeMode], so
/// "System" tracks the desktop's own light/dark switch live rather than at launch. The palette
/// itself is `abTheme`'s; nothing in this app reads a Material colour directly.
class AbguiApp extends ConsumerWidget {
  const AbguiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode mode = ref.watch(
      settingsProvider.select((Settings settings) => settings.themeMode),
    );
    return MaterialApp(
      title: 'abgui',
      // The debug ribbon covers the top-right corner of the context strip, which is where the
      // Reconnect control lives — it makes the one control a broken connection needs unclickable
      // in every screenshot a developer takes.
      debugShowCheckedModeBanner: false,
      theme: abTheme(Brightness.light),
      darkTheme: abTheme(Brightness.dark),
      themeMode: mode,
      home: const RootShell(screenBuilder: abguiScreen),
    );
  }
}

/// Which screen a sidebar row opens.
///
/// Called ONCE per destination, the first time it is selected (see `_RootShellState._children`),
/// so what it returns must read its data from providers rather than from anything captured here.
///
/// The switch is exhaustive over [ShellDestination] on purpose and has no `default`: a destination
/// added to the enum breaks this build until it is given a screen, which is the only mechanism
/// that stops a sidebar row from being added and silently opening a blank pane.
Widget abguiScreen(
  BuildContext context,
  ShellDestination destination,
) => switch (destination) {
  // -- Overview -----------------------------------------------------------------------------
  ShellDestination.dashboard => const _DashboardHost(),
  ShellDestination.systemHealth => const SystemHealthScreen(),
  ShellDestination.commandLog => const CommandLogScreen(),
  ShellDestination.runLogs => const RunLogsScreen(),
  ShellDestination.console => const ConsoleScreen(),
  ShellDestination.whatsNew => const WhatsNewScreen(),
  ShellDestination.settings => const SettingsScreen(),

  // -- GitOps -------------------------------------------------------------------------------
  ShellDestination.configurations => const ConfigurationsScreen(),
  ShellDestination.blueprints => const BlueprintsScreen(),
  ShellDestination.diff => const DiffScreen(),
  ShellDestination.archive => const ArchiveScreen(),
  ShellDestination.osReleases => const OsReleasesScreen(),

  // -- Inventory ----------------------------------------------------------------------------
  // Eight panes, one screen: `ReadOnlyKind` carries the title, the symbol, the columns and the
  // abctl verb, which is why there are not eight near-identical screen classes here. The `!`
  // is safe by construction — a destination is in this group exactly when it HAS a kind, and
  // the switch arm is the enumeration of that group.
  ShellDestination.devices ||
  ShellDestination.mdmDevices ||
  ShellDestination.users ||
  ShellDestination.userGroups ||
  ShellDestination.apps ||
  ShellDestination.packages ||
  ShellDestination.mdmServers ||
  ShellDestination.audit => ReadOnlyScreen(kind: destination.readOnly!),
};

/// Gives the Dashboard a way to open the pane behind a tile.
///
/// The dashboard's tiles are `InventoryPane` values — a tile is a count of a cache — while the
/// shell navigates by [ShellDestination], so the two have to be bridged somewhere.
///
/// **It has to be a widget, and the lookup has to happen in the callback.** The shell calls
/// [abguiScreen] from its own `BuildContext`, which sits ABOVE the `ShellNavigation` it is in the
/// middle of building; a lookup there would find nothing. This wrapper's context is below it, and
/// [ShellNavigation.readOf] is used rather than `maybeOf` so no dependency is registered — a
/// dependency would rebuild the Dashboard every time the user selected any other screen, which is
/// exactly the "navigation re-runs a load" behaviour the `IndexedStack` exists to prevent.
class _DashboardHost extends StatelessWidget {
  const _DashboardHost();

  @override
  Widget build(BuildContext context) =>
      DashboardScreen(onOpen: (InventoryPane pane) => _open(context, pane));

  static void _open(BuildContext context, InventoryPane pane) {
    final ShellDestination? destination = ShellDestination.forPane(pane);
    // Null for a pane with no sidebar row (Apps & Books). A tile that cannot open anything is a
    // tile that does nothing when clicked, which is preferable to navigating somewhere arbitrary.
    if (destination == null) return;
    ShellNavigation.readOf(context)?.go(destination);
  }
}
