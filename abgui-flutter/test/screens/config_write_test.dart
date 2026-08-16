// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// THE CONFIGURATION WRITE SURFACE, driven through the controls an administrator actually clicks.
//
// `write_safety_test.dart` pins the client seam and `profile_preflight_test.dart` pins the check.
// Neither can pin the half that decides whether a live tenant changes: whether the gate in front
// of the write can be walked past, whether the document that was checked is the document that was
// sent, and whether a half-done write is drawn as a half-done write. That is what is here.
//
// Nothing reaches a real abctl — the PROCESS seam is overridden and everything above it (the
// client, the argv builders, the recording runner, the stores) is the app's own, so a test cannot
// pass while the wiring beneath it is wrong. The workspace is overridden too, because it is a
// PRECONDITION of these verbs rather than a setting: abctl roots gitops/ at its working
// directory.
//
// The rules these defend, each one the residue of something that already went wrong:
//
//  1. A hard finding stops the write BEFORE abctl is invoked. Apple accepts an out-of-spec
//     profile with a 2xx and silently declines to store it, so the exit code was never able to
//     tell an operator that their profile was wrong.
//  2. The bytes checked are the bytes sent, and they travel on stdin — never on argv.
//  3. A truncated stdin write is a hard error and is shown verbatim. "abctl may have received
//     only part of the profile" cannot be summarised without losing the only thing it says.
//  4. Nothing is reported from optimism. After a write the resource is re-read and what is drawn
//     is abctl's own outcome — `treeUpdated` and the read-back verdict included.
//  5. Delete names the configuration it is about to remove and says where the only surviving
//     copy will be.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/profile_check.dart';
import 'package:abgui/src/models/validation.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/dialogs/config_editor_dialog.dart';
import 'package:abgui/src/ui/screens/configurations_screen.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

