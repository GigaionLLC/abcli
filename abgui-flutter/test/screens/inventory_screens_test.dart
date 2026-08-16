// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// What these pin, in order of what would hurt most if it broke:
//
//  1. The dashboard counts SEQUENTIALLY and stops at the first failure. Nine parallel abctl
//     invocations is a first run that returns nine 429s instead of nine counts, and it is an
//     easy accident: `await Future.wait(...)` reads like the obvious way to write this loop.
//  2. Which screens carry a control that can write the tenant, and that each one is disclosed on
//     the screen and inert until it has arguments. Devices has assignment; Blueprints has
//     membership; Configurations has New / Edit / Delete, each inert without the row and the
//     workspace it needs. A control appearing on one of these lists has to be justified one at a
//     time — that is what makes the list a guard rather than an inventory.
//  3. The CSV export is the file version of the rows on screen — same order, same values, with
//     the screens' em-dash placeholder mapped back to the empty field abctl's own `-o csv` emits.
//  4. OS Releases still finds a release by SUPPORTED DEVICE, which is the one search that reaches
//     data the table has no column for (and therefore the one the table cannot filter for us).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:abgui/src/abctl/abctl_client.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/json_value.dart';
import 'package:abgui/src/models/os_release.dart';
import 'package:abgui/src/models/read_only_kind.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/screens/blueprints_screen.dart';
import 'package:abgui/src/ui/screens/configurations_screen.dart';
import 'package:abgui/src/ui/screens/dashboard_screen.dart';
import 'package:abgui/src/ui/screens/inventory_chrome.dart';
import 'package:abgui/src/ui/screens/os_releases_screen.dart';
import 'package:abgui/src/ui/screens/read_only_screen.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

