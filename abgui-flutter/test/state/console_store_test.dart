// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The console is the ONE place in this app where argv is authored by a human, so it is the one
// place where "writes go through their gated surface" cannot be guaranteed structurally by
// `AbctlArgs` (which has no builder that can emit a mutating verb from a view). These tests are
// that guarantee's replacement: they pin what the guard refuses, and — the half that actually
// matters — that a refused command never reaches the runner at all.
//
// The wording moved when the write verbs shipped: a refusal is no longer "abgui is read-only in
// this release" but "that write has a home, and this is not it", naming the screen. The
// assertions below check the REFUSAL and the runner, never the sentence, except where a test is
// specifically about the sentence pointing somewhere real.
//
// They also pin the two things the console exists for: the connection and the workspace are
// applied for you, and a non-zero exit is DATA rather than a thrown error.

import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/state/console_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('the read-only boundary', () {
    test('every tenant-writing verb is refused by name', () {
      for (final String verb in <String>[
        'create',
        'replace',
        'edit',
        'delete',
        'attach',
        'detach',
        'assign',
        'unassign',
        'apply',
      ]) {
        expect(
          ConsoleGuard.refusal(<String>[verb, 'config', 'Wi-Fi']),
          isNotNull,
          reason: '`$verb` reaches Apple Business and must not run',
        );
      }
    });

    test('the two workspace-writing verbs are refused as well', () {
      // Neither is in `CommandLineParser.writeVerbs`, because that set is about writes to the
      // TENANT. `adopt` rewrites a blueprint manifest and `seed` writes the whole gitops/ tree.
      expect(
        ConsoleGuard.refusal(<String>['adopt', 'config', 'Wi-Fi']),
        isNotNull,
      );
      expect(ConsoleGuard.refusal(<String>['seed']), isNotNull);
    });

    test('a bare sync is a dry run and is allowed; --apply is not', () {
      expect(ConsoleGuard.refusal(<String>['sync']), isNull);
      expect(
        ConsoleGuard.refusal(<String>['sync', '--refresh', 'full']),
        isNull,
      );
      expect(ConsoleGuard.refusal(<String>['sync', '--apply']), isNotNull);
      expect(
        ConsoleGuard.refusal(<String>['sync', '--apply', '--prune', '--yes']),
        isNotNull,
      );
    });

    test('an approval flag is refused whatever verb carries it', () {
      // The catch-all: abctl gains verbs faster than abgui learns them, and a command that had
      // to say `--yes` is self-describing about what it was about to do.
      expect(
        ConsoleGuard.refusal(<String>['api', '/v1/devices', '--yes']),
        isNotNull,
      );
      expect(
        ConsoleGuard.refusal(<String>['something-new', '--apply']),
        isNotNull,
      );
    });

    test('the context store is read here and never written', () {
      expect(
        ConsoleGuard.refusal(<String>['context', 'list', '-o', 'json']),
        isNull,
      );
      expect(ConsoleGuard.refusal(<String>['context', 'get', 'prod']), isNull);
      for (final String sub in <String>['set', 'use', 'delete']) {
        expect(
          ConsoleGuard.refusal(<String>['context', sub, 'prod']),
          isNotNull,
          reason: '`context $sub` rewrites the operator\'s credential file',
        );
      }
    });

    test('the reads this release ships are allowed', () {
      for (final List<String> argv in <List<String>>[
        <String>['get', 'devices', '-o', 'json'],
        <String>['get', 'blueprint', 'Field kit', '--json'],
        <String>['status', 'device', 'C02XY'],
        <String>['diff', '--json'],
        <String>['validate', '--json'],
        <String>['version', '-o', 'json'],
      ]) {
        expect(ConsoleGuard.refusal(argv), isNull, reason: argv.join(' '));
      }
    });

    test('an empty command line is nothing to refuse', () {
      expect(ConsoleGuard.refusal(const <String>[]), isNull);
    });
  });

  group('the store', () {
    test('a refused command never reaches the runner', () async {
      final runner = _RecordingRunner();
      final container = _containerFor(runner);

      final bool ran = await container
          .read(consoleProvider.notifier)
          .run('delete config Wi-Fi --yes');

      expect(ran, isFalse);
      // The whole point: not "the button was disabled", but "nothing was spawned".
      expect(runner.calls, isEmpty);
      final ConsoleEntry entry = container.read(consoleProvider).entries.single;
      expect(entry.refused, isTrue);
      // A refusal is not a failure — nothing was attempted, so nothing broke.
      expect(entry.isFailure, isFalse);
      expect(entry.exitCode, isNull);
      // Not a phrase match on the boilerplate: what a refusal owes the operator is the verb it
      // declined and the place that does perform it. `delete` lives on Configurations.
      expect(entry.notRun, contains('will not run `delete`'));
      expect(entry.notRun, contains('Configurations'));
    });

    test('the connection and the workspace are applied for you', () async {
      final runner = _RecordingRunner();
      final container = _containerFor(runner);
      container.read(activeContextProvider.notifier).select('prod');
      await container.read(workspaceProvider.notifier).select('/tenants/acme');

      await container.read(consoleProvider.notifier).run('get devices -o json');

      // `--context` appended in the one place that spells it, and the cwd that makes a
      // tree-relative verb resolve the same gitops/ tree the buttons use.
      expect(runner.calls.single.args, <String>[
        'get',
        'devices',
        '-o',
        'json',
        '--context',
        'prod',
      ]);
      expect(runner.calls.single.cwd, '/tenants/acme');
    });

    test('a non-zero exit is data, not an exception', () async {
      final container = _containerFor(
        _RecordingRunner(
          reply: (List<String> args) =>
              _exit(1, 'blueprint "Field kit" not found'),
        ),
      );

      await container.read(consoleProvider.notifier).run('get blueprint Field');

      final ConsoleEntry entry = container.read(consoleProvider).entries.single;
      expect(entry.exitCode, 1);
      expect(entry.stderr, contains('not found'));
      expect(entry.notRun, isNull, reason: 'abctl ran; it simply said no');
      expect(entry.isFailure, isTrue);
    });

    test('exit 3 is drift, and drift is not a failure', () async {
      final container = _containerFor(
        _RecordingRunner(
          reply: (List<String> args) => _exit(3, 'changes pending'),
        ),
      );

      await container.read(consoleProvider.notifier).run('diff --exit-on-diff');

      expect(container.read(consoleProvider).entries.single.isFailure, isFalse);
    });

    test(
      'a credential typed at the prompt is redacted before it is recorded',
      () async {
        final container = _containerFor(_RecordingRunner());

        await container
            .read(consoleProvider.notifier)
            .run('vpp assets --vpp-token s3cr3t-content-token');

        final ConsoleEntry entry = container
            .read(consoleProvider)
            .entries
            .single;
        expect(entry.commandLine, contains('****'));
        expect(entry.commandLine, isNot(contains('s3cr3t')));
        expect(entry.transcript, isNot(contains('s3cr3t')));
      },
    );

    test('and it is redacted in the HISTORY the up arrow recalls', () async {
      // REGRESSION. `ConsoleEntry`'s constructor redacted argv, so the transcript row read
      // `--vpp-token ****` and its copy button copied that — but history stored the raw typed
      // line, and `console_screen`'s up arrow rendered it straight back into the visible text
      // field. On a screen share or a support screenshot the token was on screen again, and
      // `clear()` deliberately preserves history (its tooltip says so), so it survived the one
      // control that looks like it would remove it.
      //
      // Recalling `****` means abctl rejects a re-run, which is the safe direction: a token that
      // has to be pasted again is an inconvenience; one silently reused out of a buffer nobody
      // could see is a leak.
      final container = _containerFor(_RecordingRunner());
      final store = container.read(consoleProvider.notifier);

      await store.run('vpp assets --vpp-token s3cr3t-content-token');
      store.clear();

      final List<String> history = container.read(consoleProvider).history;
      expect(history.single, isNot(contains('s3cr3t')));
      // POSIX-quoted, because `*` is a glob character and the recalled line is meant to survive
      // being re-typed at the prompt. It re-tokenizes to the bare placeholder, which abctl then
      // rejects — the safe direction, and the point of the whole change.
      expect(history.single, "vpp assets --vpp-token '****'");
      expect(
        container.read(consoleProvider).entries,
        isEmpty,
        reason:
            'Clear empties the transcript and keeps history — as advertised',
      );
    });

    test('history is recorded in the canonical form, not as typed', () async {
      // The consequence of redacting through the tokenizer: history holds the re-rendered,
      // POSIX-quoted argv rather than the raw keystrokes. Pinned because it is a visible
      // behaviour change at the prompt, and because it is what makes the dedupe below compare
      // two runs that differ only in spacing (or only in a secret) as one.
      final container = _containerFor(_RecordingRunner());
      final store = container.read(consoleProvider.notifier);

      await store.run('get   devices    -o json');

      expect(
        container.read(consoleProvider).history.single,
        'get devices -o json',
      );
    });

    test('history keeps one copy of a command repeated back to back', () async {
      final container = _containerFor(_RecordingRunner());
      final store = container.read(consoleProvider.notifier);

      await store.run('get devices');
      await store.run('  get devices  ');
      await store.run('get users');

      expect(container.read(consoleProvider).history, <String>[
        'get devices',
        'get users',
      ]);
    });

    test('an oversized stream is clamped, and says so', () {
      final String huge = 'x' * (ConsoleStore.maxStreamBytes + 10);
      final String clamped = ConsoleStore.clamp(huge);

      expect(clamped.length, lessThan(huge.length + 200));
      expect(clamped, startsWith('x'));
      expect(clamped, contains('truncated'));
      // A copy button that quietly hands back less than abctl printed is how a truncated bug
      // report gets written, so the marker names the real size.
      expect(clamped, contains('${huge.length}'));
    });
  });
}

ProviderContainer _containerFor(_RecordingRunner runner) {
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

class _Call {
  const _Call(this.args, this.cwd);

  final List<String> args;
  final String? cwd;
}

class _RecordingRunner implements AbctlRunner {
  _RecordingRunner({this.reply});

  final AbctlResult Function(List<String> args)? reply;
  final List<_Call> calls = <_Call>[];

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    calls.add(_Call(args, cwd));
    return reply?.call(args) ?? _ok('[]');
  }
}

AbctlResult _ok(String stdout) => AbctlResult(
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: '',
  code: 0,
);

AbctlResult _exit(int code, String stderr) =>
    AbctlResult(stdout: Uint8List(0), stderr: stderr, code: code);
