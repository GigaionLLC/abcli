// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The run log is the only copy of a failed 2 a.m. sync that survives the window being closed,
// so the things tested here are the ones that make it usable afterwards: it is self-describing,
// it never contains a secret, the pruner recognizes ONLY its own files, and the whole thing
// degrades to null rather than failing a sync.

import 'dart:io';

import 'package:abgui/src/abctl/run_log.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('abgui_runlog'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // The OS owns its temp.
    }
  });

  group('naming', () {
    final started = DateTime.utc(2026, 7, 25, 14, 30, 5);

    test('the filename encodes verb, UTC start and a short run id', () {
      final name = RunLog.fileName(
        verb: RunLogVerb.diff,
        started: started,
        runId: 'b37749aabbccddee',
      );
      expect(name, 'diff-20260725T143005Z-b37749.log');
      expect(RunLog.isRunLogName(name), isTrue);
    });

    test(
      'the stamp is UTC, so two machines and a DST change still line up',
      () {
        final local = started.toLocal();
        expect(RunLog.compactUtc(local), '20260725T143005Z');
        expect(RunLog.isoUtc(local), '2026-07-25T14:30:05Z');
      },
    );

    test('the pruner recognizes only its own shape', () {
      // It DELETES. Whatever else a user or another tool parked in that folder is not ours.
      expect(RunLog.isRunLogName('sync-20260725T143005Z-abc123.log'), isTrue);
      expect(
        RunLog.isRunLogName('validate-20260725T143005Z-abc123.log'),
        isFalse,
        reason: 'validate does not open a log, so it must not claim filenames',
      );
      expect(RunLog.isRunLogName('sync-20260725T143005Z-ABC123.log'), isFalse);
      expect(RunLog.isRunLogName('sync-20260725T143005-abc123.log'), isFalse);
      expect(RunLog.isRunLogName('notes.log'), isFalse);
      expect(RunLog.isRunLogName('sync-20260725T143005Z-abc123.txt'), isFalse);
    });
  });

  group('layout', () {
    test('the transcript never lands in a roaming profile or a cache', () {
      expect(
        RunLog.defaultDirectory(
          environment: const {'LOCALAPPDATA': r'C:\Users\ada\AppData\Local'},
          isWindows: true,
          isMacOS: false,
        ),
        r'C:\Users\ada\AppData\Local\abgui\logs',
      );
      expect(
        RunLog.defaultDirectory(
          environment: const {'HOME': '/Users/ada'},
          isWindows: false,
          isMacOS: true,
        ),
        '/Users/ada/Library/Logs/abgui',
      );
      expect(
        RunLog.defaultDirectory(
          environment: const {'HOME': '/home/ada'},
          isWindows: false,
          isMacOS: false,
        ),
        '/home/ada/.local/state/abgui/logs',
      );
    });
  });

  group('header and footer', () {
    test('the header is self-describing and records stdin as a size only', () {
      final text = RunLog.headerText(
        const RunLogHeader(
          verb: RunLogVerb.sync,
          command: 'abctl create config X -f - --yes --json',
          workspace: '/Users/ada/fleet',
          context: 'prod',
          abctlVersion: '0.4.27',
          abctlCommit: 'deadbee',
          abguiVersion: '0.4.27',
          os: 'testOS 1.0',
          stdin: CommandStdin.profile(bytes: 2048),
        ),
        startedAt: DateTime.utc(2026, 7, 25, 14, 30, 5),
      );

      expect(text, contains('schema: ${RunLog.schemaVersion}'));
      expect(text, contains('verb: sync'));
      expect(text, contains('started: 2026-07-25T14:30:05Z'));
      expect(text, contains('abctl: 0.4.27 (deadbee)'));
      expect(text, contains('os: testOS 1.0'));
      expect(text, contains('stdin: profile on stdin (2048 bytes)'));
      expect(text, contains('It contains no credentials'));
    });

    test('a blank context says so rather than printing an empty field', () {
      final text = RunLog.headerText(
        const RunLogHeader(verb: RunLogVerb.diff, command: 'abctl diff --json'),
        startedAt: DateTime.utc(2026),
      );
      expect(text, contains('context: (abctl default)'));
      expect(text, contains('workspace: (none)'));
      expect(text, contains('abctl: unknown (not connected yet)'));
      expect(text, isNot(contains('stdin:')));
    });

    test('the footer carries the verdict, collapsed onto one line', () {
      final start = DateTime.utc(2026);
      final text = RunLog.footerText(
        outcome: 'failed:\n  403 Forbidden\n  from Apple',
        startedAt: start,
        finishedAt: start.add(const Duration(seconds: 125)),
        lines: 42,
        dropped: 0,
        truncated: false,
      );

      expect(text, contains('duration: 2m 5s'));
      expect(text, contains('outcome: failed: 403 Forbidden from Apple'));
      expect(text, contains('lines: 42'));
      expect(text, isNot(contains('dropped:')));
    });

    test('a run that hit the file cap says how much it lost', () {
      final start = DateTime.utc(2026);
      final text = RunLog.footerText(
        outcome: 'ok',
        startedAt: start,
        finishedAt: start.add(const Duration(seconds: 2)),
        lines: 10,
        dropped: 7,
        truncated: true,
      );
      expect(text, contains('dropped: 7 line(s)'));
      expect(text, contains('5 MiB per-file cap'));
    });

    test('each line is stamped with seconds since the run started', () {
      expect(
        RunLog.stamped('building plan', const Duration(milliseconds: 1234)),
        '[  1.234s] building plan',
      );
      expect(RunLog.stamped('start', Duration.zero), '[  0.000s] start');
    });
  });

  group('writing', () {
    test('a run writes a header, its stamped lines and a footer', () async {
      final log = await RunLog.begin(
        const RunLogHeader(
          verb: RunLogVerb.sync,
          command: 'abctl sync --apply --yes',
        ),
        directory: dir.path,
        at: DateTime.utc(2026, 7, 25, 14, 30, 5),
        runId: 'abc123def456',
      );

      expect(log, isNotNull);
      log!
        ..line('building plan')
        ..line('applying 3 changes');
      await log.finish(outcome: 'applied 3 changes');

      final text = File(log.path).readAsStringSync();
      expect(log.path.endsWith('sync-20260725T143005Z-abc123.log'), isTrue);
      expect(text, contains('# abgui run log'));
      expect(text, contains('building plan'));
      expect(text, contains('applying 3 changes'));
      expect(text, contains('outcome: applied 3 changes'));
      expect(text, contains('lines: 2'));
      // The lines land between the header and the footer, in order.
      expect(
        text.indexOf('building plan'),
        lessThan(text.indexOf('applying 3 changes')),
      );
      expect(
        text.indexOf('applying 3 changes'),
        lessThan(text.indexOf('outcome:')),
      );
    });

    test('finishing twice is safe, and lines after it are dropped', () async {
      final log = await RunLog.begin(
        const RunLogHeader(verb: RunLogVerb.seed, command: 'abctl seed'),
        directory: dir.path,
      );
      await log!.finish(outcome: 'seeded');
      log
        ..line('too late')
        ..line('also too late');
      await log.finish(outcome: 'seeded again');

      final text = File(log.path).readAsStringSync();
      expect(text, contains('outcome: seeded'));
      expect(text, isNot(contains('too late')));
      expect(text, isNot(contains('seeded again')));
    });

    test('an unwritable directory yields no log rather than a failed sync', () async {
      // Logging is a nice-to-have; applying the plan is not. The caller holds a `RunLog?`.
      // A plain FILE where the log directory should be: creating a directory under it fails on
      // every platform, which is the cheapest portable stand-in for a read-only disk.
      final wall = '${dir.path}${Platform.pathSeparator}wall.txt';
      File(wall).writeAsStringSync('x');

      final log = await RunLog.begin(
        const RunLogHeader(verb: RunLogVerb.diff, command: 'abctl diff'),
        directory: '$wall${Platform.pathSeparator}nested',
      );
      expect(log, isNull);
    });
  });

  group('retention', () {
    test(
      'old logs go, the current run stays, and foreign files are untouched',
      () {
        String write(String name, Duration age) {
          final path = '${dir.path}${Platform.pathSeparator}$name';
          File(path)
            ..writeAsStringSync('x')
            ..setLastModifiedSync(DateTime.now().subtract(age));
          return path;
        }

        final fresh = write(
          'sync-20260725T143005Z-aaaaaa.log',
          const Duration(days: 1),
        );
        final stale = write(
          'diff-20260101T000000Z-bbbbbb.log',
          const Duration(days: 30),
        );
        final staleButCurrent = write(
          'seed-20260101T000000Z-cccccc.log',
          const Duration(days: 30),
        );
        final foreign = write('someone-elses.log', const Duration(days: 300));

        RunLog.prune(excluding: staleButCurrent, directory: dir.path);

        expect(File(fresh).existsSync(), isTrue);
        expect(File(stale).existsSync(), isFalse);
        expect(
          File(staleButCurrent).existsSync(),
          isTrue,
          reason: 'never delete the run that is still writing',
        );
        expect(
          File(foreign).existsSync(),
          isTrue,
          reason: 'the pruner deletes only files it wrote',
        );
      },
    );

    test('pruning a directory that does not exist is silent', () {
      expect(
        () =>
            RunLog.prune(directory: '${dir.path}${Platform.pathSeparator}nope'),
        returnsNormally,
      );
    });
  });
}
