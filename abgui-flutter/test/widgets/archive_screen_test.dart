// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The rollback surface. Listing is a filesystem walk and reaches nothing; Restore is a gated
// tenant write, and it is the reason this file is a battery rather than a smoke test.
//
// Five rules are pinned here, each because getting it wrong destroys a production configuration
// profile rather than annoying somebody:
//
//   1. An entry with no readable sidecar CANNOT be restored. Its name is the directory slug, and
//      a slug that happens to match a different configuration would overwrite that one.
//   2. Restore runs the gated argv against the SIDECAR's name, in the workspace, with the
//      archived bytes on stdin — verbatim, never decoded and re-encoded.
//   3. Nothing runs until the confirmation is answered yes.
//   4. A write that reached Apple Business but not gitops/ is not reported as clean.
//   5. The viewer reads its file ONCE, into state, never from `build`.
//
// Nothing reaches a real abctl: the PROCESS seam is overridden and everything above it — the
// recording runner, the command log, the redaction, the client's decode-before-exit-code rule —
// is the app's own.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/archive.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/dialogs/archived_file_dialog.dart';
import 'package:abgui/src/ui/screens/archive_screen.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('ArchiveScreen', () {
    testWidgets('lists what abctl filed, under the name the sidecar gives it', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      _archive(root, dir: 'WiFi-Corp', stem: '20260101T000000Z--replaced');

      await _pumpArchive(tester, root);

      // The SIDECAR's name, not the folder's: the folder is a slug, and a slug is not what the
      // profile is called in Apple Business.
      expect(find.text('WiFi Corp.mobileconfig'), findsOneWidget);
      expect(_badge('replaced'), findsOneWidget);
      expect(find.textContaining('Reversible'), findsOneWidget);
    });

    testWidgets('an entry with no readable sidecar cannot be restored', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      _archive(root, dir: 'VPN', stem: 'x', sidecar: 'not json at all');
      final List<List<String>> ran = <List<String>>[];

      await _pumpArchive(tester, root, argv: ran);
      await _select(tester, 'VPN (?)');

      final ToolbarButton restore = tester.widget<ToolbarButton>(
        _control('Restore'),
      );
      expect(
        restore.onPressed,
        isNull,
        reason:
            'abgui only knows the folder this sits in, and restoring against a guess could '
            'overwrite a DIFFERENT configuration',
      );
      expect(
        restore.tooltip,
        contains('no readable sidecar'),
        reason: 'a disabled control still has to say why',
      );
      // Viewing is still offered: the archived profile is the only copy of those bytes, and
      // refusing to restore it is not a reason to hide it.
      expect(
        tester.widget<ToolbarButton>(_control('View')).onPressed,
        isNotNull,
      );
      expect(ran, isEmpty);
    });

    testWidgets('restore sends the gated argv, the sidecar name and the bytes', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      _archive(root, dir: 'WiFi-Corp', stem: 'v1');
      final List<List<String>> ran = <List<String>>[];
      final List<List<int>?> stdins = <List<int>?>[];
      final List<String?> cwds = <String?>[];

      await _pumpArchive(
        tester,
        root,
        argv: ran,
        stdins: stdins,
        cwds: cwds,
        response: _ok(_outcomeJson),
      );
      await _select(tester, 'WiFi Corp.mobileconfig');
      await _tap(tester, _control('Restore'));

      // Nothing has run yet: the confirmation is up.
      expect(ran, isEmpty, reason: 'the gate comes before the command');
      expect(find.text('Restore this archived version?'), findsOneWidget);
      // The promise that makes this usable, and it is true — `replace` archives the live version
      // before it PATCHes.
      expect(find.textContaining('reversible undo'), findsOneWidget);
      expect(
        find.text(
          'abctl replace config \'WiFi Corp.mobileconfig\' -f - --yes --json',
        ),
        findsOneWidget,
      );

      await _tap(tester, find.widgetWithText(FilledButton, 'Restore'));

      expect(ran.single, <String>[
        'replace',
        'config',
        'WiFi Corp.mobileconfig',
        '-f',
        '-',
        '--yes',
        '--json',
      ]);
      expect(
        utf8.decode(stdins.single!),
        _profileXml,
        reason:
            'the archived bytes go through verbatim — a decode/re-encode round trip is a chance '
            'to change what Apple stores',
      );
      expect(
        cwds.single,
        root.path,
        reason:
            'replace writes the gitops/ half of this change too, and abctl roots that tree at '
            'its working directory',
      );
    });

    testWidgets('cancelling the confirmation writes nothing', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      _archive(root, dir: 'WiFi-Corp', stem: 'v1');
      final List<List<String>> ran = <List<String>>[];

      await _pumpArchive(tester, root, argv: ran);
      await _select(tester, 'WiFi Corp.mobileconfig');
      await _tap(tester, _control('Restore'));
      await _tap(tester, find.widgetWithText(TextButton, 'Cancel'));

      expect(ran, isEmpty);
      expect(find.textContaining('Restore failed'), findsNothing);
    });

    testWidgets('a restore that missed gitops/ is not reported as clean', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      _archive(root, dir: 'WiFi-Corp', stem: 'v1');

      await _pumpArchive(tester, root, response: _ok(_halfDoneJson));
      await _select(tester, 'WiFi Corp.mobileconfig');
      await _tap(tester, _control('Restore'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Restore'));

      final Iterable<NoticeBanner> banners = tester.widgetList<NoticeBanner>(
        find.byType(NoticeBanner),
      );
      expect(
        banners.any((NoticeBanner b) => b.tone == AbSeverity.ok),
        isFalse,
        reason:
            'Apple has the change and git does not — a green tick here is how that drift becomes '
            'a mystery next week',
      );
      final NoticeBanner result = _resultBanner(banners);
      expect(result.text, 'Restored on Apple Business only');
      expect(result.tone, AbSeverity.drift);
      expect(
        result.detail,
        contains('read-only file system'),
        reason: 'abctl\'s own account of why the git half did not land',
      );
    });

    testWidgets('a failed restore says so and leaves the table readable', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      _archive(root, dir: 'WiFi-Corp', stem: 'v1');

      await _pumpArchive(
        tester,
        root,
        response: _exit(1, 'configuration not found in Apple Business'),
      );
      await _select(tester, 'WiFi Corp.mobileconfig');
      await _tap(tester, _control('Restore'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Restore'));

      final NoticeBanner failure = _resultBanner(
        tester.widgetList<NoticeBanner>(find.byType(NoticeBanner)),
      );
      expect(failure.text, 'Restore failed');
      expect(failure.tone, AbSeverity.danger);
      expect(failure.detail, contains('not found in Apple Business'));
      // The rows are still there. The Swift original emitted its table and its error as two bare
      // siblings into a one-view slot, so the error composited across the middle of the rows —
      // visible only after a write had already failed.
      expect(find.text('WiFi Corp.mobileconfig'), findsOneWidget);
    });

    testWidgets('a restore re-scans, so the version it replaced is listed', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      _archive(root, dir: 'WiFi-Corp', stem: 'v1');

      await _pumpArchive(
        tester,
        root,
        response: _ok(_outcomeJson),
        // abctl archives the live version as part of `replace`; the script does the same thing
        // to the temp tree, which is what the re-scan is supposed to notice.
        onRun: () => _archive(
          root,
          dir: 'WiFi-Corp',
          stem: 'v2',
          archivedAt: '2026-02-02T00:00:00Z',
        ),
      );
      await _select(tester, 'WiFi Corp.mobileconfig');
      await _tap(tester, _control('Restore'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Restore'));

      expect(
        find.text('v2.mobileconfig'),
        findsOneWidget,
        reason:
            'the confirmation promised the replaced version would be here; a table that does not '
            'list it makes that promise false',
      );
      expect(find.textContaining('newest row below'), findsOneWidget);
    });
  });

  group('ArchivedFileDialog', () {
    testWidgets('reads the archived file once, into state — never from build', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      final ArchiveEntry entry = _entry(
        _archive(root, dir: 'WiFi-Corp', stem: 'v1'),
      );

      await _pumpDialog(tester, ArchivedFileDialog(entry: entry));
      expect(find.textContaining('PayloadDisplayName'), findsOneWidget);

      // Delete the file, then rebuild the same element tree with a different theme: the State
      // survives, `build` runs again, and a read living in `build` would now fail.
      File(entry.filePath).deleteSync();
      await _pumpDialog(
        tester,
        ArchivedFileDialog(entry: entry),
        brightness: Brightness.dark,
      );
      expect(find.textContaining('PayloadDisplayName'), findsOneWidget);
    });

    testWidgets(
      'a signed profile is explained rather than rendered as mojibake',
      (WidgetTester tester) async {
        final Directory root = _workspace();
        final ArchiveEntry entry = _entry(
          _archive(
            root,
            dir: 'WiFi-Corp',
            stem: 'v1',
            // A lone 0x80 continuation byte: valid PKCS#7, invalid UTF-8.
            body: <int>[0x30, 0x82, 0x80, 0x01],
          ),
        );

        await _pumpDialog(tester, ArchivedFileDialog(entry: entry));

        expect(find.text('Nothing to show for this file'), findsOneWidget);
        expect(find.textContaining('binary PKCS#7 envelope'), findsOneWidget);
        expect(
          find.textContaining('can still be restored'),
          findsOneWidget,
          reason:
              'unreadable here is not the same as unusable, and the difference decides whether '
              'somebody gives up',
        );
      },
    );

    testWidgets('it says the body can carry secrets, and offers no export', (
      WidgetTester tester,
    ) async {
      final Directory root = _workspace();
      final ArchiveEntry entry = _entry(
        _archive(root, dir: 'WiFi-Corp', stem: 'v1'),
      );

      await _pumpDialog(tester, ArchivedFileDialog(entry: entry));

      expect(find.textContaining('Wi-Fi passwords'), findsOneWidget);
      expect(
        tester
            .widgetList<ToolbarButton>(find.byType(ToolbarButton))
            .where(
              (ToolbarButton b) =>
                  b.label.contains('Export') || b.label.contains('Save'),
            ),
        isEmpty,
        reason:
            'the archived body is never written anywhere new on disk — that is the rule this '
            'screen holds, and a Save button would be the exception that ends it',
      );
    });
  });
}