void main() {
  group('the pre-flight gates the write', () {
    testWidgets('a hard finding stops it before abctl is invoked', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(
        tester,
        name: 'WiFi-Corp',
        xml: _profile(version: '2'),
      );
      await _press(tester, 'Check & Create');

      // The one assertion that matters most in this file: no process was started at all.
      expect(
        runner.verbs,
        isNot(contains('create')),
        reason:
            'a profile Apple would accept with a 2xx and then discard must not '
            'reach abctl, let alone Apple',
      );
      // …and the operator is told which rule fired, in abctl's own vocabulary.
      expect(_badges(tester), contains('payload-version'));
      expect(
        _visibleText(tester, 'the write was not attempted'),
        isTrue,
        reason: 'a blocked write has to say that it was blocked',
      );
    });

    testWidgets('an empty buffer cannot be submitted at all', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: '');

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Check & Create'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('a nameless create cannot be submitted either', (
      WidgetTester tester,
    ) async {
      // abctl derives the gitops/lib/ file name from this string; an empty one would mean a
      // profile in the tenant that no manifest can ever reference.
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: '', xml: _profile());

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Check & Create'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('the check runs again at press time, not from a stale verdict', (
      WidgetTester tester,
    ) async {
      // Check a good profile, then break it, then press. The verdict on screen said "clean" a
      // moment ago; the write must be judged on what is in the buffer NOW.
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: _profile());
      await _press(tester, 'Check profile');
      expect(_badges(tester), isNot(contains('payload-version')));

      await tester.enterText(_xmlField(), _profile(version: '2'));
      await _settle(tester);
      await _press(tester, 'Check & Create');

      expect(runner.verbs, isNot(contains('create')));
      expect(_badges(tester), contains('payload-version'));
    });
  });

  group('the write itself', () {
    testWidgets('creates with the exact argv, in the workspace', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: _profile());
      await _press(tester, 'Check & Create');

      final List<String> argv = runner.callFor('create')!;
      expect(argv, <String>[
        'create',
        'config',
        'WiFi-Corp',
        '-f',
        '-',
        '--yes',
        '--json',
      ]);
      expect(
        runner.cwdFor('create'),
        _workspace,
        reason:
            'abctl roots gitops/ at its working directory; the wrong cwd writes '
            'the profile and its baseline into a tree nobody reads',
      );
    });

    testWidgets('the profile travels on stdin, byte for byte, never on argv', (
      WidgetTester tester,
    ) async {
      // Non-ASCII on purpose: a character count and a byte count part company here, and the size
      // cap — the thing that decides whether Apple rejects the upload — is about bytes.
      final String xml = _profile(displayName: 'Café Wi-Fi');
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: xml);
      await _press(tester, 'Check & Create');

      expect(runner.stdinFor('create'), utf8.encode(xml));
      for (final String argument in runner.callFor('create')!) {
        expect(
          argument,
          isNot(contains('<plist')),
          reason:
              'a .mobileconfig carries credentials and certificates; on argv it '
              'is in every process listing on the machine',
        );
      }
    });

    testWidgets('the bytes CHECKED are the bytes SENT', (
      WidgetTester tester,
    ) async {
      // The two must not be separately derived. If the check ever ran on its own encoding of the
      // buffer, a profile could pass the size cap here and fail it at Apple.
      final String xml = _profile(displayName: 'Ünïcode — Wi-Fi');
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: xml);
      await _press(tester, 'Check & Create');

      final List<int> sent = runner.stdinFor('create')!;
      final ProfileReport checked = ProfilePreflight.check(
        sent,
        name: 'WiFi-Corp.mobileconfig',
      );
      expect(checked.ok, isTrue);
      expect(checked.bytes, sent.length);
    });

    testWidgets('a create that succeeded cannot be pressed a second time', (
      WidgetTester tester,
    ) async {
      // A POST carries no id, so there is nothing to make it idempotent: a second press is a
      // second configuration with the same name and the same PayloadIdentifier, and two profiles
      // sharing an identifier overwrite each other on the device. The dialog stays open to show
      // the outcome, which is exactly what puts the button back within reach.
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: _profile());
      await _press(tester, 'Check & Create');

      expect(runner.verbs.where((String v) => v == 'create'), hasLength(1));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Check & Create'),
            )
            .onPressed,
        isNull,
        reason: 'the configuration exists now; this dialog is a receipt',
      );
    });

    testWidgets('replace stays repeatable, because it names an id', (
      WidgetTester tester,
    ) async {
      // The other half of the rule above. A replace re-archives and re-PATCHes the SAME
      // configuration, so a second round of editing is legitimate rather than duplicating
      // anything — and after the re-read the buffer holds Apple's copy to edit from.
      final _ScriptedRunner runner = _ScriptedRunner(
        configurations: <Map<String, Object?>>[_row('c1', 'WiFi-Corp')],
        outcome:
            '{"action":"replace","name":"WiFi-Corp.mobileconfig","id":"c1",'
            '"status":"done","treeUpdated":true,"verified":"confirmed"}',
      );
      await _openScreen(tester, runner);
      await _select(tester, 'WiFi-Corp');
      await _press(tester, 'Edit');
      await _press(tester, 'Check & Replace');

      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Check & Replace'),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('replace loads the live profile ONCE, not once per rebuild', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner(
        configurations: <Map<String, Object?>>[_row('c1', 'WiFi-Corp')],
      );
      await _openScreen(tester, runner);
      await _select(tester, 'WiFi-Corp');
      await _press(tester, 'Edit');
      // Many frames, several rebuilds: a fetch in build() would spawn a process for each one.
      await _settle(tester);
      await _settle(tester);

      expect(
        runner.calls
            .where((List<String> argv) => argv.contains('--profile'))
            .length,
        1,
      );
      expect(_xmlController(tester).text, contains('PayloadIdentifier'));
    });

    testWidgets('Check & Replace stays disabled until the post-write re-read lands', (
      WidgetTester tester,
    ) async {
      // REGRESSION. `_canWrite` gated on `_writing || _loading` and never on `_rereading`,
      // while `_write` clears `_writing` BEFORE it awaits `_rereadAfterWrite`. So from the
      // moment the PATCH returned until the re-read finished, the button was live again — with
      // no spinner blocking it — and the re-read is not cheap (a full configuration list plus a
      // profile fetch).
      //
      // What a second press bought: a second `replace` started, then the FIRST re-read landed
      // and ran `_xml.text = live; _report = null; _checkedText = null;` — stamping Apple's
      // pre-second-write copy over the editor mid-flight and silently discarding the pre-flight
      // verdict for the bytes actually being sent. The two re-reads then raced with nothing to
      // arbitrate, so the "what Apple actually stored" evidence could end up being the OLDER
      // fetch. That evidence is the entire point of rule 4 in this file's header.
      final Completer<void> reread = Completer<void>();
      final _ScriptedRunner runner = _ScriptedRunner(
        configurations: <Map<String, Object?>>[_row('c1', 'WiFi-Corp')],
        outcome:
            '{"action":"replace","name":"WiFi-Corp.mobileconfig","id":"c1",'
            '"status":"done","treeUpdated":true,"verified":"confirmed"}',
        holdProfileReads: reread,
      );
      await _openScreen(tester, runner);
      await _select(tester, 'WiFi-Corp');
      await _press(tester, 'Edit');
      // The editor's own initial load is a `--profile` read too; let it through first.
      reread.complete();
      await _settle(tester);

      final Completer<void> second = Completer<void>();
      runner.holdProfileReads = second;
      await _press(tester, 'Check & Replace');

      expect(
        runner.verbs.where((String verb) => verb == 'replace'),
        hasLength(1),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Check & Replace'),
            )
            .onPressed,
        isNull,
        reason:
            'the write returned, but the screen does not yet agree with Apple',
      );

      // And pressing anyway — which is what a captured closure or an accessibility activate
      // does — starts nothing.
      await _press(tester, 'Check & Replace');
      expect(
        runner.verbs.where((String verb) => verb == 'replace'),
        hasLength(1),
      );

      second.complete();
      await _settle(tester);

      // Now it is repeatable again, because a replace names an id and a second round of
      // editing is legitimate — and the buffer holds Apple's copy to edit from.
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Check & Replace'),
            )
            .onPressed,
        isNotNull,
      );
      expect(_xmlController(tester).text, contains('Live copy'));
    });

    testWidgets('a configuration write never runs on the read budget', (
      WidgetTester tester,
    ) async {
      // REGRESSION (PLAUSIBLE→fixed). `create`/`replace`/`delete` inherited `_writeOutcome`'s
      // `AbctlTimeouts.read` default, exactly as the Swift original did by passing no timeout at
      // all. But a `replace` is at least as multi-call as a membership verb — fetch the live
      // profile, archive it to gitops/archive/, PATCH Apple, rewrite gitops/lib/ and the
      // baseline, read it back — and this repo has already paid for that lesson once: on 60s
      // `adopt` died mid-flight against a real tenant and left the manifest unwritten, with
      // "abctl ran for 60s" as the only symptom. The failure mode here is worse, because
      // `AbctlTimedOut`'s message diagnoses a NETWORK problem for a tenant write that landed.
      final _ScriptedRunner runner = _ScriptedRunner(
        configurations: <Map<String, Object?>>[_row('c1', 'WiFi-Corp')],
        outcome:
            '{"action":"replace","name":"WiFi-Corp.mobileconfig","id":"c1",'
            '"status":"done","treeUpdated":true,"verified":"confirmed"}',
      );
      await _openScreen(tester, runner);
      await _select(tester, 'WiFi-Corp');
      await _press(tester, 'Edit');
      await _press(tester, 'Check & Replace');

      final int at = runner.verbs.indexOf('replace');
      expect(at, isNonNegative);
      expect(
        runner.timeouts[at],
        AbctlTimeouts.write,
        reason: 'a tenant write does not get the budget of a one-call read',
      );
      expect(runner.timeouts[at], greaterThan(AbctlTimeouts.read));
    });

    testWidgets('replace targets the selected id and gates with --yes', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner(
        configurations: <Map<String, Object?>>[_row('c1', 'WiFi-Corp')],
      );
      await _openScreen(tester, runner);
      await _select(tester, 'WiFi-Corp');
      await _press(tester, 'Edit');
      await _press(tester, 'Check & Replace');

      expect(runner.callFor('replace'), <String>[
        'replace',
        'config',
        'c1',
        '-f',
        '-',
        '--yes',
        '--json',
      ]);
    });
  });

  group('what abctl reported is what is shown', () {
    testWidgets('a tenant write that missed git says so', (
      WidgetTester tester,
    ) async {
      // Exit 0, status "done" — everything the exit code can say is success. The document says
      // otherwise, and this is the case that used to be invisible until it resurfaced as drift.
      final _ScriptedRunner runner = _ScriptedRunner(
        outcome:
            '{"action":"create","name":"WiFi-Corp.mobileconfig","id":"c9",'
            '"status":"done","treeUpdated":false,'
            '"treeError":"mkdir gitops/lib: read-only file system",'
            '"verified":"confirmed"}',
      );
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: _profile());
      await _press(tester, 'Check & Create');

      expect(_visibleText(tester, 'NOT updated'), isTrue);
      expect(_visibleText(tester, 'read-only file system'), isTrue);
      expect(_visibleText(tester, 'drift'), isTrue);
    });

    testWidgets('an unconfirmed read-back is not drawn as proof', (
      WidgetTester tester,
    ) async {
      // "done" + unconfirmed is a real state: the write was made and the confirmation was not
      // obtained. It is neither a success to celebrate nor a failure to chase.
      final _ScriptedRunner runner = _ScriptedRunner(
        outcome:
            '{"action":"create","name":"WiFi-Corp.mobileconfig","id":"c9",'
            '"status":"done","treeUpdated":true,"verified":"unconfirmed"}',
      );
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: _profile());
      await _press(tester, 'Check & Create');

      expect(_visibleText(tester, 'could not read the profile back'), isTrue);
      expect(
        _visibleText(tester, 'not evidence the write failed'),
        isTrue,
        reason:
            'an unconfirmed write must not send an operator chasing a write '
            'that very likely landed',
      );
    });

    testWidgets('an abctl with no read-back verdict is called out', (
      WidgetTester tester,
    ) async {
      // A build old enough to omit the field. Silence is not a pass.
      final _ScriptedRunner runner = _ScriptedRunner(
        outcome:
            '{"action":"create","name":"WiFi-Corp.mobileconfig","id":"c9",'
            '"status":"done","treeUpdated":true}',
      );
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: _profile());
      await _press(tester, 'Check & Create');

      expect(_visibleText(tester, 'no read-back verdict'), isTrue);
      expect(_visibleText(tester, '2xx'), isTrue);
    });

    testWidgets('after a write the list and the profile are re-read', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner();
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: _profile());
      await _press(tester, 'Check & Create');

      final int wrote = runner.verbs.indexOf('create');
      expect(wrote, isNonNegative);
      final List<List<String>> after = runner.calls.sublist(wrote + 1);
      expect(
        after.any((List<String> argv) => argv.contains('configurations')),
        isTrue,
        reason: 'the list is re-fetched, never patched in place from optimism',
      );
      expect(
        after.any((List<String> argv) => argv.contains('--profile')),
        isTrue,
        reason:
            'the editor is refilled from Apple\'s copy, which for a write Apple '
            'acknowledged and did not store is a different document',
      );
    });
  });

  group('failures are never downgraded', () {
    testWidgets('a truncated stdin write is shown verbatim', (
      WidgetTester tester,
    ) async {
      // `ProcessRunner` raises exactly this when the pipe to abctl failed part way. It is the
      // one failure whose damage is invisible — the tenant may hold half a profile — so it is
      // shown as abctl's own words plus the sentence that says what to do about it.
      const String stderr =
          'failed to send the profile to abctl (it may have received only part of it): '
          'SocketException: Broken pipe';
      final _ScriptedRunner runner = _ScriptedRunner(
        failWrites: const _Failure(code: 1, stderr: stderr),
      );
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: _profile());
      await _press(tester, 'Check & Create');

      expect(_visibleText(tester, 'only part of it'), isTrue);
      expect(_visibleText(tester, 'unknown state'), isTrue);
      expect(
        _visibleText(tester, 'WHAT ABCTL REPORTED'),
        isFalse,
        reason: 'a failed write has no outcome document to render',
      );
    });

    testWidgets('a write that fails leaves the buffer alone', (
      WidgetTester tester,
    ) async {
      // The operator's work is the only copy of their intent. Clearing or reloading it after a
      // failure would make them retype the profile that just failed to send.
      final String xml = _profile();
      final _ScriptedRunner runner = _ScriptedRunner(
        failWrites: const _Failure(code: 1, stderr: 'Error: 403 FORBIDDEN'),
      );
      await _openScreen(tester, runner);
      await _openEditor(tester);
      await _fill(tester, name: 'WiFi-Corp', xml: xml);
      await _press(tester, 'Check & Create');

      expect(_xmlController(tester).text, xml);
      expect(_visibleText(tester, '403 FORBIDDEN'), isTrue);
    });
  });

  group('delete', () {
    testWidgets('the confirmation names the configuration and the archive', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner(
        configurations: <Map<String, Object?>>[_row('c1', 'WiFi-Corp')],
      );
      await _openScreen(tester, runner);
      await _select(tester, 'WiFi-Corp');
      await _press(tester, 'Delete');

      // NAMED, with its id. "Delete this configuration?" is approved against whatever the reader
      // believes is selected, which on a filtered table is not always what is.
      expect(_visibleText(tester, 'WiFi-Corp'), isTrue);
      expect(_visibleText(tester, 'c1'), isTrue);
      expect(_visibleText(tester, 'archives the live profile'), isTrue);
      expect(_visibleText(tester, 'only copy that survives'), isTrue);
      expect(
        runner.verbs,
        isNot(contains('delete')),
        reason: 'opening the confirmation must not be the confirmation',
      );
    });

    testWidgets('confirming runs the gated verb and shows the archive path', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner(
        configurations: <Map<String, Object?>>[_row('c1', 'WiFi-Corp')],
        outcome:
            '{"action":"delete","name":"WiFi-Corp.mobileconfig","id":"c1",'
            '"status":"done","archive":"gitops/archive/WiFi-Corp/2026-08-15.mobileconfig",'
            '"treeUpdated":true}',
      );
      await _openScreen(tester, runner);
      await _select(tester, 'WiFi-Corp');
      await _press(tester, 'Delete');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await _settle(tester);

      expect(runner.callFor('delete'), <String>[
        'delete',
        'config',
        'c1',
        '--yes',
        '--json',
      ]);
      expect(runner.cwdFor('delete'), _workspace);
      // The archive is the only remaining copy of the profile, so its path is the most valuable
      // string on the screen — a dialog that dismissed on success would throw it away.
      expect(
        _visibleText(
          tester,
          'gitops/archive/WiFi-Corp/2026-08-15.mobileconfig',
        ),
        isTrue,
      );
      final int deleted = runner.verbs.indexOf('delete');
      expect(
        runner.calls
            .sublist(deleted + 1)
            .any((List<String> argv) => argv.contains('configurations')),
        isTrue,
        reason: 'the row is dropped by a re-read, never by optimism',
      );
    });
  });

  group('the workspace is a precondition, not a setting', () {
    testWidgets('with none chosen every write control is inert', (
      WidgetTester tester,
    ) async {
      final _ScriptedRunner runner = _ScriptedRunner(
        configurations: <Map<String, Object?>>[_row('c1', 'WiFi-Corp')],
      );
      await _openScreen(tester, runner, workspace: null);
      await _select(tester, 'WiFi-Corp');

      for (final String label in <String>['New', 'Edit', 'Delete']) {
        expect(
          tester.widget<ToolbarButton>(_toolbar(label)).onPressed,
          isNull,
          reason: '$label is live without a tree for abctl to write into',
        );
      }
      // And the screen says why, rather than leaving three dead buttons unexplained.
      final NoticeBanner banner = tester.widget<NoticeBanner>(
        find.byType(NoticeBanner).first,
      );
      expect(banner.text, contains('No workspace'));
      expect(banner.detail, contains('working directory'));
    });

    test('the blocker is a single sentence shared by every surface', () {
      expect(configWriteBlocker('/work/ws'), isNull);
      expect(configWriteBlocker(null), isNotNull);
      expect(
        configWriteBlocker(''),
        isNotNull,
        reason:
            'an empty path is not a workspace, and passing it as a cwd is the '
            'same bug as passing none',
      );
    });
  });

  group('the pure pieces the dialogs lean on', () {
    test('the starter template passes abgui own check, silently', () {
      // A starter that abgui's own pre-flight complains about would teach an operator that the
      // report is noise, on the very first thing they ever validate.
      final ProfileReport report = ProfilePreflight.check(
        utf8.encode(starterProfileTemplate),
        name: 'starter.mobileconfig',
      );
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
      // …and it is unmistakably a draft, so it cannot be pushed as-is by accident.
      expect(starterProfileTemplate, contains('REPLACE-ME'));
    });

    test('the fixture a passing test relies on really is clean', () {
      // Every "the write happened" assertion above is only meaningful if the profile it fed in
      // would genuinely survive the gate. A fixture that quietly acquired a warning — or an
      // error — would turn those tests green for the wrong reason.
      final ProfileReport clean = ProfilePreflight.check(
        utf8.encode(_profile()),
        name: 'fixture.mobileconfig',
      );
      expect(clean.ok, isTrue);
      expect(<ValidationIssue>[...clean.errors, ...clean.warnings], isEmpty);

      final ProfileReport broken = ProfilePreflight.check(
        utf8.encode(_profile(version: '2')),
        name: 'fixture.mobileconfig',
      );
      expect(broken.ok, isFalse);
    });

    test('the stored name mirrors abctl configName, trap included', () {
      // abctl appends .mobileconfig only when there is no extension already.
      expect(abctlStoredConfigName('WiFi-Corp'), 'WiFi-Corp.mobileconfig');
      expect(
        abctlStoredConfigName('  WiFi-Corp  '),
        'WiFi-Corp.mobileconfig',
        reason: 'the name is trimmed before abctl ever sees it',
      );
      expect(
        abctlStoredConfigName('WiFi-Corp.mobileconfig'),
        'WiFi-Corp.mobileconfig',
        reason: 'a name that already ends in the extension is left alone',
      );
      // The trap, reproduced rather than smoothed over: `Wi-Fi 6.1` already "has an extension",
      // so abctl stores it verbatim and no manifest entry saying `Wi-Fi 6.1.mobileconfig` will
      // ever match it. Showing the operator this string is the only warning they get.
      expect(abctlStoredConfigName('Wi-Fi 6.1'), 'Wi-Fi 6.1');
      expect(abctlStoredConfigName(''), '');
    });
  });
}

