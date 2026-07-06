// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import abgui

/// Decode + exit-code tests against golden JSON captured from real `abctl … -o json`,
/// run through the SAME decoder the app uses — so an abctl/Apple schema change breaks a
/// test, not the UI.
final class ContractTests: XCTestCase {

    func testVersionDecodesAndReadsCapabilities() async throws {
        let json = #"{"version":"1.2.3","commit":"abc123","buildTime":"2026-01-02T03:04:05Z","goVersion":"go1.26","capabilities":["write-json","plan-json"]}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["version": MockAbctlRunner.ok(json)]))
        let version = try await client.version()
        XCTAssertEqual(version.version, "1.2.3")
        XCTAssertTrue(version.has("write-json"))
        XCTAssertFalse(version.has("nope"))
    }

    func testWhoamiDecodesSnakeCaseKeys() async throws {
        let json = #"{"authenticated":true,"client_id":"BUSINESSAPI.x","api_base":"https://api","token_expires":"2026-01-01T00:00:00Z","configurations":3,"blueprints":2}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["auth whoami": MockAbctlRunner.ok(json)]))
        let who = try await client.whoami()
        XCTAssertEqual(who.clientID, "BUSINESSAPI.x")
        XCTAssertEqual(who.apiBase, "https://api")
        XCTAssertEqual(who.configurations, 3)
    }

    func testEmptyListDecodesToEmptyArray() async throws {
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get configurations": MockAbctlRunner.ok("[]")]))
        let list = try await client.configurations()
        XCTAssertTrue(list.isEmpty)
    }