// -------------------------------------------------------------------------------------------
// fixtures
// -------------------------------------------------------------------------------------------

const String _profileXml =
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<plist version="1.0"><dict><key>PayloadDisplayName</key><string>Wi-Fi</string></dict></plist>';

const String _outcomeJson =
    '{"action":"replace","name":"WiFi Corp.mobileconfig","id":"cfg-1","status":"done",'
    '"archive":"gitops/archive/WiFi-Corp/v2.mobileconfig","treeUpdated":true}';

/// The tenant write landed, the git half did not. `WriteOutcome.treeWarning` is what turns this
/// into a sentence, and the banner's tone is what stops it reading as a success.
const String _halfDoneJson =
    '{"action":"replace","name":"WiFi Corp.mobileconfig","id":"cfg-1","status":"done",'
    '"treeUpdated":false,"treeError":"read-only file system"}';

/// Write one archived profile plus its sidecar, and answer the profile's path.
String _archive(
  Directory root, {
  required String dir,
  required String stem,
  String name = 'WiFi Corp.mobileconfig',
  String reason = 'replaced',
  String archivedAt = '2026-01-01T00:00:00Z',
  String? sidecar,
  List<int>? body,
}) {
  final String separator = Platform.pathSeparator;
  final Directory folder = Directory(
    '${root.path}${separator}gitops${separator}archive$separator$dir',
  )..createSync(recursive: true);
  final String path = '${folder.path}$separator$stem.mobileconfig';
  File(path).writeAsBytesSync(body ?? utf8.encode(_profileXml));
  File('${folder.path}$separator$stem.json').writeAsStringSync(
    sidecar ??
        '{"name":"$name","reason":"$reason","archivedAt":"$archivedAt",'
            '"file":"$stem.mobileconfig"}',
  );
  return path;
}

