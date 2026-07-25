// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import abgui

/// Tests for the command-transparency layer: what abgui SHOWS an administrator must be an
/// accurate, runnable, secret-free rendering of what it actually executed.
final class CommandRecordTests: XCTestCase {

    // MARK: redaction — the security-critical invariant

    func testRedactionHidesTheVPPTokenInBothSpellings() {
        let spaced = CommandFormatter.redact(["vpp", "config", "--vpp-token", "s3cret-token"])
        XCTAssertEqual(spaced, ["vpp", "config", "--vpp-token", "****"])

        let joined = CommandFormatter.redact(["vpp", "config", "--vpp-token=s3cret-token"])
        XCTAssertEqual(joined, ["vpp", "config", "--vpp-token=****"])
    }

    func testSecretNeverAppearsInAnyRenderedForm() {
        let secret = "s3cret-token"
        let argv = ["vpp", "assets", "--vpp-token", secret, "-o", "json"]
        let record = CommandRecord(argv: argv, cwd: URL(fileURLWithPath: "/tmp/ws"))

        XCTAssertFalse(record.argv.contains(secret), "raw token was stored on the record")
        XCTAssertFalse(record.commandLine.contains(secret))
        XCTAssertFalse(record.script.contains(secret))
        XCTAssertFalse(record.startLogLine.contains(secret))
        XCTAssertTrue(record.commandLine.contains("****"))
    }

    func testRedactionIsIdempotent() {
        let once = CommandFormatter.redact(["vpp", "config", "--vpp-token", "abc"])
        let twice = CommandFormatter.redact(once)
        XCTAssertEqual(once, twice)
    }

    func testIdentifiersAreNotRedactedSoTheCopiedCommandStillRuns() {
        let argv = ["context", "set", "prod", "--client-id", "BUSINESSAPI.x", "--key", "/keys/p.pem"]
        let line = CommandFormatter.line(argv)
        XCTAssertTrue(line.contains("BUSINESSAPI.x"))
        XCTAssertTrue(line.contains("/keys/p.pem"))
        XCTAssertFalse(line.contains("****"))
    }

    // MARK: quoting

    func testQuotingLeavesSafeTokensBareAndQuotesTheRest() {
        XCTAssertEqual(CommandFormatter.quote("sync"), "sync")
        XCTAssertEqual(CommandFormatter.quote("--limit-writes"), "--limit-writes")
        XCTAssertEqual(CommandFormatter.quote("/tmp/a-b_c.txt"), "/tmp/a-b_c.txt")
        XCTAssertEqual(CommandFormatter.quote("WiFi Corp"), "'WiFi Corp'")
        XCTAssertEqual(CommandFormatter.quote(""), "''")
        XCTAssertEqual(CommandFormatter.quote("it's"), #"'it'\''s'"#)
    }

    func testLinePrefixesAbctlAndQuotesArguments() {
        let line = CommandFormatter.line(["get", "configuration", "WiFi Corp", "--profile"])
        XCTAssertEqual(line, "abctl get configuration 'WiFi Corp' --profile")
    }

    // MARK: the copy-paste form

    func testScriptLeadsWithCdWhenTheCommandIsTreeRelative() {
        let script = CommandFormatter.script(argv: ["diff", "--json"],
                                             cwd: URL(fileURLWithPath: "/Users/me/fleet repo"),
                                             stdin: .none)
        XCTAssertEqual(script, "cd '/Users/me/fleet repo'\nabctl diff --json")
    }

    func testScriptOmitsCdWhenThereIsNoWorkspace() {
        let script = CommandFormatter.script(argv: ["get", "devices", "-o", "json"], cwd: nil, stdin: .none)
        XCTAssertEqual(script, "abctl get devices -o json")
    }

    func testScriptRewritesStdinIntoARealPathSoItCanBePasted() {
        let argv = ["create", "config", "WiFi Corp", "-f", "-", "--yes", "--json"]
        let script = CommandFormatter.script(argv: argv, cwd: nil, stdin: .profile(bytes: 2048))

        XCTAssertTrue(script.contains("-f ./WiFi-Corp.mobileconfig"),
                      "stdin was not translated to a file path: \(script)")
        XCTAssertFalse(script.contains("-f -"), "a pasted `-f -` would hang on an empty terminal")
        XCTAssertTrue(script.contains("2048 bytes"))
        XCTAssertTrue(script.contains("#"), "the translation must be explained in a comment")
    }

    // MARK: record presentation

    func testFinishLogLineReportsExitCodeAndDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        var record = CommandRecord(argv: ["diff", "--json"], cwd: nil, startedAt: start)
        record.finishedAt = start.addingTimeInterval(2.4)
        record.status = .succeeded

        XCTAssertEqual(record.startLogLine, "$ abctl diff --json")
        XCTAssertEqual(record.finishLogLine, "→ exit 0 in 2.4s")
        XCTAssertFalse(record.isFailure)
    }