void main() {
  group('dashboard', () {
    testWidgets('counts one collection at a time, never as a burst', (
      WidgetTester tester,
    ) async {
      final runner = _ScriptedRunner(
        (List<String> args) async => _rowsFor(args, 2),
      );
      await _pumpScreen(tester, runner, DashboardScreen(onOpen: (_) {}));

      expect(
        runner.peakInFlight,
        1,
        reason: 'two abctl reads in flight at once is the rate-limit burst',
      );
      expect(runner.verbs, <String>[
        'configurations',
        'blueprints',
        'devices',
        'mdmdevices',
        'users',
        'usergroups',
        'apps',
        'packages',
        'mdmservers',
      ]);
    });

    testWidgets('stops the pass at the first failure and says which', (
      WidgetTester tester,
    ) async {
      final runner = _ScriptedRunner((List<String> args) async {
        if (args[1] == 'users') {
          return _exit(1, 'the users endpoint said no');
        }
        return _rowsFor(args, 1);
      });
      await _pumpScreen(tester, runner, DashboardScreen(onOpen: (_) {}));

      expect(
        runner.verbs,
        <String>[
          'configurations',
          'blueprints',
          'devices',
          'mdmdevices',
          'users',
        ],
        reason:
            'with one collection failing, every remaining call would fail the '
            'same way — spending them costs the user their rate budget',
      );
      final NoticeBanner banner = tester.widget<NoticeBanner>(
        find.byType(NoticeBanner),
      );
      expect(banner.text, 'Stopped after the first failure');
      expect(banner.detail, contains('the users endpoint said no'));
    });

    testWidgets('an unread collection reads an em dash, an empty one reads 0', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final runner = _ScriptedRunner((List<String> args) async {
        // Devices is where the pass stops, so every tile after it is genuinely unknown.
        if (args[1] == 'devices') return _exit(1, 'nope');
        return _ok('[]');
      });
      await _pumpScreen(tester, runner, DashboardScreen(onOpen: (_) {}));

      expect(
        find.bySemanticsLabel('Configurations, 0'),
        findsOneWidget,
        reason: 'a collection that read cleanly and is empty really is zero',
      );
      expect(
        find.bySemanticsLabel('Users, —'),
        findsOneWidget,
        reason: 'a collection the pass never reached must not claim zero',
      );
      semantics.dispose();
    });

    testWidgets('a tile opens its pane', (WidgetTester tester) async {
      final List<InventoryPane> opened = <InventoryPane>[];
      final runner = _ScriptedRunner(
        (List<String> args) async => _rowsFor(args, 1),
      );
      await _pumpScreen(tester, runner, DashboardScreen(onOpen: opened.add));

      await tester.tap(find.byTooltip('Open Devices'));
      await tester.pump();

      expect(opened, <InventoryPane>[InventoryPane.devices]);
    });
  });

  group('read-only screen', () {
    testWidgets('shows the kind\'s columns and filters on the search text', (
      WidgetTester tester,
    ) async {
      final runner = _ScriptedRunner(
        (List<String> args) async => _ok(
          jsonEncode(<Map<String, Object?>>[
            _device('MAC1', 'MacBook Pro', 'Mac'),
            _device('MAC2', 'MacBook Air', 'Mac'),
            _device('IPH9', 'iPhone 15', 'iPhone'),
          ]),
        ),
      );
      await _pumpScreen(
        tester,
        runner,
        const ReadOnlyScreen(kind: ReadOnlyKind.devices),
      );

      final AbTableState<Resource> table = tester.state<AbTableState<Resource>>(
        find.byType(AbTable<Resource>),
      );
      expect(
        <String>[
          for (final AbColumn<Resource> column in readOnlyColumns(
            ReadOnlyKind.devices,
          ))
            column.header,
        ],
        <String>['Serial', 'Model', 'Family'],
      );
      expect(table.displayedRows, hasLength(3));

      await tester.enterText(find.byType(TextField), 'macbook air');
      await _settle(tester);

      expect(table.displayedRows.single.attr('serialNumber'), 'MAC2');
    });

    testWidgets('carries exactly one write control, and discloses it', (
      WidgetTester tester,
    ) async {
      final runner = _ScriptedRunner(
        (List<String> args) async => _ok(
          jsonEncode(<Map<String, Object?>>[_device('MAC1', 'Mac', 'Mac')]),
        ),
      );
      await _pumpScreen(
        tester,
        runner,
        const ReadOnlyScreen(kind: ReadOnlyKind.devices),
      );

      // Device assignment is the Business API's ONE device write, and this screen is the only
      // place it is reachable. The set is the guard: a second write control added here has to be
      // justified one at a time, exactly like the reads on Configurations.
      expect(_toolbarLabels(tester), <String>{
        'Details',
        'Assign to MDM…',
        'Export CSV',
        'Refresh',
      });
      // The Swift banner read "Read-only · assignment gated" because an exception to a read-only
      // promise has to be visible on the screen that carries it — not discovered by clicking.
      final NoticeBanner banner = tester.widget<NoticeBanner>(
        find.byType(NoticeBanner),
      );
      expect(banner.text, 'Read-only · assignment gated');
      expect(banner.detail, contains('gated'));
    });

    testWidgets('Assign is inert until rows are selected, and never writes '
        'on its own', (WidgetTester tester) async {
      final runner = _ScriptedRunner(
        (List<String> args) async => _ok(
          jsonEncode(<Map<String, Object?>>[
            _device('MAC1', 'MacBook Pro', 'Mac'),
            _device('MAC2', 'MacBook Air', 'Mac'),
          ]),
        ),
      );
      await _pumpScreen(
        tester,
        runner,
        const ReadOnlyScreen(kind: ReadOnlyKind.devices),
      );

      // Disabled is a real state: the verb exists, this operator is not eligible for it yet
      // because it has no arguments. A hidden button would say nothing at all.
      ToolbarButton assign = tester.widget<ToolbarButton>(
        _toolbarButton('Assign to MDM…'),
      );
      expect(assign.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey<String>('MAC1')));
      await tester.pump();
      assign = tester.widget<ToolbarButton>(_toolbarButton('Assign to MDM…'));
      expect(assign.onPressed, isNotNull);

      // Opening the gate is not passing through it. The dialog reads the MDM server list and
      // stops there; nothing on this path can reach `assign` without a confirmation.
      await tester.tap(_toolbarButton('Assign to MDM…'));
      await _settle(tester);
      expect(
        runner.verbs,
        isNot(contains('assign')),
        reason: 'opening the assign dialog must not write anything',
      );
      expect(runner.verbs, contains('mdmservers'));
    });

    testWidgets('Details opens an inspector over the row already in hand', (
      WidgetTester tester,
    ) async {
      final runner = _ScriptedRunner(
        (List<String> args) async => _ok(
          jsonEncode(<Map<String, Object?>>[
            _device('MAC1', 'MacBook Pro', 'Mac'),
          ]),
        ),
      );
      await _pumpScreen(
        tester,
        runner,
        const ReadOnlyScreen(kind: ReadOnlyKind.devices),
      );

      await tester.tap(find.byKey(const ValueKey<String>('MAC1')));
      await tester.pump();
      await tester.tap(_toolbarButton('Details'));
      await _settle(tester);

      // Every attribute, not just the three the table has columns for — and no further abctl
      // call to get them: the inspector reads the row the table is already holding.
      expect(find.text('serialNumber'), findsOneWidget);
      expect(find.text('deviceModel'), findsOneWidget);
      expect(find.text('productFamily'), findsOneWidget);
      expect(runner.verbs, <String>[
        'devices',
      ], reason: 'opening a row must not spend an API call');
    });

    testWidgets('changing the audit window re-reads with that window', (
      WidgetTester tester,
    ) async {
      final runner = _ScriptedRunner((List<String> args) async => _ok('[]'));
      await _pumpScreen(
        tester,
        runner,
        const ReadOnlyScreen(kind: ReadOnlyKind.audit),
      );

      expect(
        runner.calls.single,
        containsAllInOrder(<String>['--since', '7d']),
      );

      await tester.tap(find.text('30d'));
      await _settle(tester);

      // The store deliberately does NOT refetch when the window changes — it cannot know whether
      // the control that moved it is mid-keystroke. This picker is four fixed buttons, so the
      // screen spends the call, and the window it spends it on is the one now selected.
      expect(runner.calls, hasLength(2));
      expect(runner.calls.last, containsAllInOrder(<String>['--since', '30d']));
    });

    testWidgets('configurations writes; blueprints reaches membership', (
      WidgetTester tester,
    ) async {
      final runner = _ScriptedRunner((List<String> args) async => _ok('[]'));

      await _pumpScreen(tester, runner, const ConfigurationsScreen());
      expect(
        _toolbarLabels(tester),
        // 'Profile' opens the raw .mobileconfig — `get configuration <id> --profile`, a READ, and
        // the only way to see what a profile actually contains (Apple's list endpoint returns
        // metadata and no payload). 'New', 'Edit' and 'Delete' are the write surface; 'Membership'
        // is deliberately NOT here — attach/detach belongs to the blueprint relationship, and its
        // absence is a scope line rather than an oversight.
        <String>{
          'Details',
          'Profile',
          'New',
          'Edit',
          'Delete',
          'Export CSV',
          'Refresh',
        },
        reason:
            'the write surface is New / Edit / Delete and nothing else; each '
            'addition here has to be justified one at a time',
      );
      // Nothing is armed. There is no selected row and no workspace in this harness, and either
      // one missing is enough to make a tenant write refuse — the destructive control in
      // particular must never be live merely because the screen finished loading.
      for (final String label in <String>['New', 'Edit', 'Delete']) {
        expect(
          tester.widget<ToolbarButton>(_toolbarButton(label)).onPressed,
          isNull,
          reason: '$label is live with no workspace chosen',
        );
      }
      expect(
        runner.verbs.where(
          (String verb) =>
              verb == 'create' || verb == 'replace' || verb == 'delete',
        ),
        isEmpty,
      );

      // Blueprints is the exception, and a disclosed one: Membership is the gated attach /
      // detach / adopt surface. The screen itself still browses — it holds the selected
      // blueprint and opens a dialog; it cannot emit a membership verb by itself.
      await _pumpScreen(tester, runner, const BlueprintsScreen());
      expect(_toolbarLabels(tester), <String>{
        'Details',
        'Membership',
        'Export CSV',
        'Refresh',
      });
      final ToolbarButton membership = tester.widget<ToolbarButton>(
        _toolbarButton('Membership'),
      );
      expect(
        membership.onPressed,
        isNull,
        reason: 'membership needs a blueprint; with none selected it is inert',
      );
      expect(
        runner.verbs.where(
          (String verb) =>
              verb == 'attach' || verb == 'detach' || verb == 'adopt',
        ),
        isEmpty,
      );
    });
  });

  group('os releases', () {
    testWidgets('the catalog picker and a device-model search both narrow it', (
      WidgetTester tester,
    ) async {
      final runner = _ScriptedRunner(
        (List<String> args) async => _ok(
          jsonEncode(<Map<String, Object?>>[
            _release('macOS', '26.1', '25B74', 'public', const <String>[]),
            _release('iOS', '26.1', '23B82', 'public', const <String>[
              'iPhone14,3',
            ]),
            _release('iOS', '26.0', '23A340', 'managed', const <String>[
              'iPhone12,1',
            ]),
          ]),
        ),
      );
      await _pumpScreen(tester, runner, const OsReleasesScreen());

      AbTableState<OSRelease> table() => tester.state<AbTableState<OSRelease>>(
        find.byType(AbTable<OSRelease>),
      );
      expect(table().displayedRows, hasLength(3));

      await tester.tap(find.text('Managed'));
      await _settle(tester);
      expect(table().displayedRows.single.build, '23A340');

      await tester.tap(find.text('All'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'iPhone14,3');
      await _settle(tester);

      expect(
        table().displayedRows.single.build,
        '23B82',
        reason:
            'a supported-device search is the one filter the table cannot run '
            'for us — it has no column holding that text',
      );
    });
  });

  group('csv export', () {
    test('writes the displayed rows, em dash mapped back to an empty field', () {
      final String csv = csvForColumns<Resource>(
        columns: readOnlyColumns(ReadOnlyKind.devices),
        rows: <Resource>[
          Resource.fromJson(_device('MAC1', 'MacBook Pro', 'Mac')),
          // No model: the table prints an em dash, and abctl's own `-o csv` prints nothing.
          Resource.fromJson(_device('MAC2', null, 'Mac')),
        ],
      );
      expect(
        csv,
        'Serial,Model,Family\n'
        'MAC1,MacBook Pro,Mac\n'
        'MAC2,,Mac\n',
      );
    });

    test('quotes a value that would otherwise split the row', () {
      final String csv = csvForColumns<Resource>(
        columns: <AbColumn<Resource>>[
          AbColumn<Resource>(
            header: 'Name',
            value: (Resource row) => row.attr('name') ?? '—',
          ),
        ],
        rows: <Resource>[
          Resource(
            id: 'c1',
            attributes: const JSONValue(<String, Object?>{
              'name': 'Wi-Fi, corporate',
            }),
          ),
        ],
      );
      expect(csv, 'Name\n"Wi-Fi, corporate"\n');
    });
  });
}