ArchiveEntry _entry(String path) => ArchiveEntry(
  configName: 'WiFi Corp.mobileconfig',
  reason: 'replaced',
  archivedAt: '2026-01-01T00:00:00Z',
  filePath: path,
  hasSidecar: true,
);

// -------------------------------------------------------------------------------------------
// harness
// -------------------------------------------------------------------------------------------

Finder _control(String label) => find.byWidgetPredicate(
  (Widget widget) => widget is ToolbarButton && widget.label == label,
  description: 'ToolbarButton("$label")',
);

/// The banner about the last restore, as opposed to the standing "Reversible" one this screen
/// always wears. Asserted through the WIDGET rather than through `find.text`, because a
/// [NoticeBanner] renders its headline and its detail as one `Text.rich` — so `find.text` would
/// be matching a sentence assembled by the widget, and a reworded detail would fail a test that
/// is about the headline and the tone.
NoticeBanner _resultBanner(Iterable<NoticeBanner> banners) =>
    banners.firstWhere(
      (NoticeBanner banner) => banner.text != 'Reversible',
      orElse: () =>
          throw StateError('no result banner: ${banners.length} shown'),
    );

Finder _badge(String label) => find.byWidgetPredicate(
  (Widget widget) => widget is AbBadge && widget.label == label,
  description: 'AbBadge("$label")',
);