    func testStatusTextCoversEveryTerminalOutcome() {
        let start = Date(timeIntervalSince1970: 1_000)
        func record(_ status: CommandRecord.Status) -> CommandRecord {
            var r = CommandRecord(argv: ["sync"], cwd: nil, startedAt: start)
            r.status = status
            return r
        }
        XCTAssertEqual(record(.running).statusText, "running")
        XCTAssertEqual(record(.failed(3)).statusText, "exit 3")
        XCTAssertEqual(record(.cancelled).statusText, "cancelled")
        XCTAssertEqual(record(.timedOut).statusText, "timed out")
        XCTAssertTrue(record(.timedOut).isFailure)
        XCTAssertTrue(record(.failed(1)).isFailure)
        XCTAssertFalse(record(.cancelled).isFailure)
    }

    func testLongDurationsReadAsMinutesAndSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var record = CommandRecord(argv: ["sync", "--apply"], cwd: nil, startedAt: start)
        record.finishedAt = start.addingTimeInterval(125)
        record.status = .succeeded
        XCTAssertEqual(record.durationText, "2m 5s")
    }

    // MARK: RecordingRunner — the seam

    func testRecordingRunnerReportsSuccessAndForwardsTheResultUnchanged() async throws {
        let sink = CommandSink()
        let runner = RecordingRunner(wrapping: MockAbctlRunner(responses: ["diff": MockAbctlRunner.ok("{}")]),
                                     onStart: { sink.start($0) },
                                     onFinish: { sink.finish($0, $1) })

        let result = try await runner.run(["diff", "--json"], cwd: nil, stdin: nil, timeout: .seconds(5))

        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "{}")
        let started = sink.started
        let finished = sink.finished
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.argv, ["diff", "--json"])
        XCTAssertEqual(finished.first?.1, .succeeded)
    }

    func testRecordingRunnerReportsTheExitCodeOnFailure() async throws {
        let sink = CommandSink()
        let failing = MockAbctlRunner(responses: [:]) // unmatched argv → exit 1
        let runner = RecordingRunner(wrapping: failing,
                                     onStart: { sink.start($0) },
                                     onFinish: { sink.finish($0, $1) })

        _ = try await runner.run(["validate", "--json"], cwd: nil, stdin: nil, timeout: .seconds(5))

        let finished = sink.finished
        XCTAssertEqual(finished.first?.1, .failed(1))
    }

    func testRecordingRunnerReportsCancellationRatherThanFailure() async {
        struct CancellingRunner: AbctlRunner {
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                throw CancellationError()
            }
        }
        let sink = CommandSink()
        let runner = RecordingRunner(wrapping: CancellingRunner(),
                                     onStart: { sink.start($0) },
                                     onFinish: { sink.finish($0, $1) })

        do {
            _ = try await runner.run(["sync", "--apply"], cwd: nil, stdin: nil, timeout: .seconds(5))
            XCTFail("expected the cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let finished = sink.finished
        XCTAssertEqual(finished.first?.1, .cancelled)
    }

    func testRecordingRunnerRecordsStdinSizeButNotItsContent() async throws {
        let sink = CommandSink()
        let runner = RecordingRunner(wrapping: MockAbctlRunner(responses: ["create": MockAbctlRunner.ok("{}")]),
                                     onStart: { sink.start($0) },
                                     onFinish: { sink.finish($0, $1) })
        let profile = Data("<plist>secret payload</plist>".utf8)

        _ = try await runner.run(["create", "config", "X", "-f", "-", "--yes", "--json"],
                                 cwd: nil, stdin: profile, timeout: .seconds(5))

        let started = sink.started
        XCTAssertEqual(started.first?.stdin, .profile(bytes: profile.count))
        let rendered = started.first?.script ?? ""
        XCTAssertFalse(rendered.contains("secret payload"), "profile content must never be recorded")
    }
}

/// A lock-guarded collector for the runner's sinks, which fire off the main thread.
private final class CommandSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [CommandRecord] = []
    private var _finished: [(UUID, CommandRecord.Status)] = []

    var started: [CommandRecord] { lock.withLock { _started } }
    var finished: [(UUID, CommandRecord.Status)] { lock.withLock { _finished } }

    func start(_ record: CommandRecord) { lock.withLock { _started.append(record) } }
    func finish(_ id: UUID, _ status: CommandRecord.Status) { lock.withLock { _finished.append((id, status)) } }
}
