// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The GitOps surface: the plan, the verification report and the raw profile viewer.
//
// These are the screens where a misread costs a tenant, so what is pinned here is not layout. It
// is: that a delete is counted as a delete and sorted to the top, that exit 3 renders as drift
// rather than as breakage, that the one control which writes to Apple Business cannot be pressed
// into a write without a typed confirmation and cannot report a failure as a success, that an
// error and a warning are distinguishable without colour, and that a profile is fetched once
// rather than per build.
//
// Nothing reaches a real abctl: the PROCESS seam is overridden and everything above it — the
// recording runner, the command log, the redaction, the client's decode-before-exit-code rule —
// is the app's own.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/dialogs/apply_dialog.dart';
import 'package:abgui/src/ui/dialogs/profile_dialog.dart';
import 'package:abgui/src/ui/dialogs/validate_dialog.dart';
import 'package:abgui/src/ui/screens/diff_screen.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/elapsed_ticker.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('PlanConsequence', () {
    test('classifies abctl\'s configuration verbs', () {
      expect(PlanConsequence.of('create-abm'), PlanConsequence.additive);
      expect(PlanConsequence.of('pull-new-git'), PlanConsequence.additive);
      expect(PlanConsequence.of('update-abm'), PlanConsequence.mutating);
      expect(PlanConsequence.of('pull-git'), PlanConsequence.mutating);
      expect(PlanConsequence.of('delete-abm'), PlanConsequence.destructive);
      expect(PlanConsequence.of('delete-git'), PlanConsequence.destructive);
    });

    test('matches member verbs by prefix, across all six collections', () {
      // The Swift original spelled only the `-config` pair and silently filed every other
      // collection under the default, which is the bug this case exists for.
      for (final String collection in <String>[
        'config',
        'app',
        'package',
        'device',
        'user',
        'group',
      ]) {
        expect(
          PlanConsequence.of('attach-$collection'),
          PlanConsequence.additive,
          reason: 'attach-$collection adds a member',
        );
        expect(
          PlanConsequence.of('adopt-$collection'),
          PlanConsequence.additive,
          reason: 'adopt-$collection writes a member into a manifest',
        );
        expect(
          PlanConsequence.of('detach-$collection'),
          PlanConsequence.destructive,
          reason: 'detach-$collection removes a member',
        );
      }
      expect(PlanConsequence.of('blueprint-new'), PlanConsequence.additive);
      expect(PlanConsequence.of('blueprint-adopt'), PlanConsequence.additive);
    });

    test('never files an unknown verb under "nothing is lost"', () {
      // abctl's vocabulary grows. A verb this build has never heard of must not be counted as
      // additive in the summary a user reads before deciding the plan is safe.
      expect(PlanConsequence.of('teleport-abm'), PlanConsequence.mutating);
      expect(PlanConsequence.of(''), PlanConsequence.mutating);
      expect(PlanConsequence.of('conflict'), PlanConsequence.mutating);
    });
  });

  group('DiffScreen', () {
    testWidgets('the summary counts by consequence, not by row', (
      WidgetTester tester,
    ) async {
      await _pumpDiff(tester, _planJson);

      // "5 changes" is true of a plan that creates five configurations and of one that deletes
      // four of them. The counts are what tell those apart.
      expect(find.text('5 pending changes'), findsOneWidget);
      expect(_badge('2 add'), findsOneWidget);
      expect(_badge('1 change'), findsOneWidget);
      expect(_badge('2 remove'), findsOneWidget);
      // Blocked is reported separately and is NOT counted as work.
      expect(_badge('1 blocked'), findsOneWidget);
    });

    testWidgets('destructive rows sort above everything else', (
      WidgetTester tester,
    ) async {
      await _pumpDiff(tester, _planJson);

      final List<PlanRow> shown = tester
          .state<AbTableState<PlanRow>>(find.byType(AbTable<PlanRow>))
          .displayedRows;
      expect(
        shown.take(2).map((PlanRow row) => row.consequence),
        everyElement(PlanConsequence.destructive),
        reason:
            'a delete buried under two hundred attaches is a delete nobody saw',
      );
      expect(shown.last.consequence, PlanConsequence.additive);
      // Equal consequences group by action rather than interleaving.
      expect(shown.map((PlanRow row) => row.action).toList(), <String>[
        'delete-abm',
        'detach-app',
        'update-abm',
        'attach-config',
        'create-abm',
      ]);
    });

    testWidgets('Apply opens the confirmation and never writes on its own', (
      WidgetTester tester,
    ) async {
      final List<List<String>> ran = <List<String>>[];
      await _pumpDiff(tester, _planJson, argv: ran);

      final Iterable<ToolbarButton> apply = tester
          .widgetList<ToolbarButton>(find.byType(ToolbarButton))
          .where((ToolbarButton button) => button.label == 'Apply');
      expect(
        apply.any((ToolbarButton button) => button.onPressed != null),
        isTrue,
        reason: 'there are five pending changes, so the control is live',
      );

      await tester.tap(_control('Apply'));
      await tester.pumpAndSettle();

      // The button is a presenter, not a trigger. Whatever the toolbar did, nothing gated
      // reached a process: the dialog is the only thing that can start one, and only after its
      // own confirmation.
      expect(find.byType(ApplyDialog), findsOneWidget);
      for (final List<String> args in ran) {
        expect(args, isNot(contains('--apply')));
        expect(args, isNot(contains('--yes')));
        expect(args.first, isNot('sync'));
      }
    });

    testWidgets('an in-sync tenant offers nothing to apply', (
      WidgetTester tester,
    ) async {
      // `sync --apply` over an empty plan is a tenant round-trip that changes nothing, and a live
      // Apply above the words "In sync" invites the click that finds that out.
      await _pumpDiff(tester, '{"configs":[],"blueprints":[]}');

      expect(
        tester
            .widgetList<ToolbarButton>(find.byType(ToolbarButton))
            .where((ToolbarButton button) => button.label == 'Apply')
            .every((ToolbarButton button) => button.onPressed == null),
        isTrue,
      );
    });

    testWidgets('exit 3 is drift, and drift is never a failure banner', (
      WidgetTester tester,
    ) async {
      await _pumpDiff(tester, null, exitCode: 3, stderr: 'changes pending');

      final Iterable<NoticeBanner> banners = tester.widgetList<NoticeBanner>(
        find.byType(NoticeBanner),
      );
      expect(
        banners.where((NoticeBanner b) => b.tone == AbSeverity.drift),
        hasLength(1),
        reason:
            'exit 3 is a verdict about the tenant, shown in the amber that means drift',
      );
      expect(
        banners.any((NoticeBanner b) => b.tone == AbSeverity.danger),
        isFalse,
        reason: 'nothing broke, so nothing is red',
      );
      expect(find.textContaining('Couldn\'t load'), findsNothing);
    });

    testWidgets('a narrow window wraps the toolbar instead of clipping it', (
      WidgetTester tester,
    ) async {
      // The Swift toolbar outgrew its window at ~1090px and silently clipped its last control.
      // Flutter is louder about it — a RenderFlex overflow fails this test — which is the point:
      // the controls wrap to a second line rather than one of them disappearing.
      await _pumpDiff(tester, _planJson, surface: const Size(820, 620));

      // Every control still on screen, and the LAST one — the one Swift lost — inside the
      // window rather than painted past its right edge.
      expect(
        tester.getRect(_control('Workspace')).right,
        lessThanOrEqualTo(820),
      );
      expect(
        tester.getRect(_control('Verify Configs')).right,
        lessThanOrEqualTo(820),
      );
      expect(tester.getRect(_control('Apply')).right, lessThanOrEqualTo(820));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a clean plan says so, and says when it was checked', (
      WidgetTester tester,
    ) async {
      await _pumpDiff(tester, '{"configs":[],"blueprints":[]}');

      expect(find.text('In sync'), findsOneWidget);
      // Without the stamp, Refresh on an in-sync tenant looks like a dead button.
      expect(find.textContaining('Checked '), findsOneWidget);
    });
  });

  // ===========================================================================================
  // The write. What is pinned here is not layout: it is that the numbers name a consequence,
  // that the command on screen is the command that runs, that nothing destructive can be started
  // without typing the tenant's name, and that no reading of a receipt can report a failure as a
  // success. A bug in any of those deletes a production configuration profile.
  // ===========================================================================================
  group('ApplyDialog', () {
    testWidgets('counts by consequence and names what will be removed', (
      WidgetTester tester,
    ) async {
      await _pumpApply(tester);

      expect(_badge('2 add'), findsOneWidget);
      expect(_badge('1 change'), findsOneWidget);
      expect(_badge('2 remove'), findsOneWidget);

      // The danger block, in numbers rather than adjectives: one live profile and one membership
      // are two different losses, and "2 removals" would invite one answer to both.
      expect(
        find.text('This run removes 2 things from Apple Business'),
        findsOneWidget,
      );
      expect(
        find.text('1 configuration profile deleted from Apple Business.'),
        findsOneWidget,
      );
      expect(find.text('1 member detached from a blueprint.'), findsOneWidget);
      // The reversibility claim, and it has to be the SCOPED one — a detach is not archived, and
      // an operator who believes otherwise finds out at the worst possible moment.
      expect(find.textContaining('gitops/archive/'), findsOneWidget);
      expect(
        find.textContaining('A detached member is not archived'),
        findsOneWidget,
      );
    });

    testWidgets('destructive Apply is gated on typing the tenant name', (
      WidgetTester tester,
    ) async {
      final _ApplyHarness harness = await _pumpApply(tester);

      expect(
        _applyEnabled(tester),
        isFalse,
        reason: 'a plan with two removals in it is not a one-click plan',
      );

      // A prefix of the name is not the name.
      await tester.enterText(
        _confirmField,
        harness.phrase.substring(0, harness.phrase.length - 1),
      );
      await tester.pump();
      expect(_applyEnabled(tester), isFalse);

      // Case-SENSITIVE: a gate that accepts `prod` for `Prod` accepts a guess.
      await tester.enterText(_confirmField, _swapCase(harness.phrase));
      await tester.pump();
      expect(_applyEnabled(tester), isFalse);

      // Trimmed: trailing whitespace is a paste artefact and says nothing about intent.
      await tester.enterText(_confirmField, '  ${harness.phrase}  ');
      await tester.pump();
      expect(_applyEnabled(tester), isTrue);
    });

    testWidgets('the typed gate re-arms when the command escalates to --prune', (
      WidgetTester tester,
    ) async {
      // REGRESSION. A plan that PROPOSES removals is gated even when the command would skip
      // them — `_isGated` is deliberately the union of what the command permits and what the
      // plan proposes. But the typed confirmation was never invalidated, so the two halves
      // combined into a hole: the operator read "this run skips the removals", typed the
      // tenant's name against a provably non-destructive command, then flipped the adjacent
      // "Removals off" toggle — ONE `setState`, no re-typing — and pressed Apply. `--prune`
      // reached a live tenant carrying an approval collected for a command without it. The
      // file's own justification for gating a skipping run is that the toggle must be "a
      // decision rather than a click"; without this the toggle *was* just a click.
      final _ApplyHarness harness = await _pumpApply(
        tester,
        planJson: _planJson,
        gitSourceOfTruth: false,
      );

      expect(
        _shownCommand(tester),
        isNot(contains('--prune')),
        reason: 'two-way mode with removals off skips them',
      );
      await tester.enterText(_confirmField, harness.phrase);
      await tester.pump();
      expect(_applyEnabled(tester), isTrue);

      // The one click that used to be enough.
      await tester.tap(find.widgetWithText(ToolbarButton, 'Removals off'));
      await tester.pump();

      expect(
        _shownCommand(tester),
        contains('--prune'),
        reason: 'the command really did escalate — that is the premise',
      );
      expect(
        _applyEnabled(tester),
        isFalse,
        reason:
            'the approval on file was given for a command that could not remove anything',
      );
      expect(
        tester.widget<TextField>(_confirmField).controller?.text,
        isEmpty,
        reason:
            'and the field is cleared, so the gate does not look satisfied while it is shut',
      );

      // Re-consenting to the escalated command is what opens it.
      await tester.enterText(_confirmField, harness.phrase);
      await tester.pump();
      expect(_applyEnabled(tester), isTrue);

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(harness.ran.last, contains('--prune'));
    });

    testWidgets('and it re-arms in the de-escalating direction too', (
      WidgetTester tester,
    ) async {
      // The same rule, unsigned: a confirmation is approval of a COMMAND, so any change to what
      // Apply would do closes the gate. Turning removals back off is harmless, and it still
      // costs a re-type — a rule with an exception for the "safe" direction is a rule with a
      // second code path, which is how the first one got its hole.
      final _ApplyHarness harness = await _pumpApply(
        tester,
        planJson: _planJson,
        gitSourceOfTruth: false,
      );

      await tester.tap(find.widgetWithText(ToolbarButton, 'Removals off'));
      await tester.pump();
      await tester.enterText(_confirmField, harness.phrase);
      await tester.pump();
      expect(_applyEnabled(tester), isTrue);

      await tester.tap(find.widgetWithText(ToolbarButton, 'Removals allowed'));
      await tester.pump();

      expect(_shownCommand(tester), isNot(contains('--prune')));
      expect(_applyEnabled(tester), isFalse);
    });

    testWidgets('the app default state applies with --prune, and says so before it does', (
      WidgetTester tester,
    ) async {
      // PINNED, not asserted as desirable. `GitopsState.gitSourceOfTruth` defaults to true, so
      // a fresh launch that picks a workspace and presses Apply runs with `--prune` — the
      // `_RemovalPolicy.keep` default is unreachable in that configuration, and invariant 1's
      // lib/ scan cannot see it because the field is spelled `gitSourceOfTruth`. That IS the
      // spec (abctl forces prune for `--apply --git-source-of-truth`, and Swift's `AppModel`
      // defaults the same way), so it is kept — and pinned here so it cannot change in either
      // direction without someone deciding to.
      //
      // What makes it safe is not the default. It is the two things asserted below: the
      // default state is ALWAYS gated, and the screen says what the run can do before the
      // operator can reach the button.
      final _ApplyHarness harness = await _pumpApply(tester);

      expect(_shownCommand(tester), contains('--git-source-of-truth'));
      expect(_shownCommand(tester), contains('--prune'));
      expect(
        _confirmField,
        findsOneWidget,
        reason: 'a default that prunes must never be a one-click default',
      );
      expect(_applyEnabled(tester), isFalse);
      expect(
        find.textContaining('This run can remove live configuration'),
        findsOneWidget,
        reason:
            'the gate labels itself with the consequence, not with "confirm"',
      );
      expect(
        find.textContaining('this run removes whatever Apple Business has'),
        findsOneWidget,
        reason: 'and the mode says removals are not separately optional here',
      );

      await tester.enterText(_confirmField, harness.phrase);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(harness.ran.last, contains('--prune'));
    });

    testWidgets('what the dialog shows is byte-for-byte what it runs', (
      WidgetTester tester,
    ) async {
      final _ApplyHarness harness = await _pumpApply(tester);
      await tester.enterText(_confirmField, harness.phrase);
      await tester.pump();

      // Read the line the operator is being asked to approve BEFORE anything runs.
      final String shown = _shownCommand(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      final List<String> ran = harness.ran.last;
      expect(ran.first, 'sync');
      expect(ran, contains('--apply'));
      // Without it abctl prompts on a terminal that is not there and the watchdog kills the
      // child, which the UI reports as a timeout.
      expect(ran, contains('--yes'));
      expect(
        CommandFormatter.line(ran),
        shown,
        reason:
            'an approval collected for one command and spent on another is worse than no '
            'confirmation at all',
      );
    });

    testWidgets('an additive plan applies without a typed confirmation', (
      WidgetTester tester,
    ) async {
      // Two-way mode, nothing to remove: the gate scales with the consequence, so this one is a
      // plain button. Making every apply a typing exercise is how a typing exercise stops being
      // read.
      final _ApplyHarness harness = await _pumpApply(
        tester,
        planJson: _additivePlanJson,
        gitSourceOfTruth: false,
      );

      expect(_confirmField, findsNothing);
      expect(_applyEnabled(tester), isTrue);

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(harness.ran.last, isNot(contains('--prune')));
      expect(harness.ran.last, isNot(contains('--git-source-of-truth')));
    });

    testWidgets('a failed row is never reported as a clean apply', (
      WidgetTester tester,
    ) async {
      // Exit 0 — everything the exit code can say is "success". The receipt says otherwise, and
      // the receipt is the verdict (invariant 6).
      final _ApplyHarness harness = await _pumpApply(
        tester,
        onSync: (List<String> args) async => _ok(_partialReceiptJson),
      );
      await _applyNow(tester, harness);

      expect(find.text('Applied 1, 1 failed'), findsOneWidget);
      // The failure's OWN message, in full — a clipped "403 FORB…" is not an account of what
      // Apple refused.
      expect(find.text('403 FORBIDDEN'), findsOneWidget);
      // …and the successes are still listed, because "what DID land" is the other half of the
      // question being asked.
      expect(find.text('WiFi-Corp.mobileconfig'), findsOneWidget);
    });

    testWidgets('every item done plus a non-zero exit is still not success', (
      WidgetTester tester,
    ) async {
      // The incident this screen exists for: Apple answers 2xx to a PATCH it then discards, and
      // abctl's post-apply read-back is the only thing that catches it. Every row says `done`.
      final _ApplyHarness harness = await _pumpApply(
        tester,
        onSync: (List<String> args) async => AbctlResult(
          stdout: Uint8List.fromList(utf8.encode(_droppedWriteReceiptJson)),
          stderr: 'post-apply verification FAILED: VPN.mobileconfig',
          code: 1,
        ),
      );
      await _applyNow(tester, harness);

      expect(
        find.text('Applied 2, but the run FAILED'),
        findsOneWidget,
        reason:
            '"Applied 2, 0 failed" is the one sentence on this screen that must never appear',
      );
      expect(
        find.textContaining('did not land on Apple Business'),
        findsOneWidget,
      );
    });

    testWidgets('a cancelled apply reports an ambiguous state as ambiguous', (
      WidgetTester tester,
    ) async {
      final _ApplyHarness harness = await _pumpApply(
        tester,
        onSync: (List<String> args) async => throw const AbctlCancelled(),
      );
      await _applyNow(tester, harness);

      expect(
        find.text('Stopped part way through — some changes may have landed'),
        findsOneWidget,
        reason:
            'reporting this as a clean failure tells an operator to do nothing, which leaves the '
            'tenant part way between git and where it started',
      );
      expect(find.textContaining('Refresh the plan'), findsOneWidget);
      expect(_control('Refresh Plan'), findsWidgets);
      // The rows on the Diff screen described a tenant that has since been written to.
      expect(harness.container.read(gitopsProvider).plan.superseded, isTrue);
    });

    testWidgets('while applying: live progress, an elapsed ticker and Cancel', (
      WidgetTester tester,
    ) async {
      final Completer<AbctlResult> gate = Completer<AbctlResult>();
      final _ApplyHarness harness = await _pumpApply(
        tester,
        onSync: (List<String> args) => gate.future,
      );
      await tester.enterText(_confirmField, harness.phrase);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      // Frames, not pumpAndSettle: the run is deliberately still in flight, and the elapsed
      // ticker schedules a frame twice a second for as long as it is.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.textContaining('Applying to Apple Business'), findsOneWidget);
      expect(find.byType(ElapsedTicker), findsOneWidget);
      expect(_control('Cancel'), findsOneWidget);
      // abctl's own narration, streamed through the sink rather than published per line.
      expect(find.textContaining('abctl: 1/3 configurations'), findsOneWidget);

      gate.complete(_ok(_cleanReceiptJson));
      await tester.pumpAndSettle();

      expect(find.text('Applied 1 change(s)'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('a recompute re-arms Apply; the spent plan does not', (
      WidgetTester tester,
    ) async {
      // The session-ending bug: `canApply` was gated on `ApplyState.isTerminal`, and that state
      // lives in the STORE. So the first apply of a session disabled Apply permanently — a
      // refresh did not clear it, and neither did closing and reopening the dialog, because the
      // widget was never where the flag was. The operator was left with a plan on screen, a
      // disabled button, and a green banner about a run that had already been superseded.
      //
      // Additive mode so the typed gate is not part of what is being measured here.
      final _ApplyHarness harness = await _pumpApply(
        tester,
        planJson: _additivePlanJson,
        gitSourceOfTruth: false,
      );
      expect(_applyEnabled(tester), isTrue);

      await _applyNow(tester, harness);
      expect(find.text('Applied 1 change(s)'), findsOneWidget);
      // Still the rule: these counts describe a tenant that has since changed.
      expect(
        _applyEnabled(tester),
        isFalse,
        reason: 'one apply per plan — the approved counts are no longer true',
      );

      await harness.container.read(gitopsProvider.notifier).refreshPlan();
      await tester.pumpAndSettle();

      expect(
        _applyEnabled(tester),
        isTrue,
        reason:
            'a recompute publishes a new plan, and the receipt above described the old one',
      );
      expect(
        find.text('Applied 1 change(s)'),
        findsNothing,
        reason:
            'a verdict banner over rows that run never saw is how the stale receipt read as the '
            'current one',
      );
    });

    testWidgets('a refusal that never ran abctl leaves Apply usable', (
      WidgetTester tester,
    ) async {
      // A pre-flight refusal reaches a terminal verdict without spawning anything. The store has
      // always known the difference (`didRun`); the dialog did not, so one refusal disabled Apply
      // AND hid the confirmation field under it — no way back inside the sheet.
      final _ApplyHarness harness = await _pumpApply(
        tester,
        planJson: _additivePlanJson,
        gitSourceOfTruth: false,
      );
      final GitopsStore store = harness.container.read(gitopsProvider.notifier);
      // Refuse it the way the store does: a plan in flight is another command running.
      unawaited(store.refreshPlan());
      await store.applyPlan(
        ApplyOptions.additive(
          refresh: AbctlRefresh.smart,
          verify: AbctlVerify.targeted,
        ),
      );
      await tester.pumpAndSettle();

      expect(harness.container.read(gitopsProvider).apply.didRun, isFalse);
      expect(_applyEnabled(tester), isTrue);
    });
  });

  group('ValidateDialog', () {
    testWidgets('renders the report abctl printed while exiting non-zero', (
      WidgetTester tester,
    ) async {
      // `validate` exits 1 whenever the report says ok:false and STILL prints the whole report.
      // If the exit code were mapped first, this screen would say "abctl reported an error" and
      // throw away the list of files to fix.
      await _pumpValidate(tester, _reportJson, exitCode: 1);

      expect(find.text('1 of 2 profile(s) have problems'), findsOneWidget);
      expect(find.text('wifi.mobileconfig'), findsOneWidget);
      expect(find.text('not a plist'), findsOneWidget);
      expect(
        find.text('references a configuration lib/ does not have'),
        findsOneWidget,
      );
    });

    testWidgets('error and warning are distinguishable without colour', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpValidate(tester, _reportJson, exitCode: 1);

      // The glyph is the only visual difference between an error row and a warning row, so each
      // one is spoken. Flutter's macOS accessibility is thin enough that an unlabelled icon is
      // simply absent to a screen reader.
      expect(find.bySemanticsLabel('Error'), findsWidgets);
      expect(find.bySemanticsLabel('Warning'), findsWidgets);
      expect(find.bySemanticsLabel('Failed'), findsWidgets);
      expect(find.bySemanticsLabel('Passed with warnings'), findsWidgets);
      handle.dispose();
    });

    testWidgets('problems are listed before the clean majority', (
      WidgetTester tester,
    ) async {
      await _pumpValidate(tester, _reportJson, exitCode: 1);

      final double failing = tester
          .getTopLeft(find.text('wifi.mobileconfig'))
          .dy;
      final double passing = tester
          .getTopLeft(find.text('vpn.mobileconfig'))
          .dy;
      expect(
        failing,
        lessThan(passing),
        reason:
            'a long lib/ must not make the user scroll to find what is broken',
      );
    });

    testWidgets('shows the command it ran, with the cd that makes it correct', (
      WidgetTester tester,
    ) async {
      await _pumpValidate(tester, _reportJson, exitCode: 1);

      expect(find.text('abctl validate --json'), findsOneWidget);
      expect(
        find.textContaining('the copied form includes the cd'),
        findsOneWidget,
      );
    });
  });

  group('ProfileDialog', () {
    testWidgets('loads the XML once, into state — never from build', (
      WidgetTester tester,
    ) async {
      var fetches = 0;
      final ProviderContainer container = _container((List<String> args) async {
        fetches += 1;
        return _ok(_profileXml);
      });

      await _pumpProfile(tester, container);
      expect(find.textContaining('PayloadDisplayName'), findsOneWidget);
      expect(fetches, 1);

      // Rebuild the same element tree with a different theme: the State survives, `build` runs
      // again, and a load living in `build` would spawn a second abctl here.
      await _pumpProfile(tester, container, brightness: Brightness.dark);
      expect(fetches, 1);
    });

    testWidgets('a failed fetch explains itself and offers a retry', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = _container(
        (List<String> args) async => _exit(1, 'configuration not found'),
      );

      await _pumpProfile(tester, container);

      expect(find.text('Couldn\'t load the profile'), findsOneWidget);
      expect(find.textContaining('configuration not found'), findsOneWidget);
      expect(find.text('Try Again'), findsOneWidget);
    });
  });
}

// -----------------------------------------------------------------------------------------
// harness
// -----------------------------------------------------------------------------------------

/// A plan with one row of every consequence, plus a blocked attach: two removals, one change,
/// two additions, one of which cannot be performed.
const String _planJson = '''
{
  "configs": [
    {"name": "Wi-Fi Office", "action": "create-abm", "detail": "only in git"},
    {"name": "VPN", "action": "update-abm", "detail": "payload differs"},
    {"name": "Legacy", "action": "delete-abm", "detail": "not in git"}
  ],
  "blueprints": [
    {"blueprint": "Standard Mac", "action": "detach-app", "config": "Numbers",
     "detail": "live in Apple, absent from the manifest"},
    {"blueprint": "Standard Mac", "action": "attach-config", "config": "Wi-Fi Office",
     "detail": "the configuration does not exist in Apple Business yet"}
  ]
}
''';

/// A plan with nothing to lose: one creation, and no membership rows at all.
const String _additivePlanJson = '''
{
  "configs": [
    {"name": "Wi-Fi Office", "action": "create-abm", "detail": "only in git"}
  ],
  "blueprints": []
}
''';

/// One write, one Apple refusal — and abctl exits 0 for it, which is the whole point.
const String _partialReceiptJson = '''
{
  "configs": {
    "outcomes": [
      {"name": "WiFi-Corp.mobileconfig", "action": "update", "status": "done",
       "detail": "PATCH", "archive": "gitops/archive/WiFi-Corp.mobileconfig.2026-08-15.xml"},
      {"name": "VPN.mobileconfig", "action": "update", "status": "error",
       "detail": "403 FORBIDDEN"}
    ],
    "writes": 1, "errors": 1, "skipped": 0
  },
  "blueprints": {"outcomes": [], "writes": 0, "errors": 0, "skipped": 0}
}
''';

/// Every item `done`, and one of them never reached Apple. The counters cannot see it; the
/// verification block can.
const String _droppedWriteReceiptJson = '''
{
  "configs": {
    "outcomes": [
      {"name": "WiFi-Corp.mobileconfig", "action": "update", "status": "done", "detail": "PATCH"},
      {"name": "VPN.mobileconfig", "action": "update", "status": "done", "detail": "PATCH"}
    ],
    "writes": 2, "errors": 0, "skipped": 0
  },
  "blueprints": {"outcomes": [], "writes": 0, "errors": 0, "skipped": 0},
  "verification": {
    "mode": "targeted", "written": 2, "verified": 1,
    "mismatches": [
      {"name": "VPN.mobileconfig", "detail": "stored profile differs from git", "observed": true}
    ]
  }
}
''';

const String _cleanReceiptJson = '''
{
  "configs": {
    "outcomes": [
      {"name": "Wi-Fi Office", "action": "create", "status": "done", "detail": "POST"}
    ],
    "writes": 1, "errors": 0, "skipped": 0
  },
  "blueprints": {"outcomes": [], "writes": 0, "errors": 0, "skipped": 0},
  "verification": {"mode": "targeted", "written": 1, "verified": 1, "mismatches": []}
}
''';

const String _reportJson = '''
{
  "ok": false,
  "libDir": "/workspace/gitops/lib",
  "checked": 2, "passed": 1, "failed": 1, "warnings": 2,
  "validator": "built-in",
  "profiles": [
    {"name": "wifi.mobileconfig", "path": "lib/wifi.mobileconfig", "bytes": 2048, "ok": false,
     "identifier": "com.example.wifi", "payloadTypes": ["com.apple.wifi.managed"],
     "errors": [{"code": "parse-failed", "message": "not a plist"}], "warnings": []},
    {"name": "vpn.mobileconfig", "path": "lib/vpn.mobileconfig", "bytes": 900, "ok": true,
     "identifier": "com.example.vpn", "errors": [],
     "warnings": [{"code": "no-identifier", "message": "payload has no identifier"}]}
  ],
  "treeIssues": [
    {"level": "error", "scope": "blueprints", "target": "Standard Mac", "code": "missing-config",
     "message": "references a configuration lib/ does not have"},
    {"level": "warning", "scope": "lib", "target": "old.mobileconfig", "code": "unreferenced",
     "message": "no blueprint references this profile"}
  ]
}
''';

const String _profileXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>PayloadDisplayName</key><string>Wi-Fi</string></dict></plist>
''';

/// A toolbar control by its label — the compact ones render no text, so they cannot be found by
/// the words in them.
Finder _control(String label) => find.byWidgetPredicate(
  (Widget widget) => widget is ToolbarButton && widget.label == label,
  description: 'ToolbarButton("$label")',
);

Finder _badge(String label) => find.byWidgetPredicate(
  (Widget widget) => widget is AbBadge && widget.label == label,
  description: 'AbBadge("$label")',
);

/// Mount the diff screen against a scripted abctl, with a workspace already chosen.
Future<void> _pumpDiff(
  WidgetTester tester,
  String? planJson, {
  int exitCode = 0,
  String stderr = '',
  List<List<String>>? argv,
  Size surface = const Size(1400, 900),
}) async {
  final ProviderContainer container = _container((List<String> args) async {
    argv?.add(args);
    return planJson == null ? _exit(exitCode, stderr) : _ok(planJson);
  });
  await container.read(gitopsProvider.notifier).setWorkspace(_workspace().path);

  await _pump(tester, container, const DiffScreen(), surface: surface);
}

/// What a mounted [ApplyDialog] test needs to talk about afterwards.
class _ApplyHarness {
  const _ApplyHarness({
    required this.container,
    required this.ran,
    required this.phrase,
  });

  final ProviderContainer container;

  /// Every argv that reached the process seam, in order. The last one is the apply.
  final List<List<String>> ran;

  /// What the typed gate expects. No context is named in these tests, so it is the workspace
  /// folder's name — the same fallback the dialog states on screen.
  final String phrase;
}

/// Mount the Apply dialog over a workspace that already has a plan.
///
/// The PROCESS seam is the only thing overridden, so everything between the dialog and it — the
/// recording runner, the command log, the redaction, the client's decode-before-exit-code rule —
/// is the app's own. [onSync] answers the write; anything else answers the plan.
Future<_ApplyHarness> _pumpApply(
  WidgetTester tester, {
  String planJson = _planJson,
  bool gitSourceOfTruth = true,
  Future<AbctlResult> Function(List<String> args)? onSync,
}) async {
  final List<List<String>> ran = <List<String>>[];
  final Directory workspace = _workspace();
  final ProviderContainer container = _container((List<String> args) async {
    ran.add(args);
    if (args.first == 'sync') {
      return onSync == null ? _ok(_cleanReceiptJson) : onSync(args);
    }
    return _ok(planJson);
  });
  final GitopsStore store = container.read(gitopsProvider.notifier);
  await store.setWorkspace(workspace.path);
  // Before the plan, never after: flipping it drops whatever has been computed, because a plan
  // under a switch that now says something else is a lie whichever way it is read.
  store.setGitSourceOfTruth(gitSourceOfTruth);
  await store.refreshPlan();

  await _pump(tester, container, const ApplyDialog());
  return _ApplyHarness(
    container: container,
    ran: ran,
    phrase: _folderName(workspace.path),
  );
}

/// Type the confirmation (harmless when none is asked for) and press Apply.
Future<void> _applyNow(WidgetTester tester, _ApplyHarness harness) async {
  if (_confirmField.evaluate().isNotEmpty) {
    await tester.enterText(_confirmField, harness.phrase);
    await tester.pump();
  }
  await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
  await tester.pumpAndSettle();
}

/// The typed-confirmation field: the one text field on the dialog that is not the write limit.
final Finder _confirmField = find.byWidgetPredicate(
  (Widget widget) =>
      widget is TextField && widget.decoration?.hintText != 'unlimited',
  description: 'the confirmation field',
);

bool _applyEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply'))
        .onPressed !=
    null;

/// The command line the dialog is displaying — read off the widget rather than rebuilt, because
/// what is being pinned is what the OPERATOR sees.
String _shownCommand(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((SelectableText text) => text.data ?? '')
    .firstWhere((String line) => line.startsWith('abctl sync'));

/// `Prod` → `pROD`. Any string with a letter in it comes back different, which is what makes it
/// a usable stand-in for "the right name, typed wrong".
String _swapCase(String text) => text
    .split('')
    .map((String c) => c == c.toUpperCase() ? c.toLowerCase() : c.toUpperCase())
    .join();

String _folderName(String path) => path
    .replaceAll('\\', '/')
    .split('/')
    .where((String part) => part.isNotEmpty)
    .last;

Future<void> _pumpValidate(
  WidgetTester tester,
  String reportJson, {
  int exitCode = 0,
}) async {
  final ProviderContainer container = _container(
    (List<String> args) async => AbctlResult(
      stdout: Uint8List.fromList(utf8.encode(reportJson)),
      stderr: 'validate: 1 profile failed',
      code: exitCode,
    ),
  );
  await container.read(gitopsProvider.notifier).setWorkspace(_workspace().path);

  await _pump(tester, container, const ValidateDialog());
}

Future<void> _pumpProfile(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
}) => _pump(
  tester,
  container,
  const ProfileDialog(
    config: Resource(type: 'orgDeviceActivities', id: 'CFG-1'),
  ),
  brightness: brightness,
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget screen, {
  Brightness brightness = Brightness.light,
  Size surface = const Size(1400, 900),
}) async {
  // A desktop-sized surface by default: these screens are built for one, and the 800x600 test
  // default would have the toolbar wrap and the table scroll for reasons no user would see.
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: abTheme(brightness),
        home: Scaffold(body: screen),
      ),
    ),
  );
  // The first abctl call is started from a post-frame callback (Riverpod refuses a provider
  // modified during a build), so settling is what actually runs it.
  await tester.pumpAndSettle();
}

/// Overrides the PROCESS seam and nothing above it.
ProviderContainer _container(
  Future<AbctlResult> Function(List<String> args) handler,
) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      abctlRunnerFactoryProvider.overrideWithValue(
        ({void Function(String line)? onStderrLine}) =>
            _ScriptedRunner(handler, onStderrLine),
      ),
      runLogOpenerProvider.overrideWithValue((_) async => null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Directory _workspace() {
  final Directory root = Directory.systemTemp.createTempSync('abgui_ui_');
  Directory('${root.path}${Platform.pathSeparator}gitops').createSync();
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

class _ScriptedRunner implements AbctlRunner {
  const _ScriptedRunner(this.handler, this.onStderrLine);

  final Future<AbctlResult> Function(List<String> args) handler;
  final void Function(String line)? onStderrLine;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) {
    onStderrLine?.call('abctl: 1/3 configurations');
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
