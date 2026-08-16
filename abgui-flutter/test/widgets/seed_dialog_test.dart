// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The gate in front of `abctl seed`.
//
// `GitopsStore` refuses to seed over an existing tree unless it is handed
// `SeedConsent.overwriteExistingTree` (pinned in `test/state/seed_test.dart`). What is pinned HERE
// is the other half: that the value travels from a dialog which actually told the user what they
// were agreeing to. A store that refuses correctly, in front of a dialog that hands over the
// overwrite value without mentioning the overwrite, is a gate with nobody at it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/ui/dialogs/seed_dialog.dart';
import 'package:abgui/src/ui/theme.dart';

void main() {
  testWidgets('an empty folder is an explanation, and consents to no more', (
    WidgetTester tester,
  ) async {
    final SeedConsent? consent = await _answer(
      tester,
      hasTree: false,
      press: 'Initialize',
    );

    expect(
      consent,
      SeedConsent.onlyIfAbsent,
      reason:
          'the user agreed to seed an EMPTY folder — handing back the overwrite value here would '
          'let a tree created between the check and the run be silently rewritten',
    );
  });

  testWidgets('a folder with a tree says what is lost before it consents', (
    WidgetTester tester,
  ) async {
    await _show(tester, hasTree: true);

    expect(
      find.text('Re-seed this workspace from the tenant?'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'any local edit that has not been synced is replaced',
      ),
      findsOneWidget,
      reason: 'the sentence has to name what is lost, not that something is',
    );
    expect(find.textContaining('Commit or stash first'), findsOneWidget);
    // The command, from the builder, with the cd that makes it correct — `seed` has no path flag,
    // so the directory IS the argument.
    expect(find.text('abctl seed'), findsOneWidget);
    expect(find.textContaining('No --yes'), findsOneWidget);
  });

  testWidgets('the overwrite value comes only from the overwrite button', (
    WidgetTester tester,
  ) async {
    expect(
      await _answer(tester, hasTree: true, press: 'Re-seed'),
      SeedConsent.overwriteExistingTree,
    );
  });

  testWidgets('cancelling consents to nothing', (WidgetTester tester) async {
    expect(await _answer(tester, hasTree: true, press: 'Cancel'), isNull);
    expect(await _answer(tester, hasTree: false, press: 'Cancel'), isNull);
  });
}

// -------------------------------------------------------------------------------------------
// harness
// -------------------------------------------------------------------------------------------

const String _workspace = '/work/tenant-a';

Future<SeedConsent?> _answer(
  WidgetTester tester, {
  required bool hasTree,
  required String press,
}) async {
  SeedConsent? answer;
  var answered = false;
  await _show(
    tester,
    hasTree: hasTree,
    onAnswer: (SeedConsent? value) {
      answer = value;
      answered = true;
    },
  );
  // The label, not the button type: Cancel is a `TextButton` and the other two are `FilledButton`s,
  // and `widgetWithText` matches on the exact runtime type rather than on the shared base class.
  await tester.tap(find.text(press));
  await tester.pumpAndSettle();
  expect(answered, isTrue, reason: 'the dialog closed without answering');
  return answer;
}

Future<void> _show(
  WidgetTester tester, {
  required bool hasTree,
  void Function(SeedConsent? consent)? onAnswer,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: abTheme(Brightness.light),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final SeedConsent? consent =
                      await SeedWorkspaceDialog.confirm(
                        context,
                        workspace: _workspace,
                        hasTree: hasTree,
                      );
                  onAnswer?.call(consent);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
