// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The icon table is data the model layer hands to the view layer as bare strings, which means a
// typo or a missing row is a runtime miss, not a compile error. These tests are the compiler
// that string-keyed lookup does not have: the symbols the models actually emit must resolve, and
// a name nobody mapped must fall back rather than take down the frame that drew it.

import 'package:abgui/src/models/read_only_kind.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fallback', () {
    test('an unmapped name falls back instead of throwing', () {
      // `abIcon` is called from `build`. Throwing there costs the whole screen over a glyph.
      expect(() => abIcon('not.a.real.symbol'), returnsNormally);
      expect(abIcon('not.a.real.symbol'), abIconFallback);
      expect(abIcon(''), abIconFallback);
      expect(abIconOrNull('not.a.real.symbol'), isNull);
    });

    test('the fallback is distinguishable from a mapped unknown-data glyph', () {
      // `questionmark.circle` MEANS "we could not identify this"; the fallback means "nobody
      // wrote a row". Collapsing them would hide every missing mapping behind a plausible icon.
      expect(abIcon('questionmark.circle'), isNot(abIconFallback));
    });
  });

  group('coverage', () {
    test('every ReadOnlyKind symbol resolves', () {
      // A kind added without a row would render as the fallback in three places at once: the
      // sidebar, its dashboard tile and its empty state.
      for (final kind in ReadOnlyKind.values) {
        expect(
          abIconOrNull(kind.symbol),
          isNotNull,
          reason: '${kind.wire} uses "${kind.symbol}", which has no icon',
        );
      }
    });

    test('every sidebar symbol from the macOS original resolves', () {
      // Pinned by name rather than read from a Dart sidebar model, because the sidebar is being
      // ported: this list is the frozen Swift `SidebarItem.symbol` switch, and it must keep
      // resolving as the port fills in.
      const List<String> sidebar = <String>[
        'square.grid.2x2', // Dashboard
        'stethoscope', // System Health
        'terminal', // Command Log
        'doc.text.magnifyingglass', // Logs
        'chevron.left.forwardslash.chevron.right', // Console
        'sparkles', // What's New
        'doc.text', // Configurations
        'square.stack.3d.up', // Blueprints
        'arrow.triangle.branch', // Diff / Drift
        'clock.arrow.circlepath', // Archive
        'apple.logo', // OS Releases
        'cart', // Apps & Books
        'circle', // the Swift switch's own default
      ];
      for (final symbol in sidebar) {
        expect(
          abIconOrNull(symbol),
          isNotNull,
          reason: '"$symbol" has no icon',
        );
      }
    });
  });

  group('weight', () {
    test('a fill variant is a different glyph from its outline', () {
      // The `.fill` symbols are an escalation in the original — a resolved status, a banner that
      // wants to be noticed. Mapping both halves of a pair to one glyph silently deletes that
      // distinction, and it is the easiest mistake to make while adding rows in bulk.
      const Map<String, String> pairs = <String, String>{
        'checkmark.circle': 'checkmark.circle.fill',
        'checkmark.seal': 'checkmark.seal.fill',
        'xmark.circle': 'xmark.circle.fill',
        'info.circle': 'info.circle.fill',
        'exclamationmark.triangle': 'exclamationmark.triangle.fill',
        'lock': 'lock.fill',
        'circle': 'circle.fill',
      };
      pairs.forEach((String outline, String filled) {
        final IconData? a = abIconOrNull(outline);
        final IconData? b = abIconOrNull(filled);
        expect(a, isNotNull, reason: '"$outline" has no icon');
        expect(b, isNotNull, reason: '"$filled" has no icon');
        expect(a, isNot(b), reason: '"$outline" and "$filled" share a glyph');
      });
    });
  });
}
