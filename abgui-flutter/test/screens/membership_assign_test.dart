// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// THE WRITE SURFACES, driven through the widgets an administrator actually clicks.
//
// `write_safety_test.dart` pins the client seam: that the builders are called, that a preview is
// the argv that runs, that a document is decoded before an exit code is judged. What it cannot
// pin is the half a human touches — whether the button that says Attach runs `attach`, whether
// the one gate in front of a live tenant can be walked past, and whether an outcome that is
// half-done is rendered as half-done. That is what is here.
//
// Nothing reaches a real abctl: the PROCESS seam is overridden and everything above it — the
// client, the argv builders, the recording runner, the command log, the stores — is the app's own,
// so a test cannot pass while the wiring under it is wrong.
//
// The four rules these defend, each the residue of something that already went wrong:
//
//  1. What the dialog SHOWS is what it RUNS. The preview is the approval; a lookalike collects
//     consent for a command nobody saw.
//  2. `adopt` carries no `--yes` and the tenant verbs do. adopt writes local files only, and
//     gating it behind a tenant-write confirmation teaches an operator the two are the same risk.
//  3. Every membership verb runs in the WORKSPACE, and refuses when there is none — abctl roots
//     gitops/ at its working directory, and that is how a green attach left git untouched and
//     produced a `detach-config` drift row that came back forever.
//  4. A half-done write is never reported as a clean one: a tenant write whose manifest failed, a
//     timeout that may have left the manifest unwritten, and an assignment that submitted nothing
//     each say so in their own words.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/json_value.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/dialogs/assign_dialog.dart';
import 'package:abgui/src/ui/dialogs/membership_dialog.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/choice_card.dart';
import 'package:abgui/src/ui/widgets/command_preview.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // =========================================================================================
  // membership — attach / detach / adopt
  // =========================================================================================

  group('membership dialog', () {
    testWidgets('runs the verb it previewed, in the workspace, gated', (
      WidgetTester tester,
    ) async {
      final _Script script = _Script()
        ..reply('configurations', _configurationsJson)
        ..reply('attach', _attachOkJson);
      final ProviderContainer container = await _container(
        script,
        workspace: true,
      );

      await _pumpMembership(tester, container);
      await _pickConfiguration(tester, 'c1');
      await _tapText(tester, 'Continue');

      // The line the operator is asked to approve, taken from the widget that draws it and put
      // through the same formatter the Command Log uses.
      final CommandPreview preview = tester.widget<CommandPreview>(
        find.byType(CommandPreview),
      );
      final List<String> previewed = container
          .read(abctlClientProvider)
          .previewArgv(preview.base);
      expect(previewed.first, 'attach');
      expect(previewed, contains('--context'));

      await _tapText(tester, 'Attach');
      await _settle(tester);

      final _Call call = script.callFor('attach');
      expect(
        call.args,
        previewed,
        reason: 'the approved command and the executed one must be one list',
      );
      expect(
        CommandFormatter.line(call.args),
        CommandFormatter.line(previewed),
        reason: 'and one line, since the line is what the human read',
      );
      // The cwd is the whole "detach-config forever" bug: abctl roots gitops/ at its working
      // directory, so a membership write launched from anywhere else rewrites a different tree.
      expect(call.cwd, container.read(workspaceProvider));
      expect(
        call.timeout,
        greaterThan(AbctlTimeouts.read),
        reason:
            'membership is multi-call and cannot run on the 60s read budget',
      );
      expect(call.args, contains('--yes'));
    });

    testWidgets('adopt runs adopt, names the config, and carries no --yes', (
      WidgetTester tester,
    ) async {
      final _Script script = _Script()
        ..reply('configurations', _configurationsJson)
        ..reply('adopt', _adoptOkJson);
      final ProviderContainer container = await _container(
        script,
        workspace: true,
      );

      await _pumpMembership(tester, container);
      await _chooseAction(tester, 'Adopt');
      await _pickConfiguration(tester, 'c1');
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Record in git');
      await _settle(tester);

      final _Call call = script.callFor('adopt');
      expect(call.args.take(5), <String>[
        'adopt',
        'config',
        // The NAME, not the id: the manifest records the canonical name, and the command an
        // operator reads afterwards should name the thing they picked.
        'WiFi-Corp.mobileconfig',
        '--blueprint',
        'bp-1',
      ]);
      expect(
        call.args,
        isNot(contains('--yes')),
        reason:
            'adopt writes gitops/ and never the tenant — there is nothing to gate',
      );
      expect(call.cwd, container.read(workspaceProvider));

      // And the outcome says what it did in the terms the complaint was made in.
      expect(find.textContaining('Recorded in git'), findsWidgets);
      expect(find.textContaining('stop proposing to detach'), findsWidgets);
    });

    testWidgets('detach previews detach, not attach', (
      WidgetTester tester,
    ) async {
      final _Script script = _Script()
        ..reply('configurations', _configurationsJson)
        ..reply('detach', _attachOkJson);
      final ProviderContainer container = await _container(
        script,
        workspace: true,
      );

      await _pumpMembership(tester, container);
      await _chooseAction(tester, 'Detach');
      await _pickConfiguration(tester, 'c1');
      await _tapText(tester, 'Continue');

      final CommandPreview preview = tester.widget<CommandPreview>(
        find.byType(CommandPreview),
      );
      expect(
        preview.base.first,
        'detach',
        reason:
            'a destructive verb previewing as its opposite is the worst '
            'possible drift on this surface',
      );
      // The confirm button is named for the verb, so "OK" can never be what authorised a detach.
      expect(find.text('Detach'), findsWidgets);
    });

    testWidgets('refuses every verb when no workspace is chosen', (
      WidgetTester tester,
    ) async {
      final _Script script = _Script()
        ..reply('configurations', _configurationsJson);
      final ProviderContainer container = await _container(
        script,
        workspace: false,
      );

      await _pumpMembership(tester, container);
      await _pickConfiguration(tester, 'c1');

      // Not a warning next to a live button: the gate is shut. abctl would resolve gitops/
      // against whatever directory the app happens to be in, which is how a manifest write lands
      // somewhere nobody will ever look.
      final Finder continueButton = find.widgetWithText(
        FilledButton,
        'Continue',
      );
      expect(
        tester.widget<FilledButton>(continueButton).onPressed,
        isNull,
        reason: 'no workspace means no membership write, of any kind',
      );
      final NoticeBanner banner = tester.widget<NoticeBanner>(
        find.byType(NoticeBanner),
      );
      expect(banner.text, 'No workspace chosen');
      expect(banner.detail, contains('gitops/blueprints/'));
      expect(script.verbs, isNot(contains('attach')));
      expect(script.verbs, isNot(contains('adopt')));
    });

    testWidgets('a configuration membership cannot address does not open the '
        'gate', (WidgetTester tester) async {
      // `get configurations` lists every type; membership resolves the CUSTOM_SETTING list only.
      // Selecting one of the others used to reach abctl and come back as `config "X" not found`,
      // which reads like a bug when the row is right there on screen.
      final _Script script = _Script()
        ..reply('configurations', _mixedConfigurationsJson);
      final ProviderContainer container = await _container(
        script,
        workspace: true,
      );

      await _pumpMembership(tester, container);
      await _pickConfiguration(tester, 'c2');

      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('CUSTOM_SETTING'), findsWidgets);

      // And the writable row in the same list still works.
      await _pickConfiguration(tester, 'c1');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('a tenant write whose manifest failed is not reported clean', (
      WidgetTester tester,
    ) async {
      // abctl exits 0 here: the TENANT write succeeded and only the local half failed. Reporting
      // that as a plain success is exactly how a green attach left git untouched, and the
      // operator learned about it as a drift row days later.
      final _Script script = _Script()
        ..reply('configurations', _configurationsJson)
        ..reply('attach', _attachTreeFailedJson);
      final ProviderContainer container = await _container(
        script,
        workspace: true,
      );

      await _pumpMembership(tester, container);
      await _pickConfiguration(tester, 'c1');
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Attach');
      await _settle(tester);

      final NoticeBanner banner = tester.widget<NoticeBanner>(
        find.byType(NoticeBanner),
      );
      expect(banner.text, 'Written to Apple, not to git');
      expect(banner.detail, contains('read-only file system'));
      // And the way out is offered: the adopt command abctl's own stderr recommends.
      expect(find.textContaining('abctl adopt config'), findsOneWidget);
    });

    testWidgets('a double activation runs one attach, not two', (
      WidgetTester tester,
    ) async {
      // REGRESSION, the membership half of the same hole. `_run` opened with `if (config ==
      // null) return;` and nothing else, so two activations of the captured `onPressed` closure
      // with no frame between them ran the verb twice from one approval — against a live
      // blueprint, with `_cancel` pointing at the second child and the first one unattended.
      final _Script script = _Script()
        ..reply('configurations', _configurationsJson)
        ..reply('attach', _attachOkJson);
      final ProviderContainer container = await _container(
        script,
        workspace: true,
      );

      await _pumpMembership(tester, container);
      await _pickConfiguration(tester, 'c1');
      await _tapText(tester, 'Continue');

      final Finder button = find.text('Attach').last;
      await tester.tap(button, warnIfMissed: false);
      await tester.tap(button, warnIfMissed: false);
      await _settle(tester);

      expect(
        script.verbs.where((String verb) => verb == 'attach'),
        hasLength(1),
      );
    });

    testWidgets('an adopt that timed out says the manifest may be unwritten', (
      WidgetTester tester,
    ) async {
      // The incident this dialog is built around: `adopt` on the plain read budget died
      // mid-flight against a real tenant, wrote nothing, and reported only "abctl ran for 60s" —
      // indistinguishable from a feature that does not work.
      final _Script script = _Script()
        ..reply('configurations', _configurationsJson)
        ..fail(
          'adopt',
          const AbctlTimedOut(
            seconds: 180,
            lastOutput: 'listing configs 340/1200',
          ),
        );
      final ProviderContainer container = await _container(
        script,
        workspace: true,
      );

      await _pumpMembership(tester, container);
      await _chooseAction(tester, 'Adopt');
      await _pickConfiguration(tester, 'c1');
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Record in git');
      await _settle(tester);

      expect(find.textContaining('timed out'), findsWidgets);
      // The two halves an operator has to be told apart: the tenant CANNOT have changed, and the
      // manifest is unknown. A generic failure message says neither.
      expect(
        find.textContaining('Apple Business cannot have changed'),
        findsOneWidget,
      );
      expect(find.textContaining('git status'), findsOneWidget);
    });
  });

  // =========================================================================================
  // device assignment
  // =========================================================================================

  group('assign dialog', () {
    testWidgets('sends the serials positionally, gated, with no workspace', (
      WidgetTester tester,
    ) async {
      final _Script script = _Script()
        ..reply('mdmservers', _serversJson)
        ..reply('assign', _assignOkJson);
      final ProviderContainer container = await _container(
        script,
        workspace: true,
      );

      await _pumpAssign(tester, container, _devices);
      await _tapText(tester, 'Continue');

      final CommandPreview preview = tester.widget<CommandPreview>(
        find.byType(CommandPreview),
      );
      expect(
        preview.cwd,
        isNull,
        reason:
            'assignment resolves nothing from gitops/; a cd would lie '
            'about that even with a workspace chosen',
      );

      await _tapText(tester, 'Assign');
      await _settle(tester);

      final _Call call = script.callFor('assign');
      expect(call.args, <String>[
        'assign',
        '--server',
        's1',
        'C02AAA',
        'C02BBB',
        '--yes',
        '--json',
        '--context',
        'prod',
      ]);
      expect(
        call.args,
        container.read(abctlClientProvider).previewArgv(preview.base),
      );
    });

    testWidgets('unassign is its own verb, never an assign', (
      WidgetTester tester,
    ) async {
      final _Script script = _Script()
        ..reply('mdmservers', _serversJson)
        ..reply('unassign', _unassignOkJson);
      final ProviderContainer container = await _container(
        script,
        workspace: false,
      );

      await _pumpAssign(tester, container, _devices);
      await _chooseAction(tester, 'Unassign');
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Unassign');
      await _settle(tester);

      expect(script.callFor('unassign').args.first, 'unassign');
      expect(script.verbs, isNot(contains('assign')));
    });

    testWidgets('an accepted activity is accepted, not applied', (
      WidgetTester tester,
    ) async {
      final _Script script = _Script()
        ..reply('mdmservers', _serversJson)
        ..reply('assign', _assignOkJson)
        ..reply('status', _activityJson);
      final ProviderContainer container = await _container(
        script,
        workspace: false,
      );

      await _pumpAssign(tester, container, _devices);
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Assign');
      await _settle(tester);

      // Every device went in one request, so every row reads the same — and the word is
      // Submitted, because Apple has not finished and abgui must not claim it has.
      expect(find.text('Submitted'), findsNWidgets(2));
      expect(find.textContaining('Accepted is not finished'), findsOneWidget);

      // Check status is a READ of the activity, repeatable and ungated.
      await _tapText(tester, 'Check status');
      await _settle(tester);
      // The read is context-scoped like every other command — an activity id means nothing
      // without the tenant it belongs to.
      expect(script.callFor('status').args, <String>[
        'status',
        'activity',
        'act-42',
        '--json',
        '--context',
        'prod',
      ]);
      expect(find.text('IN_PROGRESS'), findsOneWidget);
      expect(find.textContaining('per-device result'), findsOneWidget);
    });

    testWidgets('a rejected serial fails the whole command, and says so', (
      WidgetTester tester,
    ) async {
      // abctl resolves every serial BEFORE it submits anything, so one bad serial means nothing
      // was sent. "Some of them went through" and "none of them did" are different states and an
      // operator acts differently on each.
      final _Script script = _Script()
        ..reply('mdmservers', _serversJson)
        ..fail(
          'assign',
          const AbctlCliError(
            'device "C02BBB" not found (by serial number or id)',
          ),
        );
      final ProviderContainer container = await _container(
        script,
        workspace: false,
      );

      await _pumpAssign(tester, container, _devices);
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Assign');
      await _settle(tester);

      expect(find.text('Nothing was submitted'), findsOneWidget);
      // Per item: the one abctl named, and the one it never reached.
      expect(find.text('Rejected'), findsOneWidget);
      expect(find.text('Not submitted'), findsOneWidget);
      expect(find.textContaining('No device was moved'), findsOneWidget);
    });

    testWidgets('a timed-out assignment never claims nothing was submitted', (
      WidgetTester tester,
    ) async {
      // REGRESSION, and the most expensive wrong sentence on this screen. `timedOut` fell into
      // the `else` of a two-way branch, so the headline read "Nothing was submitted" and every
      // row read "Not submitted" — both stated as certainties — while the paragraph six lines
      // below said the opposite ("if the activity had already been submitted, Apple kept it").
      // The headline is what gets read, screenshotted and acted on, and the action it invites
      // is a re-submit, which on a tenant that already accepted the activity is a duplicate.
      //
      // The certainty was justified on the grounds that abctl resolves every serial before it
      // POSTs — true for an abctl-REPORTED refusal, false for abgui's own watchdog, which can
      // fire after the POST. `membership_dialog` already got this right; this dialog was the
      // one write surface that collapsed the two.
      //
      // The stderr tail is deliberately narration that QUOTES a selected serial: it is what
      // `AbctlTimedOut.message` appends, and the per-device substring match was written against
      // abctl's refusal wording (`device %q not found`). Reading a progress line with that
      // matcher marked a device "Rejected" — an assertion that Apple refused that specific
      // device, invented from a log line.
      final _Script script = _Script()
        ..reply('mdmservers', _serversJson)
        ..fail(
          'assign',
          const AbctlTimedOut(
            seconds: 180,
            lastOutput: 'resolving device "C02AAA" (1/2)',
          ),
        );
      final ProviderContainer container = await _container(
        script,
        workspace: false,
      );

      await _pumpAssign(tester, container, _devices);
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Assign');
      await _settle(tester);

      expect(find.text('Nothing was submitted'), findsNothing);
      expect(
        find.text('Timed out — what reached Apple is unknown'),
        findsOneWidget,
      );
      expect(
        find.text('Not submitted'),
        findsNothing,
        reason: 'a kill establishes nothing about any individual device',
      );
      expect(
        find.text('Rejected'),
        findsNothing,
        reason: 'abctl narrated that serial, it did not refuse it',
      );
      expect(
        find.text('Unknown'),
        findsNWidgets(_devices.length),
        reason: 'every row wears the same honest verdict',
      );
      expect(
        find.textContaining('does not know whether the activity was submitted'),
        findsOneWidget,
      );
      expect(
        find.textContaining('a duplicate, not a retry'),
        findsOneWidget,
        reason: 'the recovery has to say what NOT to do as well as what to do',
      );
    });

    testWidgets('a cancelled assignment says the same thing', (
      WidgetTester tester,
    ) async {
      // Same rule, the other interruption. A cancel is the operator's own choice and still tells
      // them nothing about whether the POST landed, so the old headline ("Stopped", unqualified)
      // was read as "stopped in time".
      final _Script script = _Script()
        ..reply('mdmservers', _serversJson)
        ..fail('assign', const AbctlCancelled());
      final ProviderContainer container = await _container(
        script,
        workspace: false,
      );

      await _pumpAssign(tester, container, _devices);
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Assign');
      await _settle(tester);

      expect(
        find.text('Stopped — what reached Apple is unknown'),
        findsOneWidget,
      );
      expect(find.text('Unknown'), findsNWidgets(_devices.length));
    });

    testWidgets('a double activation submits one activity, not two', (
      WidgetTester tester,
    ) async {
      // REGRESSION. `_run` opened with `if (server == null) return;` and nothing else, while its
      // siblings in `config_editor_dialog` open with `if (_writing) return;` / `if (_deleting)
      // return;`. The window is one frame, but what leaks through it is not cosmetic: the second
      // run overwrites `_cancel`, so the footer's Cancel reaches only that one and the FIRST
      // activity runs on against the tenant with nothing on screen tracking it.
      final _Script script = _Script()
        ..reply('mdmservers', _serversJson)
        ..reply('assign', _assignOkJson);
      final ProviderContainer container = await _container(
        script,
        workspace: false,
      );

      await _pumpAssign(tester, container, _devices);
      await _tapText(tester, 'Continue');

      // Two activations inside one frame — no pump between them, which is exactly what a
      // double-click or a synthesized `activate` produces.
      final Finder button = find.text('Assign').last;
      await tester.tap(button, warnIfMissed: false);
      await tester.tap(button, warnIfMissed: false);
      await _settle(tester);

      expect(
        script.verbs.where((String verb) => verb == 'assign'),
        hasLength(1),
        reason: 'one approval, one activity',
      );
    });

    testWidgets('an activity accepted for fewer devices is not a clean run', (
      WidgetTester tester,
    ) async {
      final _Script script = _Script()
        ..reply('mdmservers', _serversJson)
        ..reply('assign', _assignPartialJson);
      final ProviderContainer container = await _container(
        script,
        workspace: false,
      );

      await _pumpAssign(tester, container, _devices);
      await _tapText(tester, 'Continue');
      await _tapText(tester, 'Assign');
      await _settle(tester);

      // The response says how many, never which — so no row is told it succeeded.
      expect(find.text('Unconfirmed'), findsNWidgets(2));
      final NoticeBanner banner = tester.widget<NoticeBanner>(
        find.byType(NoticeBanner),
      );
      expect(banner.text, contains('1 of 2'));
    });
  });
}

