// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The staleness rule, and the reason it is a type. Each case names the Swift bug it prevents:
// `AppModel` kept `loadGeneration` and `workGeneration` as bare `Int`s, and the comment above the
// second one records what happened when they were one.

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/state/load_token.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LoadToken', () {
    test('a newer load makes every older token stale', () {
      final generation = LoadGeneration('pane');

      final first = generation.begin();
      expect(first.isStale, isFalse, reason: 'the only load in flight');

      final second = generation.begin();
      expect(first.isStale, isTrue);
      expect(second.isCurrent, isTrue);

      final third = generation.begin();
      expect(first.isStale, isTrue);
      expect(
        second.isStale,
        isTrue,
        reason: 'newest wins, not most recent-ish',
      );
      expect(third.isCurrent, isTrue);
    });

    // THE bug. Sharing one counter between the resource lists and the plan/seed pair meant
    // navigating to Configurations while a seed was in flight invalidated the SEED's token; its
    // completion guard then failed, `isSeeding` was never cleared, and the Diff screen sat on
    // "Initializing workspace from the tenant…" with every control disabled until relaunch.
    test('independent concerns cannot invalidate each other', () {
      final plan = LoadGeneration('gitops.plan');
      final list = LoadGeneration('inventory.devices');

      final planToken = plan.begin();
      // A whole screen's worth of list loads, exactly as browsing would produce.
      for (var i = 0; i < 5; i++) {
        list.begin();
      }

      expect(
        planToken.isCurrent,
        isTrue,
        reason: 'the plan is still the only plan in flight',
      );
      expect(list.begin().isCurrent, isTrue);
      expect(planToken.isCurrent, isTrue);
    });

    test('invalidate() orphans what is in flight without starting anything', () {
      final generation = LoadGeneration('gitops.plan');
      final inFlight = generation.begin();

      // "The user chose a different workspace": the run against the old one must publish nothing,
      // and nothing new is running yet either.
      generation.invalidate();

      expect(inFlight.isStale, isTrue);
      expect(generation.begin().isCurrent, isTrue);
    });

    test('a token belongs to its issuer, not to a number', () {
      final a = LoadGeneration('a');
      final b = LoadGeneration('b');

      final fromA = a.begin();
      final fromB = b.begin();

      // Same serial (both are the first issued), different issuers — never equal, and neither one
      // can be answered by asking the other.
      expect(fromA == fromB, isFalse);
      expect(
        fromA == a.begin(),
        isFalse,
        reason: 'a later token is a different receipt',
      );
      expect(fromB.isCurrent, isTrue);
    });

    test('toString names the concern, so a failed expectation is readable', () {
      final generation = LoadGeneration('gitops.plan');
      final first = generation.begin();
      generation.begin();

      expect(first.toString(), 'LoadToken(gitops.plan#1, stale)');
    });
  });

  group('loadErrorText', () {
    test('an abctl failure keeps the message written for a human', () {
      expect(
        loadErrorText(const AbctlCliError('blueprint "Lab" not found')),
        'blueprint "Lab" not found',
      );
    });

    test('a missing binary keeps the paths that were searched', () {
      final text = loadErrorText(
        const AbctlMissingBinary(searched: <String>['/a/abctl', '/b/abctl']),
      );

      // The searched list IS the diagnosis for a packaging bug; an error slot that dropped it
      // would leave the reporter with "it says it cannot find it".
      expect(text, contains('/a/abctl'));
      expect(text, contains('/b/abctl'));
    });

    test('anything else falls back to its own description', () {
      expect(loadErrorText(StateError('bad state')), contains('bad state'));
    });
  });
}
