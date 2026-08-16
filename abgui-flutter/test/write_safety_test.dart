// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// THE WRITE BATTERY. Seven invariants, one group each, every test named after the rule it
// defends — so a failure here explains itself without anyone having to reconstruct why the
// assertion was written.
//
// These verbs change a live Apple Business Manager tenant belonging to a real company. Every
// other phase of this port could be fixed in a follow-up; a bug in this one deletes production
// configuration profiles. So the rules below are not style: each is the residue of something
// that already went wrong, in the Swift app or on a real tenant, and each is encoded
// STRUCTURALLY first (a type, or a single choke point) and pinned here second. When a test and
// an intuition disagree here, the test wins.
//
// The pure argv shapes live in abctl_args_contract_test.dart. What is asserted HERE is the
// half a pure builder cannot prove: that the client calls those builders, that the preview a
// dialog would render is byte-for-byte the command that runs, that a document is decoded
// before an exit code is judged, and that a half-applied write cannot be reported as a clean
// one.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/abctl_client.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/write_outcome.dart';
import 'package:abgui/src/state/gitops_store.dart' show GitopsState;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // =========================================================================================
  // INVARIANT 1 — --prune is not a caller's boolean.
  // =========================================================================================
  //
  // `--prune` is what lets a reconcile DELETE a configuration and DETACH a member from a live
  // tenant. In the Swift app it was a `Bool` threaded from ApplySheet's checkbox into
  // `AppModel.apply`, and the rule "git-as-truth implies prune" was written out twice — once
  // in the model, once in the sheet's preview expression — so either copy could change alone
  // and the preview would quietly stop describing the run. Here it is not an argument at all:
  // [ApplyOptions] has no public constructor that takes it, and the flag is derived inside the
  // one builder that spells it.
  group('invariant 1: --prune is decided by ApplyOptions, never by a caller', () {
    test('--prune is emitted only for the option states that mean removals', () {
      // The complete set of reachable states, which is what makes this exhaustive rather than
      // a sample: there are exactly three constructors, and no other way to build the value.
      const additive = ApplyOptions.additive();
      const additiveWithDeletes = ApplyOptions.additiveAllowingDeletes();
      const gitAsTruth = ApplyOptions.gitAuthoritative();

      expect(additive.prune, isFalse);
      expect(AbctlArgs.syncApply(additive), isNot(contains('--prune')));

      expect(additiveWithDeletes.prune, isTrue);
      expect(AbctlArgs.syncApply(additiveWithDeletes), contains('--prune'));

      expect(gitAsTruth.prune, isTrue);
      expect(AbctlArgs.syncApply(gitAsTruth), contains('--prune'));
    });

    test('git-as-truth cannot be applied WITHOUT --prune', () {
      // The fourth combination — git is the complete desired state, but removals are off — is
      // deliberately unrepresentable. It would half-apply a desired state: everything git adds
      // lands, nothing git dropped goes away, and the next plan proposes the same removals
      // forever. There is no constructor that produces it, and `prune` has no setter, so this
      // sweep over every option state is the whole proof.
      for (final options in _everyApplyOptionState()) {
        if (!options.gitSourceOfTruth) continue;
        expect(
          options.prune,
          isTrue,
          reason: 'git-as-truth without prune is not a mode: $options',
        );
        expect(AbctlArgs.syncApply(options), contains('--prune'));
      }
    });

    test('the option value is the ONLY input the argv builder has', () {
      // `syncApply` takes one parameter. A future flag added as a second boolean would break
      // this line, which is the point: the type is where an apply option belongs, because the
      // type is what a preview and a run can share without either re-deriving anything.
      for (final options in _everyApplyOptionState()) {
        expect(
          AbctlArgs.syncApply(options),
          AbctlArgs.syncApply(options),
          reason:
              'the builder must be a pure function of the options: $options',
        );
      }
    });

    test('no code outside the argv builder can hold or pass a prune flag', () {
      // The scan that makes this structural rather than aspirational: a per-builder check only
      // covers builders someone remembered to list, while this reads every non-comment line in
      // lib/. Three shapes are forbidden outside abctl_args.dart, and between them they cover
      // every way the Swift arrangement could come back:
      //
      //   * the FLAG itself — a second place that spells `--prune`;
      //   * a prune-shaped ARGUMENT (`prune:`) — the checkbox wired straight through;
      //   * a prune-shaped FIELD (`bool prune`) — a view or store holding its own copy.
      //
      // The English word is deliberately NOT forbidden: `RunLog.prune` deletes old log files
      // and `_pruneSelection` drops table rows, and a rule that could not tell those from the
      // reconcile flag would be turned off the first time it fired on one of them.
      final forbidden = <String, RegExp>{
        'the flag': RegExp(r'--prune'),
        'a prune argument': RegExp(r'\bprune\s*:'),
        'a prune field': RegExp(r'\bbool\s+\w*[Pp]rune\b'),
      };
      final strays = <String>[];
      for (final entry in Directory('lib').listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        if (entry.path.endsWith('abctl_args.dart')) continue;
        for (final line in _strippedLines(entry)) {
          forbidden.forEach((what, pattern) {
            if (pattern.hasMatch(line)) {
              strays.add('${entry.path} has $what: ${line.trim()}');
            }
          });
        }
      }
      expect(
        strays,
        isEmpty,
        reason:
            'prune must be decided only by ApplyOptions inside abctl_args.dart '
            '— anywhere else is a second place it can be turned on: $strays',
      );
    });

    test('only ONE default in lib/ can turn --prune on without saying "prune"', () {
      // The hole the scan above cannot see, found by audit and closed here rather than argued
      // away. `--prune` is derived from `ApplyOptions`, and `ApplyOptions.gitAuthoritative` is
      // chosen by `ApplyDialog` whenever `GitopsState.gitSourceOfTruth` is true — which it is BY
      // DEFAULT (`gitops_store.dart`). So the app's default state applies with `--prune`, and
      // none of the three forbidden patterns above match a `bool gitSourceOfTruth = true`:
      // `ApplyDialog._policy`'s documented "safe default" is unreachable in that configuration,
      // and so is `ApplyOptions.additive`.
      //
      // That default is FAITHFUL — abctl forces prune for `--apply --git-source-of-truth`
      // (`internal/cli/phase1.go`), and Swift's `AppModel.gitSourceOfTruth` defaults the same
      // way — so it is kept. What is not acceptable is it being invisible. This asserts there is
      // exactly one place in lib/ that can set it, so a second default cannot appear in a view
      // and quietly arm removals from somewhere nobody looks; the widget test
      // `the app default state applies with --prune, and says so before it does` pins the
      // resulting argv and the gate that stands in front of it.
      final setters = <String>[];
      final pattern = RegExp(r'\bgitSourceOfTruth\s*[:=]\s*true\b');
      for (final entry in Directory('lib').listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        for (final line in _strippedLines(entry)) {
          if (pattern.hasMatch(line)) setters.add(entry.path);
        }
      }
      expect(
        setters.map((path) => path.split(Platform.pathSeparator).last).toSet(),
        <String>{'gitops_store.dart'},
        reason:
            'the one default that arms removals without spelling "prune" lives in the store '
            'and nowhere else: $setters',
      );
      // And the store's own default is the one the dialog and the argv builder agree about.
      expect(const GitopsState().gitSourceOfTruth, isTrue);
      expect(
        AbctlArgs.syncApply(const ApplyOptions.gitAuthoritative()),
        contains('--prune'),
      );
    });
  });

  // =========================================================================================
  // INVARIANT 2 — previewed argv IS executed argv.
  // =========================================================================================
  //
  // A gated write asks an administrator to approve a command. If the dialog renders anything
  // other than the list the client hands the process, the approval was collected for something
  // the operator never saw. So there is one function ([AbctlArgs.preview], which
  // `AbctlClient.previewArgv` is and which `AbctlClient` runs), and the assertion is byte
  // identity of the RENDERED line — not just of the token lists, because the rendering is what
  // the human actually reads.
  group('invariant 2: what a dialog shows is what the client runs', () {
    test('every write verb previews the exact argv it executes', () async {
      for (final entry in _everyWriteVerb().entries) {
        final runner = _FakeRunner(stdout: _anyOutcomeJson);
        final client = AbctlClient(
          runner: runner,
          context: 'prod',
          workspace: '/work/ws',
        );

        await entry.value.call(client);

        // What a confirmation sheet would draw, built the only way it can be: the builder's
        // output through preview, then through the one formatter that turns argv into text.
        final previewed = AbctlArgs.preview(entry.value.argv, context: 'prod');
        final shown = CommandFormatter.line(previewed);
        final ran = CommandFormatter.line(runner.argv);

        expect(
          runner.argv,
          previewed,
          reason: '${entry.key}: previewed $previewed but ran ${runner.argv}',
        );
        expect(
          shown,
          ran,
          reason: '${entry.key}: shown "$shown" but ran "$ran"',
        );
      }
    });

    test('a preview built without a context matches a run without one', () {
      // ContractTests.testPreviewArgvThreadsTheContextExactlyLikeTheRun. An unset context
      // means "abctl's own current context", so the flag must be ABSENT rather than empty:
      // `--context ''` is not what runs and would not work, and a preview that showed it would
      // teach a broken command to whoever copied it.
      for (final entry in _everyWriteVerb().entries) {
        expect(
          AbctlArgs.preview(entry.value.argv),
          isNot(contains('--context')),
          reason: entry.key,
        );
        expect(
          AbctlArgs.preview(entry.value.argv, context: ''),
          entry.value.argv,
          reason: entry.key,
        );
      }
    });

    test('previewArgv on the client is the same function, not a copy', () {
      // The client's own preview seam. Two implementations of "append the context" is how a
      // preview starts naming a different tenant than the run does.
      const client = AbctlClient(runner: _NullRunner(), context: 'prod');
      for (final entry in _everyWriteVerb().entries) {
        expect(
          client.previewArgv(entry.value.argv),
          AbctlArgs.preview(entry.value.argv, context: 'prod'),
          reason: entry.key,
        );
      }
    });

    test('the whole apply option matrix previews what it runs', () async {
      // ContractTests.testSyncApplyPreviewIsTheArgvThatActuallyRuns, across every option state
      // a sheet can produce — including a limit of 0, which the run path drops as "unlimited"
      // and which a preview must therefore not advertise as a circuit breaker.
      for (final options in _everyApplyOptionState()) {
        final runner = _FakeRunner(stdout: _anyOutcomeJson);
        final client = AbctlClient(runner: runner, context: 'prod');

        await client.syncApply(options);

        expect(runner.argv.first, 'sync', reason: '$options');
        expect(
          runner.argv,
          AbctlArgs.preview(AbctlArgs.syncApply(options), context: 'prod'),
          reason: 'preview drifted from execution for $options',
        );
        if (!options.limitsWrites) {
          expect(
            runner.argv,
            isNot(contains('--limit-writes')),
            reason: 'an unarmed breaker must not be advertised: $options',
          );
        }
      }
    });
  });

  // =========================================================================================
  // INVARIANT 3 — decode before exit code.
  // =========================================================================================
  //
  // `sync --apply --json` prints the COMPLETE per-item receipt and THEN returns `ExitError{1}`
  // (internal/cli/phase1.go), for which cmd/abctl/main.go exits SILENTLY. `validate --json`
  // does the same whenever the report says `ok:false`. Checking the exit code first threw the
  // structured truth away and raised a CLI error carrying whatever was on stderr — a hundred
  // lines of "building plan: …" narration presented as "the error", with the per-item outcomes
  // of a PARTIALLY APPLIED tenant write discarded.
  group('invariant 3: stdout is decoded before the exit code is judged', () {
    test('sync --apply keeps the receipt when abctl exits non-zero', () async {
      final runner = _FakeRunner(
        code: 1,
        stderr:
            'building plan: fetching configurations\n'
            'applying config WiFi-Corp.mobileconfig\n',
        stdout:
            '{"configs":{"outcomes":['
            '{"name":"WiFi-Corp.mobileconfig","action":"update","status":"done","detail":"PATCH"},'
            '{"name":"VPN.mobileconfig","action":"update","status":"error","detail":"403 FORBIDDEN"}'
            '],"writes":1,"errors":1,"skipped":0},'
            '"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}',
      );

      final run = await AbctlClient(
        runner: runner,
      ).syncApply(const ApplyOptions.additive());

      // The half that used to be thrown away: which items failed, and why.
      expect(run.result.rows, hasLength(2));
      expect(run.result.totalWrites, 1);
      expect(run.result.totalErrors, 1);
      expect(
        run.result.rows.where((r) => r.failed).single.detail,
        '403 FORBIDDEN',
      );
      // …and the half that must survive alongside it, because a receipt in which every item
      // says `done` can still accompany a non-zero exit (post-apply verification).
      expect(run.code, 1);
      expect(run.stderr, contains('building plan'));
    });

    test('a decodable document that is not a RECEIPT is not a clean apply', () async {
      // REGRESSION, and the nastiest of the set because it fails in the green direction.
      // `syncApply` accepted any `Map` as the receipt, and `ApplyResult.fromJson` defaults BOTH
      // phases to empty when their keys are missing — deliberately, so half a receipt still
      // renders. Together those two tolerances manufactured a success out of a document that
      // says nothing: exit 0 plus `{"error":…}` decoded to zero writes, zero errors, no failure,
      // and `ApplyState.verdict` answered `applied` while the banner read "Applied 0 change(s)".
      //
      // A version skew that changes the receipt's SHAPE while keeping it JSON is exactly what
      // `AbctlDecodeError`'s message is written for ("the app and the embedded CLI may not
      // match"), and it was the one case that could never reach it — `unreadable` was only
      // reachable when stdout was not JSON at all.
      //
      // The check is structural, not a content guess: `finishApply`
      // (internal/cli/phase1.go) builds `{"configs": …, "blueprints": …}` on EVERY `--json` exit
      // path, including the one that renders a receipt and then returns a non-zero cause.
      final runner = _FakeRunner(
        stdout: '{"error":"unsupported --json schema","version":"9"}',
      );

      await expectLater(
        AbctlClient(runner: runner).syncApply(const ApplyOptions.additive()),
        throwsA(
          isA<AbctlDecodeError>().having(
            (e) => e.message,
            'message',
            contains('did not print a result document'),
          ),
        ),
      );
    });

    test('half a receipt is still a receipt', () async {
      // The tolerance the check must NOT undo. abctl emits both keys, but a build that lost one
      // still carries the other's rows, and half a receipt beats an exception thrown at the end
      // of a real tenant write. So the shape test asks for EITHER key, never both.
      final runner = _FakeRunner(
        code: 1,
        stdout:
            '{"configs":{"outcomes":['
            '{"name":"VPN.mobileconfig","action":"update","status":"error","detail":"403"}'
            '],"writes":0,"errors":1,"skipped":0}}',
      );

      final run = await AbctlClient(
        runner: runner,
      ).syncApply(const ApplyOptions.additive());

      expect(run.result.rows, hasLength(1));
      expect(run.result.totalErrors, 1);
      expect(run.code, 1);
    });

    test(
      'a non-receipt on a FAILED run reports abctl, not the JSON shape',
      () async {
        // Ordering: the shape complaint must never displace abctl's own account of a failure. A
        // non-zero exit whose stdout is not a receipt goes through `checkExit` first, so the
        // operator gets the sentence they can act on.
        final runner = _FakeRunner(
          code: 1,
          stdout: '{"error":"bad token"}',
          stderr: 'Error: credentials are not set for context "prod"',
        );

        await expectLater(
          AbctlClient(runner: runner).syncApply(const ApplyOptions.additive()),
          throwsA(
            isA<AbctlCliError>().having(
              (e) => e.message,
              'message',
              contains('credentials are not set'),
            ),
          ),
        );
      },
    );

    test('validate keeps the report when abctl exits non-zero', () async {
      // ContractTests.testValidateReportOnExitOneStillReturns — the same rule, and the reason
      // it was already needed before any write verb existed: a failing report is the LIST OF
      // FILES TO FIX, not an error string.
      final runner = _FakeRunner(
        code: 1,
        stderr: 'Error: validation failed',
        stdout:
            '{"ok":false,"libDir":"gitops/lib","checked":2,"passed":1,'
            '"failed":1,"warnings":0,"profiles":[{"file":"VPN.mobileconfig",'
            '"ok":false,"issues":[{"severity":"error","message":"no PayloadUUID"}]}],'
            '"treeIssues":[],"validator":"built-in"}',
      );

      final report = await AbctlClient(runner: runner).validateProfiles();

      expect(report.ok, isFalse);
      expect(report.failed, 1);
      expect(report.profiles, hasLength(1));
    });

    test('a run with no document at all still reports abctl own words', () async {
      // The other half of the rule: decode-first must not swallow a run that never applied
      // anything. Nothing decodable on stdout means abctl died before it wrote a receipt (bad
      // credentials, no gitops/ tree, an Apple 403 while planning), and abctl's stderr is then
      // the only account of what happened — better than anything abgui could paraphrase.
      final runner = _FakeRunner(
        code: 1,
        stdout: 'building plan: fetching configurations\n',
        stderr: 'Error: no gitops/ directory in /work/ws',
      );

      await expectLater(
        AbctlClient(runner: runner).syncApply(const ApplyOptions.additive()),
        throwsA(
          isA<AbctlCliError>().having(
            (e) => e.message,
            'message',
            contains('no gitops/ directory'),
          ),
        ),
      );
    });
  });

  // =========================================================================================
  // INVARIANT 4 — --yes on every gated write except adopt.
  // =========================================================================================
  //
  // Without `--yes` abctl prompts on a terminal that is not there, the child never exits, and
  // abgui's watchdog kills it after the budget — which the UI reports as a timeout, i.e. as
  // something indistinguishable from a blocked network or a slow tenant. The operator then
  // debugs their VPN for an hour over a missing flag.
  group('invariant 4: every gated write carries --yes, and adopt carries none', () {
    test('each write verb gates exactly as its tenant impact demands', () async {
      // Per verb, not "most of them": the failure mode is silent and each verb reaches abctl
      // by a different path.
      const gatedByVerb = <String, bool>{
        'sync --apply (additive)': true,
        'sync --apply (git-as-truth)': true,
        'create config': true,
        'replace config': true,
        'delete config': true,
        'attach config': true,
        'detach config': true,
        'assign devices': true,
        'unassign devices': true,
        // Local file writes. There is no tenant change to confirm, and a gate on them would
        // teach an operator to read a tenant-write confirmation as routine paperwork.
        'adopt member': false,
        'seed': false,
      };

      for (final entry in _everyWriteVerb().entries) {
        final expected = gatedByVerb[entry.key];
        expect(
          expected,
          isNotNull,
          reason:
              '${entry.key} is a write verb with no gating rule — decide '
              'whether it changes the tenant before it ships',
        );

        final runner = _FakeRunner(stdout: _anyOutcomeJson);
        await entry.value.call(AbctlClient(runner: runner));

        expect(
          runner.argv.contains('--yes'),
          expected,
          reason: '${entry.key}: ${runner.argv}',
        );
      }
    });

    test('adopt is ungated because it never touches the tenant', () async {
      // ContractTests.testAdoptArgvIsLocalOnly. Also pins the positional shape: the member
      // COLLECTION is the first argument, which is what makes `adopt user ada@example.com`
      // different from `adopt config ada@example.com`.
      final runner = _FakeRunner(stdout: _anyOutcomeJson);
      await AbctlClient(runner: runner, workspace: '/work/ws').adoptMember(
        kind: AbctlMemberKind.config,
        name: 'WiFi.mobileconfig',
        blueprint: 'Fleet',
      );

      expect(runner.argv.take(5), [
        'adopt',
        'config',
        'WiFi.mobileconfig',
        '--blueprint',
        'Fleet',
      ]);
      expect(runner.argv, isNot(contains('--yes')));
    });
  });

  // =========================================================================================
  // INVARIANT 5 — exit 3 is not a failure.
  // =========================================================================================
  //
  // 3 is abctl's "changes pending" verdict: drift between git and the tenant. It is a NORMAL
  // state to render, and a consumer that paints it red trains users to ignore error banners.
  group('invariant 5: exit 3 means changes pending and never becomes a failure', () {
    test('the exit mapping gives 3 its own case, apart from every error', () {
      // ContractTests.testExitCodeMapping. `changesPending` is a distinct type rather than an
      // error carrying a code, precisely so a `switch` cannot lump it in with a real failure.
      expect(
        () => AbctlError.checkExit(code: 3, stderr: ''),
        throwsA(isA<AbctlChangesPending>()),
      );
      expect(
        () => AbctlError.checkExit(code: 1, stderr: 'boom'),
        throwsA(isA<AbctlCliError>()),
      );
      expect(
        () => AbctlError.checkExit(code: 2, stderr: 'unknown flag'),
        throwsA(isA<AbctlUsageError>()),
      );
      expect(() => AbctlError.checkExit(code: 0, stderr: ''), returnsNormally);
    });

    test('a result carrying 3 says so in its own words', () {
      final pending = AbctlResult(stdout: Uint8List(0), stderr: '', code: 3);
      expect(pending.changesPending, isTrue);
      expect(pending.isSuccess, isFalse);
    });

    test('a sync that exits 3 with a receipt is data, not an error', () {
      // The strongest form of the rule on the write path: decode-first means a code-3 apply
      // comes back as a document with a code attached, so nothing between here and the UI has
      // an opportunity to turn drift into breakage.
      final runner = _FakeRunner(code: 3, stdout: _anyOutcomeJson);

      expect(
        AbctlClient(runner: runner).syncApply(const ApplyOptions.additive()),
        completion(isA<ApplyRun>().having((run) => run.code, 'code', 3)),
      );
    });

    test('the console hands 3 back untouched', () async {
      // `abctl diff --exit-on-diff` returning 3 is the plainest example of a non-zero exit
      // that is a RESULT: the console maps no exit code at all, by design.
      final runner = _FakeRunner(code: 3, stdout: '{}');
      final result = await AbctlClient(
        runner: runner,
      ).console(const ['diff', '--exit-on-diff']);

      expect(result.code, 3);
      expect(result.changesPending, isTrue);
    });
  });

  // =========================================================================================
  // INVARIANT 6 — a write's success is the OUTCOME document, not the exit code.
  // =========================================================================================
  //
  // abctl emits the outcome document only when the TENANT write succeeded, and exits 0 for it
  // — including when the local `gitops/` half then failed. `treeUpdated:false` therefore
  // arrives on a run that looks entirely clean from the outside. It used to be reported as
  // true unconditionally, which is how a green attach left git untouched and the operator only
  // found out as a drift row, later, with no way to connect the two.
  group('invariant 6: a tenant write that missed git is surfaced, not swallowed', () {
    test('treeUpdated:false comes back as a warning on a zero-exit run', () async {
      const treeError = 'mkdir /gitops/blueprints: read-only file system';
      final runner = _FakeRunner(
        stdout:
            '{"action":"attach","name":"WiFi.mobileconfig","id":"c1",'
            '"status":"done","blueprint":"Fleet","treeUpdated":false,'
            '"treeError":"$treeError"}',
      );

      final outcome = await AbctlClient(
        runner: runner,
        workspace: '/work/ws',
      ).attachConfiguration(configId: 'c1', blueprint: 'Fleet');

      // Exit 0, status "done" — everything the exit code can tell you says success.
      expect(outcome.status, 'done');
      expect(outcome.treeUpdated, isFalse);
      // …and the document says otherwise, in a sentence a banner can show verbatim.
      expect(outcome.treeWarning, isNotNull);
      expect(outcome.treeWarning, contains('read-only file system'));
      expect(outcome.treeWarning, contains('drift'));
    });

    test('every tenant write hands back the document rather than a bool', () async {
      // A method returning `Future<void>` or `Future<bool>` is how "done" gets said: there is
      // nothing left to inspect. Each verb that can report a tree gap must return the outcome.
      const half =
          '{"action":"attach","name":"WiFi.mobileconfig","id":"c1",'
          '"status":"done","treeUpdated":false,"treeError":"disk full"}';
      final calls = <String, Future<WriteOutcome> Function(AbctlClient)>{
        'create': (c) =>
            c.createConfiguration(name: 'WiFi', xml: utf8.encode('<plist/>')),
        'replace': (c) =>
            c.replaceConfiguration(id: 'c1', xml: utf8.encode('<plist/>')),
        'delete': (c) => c.deleteConfiguration('c1'),
        'attach': (c) =>
            c.attachConfiguration(configId: 'c1', blueprint: 'Fleet'),
        'detach': (c) =>
            c.detachConfiguration(configId: 'c1', blueprint: 'Fleet'),
        'adopt': (c) => c.adoptMember(
          kind: AbctlMemberKind.config,
          name: 'WiFi.mobileconfig',
          blueprint: 'Fleet',
        ),
      };

      for (final entry in calls.entries) {
        final outcome = await entry.value(
          AbctlClient(
            runner: _FakeRunner(stdout: half),
            workspace: '/work/ws',
          ),
        );
        expect(
          outcome.treeWarning,
          isNotNull,
          reason: '${entry.key} lost the tree gap',
        );
      }
    });

    test('a missing treeUpdated key is read as NOT updated', () async {
      // The conservative direction, and the one the original bug got backwards. An older abctl
      // that omits the field must not be read as "git is fine"; it must be read as "we do not
      // know", which here means the same as false. With no `treeError` there is nothing
      // actionable to say, so the warning stays null — silence, not a false all-clear.
      final runner = _FakeRunner(
        stdout:
            '{"action":"attach","name":"WiFi.mobileconfig","status":"done"}',
      );

      final outcome = await AbctlClient(
        runner: runner,
      ).attachConfiguration(configId: 'c1', blueprint: 'Fleet');

      expect(outcome.treeUpdated, isFalse);
      expect(outcome.treeWarning, isNull);
    });

    test('an assignment reports ACCEPTED, not applied', () async {
      // The same class of over-claim on the device side: Apple processes assignment
      // asynchronously, so a clean exit means the activity was accepted. The id is what
      // `status activity` polls, and it is the only thing that can say the work finished.
      final runner = _FakeRunner(
        stdout:
            '{"action":"assign","server":"Built-in MDM","devices":2,'
            '"activityId":"act-42"}',
      );

      final outcome = await AbctlClient(runner: runner).assignDevices(
        action: AbctlAssignment.assign,
        server: 'Built-in MDM',
        serials: const ['C02AAA', 'C02BBB'],
      );

      expect(outcome.activityID, 'act-42');
      expect(outcome.devices, 2);
      expect(
        outcome.status,
        isNull,
        reason: 'status only exists with --wait, which abgui never passes',
      );
    });
  });

  // =========================================================================================
  // INVARIANT 7 — membership mode follows git-source-of-truth.
  // =========================================================================================
  //
  // `internal/cli/phase1.go`'s `membershipMode(gitSourceOfTruth bool)` maps ONE flag onto both
  // halves of the reconcile: with it, git is the complete desired state (an ABM-only config is
  // deleted, an ABM-only member is detached); without it, sync is additive (an ABM-only config
  // is pulled into git, an ABM-only member is adopted into its manifest). Before that mapping
  // existed the switch governed configs only, and a config attached through Apple's console
  // re-proposed the same detach on every single run.
  group('invariant 7: membership mode is the git-source-of-truth choice', () {
    test('each option state maps to the Go MembershipMode it means', () {
      // The Dart enum mirrors reconcile.MembershipMode exactly: Bidirectional is the default
      // and GitAuthoritative is what --git-source-of-truth selects.
      expect(
        const ApplyOptions.additive().membershipMode,
        AbctlMembershipMode.bidirectional,
      );
      expect(
        const ApplyOptions.additiveAllowingDeletes().membershipMode,
        AbctlMembershipMode.bidirectional,
        reason:
            'allowing deletes is not the same question as who is authoritative '
            '— prune gates the removal, the mode decides whether one is planned',
      );
      expect(
        const ApplyOptions.gitAuthoritative().membershipMode,
        AbctlMembershipMode.gitAuthoritative,
      );
    });

    test('the mode and the flag are one choice, never two', () {
      // `membershipMode` and `gitSourceOfTruth` are two readings of the same field, so they
      // cannot disagree — and the flag appears on argv exactly when the mode says it should.
      for (final options in _everyApplyOptionState()) {
        final gitAuthoritative =
            options.membershipMode == AbctlMembershipMode.gitAuthoritative;
        expect(options.gitSourceOfTruth, gitAuthoritative, reason: '$options');
        expect(
          AbctlArgs.syncApply(options).contains('--git-source-of-truth'),
          gitAuthoritative,
          reason: '$options',
        );
      }
    });

    test('the plan half of the reconcile takes the same flag', () {
      // ContractTests.testPlanArgsIncludeGitSourceOfTruth. `diff` is `sync --dry-run`: an
      // operator who previews under git-as-truth and applies without it (or the reverse) is
      // approving a plan that was never computed. One flag, one meaning, both verbs.
      expect(
        AbctlArgs.plan(gitSourceOfTruth: true),
        contains('--git-source-of-truth'),
      );
      expect(AbctlArgs.plan(), isNot(contains('--git-source-of-truth')));
    });
  });

  // =========================================================================================
  // The two regressions that are not invariants but cost the same either way.
  // =========================================================================================
  group('the workspace cwd and the membership budget', () {
    test('every tree-mutating verb runs in the workspace', () async {
      // ContractTests.testTreeMutatingVerbsRunInTheWorkspace — the "detach-config row that
      // comes back forever" bug. abctl roots gitops/ at its process working directory, so an
      // attach launched from the app bundle's cwd wrote its manifest into a different tree (or
      // none) while `diff` read the real one. The tenant changed, git did not, and the
      // resulting drift row returned on every refresh with nothing in the GUI able to clear
      // it. The failure was silent and per-verb, so the assertions are per-verb too.
      for (final entry in _everyWriteVerb().entries) {
        final runner = _FakeRunner(stdout: _anyOutcomeJson);
        await entry.value.call(
          AbctlClient(runner: runner, workspace: '/work/ws'),
        );
        expect(
          runner.cwd,
          '/work/ws',
          reason:
              '${entry.key} did not run in the workspace — its gitops/ write '
              'lands in the wrong tree',
        );
      }
    });

    test('the membership verbs get more than the read budget', () async {
      // ContractTests.testMembershipVerbsGetMoreThanTheReadBudget. attach/detach/adopt are
      // multi-call on the abctl side (resolve the blueprint, list configurations for the
      // name↔id map, read current members, then write). On the plain 60s read budget `adopt`
      // died mid-flight against a real tenant and left the manifest unwritten, with "abctl ran
      // for 60s" as the only symptom — a timeout that reads exactly like a broken feature.
      final calls = <String, Future<void> Function(AbctlClient)>{
        'attach': (c) =>
            c.attachConfiguration(configId: 'c1', blueprint: 'Fleet'),
        'detach': (c) =>
            c.detachConfiguration(configId: 'c1', blueprint: 'Fleet'),
        'adopt': (c) => c.adoptMember(
          kind: AbctlMemberKind.config,
          name: 'WiFi.mobileconfig',
          blueprint: 'Fleet',
        ),
      };

      for (final entry in calls.entries) {
        final runner = _FakeRunner(stdout: _anyOutcomeJson);
        await entry.value(AbctlClient(runner: runner, workspace: '/work/ws'));
        expect(
          runner.timeout,
          greaterThan(AbctlTimeouts.read),
          reason: '${entry.key} is multi-call and cannot run on the 60s budget',
        );
      }
    });

    test('every configuration write gets more than the read budget too', () async {
      // REGRESSION (PLAUSIBLE→fixed). `create`/`replace`/`delete` took `_writeOutcome`'s
      // `AbctlTimeouts.read` default — faithfully, because the Swift original passed no timeout
      // and inherited its own 60s default. But a `replace` is at least as multi-call as an
      // `adopt`: fetch the live profile, archive it to gitops/archive/, PATCH Apple, rewrite
      // gitops/lib/ and the baseline, then read it back under `--verify`. The test above records
      // what 60s did to `adopt` on a real tenant; the same budget on these three is worse,
      // because `AbctlTimedOut`'s message diagnoses a slow network for a tenant write that has
      // already landed and a git half that may not have.
      //
      // `assign`/`unassign` are here for the same reason and one of their own: abctl walks the
      // WHOLE org device inventory to resolve serials before it POSTs, and a kill after the POST
      // is the one outcome in this app that cannot be established afterwards.
      final calls = <String, Future<void> Function(AbctlClient)>{
        'create': (c) =>
            c.createConfiguration(name: 'WiFi', xml: const <int>[]),
        'replace': (c) => c.replaceConfiguration(id: 'c1', xml: const <int>[]),
        'delete': (c) => c.deleteConfiguration('c1'),
        'assign': (c) => c.assignDevices(
          action: AbctlAssignment.assign,
          server: 'srv-1',
          serials: const <String>['C02AAA'],
        ),
      };

      for (final entry in calls.entries) {
        final runner = _FakeRunner(stdout: _anyOutcomeJson);
        await entry.value(AbctlClient(runner: runner, workspace: '/work/ws'));
        expect(
          runner.timeout,
          AbctlTimeouts.write,
          reason:
              '${entry.key} writes a live tenant and is not a one-call read',
        );
      }
    });

    test('sync --apply gets the tenant-scale budget', () async {
      // ContractTests.testApplyArgsIncludePruneAndLimit asserted this alongside the flags: an
      // apply is the plan, plus every write, plus post-apply verification.
      final runner = _FakeRunner(stdout: _anyOutcomeJson);
      await AbctlClient(
        runner: runner,
      ).syncApply(const ApplyOptions.additive());

      expect(
        runner.timeout,
        greaterThanOrEqualTo(const Duration(seconds: 1200)),
      );
    });

    test('the profile XML travels on stdin, byte for byte', () async {
      // ContractTests.testCreateSendsGatedJSONWithStdin / testReplaceSendsGatedJSONWithStdin.
      // Bytes, not a String: a .mobileconfig is a document abgui only relays, and decoding
      // then re-encoding it is an opportunity to change what Apple stores.
      final xml = utf8.encode('<plist version="1.0"><dict/></plist>');

      final create = _FakeRunner(stdout: _anyOutcomeJson);
      await AbctlClient(
        runner: create,
        workspace: '/work/ws',
      ).createConfiguration(name: 'WiFi', xml: xml);
      expect(create.stdins.single, xml);

      final replace = _FakeRunner(stdout: _anyOutcomeJson);
      await AbctlClient(
        runner: replace,
        workspace: '/work/ws',
      ).replaceConfiguration(id: 'c1', xml: xml);
      expect(replace.stdins.single, xml);

      // A verb with no file argument must not send one — a stray stdin would leave abctl
      // waiting on a pipe that is never written.
      final delete = _FakeRunner(stdout: _anyOutcomeJson);
      await AbctlClient(runner: delete).deleteConfiguration('c1');
      expect(delete.stdins.single, isNull);
    });
  });
}