// -------------------------------------------------------------------------------------------
// harness
// -------------------------------------------------------------------------------------------

/// One recorded invocation: what abctl was asked to run, from where, and on what budget.
class _Call {
  const _Call(this.args, this.cwd, this.timeout);

  final List<String> args;
  final String? cwd;
  final Duration timeout;
}

/// A scripted abctl: canned stdout per verb, or a typed failure.
///
/// Keyed on the FIRST token, which is the verb for every command this surface can produce.
class _Script {
  final Map<String, String> _replies = <String, String>{};

  /// Typed, not `Object`: the dialogs branch on the failure's TYPE (a timeout leaves a different
  /// tenant state behind than a refusal), so a fake that could hand back anything would be
  /// exercising a path the real client cannot produce.
  final Map<String, AbctlError> _failures = <String, AbctlError>{};
  final List<_Call> calls = <_Call>[];

  void reply(String verb, String stdout) => _replies[verb] = stdout;

  void fail(String verb, AbctlError error) => _failures[verb] = error;

  List<String> get verbs => <String>[
    for (final _Call call in calls) _verbOf(call.args),
  ];

  _Call callFor(String verb) =>
      calls.firstWhere((_Call call) => _verbOf(call.args) == verb);

  /// `get configurations` and `get mdmservers` are keyed on their NOUN — the verb alone would
  /// make every plural read indistinguishable.
  static String _verbOf(List<String> args) =>
      args.first == 'get' && args.length > 1 ? args[1] : args.first;

