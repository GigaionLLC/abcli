// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// `abctl seed` — the one verb in `GitopsStore` that puts files on disk.
//
// It never touches the tenant, so there is no `--yes` and no tenant gate. What it CAN destroy is
// the workspace: a git checkout with unsynced edits, rewritten from whatever Apple Business holds
// at that moment. Every test below defends one property of that, and each is named after the rule
// rather than the mechanism, so a failure explains itself:
//
//   * the refusal is the STORE's, not a dialog's (a screen cannot forget to ask);
//   * the argv is the bare verb — no `--yes` on a command that changes no tenant state;
//   * abctl's prose answer is carried, never decoded;
//   * the seed and the plan it hands off to are ONE transcript and ONE log file;
//   * their generations are separate, which is the Swift stuck-spinner bug in test form.
//
// Nothing here reaches a real abctl: the PROCESS seam is overridden and everything above it — the
// recording runner, the command log, the redaction, the transcript wiring — is the app's own.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/abctl/run_log.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('seeding an empty folder runs the bare verb, in that folder', () async {
    final List<List<String>> ran = <List<String>>[];
    final List<String?> cwds = <String?>[];
    final ProviderContainer container = _containerFor((
      List<String> args,
      String? cwd,
    ) async {
      ran.add(args);
      cwds.add(cwd);
      return args.first == 'seed'
          ? _ok('seeded 3 configuration(s)')
          : _ok('{"configs":[],"blueprints":[]}');
    });
    final GitopsStore store = container.read(gitopsProvider.notifier);
    final Directory folder = _tempDir();
    await store.setWorkspace(folder.path);

    // A folder with no tree, so `onlyIfAbsent` is the honest consent and the store accepts it.
    // The seed does not create the tree here (the runner is a script), which is fine: what is
    // under test is the command, not abctl.
    expect(
      await store.seedWorkspace(consent: SeedConsent.onlyIfAbsent),
      isTrue,
    );

    expect(ran.first, <String>['seed']);
    expect(
      ran.first,
      isNot(contains('--yes')),
      reason:
          'seed changes no tenant state, and a gate on a command that changes nothing local is a '
          'false claim about it',
    );
    expect(
      cwds.first,
      folder.path,
      reason:
          'seed has no path flag — it writes into the directory it runs in, so the workspace IS '
          'the argument',
    );
  });

  test(
    'the store refuses to seed over an existing tree without consent',
    () async {
      var calls = 0;
      final ProviderContainer container = _containerFor((
        List<String> args,
        String? cwd,
      ) async {
        calls += 1;
        return _ok('seeded');
      });
      final GitopsStore store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);

      final bool ok = await store.seedWorkspace(
        consent: SeedConsent.onlyIfAbsent,
      );

      expect(ok, isFalse);
      expect(
        calls,
        0,
        reason:
            'the refusal happens before abctl is spawned — nothing was rewritten and then '
            'complained about',
      );
      final SeedState seed = container.read(gitopsProvider).seed;
      expect(seed.isRunning, isFalse);
      expect(seed.error, contains('already has a gitops/ tree'));
      expect(
        seed.error,
        contains('discards local edits'),
        reason:
            'the message has to name what is lost, not merely that something is',
      );
    },
  );

  test('the same folder seeds once the user has said to overwrite it', () async {
    final List<List<String>> ran = <List<String>>[];
    final ProviderContainer container = _containerFor((
      List<String> args,
      String? cwd,
    ) async {
      ran.add(args);
      return args.first == 'seed'
          ? _ok('re-seeded 12 configuration(s)\nwrote gitops/lib/')
          : _ok('{"configs":[],"blueprints":[]}');
    });
    final GitopsStore store = container.read(gitopsProvider.notifier);
    await store.setWorkspace(_workspace().path);

    expect(
      await store.seedWorkspace(consent: SeedConsent.overwriteExistingTree),
      isTrue,
    );

    expect(ran.first, <String>['seed']);
    final SeedState seed = container.read(gitopsProvider).seed;
    expect(seed.error, isNull);
    expect(seed.seededAt, isNotNull);
    // Carried VERBATIM. `seed` prints prose, not a document — there is no shape to validate and
    // no model to decode into, and a store that tried would turn a successful seed into a decode
    // failure the moment abctl reworded a sentence.
    expect(seed.summary, 're-seeded 12 configuration(s)\nwrote gitops/lib/');
  });

  test('a seed hands off to the plan, as one transcript and one log', () async {
    final List<List<String>> ran = <List<String>>[];
    final _RecordingLog log = _RecordingLog();
    final ProviderContainer container = _containerFor((
      List<String> args,
      String? cwd,
    ) async {
      ran.add(args);
      return args.first == 'seed'
          ? _ok('seeded')
          : _ok('{"configs":[],"blueprints":[]}');
    }, log: log);
    final GitopsStore store = container.read(gitopsProvider.notifier);
    await store.setWorkspace(_workspace().path);

    await store.seedWorkspace(consent: SeedConsent.overwriteExistingTree);

    expect(ran.map((List<String> a) => a.first).toList(), <String>[
      'seed',
      'diff',
    ]);
    // The plan really ran, and its result is on screen — a seed that left the user staring at
    // "no plan yet" would have made them press Refresh for no reason.
    expect(container.read(gitopsProvider).plan.hasPlan, isTrue);

    // ONE transcript. The `$ abctl seed` line the user watched appear is still there underneath
    // the diff's, which is the whole reason `refreshPlan` takes `resetTranscript`.
    final List<String> lines = container.read(progressSinkProvider).lines.value;
    expect(lines.first, startsWith(r'$ abctl seed'));
    expect(
      lines.any((String line) => line.startsWith(r'$ abctl diff')),
      isTrue,
      reason: 'the diff appends rather than clearing',
    );

    // ONE log file, opened by the seed and closed by it — headed `seed`, because the header has
    // to name the command that actually executed.
    expect(log.headers.map((RunLogHeader h) => h.verb).toList(), <RunLogVerb>[
      RunLogVerb.seed,
    ]);
    expect(log.headers.single.command, 'abctl seed');
    expect(log.outcomes, <String>['workspace initialized']);
  });

  test('a failed seed says so and never starts a plan', () async {
    final List<List<String>> ran = <List<String>>[];
    final ProviderContainer container = _containerFor((
      List<String> args,
      String? cwd,
    ) async {
      ran.add(args);
      return _exit(1, 'no credentials for context prod');
    });
    final GitopsStore store = container.read(gitopsProvider.notifier);
    await store.setWorkspace(_workspace().path);

    expect(
      await store.seedWorkspace(consent: SeedConsent.overwriteExistingTree),
      isFalse,
    );

    expect(ran.single.first, 'seed');
    final GitopsState state = container.read(gitopsProvider);
    expect(state.seed.isRunning, isFalse);
    expect(state.seed.error, contains('no credentials'));
    expect(
      state.plan.hasPlan,
      isFalse,
      reason: 'a seed that produced no tree has nothing new to diff against',
    );
    expect(
      state.plan.error,
      isNull,
      reason:
          'and a failed seed is not a failed plan — one shared error slot is how a stale message '
          'ends up under the wrong spinner',
    );
  });

  test(
    'the seed and the plan hold separate generations, so neither wedges the other',
    () async {
      // THE bug, in the shape it had in Swift: one counter for both meant the plan invalidated
      // the seed's token, the seed's completion guard failed, `isSeeding` was never cleared, and
      // the Diff screen sat on "Initializing workspace from the tenant…" with every control
      // disabled until the app was relaunched.
      final Completer<void> held = Completer<void>();
      final ProviderContainer container = _containerFor((
        List<String> args,
        String? cwd,
      ) async {
        if (args.first == 'seed') {
          await held.future;
          return _ok('seeded');
        }
        return _ok('{"configs":[],"blueprints":[]}');
      });
      final GitopsStore store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);

      final Future<bool> seeding = store.seedWorkspace(
        consent: SeedConsent.overwriteExistingTree,
      );
      // A plan started by hand while the seed is still downloading.
      await store.refreshPlan();
      expect(
        container.read(gitopsProvider).seed.isRunning,
        isTrue,
        reason: 'a finished plan must not take the seed\'s spinner down',
      );

      held.complete();
      expect(await seeding, isTrue);

      final GitopsState state = container.read(gitopsProvider);
      expect(state.seed.isRunning, isFalse, reason: 'and it does come down');
      expect(state.seed.summary, 'seeded');
    },
  );

  test('choosing another workspace cancels a seed and forgets it', () async {
    final Completer<void> held = Completer<void>();
    var cancelled = false;
    final ProviderContainer container = _containerFor((
      List<String> args,
      String? cwd,
    ) async {
      await held.future;
      return _ok('seeded');
    }, onCancel: () => cancelled = true);
    final GitopsStore store = container.read(gitopsProvider.notifier);
    await store.setWorkspace(_workspace().path);

    final Future<bool> seeding = store.seedWorkspace(
      consent: SeedConsent.overwriteExistingTree,
    );
    await store.setWorkspace(_workspace().path);
    held.complete();
    await seeding;

    expect(
      cancelled,
      isTrue,
      reason:
          'a seed writes FILES into the folder it started in — one left running would keep '
          'filling the previous workspace with nothing on screen saying so',
    );
    final SeedState seed = container.read(gitopsProvider).seed;
    expect(seed.isRunning, isFalse);
    expect(
      seed.summary,
      isNull,
      reason: 'the new folder has not been seeded, whatever the old one did',
    );
  });

  test('the summary can be dismissed without losing when it happened', () async {
    final ProviderContainer container = _containerFor(
      (List<String> args, String? cwd) async => args.first == 'seed'
          ? _ok('seeded 3 configuration(s)')
          : _ok('{"configs":[],"blueprints":[]}'),
    );
    final GitopsStore store = container.read(gitopsProvider.notifier);
    await store.setWorkspace(_workspace().path);
    await store.seedWorkspace(consent: SeedConsent.overwriteExistingTree);

    store.dismissSeedSummary();

    final SeedState seed = container.read(gitopsProvider).seed;
    expect(seed.summary, isNull);
    expect(
      seed.seededAt,
      isNotNull,
      reason:
          '"when was this tree seeded" outlives the paragraph that announced it',
    );
  });

  test('seeding without a workspace names the folder it needs', () async {
    var calls = 0;
    final ProviderContainer container = _containerFor((
      List<String> args,
      String? cwd,
    ) async {
      calls += 1;
      return _ok('seeded');
    });

    expect(
      await container
          .read(gitopsProvider.notifier)
          .seedWorkspace(consent: SeedConsent.overwriteExistingTree),
      isFalse,
    );

    expect(calls, 0);
    expect(
      container.read(gitopsProvider).seed.error,
      contains('workspace folder'),
    );
  });
}