/// One JSON document that decodes as every write's result shape, so the parity and cwd sweeps
/// can drive the whole verb table through a single fake. The models decode defensively — an
/// absent key is a default — so the extra keys are inert for the verbs that ignore them.
const String _anyOutcomeJson =
    '{"action":"attach","name":"WiFi.mobileconfig","id":"c1","status":"done",'
    '"blueprint":"Fleet","treeUpdated":true,"server":"Built-in MDM",'
    '"devices":1,"activityId":"act-1",'
    '"configs":{"outcomes":[],"writes":0,"errors":0,"skipped":0},'
    '"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}';

/// Every reachable [ApplyOptions] state: the three constructors crossed with the limit values
/// that behave differently (absent, the dropped non-positive one, a real breaker).
///
/// Exhaustive by construction — there is no other way to build the value — which is what lets
/// the prune sweeps above claim to have covered everything rather than a sample.
List<ApplyOptions> _everyApplyOptionState() => const <ApplyOptions>[
  ApplyOptions.additive(),
  ApplyOptions.additive(refresh: AbctlRefresh.full, verify: AbctlVerify.none),
  ApplyOptions.additive(limitWrites: 0),
  ApplyOptions.additive(limitWrites: 5),
  ApplyOptions.additiveAllowingDeletes(),
  ApplyOptions.additiveAllowingDeletes(
    refresh: AbctlRefresh.metadataOnly,
    verify: AbctlVerify.full,
    limitWrites: 1,
  ),
  ApplyOptions.gitAuthoritative(),
  ApplyOptions.gitAuthoritative(
    refresh: AbctlRefresh.full,
    verify: AbctlVerify.none,
    limitWrites: 5,
  ),
];