  Future<AbctlResult> run(_Call call) async {
    calls.add(call);
    final String verb = _verbOf(call.args);
    final AbctlError? failure = _failures[verb];
    if (failure != null) throw failure;
    return AbctlResult(
      stdout: Uint8List.fromList(utf8.encode(_replies[verb] ?? '[]')),
      stderr: '',
      code: 0,
    );
  }
}

class _ScriptedRunner implements AbctlRunner {
  const _ScriptedRunner(this.script);

  final _Script script;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) => script.run(_Call(List<String>.unmodifiable(args), cwd, timeout));
}

/// Overrides the PROCESS seam and nothing above it, then scopes the client to a tenant (so the
/// `--context` tail is exercised, not assumed) and optionally to a workspace.
Future<ProviderContainer> _container(
  _Script script, {
  required bool workspace,
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      abctlRunnerFactoryProvider.overrideWithValue(
        ({void Function(String line)? onStderrLine}) => _ScriptedRunner(script),
      ),
      runLogOpenerProvider.overrideWithValue((_) async => null),
    ],
  );
  addTearDown(container.dispose);
  container.read(activeContextProvider.notifier).select('prod');
  if (workspace) {
    await container.read(gitopsProvider.notifier).setWorkspace(_workspace());
  }
  return container;
}