// -----------------------------------------------------------------------------------------
// harness
// -----------------------------------------------------------------------------------------

/// Wraps a screen with the one seam a test needs: the process runner. Everything between it and
/// the widget — the client, the argv builders, the store, the per-pane status — stays real, so a
/// test cannot pass while the wiring under it is wrong.
Widget _app(AbctlRunner runner, Widget screen) => ProviderScope(
  overrides: <Override>[
    abctlClientProvider.overrideWithValue(AbctlClient(runner: runner)),
  ],
  child: MaterialApp(
    theme: abTheme(Brightness.light),
    home: Scaffold(body: screen),
  ),
);

/// Mount a screen in a desktop-sized window and let its opening read finish.
///
/// The size is not decoration. The default 800×600 test window is narrower than the toolbar of a
/// screen carrying a search field AND a segmented picker, so the frame scrolls the leftmost
/// controls out of reach — correct behaviour (see `InventoryScreenFrame`), and a tap that lands
/// on a clipped widget in a test that is not about clipping.
Future<void> _pumpScreen(
  WidgetTester tester,
  AbctlRunner runner,
  Widget screen,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(runner, screen));
  await _settle(tester);
}

/// `pumpAndSettle` is unusable here: a loading pane draws a `CircularProgressIndicator`, which
/// never stops animating, so settling would time out rather than converge. Advancing the fake
/// clock in fixed steps does the same job and stays deterministic.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Finder _toolbarButton(String label) => find.byWidgetPredicate(
  (Widget widget) => widget is ToolbarButton && widget.label == label,
);

