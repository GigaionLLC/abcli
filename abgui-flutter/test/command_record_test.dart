// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Tests for the command-transparency layer: what abgui SHOWS an administrator must be an
// accurate, runnable, secret-free rendering of what it actually executed.
//
// A port of the Swift `CommandRecordTests` — same cases, same assertions. Where Swift mutated a
// `var` copy of the struct, this uses `copyWith`, which is the same operation.
//
// This is the SINGLE suite for the consolidated `CommandRecord`, which two ports of the Swift
// type had duplicated (`lib/src/abctl/command_record.dart`, now deleted, and
// `lib/src/models/command_record.dart`, which survived). Every assertion either port's suite
// made is here, plus one case per decision the merge had to make — because those are the places
// where a future edit would silently pick the other copy's behaviour back up.

import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('redaction — the security-critical invariant', () {
    test('hides the VPP token in both spellings', () {
      expect(
        CommandFormatter.redact([
          'vpp',
          'config',
          '--vpp-token',
          's3cret-token',
        ]),
        ['vpp', 'config', '--vpp-token', '****'],
      );
      expect(
        CommandFormatter.redact(['vpp', 'config', '--vpp-token=s3cret-token']),
        ['vpp', 'config', '--vpp-token=****'],
      );
    });

    test('the secret never appears in any rendered form', () {
      const secret = 's3cret-token';
      final record = CommandRecord(
        argv: ['vpp', 'assets', '--vpp-token', secret, '-o', 'json'],
        cwd: '/tmp/ws',
      );

      expect(
        record.argv.contains(secret),
        isFalse,
        reason: 'raw token was stored on the record',
      );
      expect(record.commandLine.contains(secret), isFalse);
      expect(record.script.contains(secret), isFalse);
      expect(record.startLogLine.contains(secret), isFalse);
      expect(record.commandLine.contains('****'), isTrue);
      expect(
        record.toString().contains(secret),
        isFalse,
        reason: 'even the debug description renders through the formatter',
      );
    });

    test('redaction is idempotent', () {
      final once = CommandFormatter.redact([
        'vpp',
        'config',
        '--vpp-token',
        'abc',
      ]);
      final twice = CommandFormatter.redact(once);
      expect(twice, once);
    });

    test('identifiers are not redacted, so the copied command still runs', () {
      final line = CommandFormatter.line([
        'context',
        'set',
        'prod',
        '--client-id',
        'BUSINESSAPI.x',
        '--key',
        '/keys/p.pem',
      ]);
      expect(line.contains('BUSINESSAPI.x'), isTrue);
      expect(line.contains('/keys/p.pem'), isTrue);
      expect(line.contains('****'), isFalse);
    });

    /// The redacted argv a record carries is the ONLY argv it has. Handing back a growable copy
    /// would let a caller append the raw token onto the list the record itself is holding.
    test('a record\'s argv cannot be written back to', () {
      final record = CommandRecord(argv: ['vpp', 'assets', '--vpp-token', 'x']);
      expect(() => record.argv.add('--vpp-token'), throwsUnsupportedError);
      expect(() => record.argv[3] = 'x', throwsUnsupportedError);
    });
  });

  group('quoting', () {
    test('leaves safe tokens bare and quotes the rest', () {
      expect(CommandFormatter.quote('sync'), 'sync');
      expect(CommandFormatter.quote('--limit-writes'), '--limit-writes');
      expect(CommandFormatter.quote('/tmp/a-b_c.txt'), '/tmp/a-b_c.txt');
      expect(CommandFormatter.quote('WiFi Corp'), "'WiFi Corp'");
      expect(CommandFormatter.quote(''), "''");
      expect(CommandFormatter.quote("it's"), r"'it'\''s'");
    });

    /// A token that ends in a newline is NOT shell-safe. An anchored regex is the natural way to
    /// write this check and the wrong one — `$` is one flag away from matching before a trailing
    /// newline — so the rule is pinned here rather than left to the implementation.
    test('a trailing newline is quoted, not waved through', () {
      expect(CommandFormatter.quote('sync\n'), "'sync\n'");
    });

    test('line prefixes abctl and quotes arguments', () {
      expect(
        CommandFormatter.line([
          'get',
          'configuration',
          'WiFi Corp',
          '--profile',
        ]),
        "abctl get configuration 'WiFi Corp' --profile",
      );
    });
  });

  group('the copy-paste form', () {
    test('leads with cd when the command is tree-relative', () {
      expect(
        CommandFormatter.script(
          argv: ['diff', '--json'],
          cwd: '/Users/me/fleet repo',
        ),
        "cd '/Users/me/fleet repo'\nabctl diff --json",
      );
    });

    test('omits cd when there is no workspace', () {
      expect(
        CommandFormatter.script(argv: ['get', 'devices', '-o', 'json']),
        'abctl get devices -o json',
      );
    });

    test('rewrites stdin into a real path so it can be pasted', () {
      final script = CommandFormatter.script(
        argv: ['create', 'config', 'WiFi Corp', '-f', '-', '--yes', '--json'],
        stdin: const CommandStdin.profile(bytes: 2048),
      );

      expect(
        script.contains('-f ./WiFi-Corp.mobileconfig'),
        isTrue,
        reason: 'stdin was not translated to a file path: $script',
      );
      expect(
        script.contains('-f -'),
        isFalse,
        reason: 'a pasted `-f -` would hang on an empty terminal',
      );
      expect(script.contains('2048 bytes'), isTrue);
      expect(
        script.contains('#'),
        isTrue,
        reason: 'the translation must be explained in a comment',
      );
    });

    /// The slug is Unicode-aware because the name is there to be RECOGNIZED: a non-ASCII config
    /// must not come out as a row of hyphens.
    test('a non-ASCII config name keeps its letters', () {
      final script = CommandFormatter.script(
        argv: ['create', 'config', 'Wi-Fi Büro', '-f', '-', '--yes'],
        stdin: const CommandStdin.profile(bytes: 12),
      );
      expect(
        script.contains('./Wi-Fi-Büro.mobileconfig'),
        isTrue,
        reason: 'the slug was not Unicode-aware: $script',
      );
    });
  });

  group('stdin is a size and nothing else', () {
    test('none carries no bytes, and both predicates agree', () {
      const none = CommandStdin.none();
      expect(none.bytes, isNull);
      expect(none.isEmpty, isTrue);
      expect(none.isProfile, isFalse);
      expect(none.toString(), 'none');

      const profile = CommandStdin.profile(bytes: 2048);
      expect(profile.bytes, 2048);
      expect(profile.isEmpty, isFalse);
      expect(profile.isProfile, isTrue);
      expect(profile.toString(), 'profile(2048 bytes)');
    });

    test('two stdins of the same size are the same value', () {
      expect(
        const CommandStdin.profile(bytes: 8),
        const CommandStdin.profile(bytes: 8),
      );
      expect(
        const CommandStdin.profile(bytes: 8).hashCode,
        const CommandStdin.profile(bytes: 8).hashCode,
      );
      expect(
        const CommandStdin.profile(bytes: 8),
        isNot(const CommandStdin.none()),
      );
    });
  });

  group('record presentation', () {
    final start = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);

    test('finishLogLine reports the exit code and the duration', () {
      final record = CommandRecord(argv: ['diff', '--json'], startedAt: start)
          .copyWith(
            finishedAt: start.add(const Duration(milliseconds: 2400)),
            status: CommandStatus.succeeded,
          );

      expect(record.startLogLine, r'$ abctl diff --json');
      expect(record.finishLogLine, '→ exit 0 in 2.4s');
      expect(record.isFailure, isFalse);
    });

    test('an unfinished record has no duration to report', () {
      final record = CommandRecord(argv: ['sync'], startedAt: start);
      expect(record.duration, isNull);
      expect(record.durationText, isNull);
      expect(record.finishLogLine, '→ running');
    });

    test('statusText covers every terminal outcome', () {
      CommandRecord withStatus(CommandStatus status) => CommandRecord(
        argv: ['sync'],
        startedAt: start,
      ).copyWith(status: status);

      expect(withStatus(CommandStatus.running).statusText, 'running');
      expect(withStatus(const CommandStatus.failed(3)).statusText, 'exit 3');
      expect(withStatus(CommandStatus.cancelled).statusText, 'cancelled');
      expect(withStatus(CommandStatus.timedOut).statusText, 'timed out');
      expect(withStatus(CommandStatus.timedOut).isFailure, isTrue);
      expect(withStatus(const CommandStatus.failed(1)).isFailure, isTrue);
      expect(withStatus(CommandStatus.cancelled).isFailure, isFalse);
    });

    /// The status may be handed in at construction as well as through [CommandRecord.copyWith] —
    /// both ports supported it and each suite exercised only one of the two routes.
    test('a status given at construction is the status that is reported', () {
      expect(
        CommandRecord(
          argv: ['sync'],
          status: const CommandStatus.failed(3),
        ).statusText,
        'exit 3',
      );
      expect(
        CommandRecord(argv: ['sync']).statusText,
        'running',
        reason: 'a record is running until something says otherwise',
      );
    });

    /// The exit code belongs to the failed case ALONE. A running command that answers `0` is
    /// claiming a successful exit that has not happened.
    test('only a failure carries an exit code', () {
      expect(const CommandStatus.failed(3).exitCode, 3);
      expect(CommandStatus.running.exitCode, isNull);
      expect(CommandStatus.succeeded.exitCode, isNull);
      expect(CommandStatus.cancelled.exitCode, isNull);
      expect(CommandStatus.timedOut.exitCode, isNull);

      // Two failures with different codes are different statuses.
      expect(
        const CommandStatus.failed(1),
        isNot(const CommandStatus.failed(2)),
      );
      expect(const CommandStatus.failed(1), const CommandStatus.failed(1));
      expect(CommandStatus.succeeded, isNot(CommandStatus.running));
    });

    test('long durations read as minutes and seconds', () {
      final record = CommandRecord(argv: ['sync', '--apply'], startedAt: start)
          .copyWith(
            finishedAt: start.add(const Duration(seconds: 125)),
            status: CommandStatus.succeeded,
          );
      expect(record.durationText, '2m 5s');
      expect(DurationText.short(const Duration(milliseconds: 1440)), '1.4s');
      expect(DurationText.short(const Duration(seconds: 95)), '1m 35s');
    });

    test('closing a record keeps its identity', () {
      final record = CommandRecord(argv: ['diff']);
      final finished = record.copyWith(
        finishedAt: record.startedAt,
        status: CommandStatus.succeeded,
      );
      expect(finished.id, record.id);
      expect(finished.duration, Duration.zero);
      expect(record.duration, isNull, reason: 'the original is untouched');
    });

    /// …but it is NOT the same VALUE. `copyWith` keeps the id on purpose, so an id-only `==`
    /// would report a finished command as equal to the running one it replaced, and a list that
    /// rebuilds off equality would never redraw the row.
    test('a closed record is not equal to the record it replaced', () {
      final running = CommandRecord(
        argv: ['sync', '--apply'],
        startedAt: start,
      );
      final finished = running.copyWith(
        finishedAt: start.add(const Duration(seconds: 3)),
        status: CommandStatus.succeeded,
      );

      expect(finished, isNot(running));
      expect(finished.hashCode, isNot(running.hashCode));
      expect(running, running.copyWith(), reason: 'an unchanged copy is equal');
      expect(running.hashCode, running.copyWith().hashCode);

      // argv participates too, so two records that differ only in what they ran differ.
      expect(
        CommandRecord(argv: ['diff'], startedAt: start, id: 'fixed'),
        isNot(CommandRecord(argv: ['sync'], startedAt: start, id: 'fixed')),
      );
      expect(
        CommandRecord(argv: ['diff'], startedAt: start, id: 'fixed'),
        CommandRecord(argv: ['diff'], startedAt: start, id: 'fixed'),
      );
    });

    /// A negative wall clock (the machine slept, or NTP stepped the clock backwards) reads as
    /// zero rather than as a command that finished before it started.
    test('a backwards clock cannot produce a negative duration', () {
      final record = CommandRecord(argv: ['diff'], startedAt: start).copyWith(
        finishedAt: start.subtract(const Duration(seconds: 5)),
        status: CommandStatus.succeeded,
      );
      expect(record.duration, Duration.zero);
      expect(record.durationText, '0.0s');
    });

    /// The id only has to be unique within one app run — but it does have to be that, including
    /// for records built in the same instant.
    test('ids do not collide', () {
      final ids = <String>{
        for (var i = 0; i < 500; i++) CommandRecord(argv: ['diff']).id,
      };
      expect(ids.length, 500);
      expect(
        CommandRecord(argv: ['diff'], id: 'given').id,
        'given',
        reason: 'a caller-supplied id is used as given',
      );
    });
  });

  group('RecordingRunner — the seam', () {
    test('reports success and forwards the result unchanged', () async {
      final sink = _CommandSink();
      final runner = RecordingRunner(
        wrapped: _MockAbctlRunner({'diff': _MockAbctlRunner.ok('{}')}),
        onStart: sink.start,
        onFinish: sink.finish,
      );

      final result = await runner.run([
        'diff',
        '--json',
      ], timeout: const Duration(seconds: 5));

      expect(result.code, 0);
      expect(result.stdoutText, '{}');
      expect(sink.started.length, 1);
      expect(sink.started.first.argv, ['diff', '--json']);
      expect(sink.finished.first.status, CommandStatus.succeeded);
    });

    test('reports the exit code on failure', () async {
      final sink = _CommandSink();
      final runner = RecordingRunner(
        wrapped: _MockAbctlRunner(const {}), // unmatched argv → exit 1
        onStart: sink.start,
        onFinish: sink.finish,
      );

      await runner.run([
        'validate',
        '--json',
      ], timeout: const Duration(seconds: 5));

      expect(sink.finished.first.status, const CommandStatus.failed(1));
    });

    test('reports cancellation rather than failure', () async {
      final sink = _CommandSink();
      final runner = RecordingRunner(
        wrapped: const _CancellingRunner(),
        onStart: sink.start,
        onFinish: sink.finish,
      );

      await expectLater(
        runner.run(['sync', '--apply'], timeout: const Duration(seconds: 5)),
        throwsA(isA<AbctlCancelled>()),
      );
      expect(sink.finished.first.status, CommandStatus.cancelled);
    });

    test('records the stdin size but not its content', () async {
      final sink = _CommandSink();
      final runner = RecordingRunner(
        wrapped: _MockAbctlRunner({'create': _MockAbctlRunner.ok('{}')}),
        onStart: sink.start,
        onFinish: sink.finish,
      );
      final profile = utf8.encode('<plist>secret payload</plist>');

      await runner.run(
        ['create', 'config', 'X', '-f', '-', '--yes', '--json'],
        stdin: profile,
        timeout: const Duration(seconds: 5),
      );

      expect(
        sink.started.first.stdin,
        CommandStdin.profile(bytes: profile.length),
      );
      expect(
        sink.started.first.script.contains('secret payload'),
        isFalse,
        reason: 'profile content must never be recorded',
      );
    });

    test(
      'a timeout is recorded as its own status, not as an exit code',
      () async {
        final sink = _CommandSink();
        final runner = RecordingRunner(
          wrapped: const _TimingOutRunner(),
          onStart: sink.start,
          onFinish: sink.finish,
        );

        await expectLater(
          runner.run(['diff'], timeout: const Duration(seconds: 5)),
          throwsA(isA<AbctlTimedOut>()),
        );
        expect(sink.finished.first.status, CommandStatus.timedOut);
      },
    );
  });
}

