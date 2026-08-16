// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Exercises the runner against a REAL child process, because every property worth testing
// here is a property of pipes and process teardown — a fake `Process` would assert that the
// mock behaves like the mock. The child is a Dart script written to a temp directory and run
// with the SDK's own `dart` binary, which exists on all three platforms and lets the test
// dictate exit code, output volume, and timing exactly.
//
// Note `Platform.resolvedExecutable` is NOT usable directly: under `flutter test` it is
// `flutter_tester`, which cannot run an arbitrary script. See [_dartBinary].

import 'dart:convert';
import 'dart:io';

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory workDir;
  late String helper;
  late String dart;

  setUpAll(() {
    dart = _dartBinary();
    workDir = Directory.systemTemp.createTempSync('abgui_process_runner');
    helper = '${workDir.path}${Platform.pathSeparator}child.dart';
    File(helper).writeAsStringSync(_childSource);
  });

  tearDownAll(() {
    try {
      workDir.deleteSync(recursive: true);
    } on FileSystemException {
      // A killed child can still hold the directory open on Windows for a moment; the OS
      // cleans its own temp.
    }
  });

  ProcessRunner runnerWith({void Function(String)? onLine}) =>
      ProcessRunner(executable: dart, onStderrLine: onLine);

  Future<AbctlResult> runHelper(
    List<String> args, {
    void Function(String)? onLine,
    List<int>? stdin,
    Duration timeout = const Duration(seconds: 30),
    CancelToken? cancel,
  }) => runnerWith(
    onLine: onLine,
  ).run([helper, ...args], stdin: stdin, timeout: timeout, cancel: cancel);

  test('a clean exit hands back stdout, stderr and code 0', () async {
    final result = await runHelper(['ok']);

    expect(result.code, 0);
    expect(result.isSuccess, isTrue);
    expect(result.stdoutText, 'hello stdout');
    expect(result.stderr, 'hello stderr');
  });

  test('exit 3 is "changes pending" — a normal state, not a failure', () async {
    final result = await runHelper(['pending']);

    expect(result.code, 3);
    expect(result.changesPending, isTrue);
    expect(
      result.stdoutText,
      isNotEmpty,
      reason: 'abctl prints the plan on stdout and THEN exits 3',
    );
    // The verdict only becomes an error where a caller asks for it to be mapped, and it maps
    // to its own case so nothing can render drift as breakage.
    expect(result.checkExit, throwsA(isA<AbctlChangesPending>()));
  });

  test('exit 1 carries stderr, and any other code is an argv bug', () async {
    final failed = await runHelper(['fail']);
    expect(failed.code, 1);
    expect(
      failed.checkExit,
      throwsA(
        isA<AbctlCliError>().having(
          (e) => e.message,
          'message',
          contains('something broke'),
        ),
      ),
    );

    final usage = await runHelper(['usage']);
    expect(usage.code, 2);
    expect(
      usage.checkExit,
      throwsA(
        isA<AbctlUsageError>().having(
          (e) => e.message,
          'message',
          contains('unexpected abctl exit'),
        ),
      ),
    );
  });

  test(
    'both pipes are drained concurrently, so >64 KB on each cannot deadlock',
    () async {
      // The child writes 128 KB to stderr and 128 KB to stdout, flushing after every 8 KB chunk
      // so it genuinely blocks on a full pipe rather than buffering in its own process. A parent
      // that read one stream to completion before subscribing to the other would hang here
      // forever: the child is blocked writing stderr, the parent is blocked reading stdout.
      final result = await runHelper([
        'flood',
        '16',
      ], timeout: const Duration(seconds: 60));

      expect(result.code, 0);
      expect(result.stdout.length, 16 * 8192);
      expect(result.stderr.length, 16 * 8192);
    },
  );

  test('stderr arrives line by line while the child is still running', () async {
    final seen = <String>[];
    final result = await runHelper(['lines'], onLine: seen.add);

    expect(result.code, 0);
    // Trimmed, blank lines dropped, and the unterminated last line still delivered — abctl
    // does not always end its narration with a newline before it exits.
    expect(seen, ['step one', 'step two', 'step three', 'trailing partial']);
  });

  test(
    'a run that outstays its budget is killed and says what it last printed',
    () async {
      final started = DateTime.now();
      await expectLater(
        runHelper(['hang'], timeout: const Duration(seconds: 1)),
        throwsA(
          isA<AbctlTimedOut>()
              .having((e) => e.seconds, 'seconds', 1)
              .having(
                (e) => e.lastOutput,
                'lastOutput',
                contains('contacting Apple'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('abctl ran for 1s without finishing and was stopped'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('api-business.apple.com'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('Last output from abctl:'),
              ),
        ),
      );
      // The watchdog has to actually KILL the child; if it only gave up waiting, this would sit
      // here for the two minutes the child sleeps.
      expect(DateTime.now().difference(started).inSeconds, lessThan(20));
    },
  );

  test('cancellation kills a running child', () async {
    final token = CancelToken();
    final run = runHelper(
      ['hang'],
      timeout: const Duration(minutes: 5),
      cancel: token,
    );

    // Let it get as far as printing, so this cancels a genuinely running process rather than
    // taking the pre-cancelled shortcut below.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    token.cancel();

    await expectLater(run, throwsA(isA<AbctlCancelled>()));
    expect(token.isCancelled, isTrue);
  });

  test('an already-cancelled token spawns nothing at all', () async {
    final token = CancelToken()..cancel();
    // A path that does not exist: reaching Process.start would report THAT error instead.
    final runner = ProcessRunner(executable: '${workDir.path}/no-such-binary');

    await expectLater(
      runner.run(const ['version'], cancel: token),
      throwsA(isA<AbctlCancelled>()),
    );
  });

  test('cancelling twice is a no-op and listeners are only called once', () {
    final token = CancelToken();
    var calls = 0;
    token.onCancel(() => calls++);
    token
      ..cancel()
      ..cancel();
    expect(calls, 1);

    // Registering after the fact still fires, so a check-then-register race cannot drop it.
    var late = 0;
    token.onCancel(() => late++);
    expect(late, 1);
  });

  test(
    'stdin is closed even when there is nothing to send, so the child sees EOF',
    () async {
      // The child reads stdin to completion before it exits. Without the close it would wait
      // for input that is never coming and this would fail as a timeout, not as a hang.
      final result = await runHelper([
        'count-stdin',
      ], timeout: const Duration(seconds: 15));

      expect(result.code, 0);
      expect(result.stdoutText, '0');
    },
  );

  test('a payload larger than the pipe buffer arrives whole', () async {
    final payload = utf8.encode('<plist>${'p' * (512 * 1024)}</plist>');
    final result = await runHelper(
      ['count-stdin'],
      stdin: payload,
      timeout: const Duration(seconds: 30),
    );

    expect(result.code, 0);
    expect(
      result.stdoutText,
      '${payload.length}',
      reason: 'the child received a different number of bytes than were sent',
    );
  });

  test(
    'a failed stdin write fails the run rather than reporting a clean exit',
    () async {
      // The child exits immediately without reading stdin, so the write breaks part-way. That is
      // a TRUNCATED profile: abctl may already have sent half a configuration to Apple, and the
      // exit code alone cannot tell that from success. Reporting it is the whole point.
      final payload = List<int>.filled(8 * 1024 * 1024, 0x41);

      await expectLater(
        runHelper(
          ['exit-now'],
          stdin: payload,
          timeout: const Duration(seconds: 30),
        ),
        throwsA(
          isA<AbctlCliError>().having(
            (e) => e.message,
            'message',
            contains('it may have received only part of it'),
          ),
        ),
      );
    },
  );

  test(
    'a binary that cannot be started is reported as a packaging problem, not an abctl abort',
    () async {
      // REGRESSION: a spawn failure used to be raised as `AbctlCliError`, which is documented as
      // "exit 1: a runtime error, carrying abctl's own stderr". A child that never started
      // produced neither. Dressed that way it went down the abort path everywhere —
      // `GitopsStore._applyFailure` maps it to `SyncFailure.fromAbort`, so an operator whose
      // bundled binary had been quarantined by AV after an update read "could not start abctl at
      // …" underneath "Nothing was applied", with nothing anywhere saying that reinstalling is
      // the fix. `AbctlMissingBinary` is the type that says exactly that, and it was reachable
      // only from the STARTUP probe until now.
      final String path = '${workDir.path}${Platform.pathSeparator}not-abctl';
      final runner = ProcessRunner(executable: path);

      await expectLater(
        runner.run(const ['version']),
        throwsA(
          isA<AbctlMissingBinary>()
              // The probed path is carried as data, not buried in prose, because the Logs and
              // Diagnostics screens render it as a path.
              .having((e) => e.searched, 'searched', <String>[path])
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('packaging problem'),
                  contains('reinstalling the app is the fix'),
                  // The OS's own reason survives: "no such file" and "permission denied" are
                  // different problems and the operator is the one who can tell them apart.
                  contains('refused to start it'),
                ),
              ),
        ),
      );
    },
  );
}

