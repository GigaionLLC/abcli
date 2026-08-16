// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The shell's contract, which is one sentence: NOTHING IS EVER REPLACED BY A SPINNER.
//
// Every case here is the Swift app's blanking bug approached from a different side — a command
// starting, a screen being revisited, a divider being dragged — and each asserts the same two
// things: the sidebar is still on screen, and the content pane did not rebuild. The build counter
// is the load-bearing part of these tests. A screen that rebuilds is a screen that re-runs its
// load, and re-running loads on navigation is what made the Swift sidebar unusable as a place to
// see what was happening.

import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/src/abctl/abctl_client.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/shell/root_shell.dart';
import 'package:abgui/src/ui/shell/sidebar.dart';
import 'package:abgui/src/ui/shell/sidebar_item.dart';
import 'package:abgui/src/ui/shell/status_bar.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/elapsed_ticker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // The shell restores its sidebar width through this. Without the mock the plugin channel is
    // missing, the restore falls into its own catch, and the test would be exercising the failure
    // path while looking like it exercised the happy one.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'a running command replaces neither the sidebar nor the content',
    (WidgetTester tester) async {
      final _Harness harness = await _pumpShell(tester);

      expect(find.text('Devices'), findsOneWidget);
      expect(harness.builds[ShellDestination.dashboard], 1);
      expect(
        find.byType(ElapsedTicker),
        findsNothing,
        reason: 'the run strip draws nothing at all while abgui is idle',
      );

      harness.container
          .read(commandLogProvider.notifier)
          .start(
            CommandRecord(argv: <String>['diff', '--json'], cwd: '/tmp/ws'),
          );
      await tester.pump();

      expect(find.textContaining('abctl diff --json'), findsOneWidget);
      expect(find.byType(ElapsedTicker), findsOneWidget);
      expect(
        find.text('Devices'),
        findsOneWidget,
        reason:
            'the sidebar stays on screen for the whole run — the Swift '
            'footer inset blanked it here',
      );
      expect(find.byType(Sidebar), findsOneWidget);
      expect(
        harness.builds[ShellDestination.dashboard],
        1,
        reason:
            'a command starting must not rebuild the content pane: the '
            'strip is a sibling, not an overlay',
      );
    },
  );

  testWidgets(
    'revisiting a screen does not rebuild it, and unvisited screens are never built',
    (WidgetTester tester) async {
      final _Harness harness = await _pumpShell(tester);

      await tester.tap(find.text('Diff / Drift'));
      await tester.pump();
      expect(find.text('screen:diff'), findsOneWidget);
      expect(harness.builds[ShellDestination.diff], 1);

      await tester.tap(find.text('Dashboard'));
      await tester.pump();
      expect(find.text('screen:dashboard'), findsOneWidget);
      expect(
        harness.builds[ShellDestination.dashboard],
        1,
        reason:
            'the IndexedStack keeps the element alive, so coming back is '
            'free — no rebuild, and therefore no second load',
      );
      expect(
        harness.builds[ShellDestination.diff],
        1,
        reason: 'and the screen navigated away from keeps its in-flight work',
      );
      expect(
        harness.builds[ShellDestination.audit],
        isNull,
        reason:
            'an IndexedStack builds every child it is given, so unvisited '
            'destinations must be empty slots — otherwise nineteen screens '
            'would each fire a tenant read at launch',
      );
    },
  );

  testWidgets(
    'dragging the sidebar divider resizes it without rebuilding the content',
    (WidgetTester tester) async {
      final _Harness harness = await _pumpShell(tester);
      final double before = tester.getSize(find.byType(Sidebar)).width;

      await tester.drag(
        find.bySemanticsLabel('Resize sidebar'),
        const Offset(60, 0),
      );
      // Long enough for the divider's double-tap recognizer to give up waiting for a second tap.
      // It arms on every pointer-up, and a timer still pending at the end of a test is an error.
      await tester.pump(const Duration(milliseconds: 400));

      // The FULL 60, including the 20px of touch slop the recognizer spends deciding this is a
      // drag: `DragStartBehavior.down` is what hands those back, and without it the divider ends up
      // permanently 20px away from the cursor that is dragging it.
      expect(tester.getSize(find.byType(Sidebar)).width, before + 60);
      expect(
        harness.builds[ShellDestination.dashboard],
        1,
        reason:
            'the width is a ValueNotifier and the screens are cached '
            'instances, so a drag rebuilds one SizedBox',
      );
    },
  );

  testWidgets('collapsing hides the titles and keeps every row', (
    WidgetTester tester,
  ) async {
    await _pumpShell(tester);

    await tester.tap(find.byTooltip('Collapse the sidebar to an icon rail'));
    await tester.pump();

    expect(find.text('Devices'), findsNothing);
    expect(find.text('OVERVIEW'), findsNothing);
    expect(tester.getSize(find.byType(Sidebar)).width, RootShell.railWidth);
    expect(
      find.byTooltip('Devices'),
      findsOneWidget,
      reason: 'the rail keeps every destination reachable and named',
    );
  });

  testWidgets('a failed load on one pane is visible from another screen', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _pumpShell(
      tester,
      handler: (List<String> args) async =>
          _exit(1, 'the devices endpoint said no'),
    );

    // The user is on the Dashboard. The failure happens on a pane they are not looking at, which
    // in the Swift app meant it was reported nowhere they could see.
    await harness.container
        .read(inventoryProvider.notifier)
        .load(InventoryPane.devices);
    await tester.pump();

    expect(find.byTooltip('Devices — last load failed'), findsOneWidget);
    expect(
      find.byTooltip('Users'),
      findsOneWidget,
      reason:
          'and no other pane is flagged — the error belongs to the pane '
          'that raised it',
    );
  });

  test(
    'status reports are keyed by screen, because hidden screens never rebuild',
    () {
      final ShellStatusController controller = ShellStatusController();
      addTearDown(controller.dispose);
      controller.show('devices');

      controller.report('devices', const ShellStatus(rowCount: 12));
      expect(controller.visible.rowCount, 12);

      // A background refresh landing on a screen the user is not looking at records its numbers but
      // must not put them in the bar.
      controller.report('users', const ShellStatus(rowCount: 3));
      expect(controller.visible.rowCount, 12);

      controller.show('users');
      expect(controller.visible.rowCount, 3);

      controller.show('archive');
      expect(
        controller.visible,
        ShellStatus.empty,
        reason:
            'a screen that has never reported shows nothing, rather than '
            'the last screen\'s counts',
      );
    },
  );
}