/// A deterministic, offline [AbctlRunner]: canned results keyed by the first one or two argv
/// tokens (e.g. "version", "auth whoami", "get configurations"). No binary, no credentials —
/// the seam that makes the whole client layer unit-testable.
class _MockAbctlRunner implements AbctlRunner {
  const _MockAbctlRunner(this.responses);

  final Map<String, AbctlResult> responses;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    final hit =
        responses[args.take(2).join(' ')] ??
        (args.isEmpty ? null : responses[args.first]);
    if (hit != null) return hit;
    return AbctlResult(
      stdout: Uint8List(0),
      stderr: 'no mock for ${args.join(' ')}',
      code: 1,
    );
  }

  static AbctlResult ok(String stdout) => AbctlResult(
    stdout: Uint8List.fromList(utf8.encode(stdout)),
    stderr: '',
    code: 0,
  );
}

class _CancellingRunner implements AbctlRunner {
  const _CancellingRunner();

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async => throw const AbctlCancelled();
}

class _TimingOutRunner implements AbctlRunner {
  const _TimingOutRunner();

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async =>
      throw const AbctlTimedOut(seconds: 5, lastOutput: 'building plan');
}

/// Collects what the runner's sinks reported. No lock, unlike the Swift original: the sinks
/// fire on the caller's isolate here, so there is nothing to race with.
class _CommandSink {
  final List<CommandRecord> started = [];
  final List<({String id, CommandStatus status})> finished = [];

  void start(CommandRecord record) => started.add(record);

  void finish(String id, CommandStatus status) =>
      finished.add((id: id, status: status));
}