Set<String> _toolbarLabels(WidgetTester tester) => <String>{
  for (final ToolbarButton button in tester.widgetList<ToolbarButton>(
    find.byType(ToolbarButton),
  ))
    button.label,
};

class _ScriptedRunner implements AbctlRunner {
  _ScriptedRunner(this.handler);

  final Future<AbctlResult> Function(List<String> args) handler;

  /// The verbs, in the order they were actually invoked — which for the dashboard IS the
  /// behaviour under test.
  final List<String> verbs = <String>[];

  /// The full argv of each call, for the assertions that are about a FLAG rather than a verb.
  final List<List<String>> calls = <List<String>>[];

  int inFlight = 0;
  int peakInFlight = 0;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    verbs.add(args.length > 1 ? args[1] : args.first);
    calls.add(List<String>.unmodifiable(args));
    inFlight += 1;
    peakInFlight = math.max(peakInFlight, inFlight);
    try {
      // A real gap, so two overlapping reads would actually overlap: with no await here every
      // load would complete before the next began no matter how the loop was written.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return await handler(args);
    } finally {
      inFlight -= 1;
    }
  }
}

AbctlResult _ok(String stdout) => AbctlResult(
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: '',
  code: 0,
);

AbctlResult _exit(int code, String stderr) =>
    AbctlResult(stdout: Uint8List(0), stderr: stderr, code: code);

/// [count] rows of the shape the verb in [args] returns.
AbctlResult _rowsFor(List<String> args, int count) => _ok(
  jsonEncode(<Map<String, Object?>>[
    for (var i = 0; i < count; i++)
      <String, Object?>{'type': args[1], 'id': '${args[1]}-$i'},
  ]),
);

Map<String, Object?> _device(String serial, String? model, String family) =>
    <String, Object?>{
      'type': 'orgDevices',
      'id': serial,
      'attributes': <String, Object?>{
        'serialNumber': serial,
        if (model != null) 'deviceModel': model,
        'productFamily': family,
      },
    };

Map<String, Object?> _release(
  String platform,
  String version,
  String build,
  String catalog,
  List<String> devices,
) => <String, Object?>{
  'platform': platform,
  'productVersion': version,
  'build': build,
  'catalog': catalog,
  'postingDate': '2026-08-01',
  'supportedDevices': devices,
};
