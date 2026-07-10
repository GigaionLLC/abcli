// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// An RFC-4180 CSV file for `.fileExporter` (the read-only list screens' Export CSV).
/// Mirrors abctl's CSV output (internal/cli/output.go): fields containing a comma,
/// quote, or newline are quoted with embedded quotes doubled, and tenant-controlled
/// cell values are neutralized against spreadsheet formula injection.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    /// The finished CSV text (header row first, LF-terminated lines like abctl's).
    let text: String

    /// Builds the document from column headers + row cells. Cells are formula-
    /// neutralized; headers are our own literals, so they are quoted but not prefixed.
    init(headers: [String], rows: [[String]]) {
        var lines = [Self.line(headers)]
        for row in rows {
            lines.append(Self.line(row.map(Self.sanitize)))
        }
        text = lines.joined(separator: "\n") + "\n"
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    private static func line(_ fields: [String]) -> String {
        fields.map(quote).joined(separator: ",")
    }

    /// RFC-4180 quoting: wrap the field in quotes when it contains a comma, quote,
    /// or newline, doubling any embedded quotes; otherwise emit it verbatim.
    private static func quote(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"")
                || field.contains("\n") || field.contains("\r") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Neutralizes spreadsheet formula injection exactly like abctl's csvSanitize:
    /// cells starting with '=', '+', '-', '@', tab, or CR are interpreted as formulas
    /// by Excel/LibreOffice/Google Sheets, so they get a leading single quote — the
    /// standard mitigation, rendered as a literal by spreadsheets.
    private static func sanitize(_ field: String) -> String {
        guard let first = field.first else { return field }
        switch first {
        case "=", "+", "-", "@", "\t", "\r":
            return "'" + field
        default:
            return field
        }
    }
}
