// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Port note (rule 6): the Swift type conformed to SwiftUI's `FileDocument` so `.fileExporter`
// could hand it to a save panel. That conformance is macOS plumbing, not contract — in Flutter
// the save dialog comes from `file_selector` and wants bytes — so what survives here is the
// part that IS the contract: the encoding. It is a pure function of headers and rows, which
// also makes it testable without a widget tree or a file system.

/// Builds an RFC-4180 CSV document (the read-only list screens' Export CSV).
///
/// Mirrors abctl's CSV output (internal/cli/output.go): fields containing a comma, quote, or
/// newline are quoted with embedded quotes doubled, and tenant-controlled cell values are
/// neutralized against spreadsheet formula injection. Header row first, LF-terminated lines
/// like abctl's — so a CSV exported from the GUI diffs cleanly against one piped from the CLI.
///
/// Cells are formula-neutralized; headers are our own literals, so they are quoted but not
/// prefixed.
String csvDocument({
  required List<String> headers,
  required List<List<String>> rows,
}) {
  final lines = <String>[_csvLine(headers)];
  for (final row in rows) {
    lines.add(_csvLine(row.map(csvSanitizeCell).toList(growable: false)));
  }
  return '${lines.join('\n')}\n';
}

String _csvLine(List<String> fields) => fields.map(csvQuoteField).join(',');

/// RFC-4180 quoting: wrap the field in quotes when it contains a comma, quote, or newline,
/// doubling any embedded quotes; otherwise emit it verbatim.
String csvQuoteField(String field) {
  if (!field.contains(',') &&
      !field.contains('"') &&
      !field.contains('\n') &&
      !field.contains('\r')) {
    return field;
  }
  return '"${field.replaceAll('"', '""')}"';
}

/// Neutralizes spreadsheet formula injection exactly like abctl's csvSanitize: cells starting
/// with '=', '+', '-', '@', tab, or CR are interpreted as formulas by Excel/LibreOffice/Google
/// Sheets, so they get a leading single quote — the standard mitigation, rendered as a literal
/// by spreadsheets.
///
/// Note the interaction with [csvQuoteField], which runs afterwards: a cell starting with CR
/// becomes `'\r…`, which then quotes as a multi-line field. That ordering is abctl's and is
/// preserved deliberately — sanitize decides the CONTENT, quote decides the FRAMING.
String csvSanitizeCell(String field) {
  if (field.isEmpty) return field;
  switch (field[0]) {
    case '=':
    case '+':
    case '-':
    case '@':
    case '\t':
    case '\r':
      return "'$field";
    default:
      return field;
  }
}
