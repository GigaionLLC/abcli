// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import abgui

/// CSVDocument must emit the same RFC-4180 quoting + formula-injection hardening as
/// abctl's printCSV/csvSanitize (internal/cli/output.go) — these pin that contract.
final class CSVDocumentTests: XCTestCase {

    func testPlainRowsAndHeaders() {
        let doc = CSVDocument(headers: ["Serial", "Name"],
                              rows: [["C02XX", "Mac mini"], ["F9FYY", "iPad"]])
        XCTAssertEqual(doc.text, "Serial,Name\nC02XX,Mac mini\nF9FYY,iPad\n")
    }

    func testQuotesCommaQuoteAndNewlineAndDoublesEmbeddedQuotes() {
        let doc = CSVDocument(headers: ["Name"],
                              rows: [["a,b"], ["say \"hi\""], ["line1\nline2"]])
        XCTAssertEqual(doc.text, "Name\n\"a,b\"\n\"say \"\"hi\"\"\"\n\"line1\nline2\"\n")
    }

    func testNeutralizesFormulaPrefixesLikeAbctl() {
        // Same set as csvSanitize: '=', '+', '-', '@', tab, CR get a leading quote.
        let doc = CSVDocument(headers: ["V"],
                              rows: [["=1+2"], ["+x"], ["-x"], ["@x"], ["\tx"], ["\rx"], ["safe"], [""]])
        XCTAssertEqual(doc.text, "V\n'=1+2\n'+x\n'-x\n'@x\n'\tx\n\"'\rx\"\nsafe\n\n")
    }
}