/// The Dart SDK binary that can run [_childSource].
///
/// `flutter test` runs this suite inside `flutter_tester`, so `Platform.resolvedExecutable`
/// points at the harness rather than at a Dart VM that takes a script argument. The SDK is
/// always present next to it — `<flutter>/bin/cache/dart-sdk/bin/dart` — so it is found from
/// `FLUTTER_ROOT` and, failing that, by walking up from the harness itself. Under a plain
/// `dart test` the resolved executable already IS dart, which is the first case below.
String _dartBinary() {
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  final sep = Platform.pathSeparator;
  final resolved = Platform.resolvedExecutable;

  if (resolved.split(sep).last.toLowerCase() == exeName) return resolved;

  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final candidate = [
      root,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      exeName,
    ].join(sep);
    if (File(candidate).existsSync()) return candidate;
  }

  // .../bin/cache/artifacts/engine/<platform>/flutter_tester(.exe) → .../bin/cache/dart-sdk/...
  final parts = resolved.split(sep);
  final cache = parts.lastIndexOf('cache');
  if (cache > 0) {
    final candidate = [
      ...parts.sublist(0, cache + 1),
      'dart-sdk',
      'bin',
      exeName,
    ].join(sep);
    if (File(candidate).existsSync()) return candidate;
  }

  throw StateError(
    'could not locate a dart binary to run the test child from $resolved',
  );
}

