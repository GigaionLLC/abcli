// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The workspace verbs. Two independent operations (compute the plan, verify the profiles) that a
// user can start in either order — which is exactly the shape that produced the Swift app's
// unrecoverable stuck spinner when they shared one generation counter.
//
// Nothing here reaches a real abctl, a real log file or a real preferences store: the client is
// scripted, the run-log opener is overridden to answer null (what `RunLog.begin` itself does on
// any failure), and shared_preferences runs on its in-memory mock.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/sync_failure.dart';
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

  test('a plan without a workspace names the folder it needs', () async {
    final container = _containerFor((args) async => _ok('{}'));

    await container.read(gitopsProvider.notifier).refreshPlan();

    final plan = container.read(gitopsProvider).plan;
    expect(plan.error, contains('gitops/'));
    expect(plan.hasPlan, isFalse);
  });

  test('a folder with no gitops/ tree is a state, not a failure', () async {
    var calls = 0;
    final container = _containerFor((args) async {
      calls += 1;
      return _ok('{}');
    });
    final store = container.read(gitopsProvider.notifier);

    await store.setWorkspace(_tempDir().path);
    await store.refreshPlan();

    final plan = container.read(gitopsProvider).plan;
    expect(plan.needsGitopsTree, isTrue);
    expect(plan.error, isNull, reason: 'nothing has gone wrong yet');
    expect(
      calls,
      0,
      reason:
          'a stat answers this; a network diff with nothing to compare does not',
    );
  });

  test('an in-sync tenant still stamps the time it was checked', () async {
    final container = _containerFor(
      (args) async => _ok('{"configs":[],"blueprints":[]}'),
    );
    final store = container.read(gitopsProvider.notifier);

    await store.setWorkspace(_workspace().path);
    await store.refreshPlan();

    final plan = container.read(gitopsProvider).plan;
    expect(plan.plan?.isEmpty, isTrue);
    expect(plan.isRunning, isFalse);
    expect(
      plan.checkedAt,
      isNotNull,
      reason:
          'without the stamp, Refresh on a clean tenant looks like a dead button',
    );
  });

  test('exit 3 is drift, and drift is never a failure banner', () async {
    final container = _containerFor(
      (args) async => _exit(3, 'changes pending'),
    );
    final store = container.read(gitopsProvider.notifier);

    await store.setWorkspace(_workspace().path);
    await store.refreshPlan();

    final plan = container.read(gitopsProvider).plan;
    expect(plan.error, isNull);
    expect(
      plan.note,
      isNotNull,
      reason: 'but it still has to reach the screen',
    );
  });

  test(
    'a superseded plan publishes neither its rows nor its spinner',
    () async {
      final stale = Completer<void>();
      var call = 0;
      final container = _containerFor((args) async {
        call += 1;
        if (call == 1) {
          await stale.future;
          return _ok(
            '{"configs":[{"name":"stale","action":"create-abm","detail":""}]}',
          );
        }
        return _ok(
          '{"configs":[{"name":"fresh","action":"create-abm","detail":""}]}',
        );
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);

      final superseded = store.refreshPlan();
      await store.refreshPlan();
      stale.complete();
      await superseded;

      final plan = container.read(gitopsProvider).plan;
      expect(plan.plan?.configs.single.name, 'fresh');
      expect(
        plan.isRunning,
        isFalse,
        reason: 'the run that replaced it had already finished',
      );
    },
  );

  test('a new workspace never inherits the last one\'s green light', () async {
    final container = _containerFor((args) async {
      if (args.first == 'validate') return _ok('{"ok":true,"checked":2}');
      return _ok('{"configs":[],"blueprints":[]}');
    });
    final store = container.read(gitopsProvider.notifier);

    await store.setWorkspace(_workspace().path);
    await store.refreshPlan();
    expect(await store.validate(), isTrue);
    expect(container.read(gitopsProvider).validation.report, isNotNull);

    await store.setWorkspace(_workspace().path);

    final state = container.read(gitopsProvider);
    expect(
      state.validation.report,
      isNull,
      reason: 'those files were never checked',
    );
    expect(state.validation.checkedAt, isNull);
    expect(state.plan.hasPlan, isFalse);
    expect(state.plan.checkedAt, isNull);
  });

  test(
    'a validate that could not complete leaves verification unknown',
    () async {
      var call = 0;
      final container = _containerFor((args) async {
        call += 1;
        return call == 1
            ? _ok('{"ok":true,"checked":2}')
            : _exit(1, 'gitops/lib is unreadable');
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);

      expect(await store.validate(), isTrue);
      expect(await store.validate(), isFalse);

      final validation = container.read(gitopsProvider).validation;
      // Keeping the last report would render a green "Verified" row on the strength of a run that
      // never produced a verdict.
      expect(validation.report, isNull);
      expect(validation.checkedAt, isNull);
      expect(validation.error, contains('unreadable'));
    },
  );

  test('verifying does not disturb the plan, and vice versa', () async {
    final validating = Completer<void>();
    final container = _containerFor((args) async {
      if (args.first == 'validate') {
        await validating.future;
        return _exit(1, 'a profile is malformed');
      }
      return _ok('{"configs":[],"blueprints":[]}');
    });
    final store = container.read(gitopsProvider.notifier);
    await store.setWorkspace(_workspace().path);

    final verify = store.validate();
    await store.refreshPlan();

    expect(
      container.read(gitopsProvider).validation.isRunning,
      isTrue,
      reason: 'a finished plan must not take the verify spinner down',
    );

    validating.complete();
    await verify;

    final state = container.read(gitopsProvider);
    expect(state.validation.error, isNotNull);
    expect(
      state.plan.error,
      isNull,
      reason: 'and a failed verify is not a failed plan',
    );
    expect(state.plan.checkedAt, isNotNull);
    expect(
      container.read(progressSinkProvider).lines.value,
      hasLength(3),
      reason:
          'validate runs the SILENT client: only the plan\'s three lines are in the transcript',
    );
  });

  test(
    'flipping git-source-of-truth drops the plan the other mode computed',
    () async {
      final container = _containerFor(
        (args) async => _ok('{"configs":[],"blueprints":[]}'),
      );
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);
      await store.refreshPlan();
      expect(container.read(gitopsProvider).plan.hasPlan, isTrue);

      store.setGitSourceOfTruth(false);

      expect(
        container.read(gitopsProvider).plan.hasPlan,
        isFalse,
        reason:
            'a plan under a switch that now says something else is a lie either way',
      );
    },
  );

  test(
    'the workspace is remembered, and restored only if it still exists',
    () async {
      final directory = _workspace();
      final first = _containerFor((args) async => _ok('{}'));
      await first.read(gitopsProvider.notifier).setWorkspace(directory.path);

      // A second launch, sharing the mock preferences store.
      final second = _containerFor((args) async => _ok('{}'));
      await second.read(gitopsProvider.notifier).restoreWorkspace();
      expect(second.read(workspaceProvider), directory.path);

      directory.deleteSync(recursive: true);
      final third = _containerFor((args) async => _ok('{}'));
      await third.read(gitopsProvider.notifier).restoreWorkspace();
      expect(
        third.read(workspaceProvider),
        isNull,
        reason: 'a folder that moved is a folder to pick again, not a banner',
      );
    },
  );

  test('the plan is narrated and the transcript is reset per run', () async {
    final container = _containerFor((args) async => _ok('{"configs":[]}'));
    final store = container.read(gitopsProvider.notifier);
    await store.setWorkspace(_workspace().path);

    await store.refreshPlan();
    final first = container.read(progressSinkProvider).lines.value;
    await store.refreshPlan();
    final second = container.read(progressSinkProvider).lines.value;

    // One transcript: the command abgui ran, abctl's own narration, and how it ended — in that
    // order, which is only true because the `$ …` and `→ …` lines flush the buffer before they
    // publish.
    expect(first, <Object>[
      startsWith(r'$ abctl diff --json'),
      _ScriptedRunner.narration,
      startsWith('→ exit 0'),
    ]);
    expect(
      second,
      hasLength(first.length),
      reason:
          'each run starts a transcript rather than appending to the last one',
    );
    // Both runs are in the command log, redacted, without either store instrumenting a thing.
    expect(container.read(commandLogProvider).records, hasLength(2));
  });

  // =========================================================================================
  // `sync --apply` — the one verb here that changes a live Apple Business tenant.
  //
  // What is pinned below is the half a dialog cannot be trusted with: the store's own refusals,
  // and the rule that an outcome nobody can establish is reported as unestablished. A screen
  // that forgets to check something must get a message, never a write.
  // =========================================================================================
  group('applyPlan', () {
    test('an apply whose mode disagrees with the plan never runs', () async {
      // `diff` and `sync --apply` take the same git-source-of-truth flag. Applying under the
      // other setting executes a reconcile nobody computed — every removal the plan on screen
      // does not list, or none of the ones it does.
      final ran = <List<String>>[];
      final container = _containerFor((args) async {
        ran.add(args);
        return _ok('{"configs":[],"blueprints":[]}');
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);
      await store.refreshPlan(); // git-as-truth is the store's default

      await store.applyPlan(const ApplyOptions.additive());

      expect(
        ran.any((args) => args.first == 'sync'),
        isFalse,
        reason: 'the refusal has to happen before a process, not after one',
      );
      final apply = container.read(gitopsProvider).apply;
      expect(apply.verdict, ApplyVerdict.failed);
      expect(apply.failure?.details, contains('Recompute the plan first'));
    });

    test('a metadata-only plan cannot be applied', () async {
      // abctl rejects the combination itself (`internal/cli/phase1.go`): metadata-only never
      // fetches profile XML, which every write needs in order to archive the live version first.
      // Refusing here turns a spawned process and a flag error into a sentence.
      final ran = <List<String>>[];
      final container = _containerFor((args) async {
        ran.add(args);
        return _ok('{"configs":[],"blueprints":[]}');
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);

      await store.applyPlan(
        const ApplyOptions.gitAuthoritative(refresh: AbctlRefresh.metadataOnly),
      );

      expect(ran.any((args) => args.first == 'sync'), isFalse);
      expect(
        container.read(gitopsProvider).apply.failure?.details,
        contains('archive the live version'),
      );
    });

    test('a receipt survives a non-zero exit as a PARTIAL verdict', () async {
      // Decode-before-exit-code, end to end: abctl prints the per-item document and only then
      // returns ExitError{1}. The rows are what the operator has to read.
      final container = _containerFor((args) async {
        if (args.first != 'sync') return _ok('{"configs":[],"blueprints":[]}');
        return AbctlResult(
          stdout: Uint8List.fromList(
            utf8.encode(
              '{"configs":{"outcomes":['
              '{"name":"VPN","action":"update","status":"error","detail":"403"}'
              '],"writes":1,"errors":1,"skipped":0},'
              '"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}',
            ),
          ),
          stderr: 'building plan: fetching configurations',
          code: 1,
        );
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);
      await store.refreshPlan();

      await store.applyPlan(const ApplyOptions.gitAuthoritative());

      final state = container.read(gitopsProvider);
      expect(state.apply.verdict, ApplyVerdict.partial);
      expect(state.apply.failedCount, 1);
      expect(state.apply.result?.rows, hasLength(1));
      expect(state.apply.failure?.details, contains('403'));
      // Something landed, so the rows on the Diff screen are a record rather than a forecast.
      expect(state.plan.superseded, isTrue);
    });

    test('a cancel mid-write is unknown, never a clean failure', () async {
      // The most expensive wrong sentence on this path is "it failed": it tells an operator the
      // tenant is untouched, and they then do nothing about a tenant that is part way between
      // git and where it started.
      final container = _containerFor((args) async {
        if (args.first != 'sync') return _ok('{"configs":[],"blueprints":[]}');
        throw const AbctlCancelled();
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);
      await store.refreshPlan();

      await store.applyPlan(const ApplyOptions.gitAuthoritative());

      final state = container.read(gitopsProvider);
      expect(state.apply.verdict, ApplyVerdict.unknown);
      expect(state.apply.interrupted, isTrue);
      expect(state.apply.result, isNull);
      expect(state.plan.superseded, isTrue);
    });

    test('an abort with no receipt leaves the plan alone', () async {
      // The other side of the same rule. abctl prints its receipt before exiting, so a run that
      // produced none stopped before writing — and the plan on screen is still true. Marking it
      // superseded here would train the reader to ignore the banner that matters.
      final container = _containerFor((args) async {
        if (args.first != 'sync') return _ok('{"configs":[],"blueprints":[]}');
        return _exit(1, 'Error: no gitops/ directory');
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);
      await store.refreshPlan();

      await store.applyPlan(const ApplyOptions.gitAuthoritative());

      final state = container.read(gitopsProvider);
      expect(state.apply.verdict, ApplyVerdict.failed);
      expect(state.plan.superseded, isFalse);
      expect(state.apply.failure?.headline, contains('no gitops/ directory'));
    });

    // -------------------------------------------------------------------------------------
    // Rule 4 and rule 5 — the two guards a disabled button is not.
    // -------------------------------------------------------------------------------------

    test('a refused second apply does not erase the state of the one still writing', () async {
      // REGRESSION. Rule 4 refused a concurrent apply by calling `_refuseApply`, which builds
      // `const ApplyState().aborted(…)` — isRunning:false, startedAt:null, interrupted:false.
      // For every OTHER refusal that is correct; for this one it replaced a run that was at
      // that moment executing `sync --apply --yes --prune` against a live tenant. The
      // consequences were all on the screen the operator was watching: the verdict banner said
      // "Nothing was applied" over a running write, `PopScope(canPop: !apply.isRunning)` let
      // Escape close the sheet, and the Cancel button — the ONLY control in the app that
      // reaches `_applyCancel`, since the shell's run strip deliberately excludes the apply —
      // disappeared for the rest of the run.
      final gate = Completer<void>();
      final container = _containerFor((args) async {
        if (args.first != 'sync') return _ok('{"configs":[],"blueprints":[]}');
        await gate.future;
        return _ok(
          '{"configs":{"outcomes":[],"writes":2,"errors":0,"skipped":0},'
          '"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}',
        );
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);
      await store.refreshPlan();

      final Future<void> first = store.applyPlan(
        const ApplyOptions.gitAuthoritative(),
      );
      // Let the run get past `state.apply.started(...)` and into the awaited process.
      await Future<void>.delayed(Duration.zero);
      expect(container.read(gitopsProvider).apply.isRunning, isTrue);
      final DateTime? startedAt = container
          .read(gitopsProvider)
          .apply
          .startedAt;
      expect(startedAt, isNotNull);

      // The second press, while the first is mid-write.
      await store.applyPlan(const ApplyOptions.gitAuthoritative());

      final ApplyState during = container.read(gitopsProvider).apply;
      expect(
        during.isRunning,
        isTrue,
        reason: 'the write is still in flight and the sheet must still say so',
      );
      expect(
        during.verdict,
        ApplyVerdict.running,
        reason: 'never "failed": that is a claim the tenant is untouched',
      );
      expect(
        during.startedAt,
        startedAt,
        reason: 'the elapsed reading counts from the run, not from the refusal',
      );
      expect(
        store.canCancelWork,
        isTrue,
        reason: 'and the kill switch is still reachable',
      );

      gate.complete();
      await first;
      final ApplyState after = container.read(gitopsProvider).apply;
      expect(after.verdict, ApplyVerdict.applied);
      expect(after.startedAt, startedAt);
    });

    test('one apply per plan: a repeat is refused until the plan is recomputed', () async {
      // REGRESSION. "One apply per dialog" was enforced only by `ApplyDialog` disabling its
      // button on the next frame, so two activations of the captured `onPressed` closure — a
      // double-click, an accessibility `activate`, a synthesized tap — ran `sync --apply` twice
      // against the tenant from one typed confirmation. `create config` has had the equivalent
      // guard since it shipped; the one verb that can DELETE production profiles had none, in a
      // store whose own doc says that safety which depends on every caller remembering is not
      // guarded at all.
      final ran = <List<String>>[];
      final container = _containerFor((args) async {
        ran.add(args);
        if (args.first != 'sync') {
          return _ok(
            '{"configs":[{"name":"VPN","action":"delete-abm","detail":""}]}',
          );
        }
        return _ok(
          '{"configs":{"outcomes":[],"writes":1,"errors":0,"skipped":0},'
          '"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}',
        );
      });
      final store = container.read(gitopsProvider.notifier);
      await store.setWorkspace(_workspace().path);
      await store.refreshPlan();

      await store.applyPlan(const ApplyOptions.gitAuthoritative());
      expect(ran.where((args) => args.first == 'sync'), hasLength(1));

      await store.applyPlan(const ApplyOptions.gitAuthoritative());

      expect(
        ran.where((args) => args.first == 'sync'),
        hasLength(1),
        reason: 'the second approval was never given — it was the same one',
      );
      expect(
        container.read(gitopsProvider).apply.failure?.details,
        contains('Recompute the plan first'),
      );

      // And the way back is the recompute, which publishes a new Plan object.
      await store.refreshPlan();
      await store.applyPlan(const ApplyOptions.gitAuthoritative());
      expect(
        ran.where((args) => args.first == 'sync'),
        hasLength(2),
        reason: 'a freshly computed plan is a fresh decision',
      );
    });

    test('a pre-flight refusal does not count as an apply', () async {
      // The other direction of the same guard, and the reason it keys off `startedAt` rather
      // than "the apply state is terminal": a refusal builds a terminal-looking `ApplyState`
      // too. Keying off terminality alone would let one refusal — no workspace chosen, say —
      // disable Apply for the rest of the session.
      final ran = <List<String>>[];
      final container = _containerFor((args) async {
        ran.add(args);
        return _ok('{"configs":[],"blueprints":[]}');
      });
      final store = container.read(gitopsProvider.notifier);

      // No workspace yet: refused.
      await store.applyPlan(const ApplyOptions.gitAuthoritative());
      expect(container.read(gitopsProvider).apply.verdict, ApplyVerdict.failed);
      expect(container.read(gitopsProvider).apply.didRun, isFalse);

      await store.setWorkspace(_workspace().path);
      await store.refreshPlan();
      await store.applyPlan(const ApplyOptions.gitAuthoritative());

      expect(
        ran.where((args) => args.first == 'sync'),
        hasLength(1),
        reason: 'the refusal must not have locked the button',
      );
    });

    test('a plan or a seed started during an apply is refused, not run', () async {
      // REGRESSION. A plan, a seed and an apply share ONE `ProgressSink` and ONE run log.
      // `refreshPlan` calls `sink.clear()` and `_openRunLog`, which closes the previous log
      // stamped "superseded by a new run" — so a plan started during an apply wiped the apply's
      // live transcript, closed its log file, and made the apply's own `finally` skip its footer
      // because `identical(_runLog, log)` had become false. The apply would then snapshot
      // `sink.lines.value` — by then the PLAN's narration — into `ApplyState.transcript` and
      // hand it to `SyncFailure.fromApplyResult`: another command's output filed as the receipt
      // for a live tenant write. Unreachable through the UI today, which is exactly why it
      // belongs in the store: it rested entirely on `ApplyDialog` staying app-modal.
      final gate = Completer<void>();
      final ran = <List<String>>[];
      final container = _containerFor((args) async {
        ran.add(args);
        if (args.first != 'sync') return _ok('{"configs":[],"blueprints":[]}');
        await gate.future;
        return _ok(
          '{"configs":{"outcomes":[],"writes":1,"errors":0,"skipped":0},'
          '"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}',
        );
      });
      final store = container.read(gitopsProvider.notifier);
      final Directory workspace = _workspace();
      await store.setWorkspace(workspace.path);
      await store.refreshPlan();
      final int reads = ran.length;

      final Future<void> applying = store.applyPlan(
        const ApplyOptions.gitAuthoritative(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(gitopsProvider).apply.isRunning, isTrue);

      await store.refreshPlan();
      final bool seeded = await store.seedWorkspace(
        consent: SeedConsent.overwriteExistingTree,
      );

      expect(seeded, isFalse);
      expect(
        ran.length,
        reads + 1,
        reason: 'only the sync itself was spawned during the apply',
      );
      expect(
        container.read(gitopsProvider).plan.error,
        contains('writing to Apple Business right now'),
      );
      expect(
        container.read(gitopsProvider).seed.error,
        contains('rewrite that tree underneath it'),
      );
      // And the apply's own state is untouched by either refusal.
      expect(container.read(gitopsProvider).apply.isRunning, isTrue);

      gate.complete();
      await applying;
      expect(
        container.read(gitopsProvider).apply.verdict,
        ApplyVerdict.applied,
      );
    });

    test(
      'stdout that is JSON but not a receipt is unknown, never "applied 0 changes"',
      () async {
        // REGRESSION. `ApplyResult.fromJson` defaults BOTH phases to empty when their keys are
        // missing — deliberately, so half a receipt still renders — and the client accepted any
        // `Map` as a receipt. Together that manufactured a clean verdict out of nothing: exit 0
        // plus a document of the wrong shape decoded to zero writes, zero errors and no failure,
        // the banner read "Applied 0 change(s)", and `plan.superseded` stayed false so the Diff
        // rows kept claiming to describe the current tenant. A version skew that changes the
        // receipt's SHAPE while keeping it JSON is the exact case `AbctlDecodeError`'s wording
        // is written for, and it was the one case that could not reach it.
        final container = _containerFor((args) async {
          if (args.first != 'sync') {
            return _ok('{"configs":[],"blueprints":[]}');
          }
          return _ok('{"error":"unsupported --json schema","version":"9"}');
        });
        final store = container.read(gitopsProvider.notifier);
        await store.setWorkspace(_workspace().path);
        await store.refreshPlan();

        await store.applyPlan(const ApplyOptions.gitAuthoritative());

        final ApplyState apply = container.read(gitopsProvider).apply;
        expect(
          apply.verdict,
          ApplyVerdict.unknown,
          reason:
              'we cannot read what it did, which is not the same as "it did nothing"',
        );
        expect(apply.result, isNull);
        expect(apply.failure?.kind, SyncFailureKind.unreadable);
      },
    );

    test(
      'a NON-ZERO exit with an unreadable body reports abctl, not the shape',
      () async {
        // The companion rule: the shape check must not swallow abctl's own account of a failure.
        // `checkExit` runs first for a body that is not a receipt, so a failed run still shows the
        // stderr an operator can act on rather than abgui complaining about JSON keys.
        final container = _containerFor((args) async {
          if (args.first != 'sync') {
            return _ok('{"configs":[],"blueprints":[]}');
          }
          return AbctlResult(
            stdout: Uint8List.fromList(utf8.encode('{"error":"bad token"}')),
            stderr: 'Error: credentials are not set for context "prod"',
            code: 1,
          );
        });
        final store = container.read(gitopsProvider.notifier);
        await store.setWorkspace(_workspace().path);
        await store.refreshPlan();

        await store.applyPlan(const ApplyOptions.gitAuthoritative());

        final ApplyState apply = container.read(gitopsProvider).apply;
        expect(apply.verdict, ApplyVerdict.failed);
        expect(apply.failure?.headline, contains('credentials are not set'));
      },
    );
  });
}

/// Overrides the PROCESS seam and nothing above it, so the recording runner, the command log, the
/// redaction and the transcript wiring are all the app's real ones — the parts a client-level
/// override would quietly skip.
ProviderContainer _containerFor(
  Future<AbctlResult> Function(List<String> args) handler,
) {
  final container = ProviderContainer(
    overrides: <Override>[
      abctlRunnerFactoryProvider.overrideWithValue(
        ({void Function(String line)? onStderrLine}) =>
            _ScriptedRunner(handler, onStderrLine),
      ),
      runLogOpenerProvider.overrideWithValue((header) async => null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A workspace with a `gitops/` tree — what abctl calls a workspace.
Directory _workspace() {
  final root = _tempDir();
  Directory('${root.path}${Platform.pathSeparator}gitops').createSync();
  return root;
}

Directory _tempDir() {
  final directory = Directory.systemTemp.createTempSync('abgui_state_');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

/// Stands in for `ProcessRunner`: it answers from the script and, like the real one, narrates on
/// stderr only when it was given somewhere to narrate — which is how the silent path proves it is
/// silent rather than merely quiet on this particular script.
class _ScriptedRunner implements AbctlRunner {
  const _ScriptedRunner(this.handler, this.onStderrLine);

  final Future<AbctlResult> Function(List<String> args) handler;
  final void Function(String line)? onStderrLine;

  static const String narration = 'abctl: 1/3 configurations';

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) {
    onStderrLine?.call(narration);
    return handler(args);
  }
}

AbctlResult _ok(String stdout) => AbctlResult(
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: '',
  code: 0,
);

AbctlResult _exit(int code, String stderr) =>
    AbctlResult(stdout: Uint8List(0), stderr: stderr, code: code);