    func testResourceAttributesDecode() async throws {
        let json = #"[{"type":"configurations","id":"id1","attributes":{"name":"WiFi-Corp","type":"CUSTOM_SETTING"}}]"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get configurations": MockAbctlRunner.ok(json)]))
        let list = try await client.configurations()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.attr("name"), "WiFi-Corp")
        XCTAssertEqual(list.first?.attr("type"), "CUSTOM_SETTING")
        XCTAssertNil(list.first?.attr("missing"))
    }

    func testPlanDecodes() async throws {
        let json = """
        {"configs":[{"name":"WiFi-Corp.mobileconfig","action":"update-abm","detail":"changed in git"}],
         "blueprints":[{"blueprint":"Fleet-A","bp_id":"b1","action":"attach-config","config":"WiFi-Corp.mobileconfig","config_id":"c1","detail":"attach"}]}
        """
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["diff": MockAbctlRunner.ok(json)]))
        let plan = try await client.plan()
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.changeCount, 2)
        XCTAssertEqual(plan.configs.first?.action, "update-abm")
        XCTAssertEqual(plan.blueprints.first?.bpID, "b1")
        XCTAssertEqual(plan.blueprints.first?.config, "WiFi-Corp.mobileconfig")
    }

    func testEmptyPlanIsInSync() async throws {
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["diff": MockAbctlRunner.ok(#"{"configs":[],"blueprints":[]}"#)]))
        let plan = try await client.plan()
        XCTAssertTrue(plan.isEmpty)
    }

    func testCreateSendsGatedJSONWithStdin() async throws {
        actor Recorder {
            var args: [String] = []
            var stdin: Data?
            func record(_ a: [String], _ s: Data?) { args = a; stdin = s }
        }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.record(args, stdin)
                return MockAbctlRunner.ok(#"{"action":"create","name":"WiFi.mobileconfig","id":"id-9","status":"done","treeUpdated":true}"#)
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        let outcome = try await client.createConfiguration(name: "WiFi", xml: Data("<plist/>".utf8))
        XCTAssertEqual(outcome.action, "create")
        XCTAssertEqual(outcome.id, "id-9")
        XCTAssertTrue(outcome.treeUpdated)
        let args = await recorder.args
        for token in ["create", "config", "WiFi", "-f", "-", "--yes", "--json"] {
            XCTAssertTrue(args.contains(token), "missing \(token) in \(args)")
        }
        let recordedStdin = await recorder.stdin
        XCTAssertEqual(recordedStdin, Data("<plist/>".utf8))
    }

    func testDeleteOutcomeDecodesArchive() async throws {
        let json = #"{"action":"delete","name":"Old.mobileconfig","id":"id-1","status":"done","archive":"gitops/archive/Old/ts.mobileconfig","treeUpdated":true}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["delete config": MockAbctlRunner.ok(json)]))
        let outcome = try await client.deleteConfiguration(id: "id-1")
        XCTAssertEqual(outcome.action, "delete")
        XCTAssertEqual(outcome.archive, "gitops/archive/Old/ts.mobileconfig")
    }

    func testApplyResultDecodesAndCounts() async throws {
        let json = """
        {"configs":{"outcomes":[{"name":"WiFi.mobileconfig","action":"update","status":"done","detail":"PATCH","archive":"a/b"}],"writes":1,"errors":0,"skipped":0},
         "blueprints":{"outcomes":[{"blueprint":"Fleet","config":"WiFi.mobileconfig","action":"attach","status":"done","detail":"attached"}],"writes":1,"errors":0,"skipped":0}}
        """
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["sync --apply": MockAbctlRunner.ok(json)]))
        let result = try await client.syncApply(prune: false, limitWrites: nil)
        XCTAssertEqual(result.totalWrites, 2)
        XCTAssertEqual(result.totalErrors, 0)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertTrue(result.rows.contains { $0.name == "Fleet / WiFi.mobileconfig" })
        XCTAssertEqual(result.rows.first?.archive, "a/b")
    }

    func testApplyArgsIncludePruneAndLimit() async throws {
        actor Recorder {
            var args: [String] = []
            func record(_ a: [String]) { args = a }
        }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.record(args)
                return MockAbctlRunner.ok(#"{"configs":{"outcomes":[],"writes":0,"errors":0,"skipped":0},"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}"#)
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        _ = try await client.syncApply(prune: true, limitWrites: 5)
        let args = await recorder.args
        for token in ["sync", "--apply", "--yes", "--json", "--prune", "--limit-writes", "5"] {
            XCTAssertTrue(args.contains(token), "missing \(token) in \(args)")
        }
    }

    func testArchiveScannerParsesTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("abgui-arch-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("gitops/archive/WiFi-Corp")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let stem = "20260101T000000Z--replaced"
        try Data("<plist/>".utf8).write(to: dir.appendingPathComponent("\(stem).mobileconfig"))
        let sidecar = #"{"name":"WiFi-Corp.mobileconfig","reason":"replaced","archivedAt":"2026-01-01T00:00:00Z","file":"\#(stem).mobileconfig"}"#
        try Data(sidecar.utf8).write(to: dir.appendingPathComponent("\(stem).json"))

        let entries = ArchiveScanner.scan(root: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.configName, "WiFi-Corp.mobileconfig")
        XCTAssertEqual(entries.first?.reason, "replaced")
    }

    func testReplaceSendsGatedJSONWithStdin() async throws {
        actor Recorder {
            var args: [String] = []
            var stdin: Data?
            func record(_ a: [String], _ s: Data?) { args = a; stdin = s }
        }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.record(args, stdin)
                return MockAbctlRunner.ok(#"{"action":"replace","name":"WiFi.mobileconfig","id":"id-1","status":"done","treeUpdated":true}"#)
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        _ = try await client.replaceConfiguration(id: "id-1", xml: Data("<x/>".utf8))
        let args = await recorder.args
        for token in ["replace", "config", "id-1", "-f", "-", "--yes", "--json"] {
            XCTAssertTrue(args.contains(token), "missing \(token) in \(args)")
        }
        let recordedStdin = await recorder.stdin
        XCTAssertEqual(recordedStdin, Data("<x/>".utf8))
    }

    func testUserRolesDecodeAndColumns() throws {
        let json = #"{"type":"users","id":"u1","attributes":{"firstName":"Ada","lastName":"Lovelace","managedAppleId":"ada@x.appleid.com","status":"ACTIVE","roles":[{"role":"Administrator","organizationalUnit":"HQ"},{"role":"Manager"}]}}"#
        let user = try JSONDecoder().decode(Resource.self, from: Data(json.utf8))
        XCTAssertEqual(user.roleNames(), "Administrator, Manager")
        let columns = ReadOnlyKind.users.columns
        XCTAssertEqual(columns.first { $0.header == "Name" }?.value(user), "Ada Lovelace")
        XCTAssertEqual(columns.first { $0.header == "Roles" }?.value(user), "Administrator, Manager")
        XCTAssertEqual(columns.first { $0.header == "Managed Apple ID" }?.value(user), "ada@x.appleid.com")
    }

    func testPackagesUsesGetPackages() async throws {
        actor Recorder {
            var args: [String] = []
            func record(_ a: [String]) { args = a }
        }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.record(args)
                return MockAbctlRunner.ok("[]")
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        let packages = try await client.packages()
        XCTAssertTrue(packages.isEmpty)
        let args = await recorder.args
        XCTAssertEqual(Array(args.prefix(2)), ["get", "packages"])
    }

    func testVPPAssetDecodes() async throws {
        // Matches `abctl vpp assets -o json` (internal/vpp.Asset).
        let json = #"[{"adamId":"408709785","productType":"App","pricingParam":"STDQ","availableCount":42,"assignedCount":8,"retiredCount":0,"totalCount":50,"deviceAssignable":true,"revocable":true,"supportedPlatforms":["iOS","macOS"]}]"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["vpp assets": MockAbctlRunner.ok(json)]))
        let assets = try await client.vppAssets(token: "tok")
        XCTAssertEqual(assets.count, 1)
        let asset = assets[0]
        XCTAssertEqual(asset.adamId, "408709785")
        XCTAssertEqual(asset.availableCount, 42)
        XCTAssertEqual(asset.totalCount, 50)
        XCTAssertEqual(asset.deviceAssignable, true)
        XCTAssertEqual(asset.supportedPlatforms, ["iOS", "macOS"])
    }

    func testVPPTokenIsPassedAsFlag() async throws {
        actor Recorder {
            var args: [String] = []
            func record(_ a: [String]) { args = a }
        }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.record(args)
                return MockAbctlRunner.ok(#"{"locationName":"HQ","limits":{"maxAssets":25}}"#)
            }
        }
        let recorder = Recorder()
        _ = try await AbctlClient(runner: RecordingRunner(recorder: recorder)).vppConfig(token: "sTok")
        let args = await recorder.args
        for token in ["vpp", "config", "--vpp-token", "sTok"] {
            XCTAssertTrue(args.contains(token), "missing \(token) in \(args)")
        }
    }

    func testExitCodeMapping() throws {
        // exit 3 is a normal "changes pending", not an error.
        XCTAssertThrowsError(try AbctlClient.checkExit(AbctlResult(stdout: Data(), stderr: "", code: 3))) { error in
            XCTAssertEqual(error as? AbctlError, .changesPending)
        }
        // exit 1 surfaces stderr.
        XCTAssertThrowsError(try AbctlClient.checkExit(AbctlResult(stdout: Data(), stderr: "API 403 (grant View)", code: 1))) { error in
            guard case AbctlError.cli(let msg)? = error as? AbctlError else { return XCTFail("want .cli") }
            XCTAssertTrue(msg.contains("403"))
        }
        // exit 0 is success.
        XCTAssertNoThrow(try AbctlClient.checkExit(AbctlResult(stdout: Data("{}".utf8), stderr: "", code: 0)))
    }

    func testCliErrorPropagatesThroughClient() async throws {
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["auth whoami": AbctlResult(stdout: Data(), stderr: "boom", code: 1)]))
        do {
            _ = try await client.whoami()
            XCTFail("expected an error")
        } catch let AbctlError.cli(message) {
            XCTAssertEqual(message, "boom")
        }
    }

    func testProcessRunnerEnforcesTimeout() async throws {
        // A real child that would run for 5s is terminated by the 150ms watchdog.
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sleep"))
        do {
            _ = try await runner.run(["5"], cwd: nil, stdin: nil, timeout: .milliseconds(150))
            XCTFail("expected a timeout")
        } catch AbctlError.timedOut {
            // expected
        }
    }

    func testContextIsThreadedAsFlag() async throws {
        // A recording runner asserts --context is appended when set.
        actor Recorder { var last: [String] = []; func set(_ a: [String]) { last = a } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(args)
                return MockAbctlRunner.ok(#"{"version":"x","goVersion":"go1.26","capabilities":[]}"#)
            }
        }
        let recorder = Recorder()
        var client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        client.context = "prod"
        _ = try await client.version()
        let args = await recorder.last
        XCTAssertEqual(args.suffix(2), ["--context", "prod"])
    }
}

extension AbctlError: Equatable {
    public static func == (lhs: AbctlError, rhs: AbctlError) -> Bool {
        switch (lhs, rhs) {
        case (.changesPending, .changesPending): return true
        case (.timedOut, .timedOut): return true
        case (.cli(let a), .cli(let b)): return a == b
        case (.usage(let a), .usage(let b)): return a == b
        case (.decode, .decode): return true
        default: return false
        }
    }
}