/// The pumped shell plus the two things a test needs to interrogate it: the container (to move
/// state the way a store would) and a per-destination build counter.
class _Harness {
  _Harness(this.container, this.builds);

  final ProviderContainer container;
  final Map<ShellDestination, int> builds;
}

Future<_Harness> _pumpShell(
  WidgetTester tester, {
  Future<AbctlResult> Function(List<String> args)? handler,
}) async {
  final Map<ShellDestination, int> builds = <ShellDestination, int>{};
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      abctlClientProvider.overrideWithValue(
        AbctlClient(
          runner: _ScriptedRunner(
            handler ?? (List<String> args) async => _ok('[]'),
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: abTheme(Brightness.light),
        home: RootShell(
          // No bootstrap: a widget test must not reach for the last workspace or spawn abctl.
          bootstrap: false,
          screenBuilder: (BuildContext context, ShellDestination destination) =>
              _CountingScreen(destination: destination, builds: builds),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(container, builds);
}

/// A stand-in screen that records every build. Screens proper are built elsewhere; what the shell
/// owes them is that this counter stays at 1.
class _CountingScreen extends StatelessWidget {
  const _CountingScreen({required this.destination, required this.builds});

  final ShellDestination destination;
  final Map<ShellDestination, int> builds;

  @override
  Widget build(BuildContext context) {
    builds[destination] = (builds[destination] ?? 0) + 1;
    return Center(child: Text('screen:${destination.id}'));
  }
}

class _ScriptedRunner implements AbctlRunner {
  const _ScriptedRunner(this.handler);

  final Future<AbctlResult> Function(List<String> args) handler;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) => handler(args);
}

AbctlResult _ok(String stdout) => AbctlResult(
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: '',
  code: 0,
);

AbctlResult _exit(int code, String stderr) =>
    AbctlResult(stdout: Uint8List(0), stderr: stderr, code: code);