/// Every write verb, paired with the argv a preview would render for it and the client call
/// that executes it.
///
/// The pairing is the point: a verb whose builder and whose client method disagree fails the
/// parity sweep, and a verb missing from this map fails the gating sweep (which requires a
/// rule per entry) the moment someone adds it.
Map<String, ({List<String> argv, Future<void> Function(AbctlClient) call})>
_everyWriteVerb() =>
    <String, ({List<String> argv, Future<void> Function(AbctlClient) call})>{
      'sync --apply (additive)': (
        argv: AbctlArgs.syncApply(const ApplyOptions.additive()),
        call: (c) => c.syncApply(const ApplyOptions.additive()),
      ),
      'sync --apply (git-as-truth)': (
        argv: AbctlArgs.syncApply(
          const ApplyOptions.gitAuthoritative(limitWrites: 5),
        ),
        call: (c) =>
            c.syncApply(const ApplyOptions.gitAuthoritative(limitWrites: 5)),
      ),
      'seed': (argv: AbctlArgs.seed(), call: (c) => c.seed()),
      'create config': (
        argv: AbctlArgs.createConfiguration('WiFi'),
        call: (c) =>
            c.createConfiguration(name: 'WiFi', xml: utf8.encode('<plist/>')),
      ),
      'replace config': (
        argv: AbctlArgs.replaceConfiguration('c1'),
        call: (c) =>
            c.replaceConfiguration(id: 'c1', xml: utf8.encode('<plist/>')),
      ),
      'delete config': (
        argv: AbctlArgs.deleteConfiguration('c1'),
        call: (c) => c.deleteConfiguration('c1'),
      ),
      'attach config': (
        argv: AbctlArgs.attachConfiguration(configId: 'c1', blueprint: 'Fleet'),
        call: (c) => c.attachConfiguration(configId: 'c1', blueprint: 'Fleet'),
      ),
      'detach config': (
        argv: AbctlArgs.detachConfiguration(configId: 'c1', blueprint: 'Fleet'),
        call: (c) => c.detachConfiguration(configId: 'c1', blueprint: 'Fleet'),
      ),
      'adopt member': (
        argv: AbctlArgs.adoptMember(
          kind: AbctlMemberKind.config,
          name: 'WiFi.mobileconfig',
          blueprint: 'Fleet',
        ),
        call: (c) => c.adoptMember(
          kind: AbctlMemberKind.config,
          name: 'WiFi.mobileconfig',
          blueprint: 'Fleet',
        ),
      ),
      'assign devices': (
        argv: AbctlArgs.assignment(
          action: AbctlAssignment.assign,
          server: 'Built-in MDM',
          serials: const ['C02AAA', 'C02BBB'],
        ),
        call: (c) => c.assignDevices(
          action: AbctlAssignment.assign,
          server: 'Built-in MDM',
          serials: const ['C02AAA', 'C02BBB'],
        ),
      ),
      'unassign devices': (
        argv: AbctlArgs.assignment(
          action: AbctlAssignment.unassign,
          server: 'Built-in MDM',
          serials: const ['C02AAA'],
        ),
        call: (c) => c.assignDevices(
          action: AbctlAssignment.unassign,
          server: 'Built-in MDM',
          serials: const ['C02AAA'],
        ),
      ),
    };

