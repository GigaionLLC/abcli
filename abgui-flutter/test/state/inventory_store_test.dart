// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Per-pane isolation, which is the whole reason this layer is many small notifiers instead of one
// model. Every case here is a bug the Swift app shipped with a single `isLoading`/`loadError`:
// a slow Devices fetch spun Configurations, an OS Releases failure landed on whatever list was
// behind the sheet that raised it, and a superseded read cleared the spinner of the read that had
// replaced it.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/src/abctl/abctl_client.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/read_only_kind.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loading one pane neither flags nor clears another', () async {
    final devices = Completer<void>();
    final container = _containerFor((args) async {
      if (args.contains('devices')) {
        await devices.future;
        return _ok('[{"type":"orgDevices","id":"d1"}]');
      }
      return _exit(1, 'the users endpoint said no');
    });
    final store = container.read(inventoryProvider.notifier);

    final slow = store.load(InventoryPane.devices);
    await store.load(InventoryPane.users);

    var state = container.read(inventoryProvider);
    expect(state.status(InventoryPane.users).error, isNotNull);
    expect(
      state.status(InventoryPane.devices).isLoading,
      isTrue,
      reason: 'the Users failure must not take the Devices spinner down',
    );
    expect(
      state.status(InventoryPane.devices).error,
      isNull,
      reason: 'and it must not land on the Devices screen either',
    );

    devices.complete();
    await slow;

    state = container.read(inventoryProvider);
    expect(
      state.status(InventoryPane.users).error,
      isNotNull,
      reason: 'a successful Devices read must not clear the Users error',
    );
    expect(state.status(InventoryPane.devices).isLoading, isFalse);
    expect(state.status(InventoryPane.devices).hasLoaded, isTrue);
    expect(state.resources(InventoryPane.devices), hasLength(1));
    expect(state.resources(InventoryPane.users), isEmpty);
  });

  test(
    'a superseded load publishes neither its rows nor its spinner',
    () async {
      final stale = Completer<void>();
      var call = 0;
      final container = _containerFor((args) async {
        call += 1;
        if (call == 1) {
          await stale.future;
          return _ok('[{"type":"orgDevices","id":"stale"}]');
        }
        return _ok('[{"type":"orgDevices","id":"fresh"}]');
      });
      final store = container.read(inventoryProvider.notifier);

      final superseded = store.load(InventoryPane.devices);
      await store.load(InventoryPane.devices);

      expect(
        container
            .read(inventoryProvider)
            .resources(InventoryPane.devices)
            .single
            .id,
        'fresh',
      );

      stale.complete();
      await superseded;

      final status = container
          .read(inventoryProvider)
          .status(InventoryPane.devices);
      expect(
        container
            .read(inventoryProvider)
            .resources(InventoryPane.devices)
            .single
            .id,
        'fresh',
        reason:
            'the older run must not overwrite the newer answer as it unwinds',
      );
      expect(
        status.isLoading,
        isFalse,
        reason:
            'the newer run finished; nothing may re-raise its spinner either',
      );
    },
  );

  test(
    'a failed refresh keeps the rows and the stamp it already had',
    () async {
      var call = 0;
      final container = _containerFor((args) async {
        call += 1;
        return call == 1
            ? _ok('[{"type":"orgDevices","id":"d1"}]')
            : _exit(1, 'Apple returned 503');
      });
      final store = container.read(inventoryProvider.notifier);

      await store.load(InventoryPane.devices);
      final loadedAt = container
          .read(inventoryProvider)
          .status(InventoryPane.devices)
          .loadedAt;
      await store.load(InventoryPane.devices);

      final state = container.read(inventoryProvider);
      expect(state.status(InventoryPane.devices).error, contains('503'));
      expect(
        state.resources(InventoryPane.devices),
        hasLength(1),
        reason:
            'the last thing the tenant said is still the only data there is',
      );
      expect(
        state.status(InventoryPane.devices).loadedAt,
        loadedAt,
        reason: 'the stamp is what tells the reader those rows are not fresh',
      );
    },
  );

  test(
    'starting a load clears that pane\'s error and nobody else\'s',
    () async {
      var call = 0;
      final container = _containerFor((args) async {
        call += 1;
        return call <= 2 ? _exit(1, 'boom') : _ok('[]');
      });
      final store = container.read(inventoryProvider.notifier);

      await store.load(InventoryPane.devices);
      await store.load(InventoryPane.users);
      expect(
        container.read(inventoryProvider).status(InventoryPane.devices).error,
        isNotNull,
      );

      await store.load(InventoryPane.devices);

      final state = container.read(inventoryProvider);
      expect(state.status(InventoryPane.devices).error, isNull);
      expect(
        state.status(InventoryPane.users).error,
        isNotNull,
        reason: 'a retry on one screen is not a verdict about another',
      );
    },
  );

  test(
    'the audit window reaches abctl verbatim and does not refetch by itself',
    () async {
      final seen = <List<String>>[];
      final container = _containerFor((args) async {
        seen.add(args);
        return _ok('[]');
      });
      final store = container.read(inventoryProvider.notifier);

      store.setAuditSince('24h');
      expect(
        seen,
        isEmpty,
        reason: 'the screen decides when to spend an API call',
      );

      await store.load(InventoryPane.audit);

      expect(seen.single, <String>[
        'get',
        'audit',
        '--since',
        '24h',
        '-o',
        'json',
      ]);
    },
  );

  test('Apps & Books cannot be loaded without its content token', () async {
    final container = _containerFor((args) async => _ok('[]'));
    final store = container.read(inventoryProvider.notifier);

    // The signature has nowhere to carry the token, so a caller that reaches for the generic path
    // gets an error instead of a screen that silently reads nothing.
    expect(() => store.load(InventoryPane.vpp), throwsArgumentError);
  });

  test('an unknown read-only kind has no pane and loads nothing', () async {
    var calls = 0;
    final container = _containerFor((args) async {
      calls += 1;
      return _ok('[]');
    });

    // `unknown` exists so a value persisted by another build cannot crash the sidebar; it is
    // deliberately not one of the eight browsable screens, so it must not be able to claim a cache.
    await container
        .read(inventoryProvider.notifier)
        .loadReadOnly(ReadOnlyKind.unknown);

    expect(calls, 0);
  });
}

/// A container whose only wiring is the client, so nothing here can reach a real binary, the
/// filesystem, or a plugin channel.
ProviderContainer _containerFor(
  Future<AbctlResult> Function(List<String> args) handler,
) {
  final container = ProviderContainer(
    overrides: <Override>[
      abctlClientProvider.overrideWithValue(
        AbctlClient(runner: _ScriptedRunner(handler)),
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