// -------------------------------------------------------------------------------------------
// harness
// -------------------------------------------------------------------------------------------

/// Overrides the PROCESS seam and nothing above it, so the recording runner, the command log, the
/// redaction and the transcript wiring are all the app's real ones.
ProviderContainer _containerFor(
  Future<AbctlResult> Function(List<String> args, String? cwd) handler, {
  _RecordingLog? log,
  void Function()? onCancel,
}) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      abctlRunnerFactoryProvider.overrideWithValue(
        ({void Function(String line)? onStderrLine}) =>
            _ScriptedRunner(handler, onStderrLine, onCancel),
      ),
      runLogOpenerProvider.overrideWithValue(
        (RunLogHeader header) async => log?.begin(header),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A workspace with a `gitops/` tree — what abctl calls a workspace.
Directory _workspace() {
  final Directory root = _tempDir();
  Directory('${root.path}${Platform.pathSeparator}gitops').createSync();
  return root;
}

Directory _tempDir() {
  final Directory directory = Directory.systemTemp.createTempSync(
    'abgui_seed_',
  );
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

class _ScriptedRunner implements AbctlRunner {
  const _ScriptedRunner(this.handler, this.onStderrLine, this.onCancel);

  final Future<AbctlResult> Function(List<String> args, String? cwd) handler;
  final void Function(String line)? onStderrLine;
  final void Function()? onCancel;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) {
    // The real runner kills its child on this; here it is just the signal that the store asked.
    cancel?.onCancel(() => onCancel?.call());
    return handler(args, cwd);
  }
}

/// A run log that records rather than writes, so "one file, headed seed, closed once" is a thing a
/// test can assert instead of a thing a reader has to trust.
class _RecordingLog {
  final List<RunLogHeader> headers = <RunLogHeader>[];
  final List<String> lines = <String>[];
  final List<String> outcomes = <String>[];

  RunLog begin(RunLogHeader header) {
    headers.add(header);
    return _FakeRunLog(this);
  }
}

class _FakeRunLog implements RunLog {
  _FakeRunLog(this.recorder);

  final _RecordingLog recorder;

  @override
  final String path = '(in memory)';

  @override
  final DateTime startedAt = DateTime.utc(2026, 1, 1);

  @override
  void line(String text) => recorder.lines.add(text);

  @override
  Future<void> finish({required String outcome, DateTime? at}) async =>
      recorder.outcomes.add(outcome);
}

AbctlResult _ok(String stdout) => AbctlResult(
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: '',
  code: 0,
);

AbctlResult _exit(int code, String stderr) =>
    AbctlResult(stdout: Uint8List(0), stderr: stderr, code: code);