/// [file]'s lines with `//` comments removed, so a scan can tell code from the prose that
/// explains it. No file in `lib/` contains `//` inside a string literal.
Iterable<String> _strippedLines(File file) =>
    file.readAsLinesSync().map((line) {
      final comment = line.indexOf('//');
      return comment < 0 ? line : line.substring(0, comment);
    });

/// A runner that answers with canned bytes and records every invocation, mirroring
/// `abctl_client_test.dart`'s fake (and ContractTests.swift's `ArgvTap`).
class _FakeRunner implements AbctlRunner {
  _FakeRunner({this.stdout = '', this.stderr = '', this.code = 0});

  String stdout;
  String stderr;
  int code;

  final List<List<String>> argvs = <List<String>>[];
  final List<String?> cwds = <String?>[];
  final List<Duration> timeouts = <Duration>[];
  final List<List<int>?> stdins = <List<int>?>[];

  List<String> get argv => argvs.last;
  String? get cwd => cwds.last;
  Duration get timeout => timeouts.last;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    argvs.add(args);
    cwds.add(cwd);
    timeouts.add(timeout);
    stdins.add(stdin);
    return AbctlResult(
      stdout: Uint8List.fromList(utf8.encode(stdout)),
      stderr: stderr,
      code: code,
    );
  }
}

/// A runner for the cases that never run anything — the preview-parity check needs a client,
/// not a process. Spawning would be a real command; failing loudly is the honest alternative.
class _NullRunner implements AbctlRunner {
  const _NullRunner();

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async => throw StateError('this client is for previews only');
}
