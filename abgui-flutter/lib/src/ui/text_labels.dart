// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The last component of a filesystem path, for use as a LABEL.
///
/// **One copy, and it earned its own file by being written three times.** The Diff screen, the
/// Apply dialog and the Validate dialog each grew an identical private `_folderName` while the
/// screens were being built in parallel, and one of them had already started to drift in its
/// comment. That matters more here than the duplication suggests: the string this returns is what
/// the Apply dialog asks an operator to TYPE when there is no named context — it is the
/// confirmation phrase for a command that can delete production configuration profiles — and two
/// implementations of a confirmation phrase is one too many.
///
/// Both separators are split on rather than `Platform.pathSeparator`, and that is deliberate
/// rather than defensive: a Windows user can type a forward-slash path, a workspace path
/// remembered in preferences can have come from another machine, and this function is never used
/// to REACH the folder — only to name it. It imports nothing, so a view can call it without
/// pulling `dart:io` into the widget layer.
///
/// A path that is nothing but separators (or empty) answers with the path itself: an empty label
/// under "Type … to enable Apply" would be a gate with nothing to type, and the caller
/// ([ApplyDialog]) treats an empty phrase as permanently closed for exactly that reason.
String folderLabel(String path) {
  final List<String> parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((String part) => part.isNotEmpty)
      .toList(growable: false);
  return parts.isEmpty ? path : parts.last;
}

/// How many lines a document has, for the gutter reading beside an editor or a viewer.
///
/// Counts SEPARATORS plus one, which is what a text editor shows: an empty buffer is line 1, and
/// a buffer ending in a newline has a real (empty) last line. Shared because
/// `config_editor_dialog` and `profile_dialog` had byte-identical copies — the same document,
/// counted twice.
int lineCount(String text) => '\n'.allMatches(text).length + 1;

/// A byte count in the units Apple Business's 1 MiB configuration cap is actually expressed in.
///
/// **BINARY units, spelled as binary units, and that is the bug this function was extracted to
/// fix.** There were two private copies of this — `config_editor_dialog` and `validate_dialog` —
/// and they had already drifted: both divided by 1024, but one labelled the result `KiB`/`MiB`
/// and the other `KB`/`MB`. So the same profile was "996 KiB" on the editor and "996.0 KB" on the
/// validation report, and the second label was simply wrong about its own arithmetic. On the one
/// screen pair whose job is to say whether a profile fits under a 1 MiB limit, two answers to
/// "how big is it" is not a cosmetic problem.
///
/// The precision tapers on purpose: a tenth of a KiB matters at 3.4 KiB and is noise at 812 KiB,
/// where what the reader is doing is comparing against 1024.
String byteSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final double kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KiB';
  return '${(kib / 1024).toStringAsFixed(2)} MiB';
}
