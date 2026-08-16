// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The assembly, as opposed to the parts.
//
// Every screen, store and widget below this level has its own tests; what none of them can catch
// is the app failing to be an app — a sidebar row that opens nothing, a destination nobody routed,
// or the launch state that is by far the most likely one a developer and a mis-packaged install
// will both see: no abctl anywhere on disk. That last case has to produce a window that explains
// itself, and "it did not throw" is not the assertion — "it says so, in the chrome, on the first
// frame" is.

import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/app.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/screens/archive_screen.dart';
import 'package:abgui/src/ui/screens/read_only_screen.dart';
import 'package:abgui/src/ui/screens/settings_screen.dart';
import 'package:abgui/src/ui/shell/abctl_missing_banner.dart';
import 'package:abgui/src/ui/shell/sidebar.dart';
import 'package:abgui/src/ui/shell/sidebar_item.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('routing', () {
    testWidgets('every sidebar destination builds a real screen', (
      WidgetTester tester,
    ) async {
      final Map<ShellDestination, Widget> screens =
          <ShellDestination, Widget>{};
      await tester.pumpWidget(
        MaterialApp(
          theme: abTheme(Brightness.light),
          home: Builder(
            builder: (BuildContext context) {
              for (final ShellDestination destination
                  in ShellDestination.values) {
                screens[destination] = abguiScreen(context, destination);
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      for (final ShellDestination destination in ShellDestination.values) {
        final Widget screen = screens[destination]!;
        expect(
          screen,
          isNot(isA<SizedBox>()),
          reason:
              '${destination.id} ("${destination.title}") is reachable from '
              'the sidebar and must open something',
        );
      }
    });

    testWidgets('an inventory row opens its own kind, not a neighbour\'s', (
      WidgetTester tester,
    ) async {
      // The eight inventory destinations share ONE screen class parameterised by kind, so a
      // mis-wired arm here is invisible — every row would still open a table, just the wrong one.
      final Map<ShellDestination, Widget> screens =
          <ShellDestination, Widget>{};
      await tester.pumpWidget(
        MaterialApp(
          theme: abTheme(Brightness.light),
          home: Builder(
            builder: (BuildContext context) {
              for (final ShellDestination destination
                  in ShellDestination.values) {
                screens[destination] = abguiScreen(context, destination);
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      for (final ShellDestination destination in ShellDestination.values) {
        final Widget screen = screens[destination]!;
        if (destination.readOnly == null) {
          expect(
            screen,
            isNot(isA<ReadOnlyScreen>()),
            reason: '${destination.id} has no ReadOnlyKind to browse',
          );
          continue;
        }
        expect(screen, isA<ReadOnlyScreen>());
        expect((screen as ReadOnlyScreen).kind, destination.readOnly);
      }
    });

    test('a dashboard tile knows which screen its pane belongs to', () {
      // The Dashboard counts caches (`InventoryPane`) and the shell navigates screens
      // (`ShellDestination`); `forPane` is the bridge, and it is derived rather than written out
      // twice precisely so it cannot drift.
      for (final InventoryPane pane in InventoryPane.values) {
        final ShellDestination? destination = ShellDestination.forPane(pane);
        if (pane == InventoryPane.vpp) {
          expect(
            destination,
            isNull,
            reason:
                'Apps & Books has a cache and deliberately no sidebar row — '
                'see the omission note on ShellDestination',
          );
          continue;
        }
        expect(destination, isNotNull, reason: '${pane.name} opens nothing');
        expect(destination!.pane, pane);
      }
    });
  });

  group('launch with no abctl', () {
    testWidgets('the window explains itself instead of blanking', (
      WidgetTester tester,
    ) async {
      await _pumpApp(tester, missing: _missing);

      expect(
        find.textContaining('abctl not found'),
        findsOneWidget,
        reason:
            'this is the first frame on any machine where the binary was '
            'never packaged beside the app',
      );
      expect(
        find.byType(Sidebar),
        findsOneWidget,
        reason:
            'and it is a banner, not a takeover: Logs, the Command Log and '
            'What’s New are all still worth reading with no CLI at all',
      );
      // The paths that were searched are the whole diagnosis for a packaging bug, and they are
      // far too long for the strip — so the strip offers them rather than showing them.
      expect(find.text('Copy details'), findsOneWidget);
      expect(find.byTooltip('Devices'), findsOneWidget);
    });

    testWidgets('and says nothing at all once abctl is there', (
      WidgetTester tester,
    ) async {
      await _pumpApp(tester);

      expect(find.byType(AbctlMissingBanner), findsOneWidget);
      expect(
        find.textContaining('abctl not found'),
        findsNothing,
        reason: 'chrome that states a non-problem trains users to skip chrome',
      );
    });
  });

  group('navigation', () {
    testWidgets('the rows added by the port open their screens', (
      WidgetTester tester,
    ) async {
      // Settings (no ⌘, scene off macOS), Archive and What's New are the three destinations that
      // had no Flutter screen when the parts were assembled — the exact places a sidebar row that
      // opens nothing would have survived review.
      await _pumpApp(tester);

      await tester.tap(find.text('Settings'));
      await tester.pump();
      expect(find.byType(SettingsScreen), findsOneWidget);

      await tester.tap(find.text('Archive'));
      await tester.pump();
      expect(find.byType(ArchiveScreen), findsOneWidget);
      expect(
        find.text('No GitOps workspace'),
        findsOneWidget,
        reason:
            'with no workspace chosen the archive says which folder it needs, '
            'rather than rendering an empty table',
      );

      await tester.tap(find.text('What’s New'));
      await tester.pump();
      expect(find.text('In this release'), findsOneWidget);
      expect(
        find.text('What this build cannot do'),
        findsOneWidget,
        reason:
            'an operator arriving from the macOS app will go looking for the '
            'write verbs; this screen is where they find out',
      );

      // REGRESSION. This screen used to open its constraints list with "Nothing here writes to
      // Apple Business — no create, replace or delete … and no sync --apply", written as a flat
      // statement of capability because at the time it was true. It is now false, and it is the
      // most dangerous sentence in the app to leave standing: it is precisely what an operator
      // would rely on before clicking through a plan on a tenant they do not own. Pinned as a
      // negative because rewording it is not enough — the claim has to be absent.
      expect(
        find.textContaining('Nothing here writes to Apple Business'),
        findsNothing,
      );
      expect(find.textContaining('no sync --apply'), findsNothing);
      expect(
        find.textContaining('the plan on the Diff screen is a plan only'),
        findsNothing,
      );
      // And the replacement says what IS true, including the gate.
      expect(find.text('Apply, gated'), findsOneWidget);
      expect(
        find.textContaining('until the tenant\'s own name is typed'),
        findsOneWidget,
      );
      // The boundary that did NOT move is still stated, so its absence cannot be read as the
      // console having quietly gained the writes.
      expect(find.text('The console will not run a write'), findsOneWidget);
      expect(find.text('Credentials are read, never written'), findsOneWidget);
    });

    testWidgets('the screen on display fills the status bar', (
      WidgetTester tester,
    ) async {
      // The two halves of this were built apart: the shell owns a status bar keyed by
      // destination, and the table owns the only number that answers "how many rows survived the
      // filter". Neither is wrong alone and together they were a permanently empty strip.
      await _pumpApp(
        tester,
        reply: (List<String> args) => args.contains('devices')
            ? '[{"type":"device","id":"A","attributes":{"serialNumber":"S1"}},'
                  '{"type":"device","id":"B","attributes":{"serialNumber":"S2"}}]'
            : '{}',
      );

      // The sidebar's row, not the Dashboard's tile of the same name — both are on screen, and
      // the tile would open the pane through a different path than the one under test.
      await tester.tap(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.text('Devices'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // The extra frame is the contract, not flake: `ShellStatusController` defers its
      // notification past the end of the frame the counts were computed in, because a table that
      // marked the status bar dirty from inside `build` is exactly what Flutter asserts on.
      await tester.pump();

      // `findRichText`, because the bar draws machine data through `MonoText` — a `Text.rich`, so
      // that a filter match can be highlighted inside a cell.
      expect(find.text('2 rows', findRichText: true), findsOneWidget);

      // And the counts belong to the VISIBLE screen: What's New has no table, so the bar goes
      // quiet rather than keeping the device count on display under an unrelated pane.
      await tester.tap(find.text('What’s New'));
      await tester.pump();
      expect(find.text('2 rows', findRichText: true), findsNothing);
    });
  });
}

const AbctlMissingBinary _missing = AbctlMissingBinary(
  searched: <String>[r'C:\Program Files\abgui\abctl.exe'],
);

/// Pump the real [AbguiApp], with the process seam replaced.
///
/// `abctlRunnerFactoryProvider` is the override rather than a client, for the reason
/// `providers.dart` gives: overriding a client would bypass the command log, the redaction and
/// the transcript lines, so this test could pass while the wiring under it was wrong.
///
/// Never `pumpAndSettle`: the run strip's elapsed ticker is a periodic timer for as long as a
/// command is in flight, and settling would wait for a clock that is doing its job.
Future<void> _pumpApp(
  WidgetTester tester, {
  AbctlMissingBinary? missing,
  String Function(List<String> args)? reply,
}) async {
  // Wide enough for all twenty sidebar rows: the test window's default 800x600 would scroll the
  // last of them out of reach, and a tap on an off-screen row fails for a reason that has nothing
  // to do with routing.
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      abctlRunnerFactoryProvider.overrideWithValue(
        ({void Function(String line)? onStderrLine}) => _StubRunner(reply),
      ),
      // Pinned rather than probed. The real provider walks the filesystem next to whatever
      // executable is running the test, and a developer with $ABGUI_ABCTL set would otherwise get
      // a different answer from the same test than CI does.
      abctlMissingProvider.overrideWithValue(missing),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const AbguiApp()),
  );
  // Two frames plus a beat: the shell's screens start their loads from a post-frame callback, and
  // the stub answers on the microtask queue.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Answers every verb with an empty document. The models decode tolerantly by design (see
/// `models/json.dart`), so this is enough to get every screen past its first load without
/// pinning this test to any one payload's shape.
class _StubRunner implements AbctlRunner {
  const _StubRunner(this.reply);

  final String Function(List<String> args)? reply;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async => AbctlResult(
    stdout: Uint8List.fromList(utf8.encode(reply?.call(args) ?? '{}')),
    stderr: '',
    code: 0,
  );
}