String _workspace() {
  final Directory root = Directory.systemTemp.createTempSync('abgui_write_');
  Directory('${root.path}${Platform.pathSeparator}gitops').createSync();
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root.path;
}

Future<void> _pumpMembership(
  WidgetTester tester,
  ProviderContainer container,
) => _pump(
  tester,
  container,
  const MembershipDialog(
    blueprint: Resource(
      type: 'blueprints',
      id: 'bp-1',
      attributes: JSONValue(<String, Object?>{'name': 'Fleet-A'}),
    ),
  ),
);

Future<void> _pumpAssign(
  WidgetTester tester,
  ProviderContainer container,
  List<Resource> devices,
) => _pump(tester, container, AssignDialog(devices: devices));

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget dialog,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: abTheme(Brightness.light),
        home: Scaffold(body: dialog),
      ),
    ),
  );
  await _settle(tester);
}

/// `pumpAndSettle` is unusable on these dialogs: a loading pane draws a
/// `CircularProgressIndicator` and the running stage drives a live elapsed reading, neither of
/// which ever stops animating. Fixed steps do the same job deterministically.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _tapText(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await _settle(tester);
}

/// Pick one of the choice cards by the first word of its title ('Attach', 'Adopt', 'Unassign').
Future<void> _chooseAction(WidgetTester tester, String title) async {
  await tester.tap(
    find.byWidgetPredicate(
      (Widget widget) =>
          widget is AbChoiceCard && widget.title.startsWith(title),
    ),
  );
  await _settle(tester);
}