// -----------------------------------------------------------------------------------------
// harness
// -----------------------------------------------------------------------------------------

const String _workspace = '/work/ws';

/// A workspace fixed for the test. Overriding the STORE rather than poking preferences keeps the
/// precondition deterministic — and the client under test still derives its cwd from it, so the
/// cwd assertions are about the real wiring.
class _FixedWorkspace extends WorkspaceStore {
  _FixedWorkspace(this.path);

  final String? path;

  @override
  String? build() => path;
}

/// Mount the Configurations screen over a scripted process seam.
///
/// The PROCESS is the only thing faked. The client, the argv builders, the recording runner and
/// the stores are all the app's own, so a test here cannot pass while the layer beneath it is
/// wired wrongly.
Future<void> _openScreen(
  WidgetTester tester,
  _ScriptedRunner runner, {
  String? workspace = _workspace,
}) async {
  tester.view.physicalSize = const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        abctlRunnerFactoryProvider.overrideWithValue(
          ({void Function(String line)? onStderrLine}) => runner,
        ),
        workspaceProvider.overrideWith(() => _FixedWorkspace(workspace)),
      ],
      child: MaterialApp(
        theme: abTheme(Brightness.light),
        home: const Scaffold(body: ConfigurationsScreen()),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _openEditor(WidgetTester tester) async {
  await _press(tester, 'New');
  expect(find.byType(ConfigEditorDialog), findsOneWidget);
}

/// Select a row by the name in its Name cell.
Future<void> _select(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  await _settle(tester);
}

Future<void> _press(WidgetTester tester, String label) async {
  final Finder button = find.widgetWithText(FilledButton, label);
  await tester.tap(button.evaluate().isNotEmpty ? button : _toolbar(label));
  await _settle(tester);
}

Finder _toolbar(String label) => find.byWidgetPredicate(
  (Widget widget) => widget is ToolbarButton && widget.label == label,
);

/// The editor's two fields, in tree order: the name, then the XML.
Finder _dialogFields() => find.descendant(
  of: find.byType(ConfigEditorDialog),
  matching: find.byType(TextField),
);

Finder _xmlField() {
  final Finder fields = _dialogFields();
  return fields.evaluate().length > 1 ? fields.at(1) : fields.first;
}

TextEditingController _xmlController(WidgetTester tester) =>
    tester.widget<TextField>(_xmlField()).controller!;

Future<void> _fill(
  WidgetTester tester, {
  required String name,
  required String xml,
}) async {
  await tester.enterText(_dialogFields().first, name);
  await _settle(tester);
  await tester.enterText(_xmlField(), xml);
  await _settle(tester);
}

/// `pumpAndSettle` is unusable here: a busy dialog draws a `CircularProgressIndicator`, which
/// never stops animating, so settling would time out rather than converge.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Whether [needle] appears in any rendered prose.
///
/// Both widget kinds are searched because the write surface uses `SelectableText` wherever the
/// value is something a human pastes into a ticket — abctl's stderr, an archive path, an id.
bool _visibleText(WidgetTester tester, String needle) {
  for (final Widget widget in tester.allWidgets) {
    if (widget is Text && (widget.data ?? '').contains(needle)) return true;
    if (widget is SelectableText && (widget.data ?? '').contains(needle)) {
      return true;
    }
  }
  return false;
}

/// Every issue-code chip on screen — the codes are what the docs list and what an operator greps
/// for, so they are the honest thing to assert on.
Set<String> _badges(WidgetTester tester) => <String>{
  for (final AbBadge badge in tester.widgetList<AbBadge>(find.byType(AbBadge)))
    badge.label,
};

// -----------------------------------------------------------------------------------------
// fixtures
// -----------------------------------------------------------------------------------------

/// A structurally complete profile. [version] is the OUTER PayloadVersion — the one Apple pins to
/// exactly 1 and silently drops the profile over.
String _profile({String version = '1', String displayName = 'Corp Wi-Fi'}) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0">\n<dict>\n'
    '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
    '\t<key>PayloadVersion</key>\n\t<integer>$version</integer>\n'
    '\t<key>PayloadIdentifier</key>\n\t<string>com.example.wifi</string>\n'
    '\t<key>PayloadUUID</key>\n\t<string>6E8B0F2A-2E4E-4E3A-9C2F-2A0C7D3B1E55</string>\n'
    '\t<key>PayloadDisplayName</key>\n\t<string>$displayName</string>\n'
    '\t<key>PayloadContent</key>\n\t<array>\n\t\t<dict>\n'
    '\t\t\t<key>PayloadType</key>\n\t\t\t<string>com.apple.wifi.managed</string>\n'
    '\t\t</dict>\n\t</array>\n'
    '</dict>\n</plist>\n';

Map<String, Object?> _row(String id, String name) => <String, Object?>{
  'type': 'configurations',
  'id': id,
  'attributes': <String, Object?>{
    'name': name,
    'type': 'CUSTOM_SETTING',
    'updatedDateTime': '2026-08-01T00:00:00Z',
  },
};

class _Failure {
  const _Failure({required this.code, required this.stderr});

  final int code;
  final String stderr;
}

/// Answers each verb with something shaped like abctl's own output, and records every call.
class _ScriptedRunner implements AbctlRunner {
  _ScriptedRunner({
    this.configurations = const <Map<String, Object?>>[],
    this.outcome =
        '{"action":"create","name":"WiFi-Corp.mobileconfig","id":"c9",'
        '"status":"done","treeUpdated":true,"verified":"confirmed"}',
    this.failWrites,
    this.holdProfileReads,
  });

  /// When non-null, every `--profile` fetch waits on it. The post-write re-read is the only
  /// place in this dialog with a window between "the write returned" and "the screen agrees with
  /// Apple", and a test cannot stand in that window without a way to hold the read open.

  final List<Map<String, Object?>> configurations;
  final String outcome;

  /// Non-null makes every gated write fail the way abctl fails: a non-zero exit with the account
  /// of what happened on stderr.
  final _Failure? failWrites;

  Completer<void>? holdProfileReads;

  final List<List<String>> calls = <List<String>>[];

  /// The budget each call was given. The write verbs must not be on the read budget — see
  /// `AbctlTimeouts.write` for the incident that rule came from.
  final List<Duration> timeouts = <Duration>[];
  final List<String?> cwds = <String?>[];
  final List<List<int>?> stdins = <List<int>?>[];

  List<String> get verbs => <String>[
    for (final List<String> argv in calls) argv.first,
  ];

  int _indexOf(String verb) => verbs.indexOf(verb);

  List<String>? callFor(String verb) {
    final int i = _indexOf(verb);
    return i < 0 ? null : calls[i];
  }

  String? cwdFor(String verb) {
    final int i = _indexOf(verb);
    return i < 0 ? null : cwds[i];
  }

  List<int>? stdinFor(String verb) {
    final int i = _indexOf(verb);
    return i < 0 ? null : stdins[i];
  }

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    calls.add(List<String>.unmodifiable(args));
    cwds.add(cwd);
    stdins.add(stdin);
    timeouts.add(timeout);

    const Set<String> writes = <String>{'create', 'replace', 'delete'};
    if (writes.contains(args.first)) {
      final _Failure? failure = failWrites;
      if (failure != null) {
        return _result('', code: failure.code, stderr: failure.stderr);
      }
      return _result(outcome);
    }
    if (args.contains('--profile')) {
      await holdProfileReads?.future;
      return _result(_profile(displayName: 'Live copy'));
    }
    return _result(jsonEncode(configurations));
  }

  AbctlResult _result(String stdout, {int code = 0, String stderr = ''}) =>
      AbctlResult(
        stdout: Uint8List.fromList(utf8.encode(stdout)),
        stderr: stderr,
        code: code,
      );
}