/// The controllable child. One script, one mode argument, so every case below spawns the same
/// file and the differences between them are visible in one place.
const String _childSource = r'''
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'ok' : args.first;
  switch (mode) {
    case 'ok':
      stdout.write('hello stdout');
      stderr.write('hello stderr');
      await stdout.flush();
      await stderr.flush();
      exit(0);
    case 'pending':
      stdout.write('{"changes":1}');
      await stdout.flush();
      exit(3);
    case 'fail':
      stderr.write('abctl: something broke');
      await stderr.flush();
      exit(1);
    case 'usage':
      stderr.write('unknown flag: --nope');
      await stderr.flush();
      exit(2);
    case 'flood':
      // Flush after every chunk so the child really blocks on a full pipe. Buffering in the
      // child would let a serialized parent pass a test it should fail.
      final chunks = int.parse(args[1]);
      final chunk = 'x' * 8192;
      for (var i = 0; i < chunks; i++) {
        stderr.write(chunk);
        await stderr.flush();
        stdout.write(chunk);
        await stdout.flush();
      }
      exit(0);
    case 'lines':
      for (final line in ['  step one  ', '', 'step two', 'step three']) {
        stderr.writeln(line);
        await stderr.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      stderr.write('trailing partial'); // deliberately unterminated
      await stderr.flush();
      exit(0);
    case 'hang':
      stderr.writeln('contacting Apple');
      await stderr.flush();
      await Future<void>.delayed(const Duration(seconds: 120));
      exit(0);
    case 'count-stdin':
      final total = await stdin.fold<int>(0, (sum, chunk) => sum + chunk.length);
      stdout.write('$total');
      await stdout.flush();
      exit(0);
    case 'exit-now':
      exit(0);
    default:
      stderr.write('unknown mode: $mode');
      await stderr.flush();
      exit(9);
  }
}
''';