/// Select a configuration row by its id — the table keys rows on it.
Future<void> _pickConfiguration(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey<String>(id)));
  await _settle(tester);
}

// -------------------------------------------------------------------------------------------
// fixtures
// -------------------------------------------------------------------------------------------

final String _configurationsJson = jsonEncode(<Map<String, Object?>>[
  <String, Object?>{
    'type': 'configurations',
    'id': 'c1',
    'attributes': <String, Object?>{
      'name': 'WiFi-Corp.mobileconfig',
      'type': 'CUSTOM_SETTING',
    },
  },
]);

/// A tenant whose configuration list holds one attachable row and one Apple-managed one.
final String _mixedConfigurationsJson = jsonEncode(<Map<String, Object?>>[
  <String, Object?>{
    'type': 'configurations',
    'id': 'c1',
    'attributes': <String, Object?>{
      'name': 'WiFi-Corp.mobileconfig',
      'type': 'CUSTOM_SETTING',
    },
  },
  <String, Object?>{
    'type': 'configurations',
    'id': 'c2',
    'attributes': <String, Object?>{
      'name': 'Restrictions',
      'type': 'RESTRICTIONS',
    },
  },
]);

final String _serversJson = jsonEncode(<Map<String, Object?>>[
  <String, Object?>{
    'type': 'mdmServers',
    'id': 's1',
    'attributes': <String, Object?>{
      'serverName': 'Built-in MDM',
      'serverType': 'APPLE_MDM',
    },
  },
]);

