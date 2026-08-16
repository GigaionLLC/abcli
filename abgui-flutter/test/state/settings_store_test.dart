// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The context store is READ here and never written, and the two presentation choices survive a
// relaunch. Both halves have a failure mode worth pinning: a list that could not be read must not
// render as an empty one, and a preferences store that will not open must not stop the app.

import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('the saved connections are read, and only read', () async {
    final seen = <List<String>>[];
    final container = _containerFor((args) async {
      seen.add(args);
      return _ok('{"current":"prod","contexts":["prod","lab"]}');
    });

    await container.read(settingsProvider.notifier).loadContexts();

    final settings = container.read(settingsProvider);
    expect(settings.contexts, <String>['prod', 'lab']);
    expect(settings.currentContext, 'prod');
    expect(settings.isLoadingContexts, isFalse);
    // No `--context` tail on a context-store verb: `abctl context list --context prod` asks the
    // store to list itself as seen through one of its own entries. AbctlArgs refuses structurally;
    // this is the end-to-end proof that the refusal survives the wiring.
    expect(seen.single, <String>['context', 'list', '-o', 'json']);
  });

  test('a list that could not be read says so', () async {
    final container = _containerFor(
      (args) async => _exit(1, 'contexts.yaml is unreadable'),
    );

    await container.read(settingsProvider.notifier).loadContexts();

    final settings = container.read(settingsProvider);
    // Silence here renders as "No saved connections yet" over a store that has several, inviting
    // the user to re-enter credentials they already have.
    expect(settings.contextsError, contains('unreadable'));
    expect(settings.isLoadingContexts, isFalse);
  });

  test('a later load clears the error it is retrying', () async {
    var call = 0;
    final container = _containerFor((args) async {
      call += 1;
      return call == 1
          ? _exit(1, 'contexts.yaml is unreadable')
          : _ok('{"current":"prod","contexts":["prod"]}');
    });
    final store = container.read(settingsProvider.notifier);

    await store.loadContexts();
    await store.loadContexts();

    expect(container.read(settingsProvider).contextsError, isNull);
    expect(container.read(settingsProvider).contexts, <String>['prod']);
  });

  test('theme and density survive a relaunch', () async {
    final first = _containerFor((args) async => _ok('{}'));
    await first.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
    await first.read(settingsProvider.notifier).setDensity(AbDensity.compact);

    final second = _containerFor((args) async => _ok('{}'));
    await second.read(settingsProvider.notifier).restore();

    expect(second.read(settingsProvider).themeMode, ThemeMode.dark);
    expect(second.read(settingsProvider).density, AbDensity.compact);
  });

  test('a value no build recognizes falls back instead of throwing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${SettingsStore.themeKey}': 'solarized',
      'flutter.${SettingsStore.densityKey}': 'roomy',
    });
    final container = _containerFor((args) async => _ok('{}'));

    await container.read(settingsProvider.notifier).restore();

    expect(container.read(settingsProvider).themeMode, ThemeMode.system);
    expect(container.read(settingsProvider).density, AbDensity.comfortable);
  });
}

ProviderContainer _containerFor(
  Future<AbctlResult> Function(List<String> args) handler,
) {
  final container = ProviderContainer(
    overrides: <Override>[
      abctlRunnerFactoryProvider.overrideWithValue(
        ({void Function(String line)? onStderrLine}) =>
            _ScriptedRunner(handler),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
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
