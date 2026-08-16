// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// THE SEAM GUARD. The write screens were built in parallel, and where two of them needed the same
// small thing they each grew their own copy. That is not a tidiness complaint: by the time these
// were found, one pair had already DRIFTED, and it had drifted on the number an operator uses to
// decide whether a profile fits under Apple Business's 1 MiB cap. `config_editor_dialog` and
// `validate_dialog` both divided bytes by 1024; one labelled the result `KiB`/`MiB` and the other
// `KB`/`MB`, so the same profile was "996 KiB" on one screen and "996.0 KB" on the next and one
// of those labels was wrong about its own arithmetic.
//
// So this file does not test behaviour. It asserts that the shared helpers have no private twins
// left, by scanning lib/ for the signatures the duplicates had. A grep-shaped test is the only
// kind that can catch a copy someone adds in a file nobody thought to open — which is exactly how
// each of these arrived.

import 'dart:io';

import 'package:abgui/src/ui/text_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('one implementation per shared helper', () {
    // Each entry: the shared function that now owns the job, and the private signature the
    // duplicates were spelled with. The patterns match a DECLARATION, never a call, so a local
    // variable or an unrelated name cannot trip them.
    final duplicates = <String, RegExp>{
      // Three copies: apply_dialog, validate_dialog, diff_screen. This one matters beyond
      // duplication — the string it returns is the confirmation phrase `ApplyDialog` asks an
      // operator to TYPE when no context is named, in front of a command that can delete
      // production configuration profiles. Two implementations of a confirmation phrase is one
      // too many.
      'folderLabel': RegExp(r'\bString _folderName\s*\('),
      // Two copies, already drifted on their units. See the header.
      'byteSizeLabel': RegExp(r'\bString _sizeText\s*\('),
      // Two byte-identical copies: config_editor_dialog and profile_dialog.
      'lineCount': RegExp(r'\bint _lineCount\s*\('),
      // Two byte-identical copies: assign_dialog and membership_dialog, both rendering the
      // tinted paragraph that explains what a failed write left behind.
      'AbNote (was _sentence)': RegExp(r'\bWidget _sentence\s*\('),
      // Two DIFFERENT widgets sharing one name across apply_dialog and config_editor_dialog —
      // same tint, same radius, different ink, different text widget, different constructor. A
      // reader moving between two write dialogs was reading two things that looked alike and
      // were not.
      'AbNote (was _Note)': RegExp(r'\bclass _Note\b'),
    };

    test('no view re-declares one privately', () {
      final strays = <String>[];
      for (final entry in Directory('lib').listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        final lines = entry.readAsLinesSync().map((line) {
          final comment = line.indexOf('//');
          return comment < 0 ? line : line.substring(0, comment);
        });
        for (final line in lines) {
          duplicates.forEach((shared, pattern) {
            if (pattern.hasMatch(line)) {
              strays.add('${entry.path}: ${line.trim()}  (use $shared)');
            }
          });
        }
      }
      expect(
        strays,
        isEmpty,
        reason:
            'these were extracted because two copies had already disagreed; a third copy '
            'is how the disagreement comes back: $strays',
      );
    });
  });

  group('the shared helpers themselves', () {
    test('folderLabel takes the last component of either separator', () {
      // Both separators rather than `Platform.pathSeparator`: a Windows user can type a
      // forward-slash path, and a workspace path remembered in preferences can have come from
      // another machine. This is only ever a label, never used to reach the folder.
      expect(folderLabel('/tenants/acme'), 'acme');
      expect(folderLabel(r'C:\tenants\acme'), 'acme');
      expect(folderLabel('/tenants/acme/'), 'acme');
      expect(folderLabel('acme'), 'acme');
    });

    test('folderLabel answers something rather than nothing', () {
      // A path that is nothing but separators must not produce an empty phrase: `ApplyDialog`
      // treats an empty confirmation phrase as a gate that can never open (`phrase.isNotEmpty`),
      // so this failing quietly would be a locked Apply button with no explanation.
      expect(folderLabel('/'), '/');
      expect(folderLabel(''), '');
    });

    test('byteSizeLabel is binary and says so', () {
      // The drift this replaced: dividing by 1024 and printing "KB". The units in the label and
      // the units in the arithmetic have to be the same ones, on the pair of screens whose job
      // is to compare a profile against a 1 MiB limit.
      expect(byteSizeLabel(512), '512 B');
      expect(byteSizeLabel(1024), '1.0 KiB');
      expect(byteSizeLabel(1024 * 1024), '1.00 MiB');
      // Precision tapers: a tenth of a KiB matters at 3.4 and is noise at 812.
      expect(byteSizeLabel(3481), '3.4 KiB');
      expect(byteSizeLabel(1024 * 812), '812 KiB');
    });

    test('lineCount counts the way an editor gutter does', () {
      expect(lineCount(''), 1, reason: 'an empty buffer is still line 1');
      expect(lineCount('one'), 1);
      expect(lineCount('one\ntwo'), 2);
      expect(
        lineCount('one\n'),
        2,
        reason: 'a trailing newline opens a real, empty last line',
      );
    });
  });
}