const String _attachOkJson =
    '{"action":"attach","name":"WiFi-Corp.mobileconfig","id":"c1",'
    '"status":"done","blueprint":"Fleet-A","treeUpdated":true}';

const String _attachTreeFailedJson =
    '{"action":"attach","name":"WiFi-Corp.mobileconfig","id":"c1",'
    '"status":"done","blueprint":"Fleet-A","treeUpdated":false,'
    '"treeError":"mkdir /gitops/blueprints: read-only file system"}';

const String _adoptOkJson =
    '{"action":"adopt","name":"WiFi-Corp.mobileconfig","id":"c1",'
    '"status":"done","blueprint":"Fleet-A","treeUpdated":true}';

const String _assignOkJson =
    '{"action":"assign","server":"Built-in MDM","devices":2,"activityId":"act-42"}';

const String _assignPartialJson =
    '{"action":"assign","server":"Built-in MDM","devices":1,"activityId":"act-43"}';

const String _unassignOkJson =
    '{"action":"unassign","server":"Built-in MDM","devices":2,"activityId":"act-44"}';

const String _activityJson =
    '{"type":"orgDeviceActivities","id":"act-42","attributes":'
    '{"status":"IN_PROGRESS","subStatus":"SUBMITTED_TO_SERVER",'
    '"createdDateTime":"2026-08-15T00:00:00Z",'
    '"downloadUrl":"https://example.invalid/act-42.csv"}}';

final List<Resource> _devices = <Resource>[
  const Resource(
    type: 'orgDevices',
    id: 'd1',
    attributes: JSONValue(<String, Object?>{
      'serialNumber': 'C02AAA',
      'deviceModel': 'MacBook Pro',
    }),
  ),
  const Resource(
    type: 'orgDevices',
    id: 'd2',
    attributes: JSONValue(<String, Object?>{
      'serialNumber': 'C02BBB',
      'deviceModel': 'MacBook Air',
    }),
  ),
];
