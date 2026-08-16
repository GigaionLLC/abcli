// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Smoke tests for the three diagnostic screens that touch nothing but providers.
//
// They are cheap and they catch the two failures that are invisible in a unit test of the stores:
// a layout that overflows (the widget tester turns an overflow into a failure) and a screen that
// renders the wrong answer for a state the store can legitimately be in. The Logs and System
// Health screens are deliberately NOT here — both resolve a real directory on the host, and a
// test that creates `%LOCALAPPDATA%\abgui\logs` (and shells out to icacls to lock it down) is a
// side effect on the developer's machine, not a test.

import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/state/console_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/screens/command_log_screen.dart';
import 'package:abgui/src/ui/screens/console_screen.dart';
import 'package:abgui/src/ui/screens/settings_screen.dart';
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

  testWidgets('the command log shows what ran, and its detail on selection', (
    WidgetTester tester,
  ) async {
    final runner = _FakeRunner();
    final container = _container(runner);
    // Recorded the way the app records: through the client, through the RecordingRunner, so the
    // test exercises the wiring and not a hand-built row.
    await container.read(consoleProvider.notifier).run('get devices -o json');

    await _pump(tester, container, const CommandLogScreen());

    expect(find.textContaining('abctl get devices'), findsWidgets);
    // Nothing is selected yet, so the pane asks rather than showing an empty form.
    expect(find.text('Select a command'), findsOneWidget);

    await tester.tap(find.textContaining('abctl get devices').first);
    await tester.pumpAndSettle();

    expect(find.text('Copy command'), findsOneWidget);
    expect(find.text('Copy with cd'), findsOneWidget);
    // The deviation this screen documents: it records the command, not the payload.
    expect(find.text('WHERE THE OUTPUT IS'), findsOneWidget);
  });

  testWidgets('the console warns before Run, and refuses on Run', (
    WidgetTester tester,
  ) async {
    final runner = _FakeRunner();
    final container = _container(runner);

    await _pump(tester, container, const ConsoleScreen());

    await tester.enterText(find.byType(TextField), 'delete config Wi-Fi --yes');
    await tester.pump();
    // Said BEFORE the command is submitted: the hint and the refusal come from one function, so
    // the screen cannot promise something the store then declines to do.
    expect(find.textContaining('will not run'), findsWidgets);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(runner.calls, isEmpty);
    final ConsoleEntry entry = container.read(consoleProvider).entries.single;
    expect(entry.refused, isTrue);
    expect(find.textContaining('abctl delete config'), findsWidgets);
  });

  testWidgets('settings lists the saved connections it cannot edit', (
    WidgetTester tester,
  ) async {
    final runner = _FakeRunner(
      reply: (List<String> args) {
        if (args.first == 'context' && args[1] == 'list') {
          return _ok('{"current":"prod","contexts":["prod","lab"]}');
        }
        if (args.first == 'context' && args[1] == 'get') {
          return _ok(
            '{"name":"prod","context":{"client_id":"BUSINESSAPI.abc",'
            '"key":"/keys/prod.pem"}}',
          );
        }
        if (args.first == 'version') {
          return _ok(
            '{"version":"0.4.27","goVersion":"go1.24","commit":"abc123"}',
          );
        }
        return _ok('{"authenticated":true,"client_id":"BUSINESSAPI.abc"}');
      },
    );
    final container = _container(runner);

    await _pump(tester, container, const SettingsScreen());
    await tester.pumpAndSettle();

    expect(find.text('prod'), findsWidgets);
    expect(find.text('lab'), findsWidgets);
    expect(find.text('0.4.27'), findsOneWidget);
    expect(find.text('/keys/prod.pem'), findsOneWidget);
    // The boundary is stated on the screen, not just in the code — and it is stated as a
    // STANDING fact rather than as a release note, because it does not expire when the tenant
    // writes ship. Matched loosely because the banner renders headline and detail as one span.
    expect(
      find.textContaining('never writes your saved connections'),
      findsWidgets,
    );
  });
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget screen,
) async {
  // A desktop-sized window: these screens are two-pane, and 800x600 would exercise a layout no
  // user of a desktop admin tool ever sees.
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: abTheme(Brightness.light),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await tester.pump();
}

ProviderContainer _container(_FakeRunner runner) {
  final container = ProviderContainer(
    overrides: <Override>[
      abctlRunnerFactoryProvider.overrideWithValue(
        ({void Function(String line)? onStderrLine}) => runner,
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _FakeRunner implements AbctlRunner {
  _FakeRunner({this.reply});

  final AbctlResult Function(List<String> args)? reply;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    calls.add(args);
    return reply?.call(args) ?? _ok('[]');
  }
}

AbctlResult _ok(String stdout) => AbctlResult(
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: '',
  code: 0,
);
