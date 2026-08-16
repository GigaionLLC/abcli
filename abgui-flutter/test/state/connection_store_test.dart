// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// What "connected" means, and what it deliberately does not mean. The seam overridden here is the
// process factory, so the recording runner, the redaction and the `--context` threading are the
// app's real ones — a client-level override would skip exactly the part being asserted.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/state/connection_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a failing whoami is unauthenticated, not disconnected', () async {
    final container = _containerFor(
      (args) async => args.first == 'version'
          ? _ok('{"version":"0.4.27","capabilities":["plan-json"]}')
          : _exit(1, 'no credentials configured'),
    );

    await container.read(connectionProvider.notifier).check();

    final connection = container.read(connectionProvider);
    // A first run with nothing configured is CONNECTED to the CLI and unauthenticated to the
    // tenant. Collapsing the two sends a new user hunting for a bug instead of to Settings.
    expect(connection, isA<ConnectionConnected>());
    final connected = connection as ConnectionConnected;
    expect(connected.version.version, '0.4.27');
    expect(connected.identity, isNull);
    expect(connected.isAuthenticated, isFalse);
  });

  test('a failing version is a failure, in abctl\'s own words', () async {
    final container = _containerFor(
      (args) async => _exit(1, 'abctl: permission denied'),
    );

    await container.read(connectionProvider.notifier).check();

    final connection = container.read(connectionProvider);
    expect(connection, isA<ConnectionFailed>());
    expect(
      (connection as ConnectionFailed).message,
      contains('permission denied'),
    );
  });

  test('choosing a context scopes commands and rewrites nothing', () async {
    final seen = <List<String>>[];
    final container = _containerFor((args) async {
      seen.add(args);
      return _ok('{"version":"0.4.27"}');
    });

    await container.read(connectionProvider.notifier).useContext('prod');

    expect(container.read(activeContextProvider), 'prod');
    expect(seen.first, <String>['version', '-o', 'json', '--context', 'prod']);
    // `abctl context use` WRITES ~/.abctl/contexts.yaml. This release scopes its own commands and
    // leaves the operator's credential store exactly as it found it.
    expect(seen.any((args) => args.first == 'context'), isFalse);
  });

  test('a superseded check never publishes its answer', () async {
    final stale = Completer<void>();
    var call = 0;
    final container = _containerFor((args) async {
      call += 1;
      if (call == 1) {
        await stale.future;
        return _ok('{"version":"stale"}');
      }
      return _ok('{"version":"fresh"}');
    });
    final store = container.read(connectionProvider.notifier);

    final superseded = store.check();
    await store.check();
    stale.complete();
    await superseded;

    final connection =
        container.read(connectionProvider) as ConnectionConnected;
    expect(connection.version.version, 'fresh');
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