/// Wait for the real-world work this screen does, then settle.
///
/// **Two things fight a plain `pumpAndSettle` here, and both are properties of the screen rather
/// than of the test.** The archive walk runs in an `Isolate` and every file read is `dart:io`
/// async, so both complete on the REAL event loop — which the binding's fake clock cannot advance,
/// and which only `runAsync` yields to. And while the walk is in flight the pane shows a spinner,
/// an animation that never stops scheduling frames, so `pumpAndSettle` alone would time out
/// instead of waiting.
///
/// Hence: always at least [minPasses] of wall-clock time (a file read finishes in one, and it
/// finishes without ever raising a spinner), then keep going while a spinner is up. Bounded, so a
/// genuinely stuck read fails the test rather than hanging it.
Future<void> _settle(WidgetTester tester) async {
  const int minPasses = 5;
  for (int attempt = 0; attempt < 60; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    final bool busy = find
        .byType(CircularProgressIndicator)
        .evaluate()
        .isNotEmpty;
    if (!busy && attempt >= minPasses) break;
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await _settle(tester);
}

/// Click a row by the text in its Configuration cell.
Future<void> _select(WidgetTester tester, String cell) =>
    _tap(tester, find.text(cell));

Future<void> _pumpArchive(
  WidgetTester tester,
  Directory workspace, {
  List<List<String>>? argv,
  List<List<int>?>? stdins,
  List<String?>? cwds,
  AbctlResult? response,
  void Function()? onRun,
}) async {
  final ProviderContainer container = _container((
    List<String> args,
    String? cwd,
    List<int>? stdin,
  ) async {
    argv?.add(args);
    stdins?.add(stdin);
    cwds?.add(cwd);
    onRun?.call();
    return response ?? _ok(_outcomeJson);
  });
  await container.read(gitopsProvider.notifier).setWorkspace(workspace.path);
  await _pump(tester, container, const ArchiveScreen());
}

Future<void> _pumpDialog(
  WidgetTester tester,
  Widget dialog, {
  Brightness brightness = Brightness.light,
}) => _pump(
  tester,
  _container(
    (List<String> args, String? cwd, List<int>? stdin) async => _ok(''),
  ),
  dialog,
  brightness: brightness,
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget screen, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
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
  // The scan and the dialog's read both start from a post-frame callback (Riverpod refuses a
  // provider modified during a build), so a pump is what actually starts them.
  await tester.pump();
  await _settle(tester);
}

/// Overrides the PROCESS seam and nothing above it.
ProviderContainer _container(
  Future<AbctlResult> Function(List<String> args, String? cwd, List<int>? stdin)
  handler,
) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      abctlRunnerFactoryProvider.overrideWithValue(
        ({void Function(String line)? onStderrLine}) =>
            _ScriptedRunner(handler),
      ),
      runLogOpenerProvider.overrideWithValue((_) async => null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Directory _workspace() {
  final Directory root = Directory.systemTemp.createTempSync('abgui_arch_');
  Directory('${root.path}${Platform.pathSeparator}gitops').createSync();
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

class _ScriptedRunner implements AbctlRunner {
  const _ScriptedRunner(this.handler);

  final Future<AbctlResult> Function(
    List<String> args,
    String? cwd,
    List<int>? stdin,
  )
  handler;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) => handler(args, cwd, stdin);
}

AbctlResult _ok(String stdout) => AbctlResult(
  stdout: Uint8List.fromList(utf8.encode(stdout)),
  stderr: '',
  code: 0,
);

AbctlResult _exit(int code, String stderr) =>
    AbctlResult(stdout: Uint8List(0), stderr: stderr, code: code);
