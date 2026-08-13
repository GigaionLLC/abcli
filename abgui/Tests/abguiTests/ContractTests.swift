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

    func testPlanArgsIncludeGitSourceOfTruth() async throws {
        actor Recorder {
            var args: [String] = []
            func record(_ a: [String]) { args = a }
        }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.record(args)
                return MockAbctlRunner.ok(#"{"configs":[],"blueprints":[]}"#)
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        _ = try await client.plan(gitSourceOfTruth: true, refresh: "full")
        let args = await recorder.args
        XCTAssertTrue(args.contains("--git-source-of-truth"), "missing --git-source-of-truth in \(args)")
        XCTAssertTrue(args.contains("--refresh") && args.contains("full"), "missing refresh mode in \(args)")
    }

    func testPlanCountsMissingIDBlueprintAttachAsBlocked() async throws {
        let json = """
        {"configs":[],
         "blueprints":[{"blueprint":"Fleet","action":"attach-config","config":"New.mobileconfig","detail":"blocked: config is listed on this blueprint but has no ABM id"},
                       {"blueprint":"Fleet","action":"attach-config","config":"WiFi.mobileconfig","config_id":"c1","detail":"attach"}]}
        """
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["diff": MockAbctlRunner.ok(json)]))
        let plan = try await client.plan()
        XCTAssertEqual(plan.changeCount, 2)
        XCTAssertEqual(plan.actionableChangeCount, 1)
        XCTAssertEqual(plan.blockedChangeCount, 1)
        XCTAssertFalse(plan.blueprints[0].isActionable)
        XCTAssertTrue(plan.blueprints[1].isActionable)
    }

    func testSeedRunsSeedInWorkspaceWithContext() async throws {
        actor Recorder { var args: [String] = []; var cwd: URL?; func set(_ a: [String], _ c: URL?) { args = a; cwd = c } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(args, cwd)
                return MockAbctlRunner.ok("seeded 3 configuration(s)")
            }
        }
        let recorder = Recorder()
        var client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        client.context = "prod"
        client.repoRoot = URL(fileURLWithPath: "/work/ws")
        let summary = try await client.seed()
        XCTAssertTrue(summary.contains("seeded"))
        let args = await recorder.args
        XCTAssertEqual(args.first, "seed")
        XCTAssertEqual(args.suffix(2), ["--context", "prod"]) // seed needs creds → context threaded
        let cwd = await recorder.cwd
        XCTAssertEqual(cwd?.path, "/work/ws") // tree is written into the chosen workspace
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
            var timeoutSeconds: Int = 0
            func record(_ a: [String], timeout: Duration) {
                args = a
                timeoutSeconds = Int(timeout.components.seconds)
            }
        }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.record(args, timeout: timeout)
                return MockAbctlRunner.ok(#"{"configs":{"outcomes":[],"writes":0,"errors":0,"skipped":0},"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}"#)
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        _ = try await client.syncApply(prune: true, limitWrites: 5, gitSourceOfTruth: true, refresh: "full", verify: "none")
        let args = await recorder.args
        for token in ["sync", "--apply", "--yes", "--json", "--git-source-of-truth", "--prune", "--limit-writes", "5", "--refresh", "full", "--verify", "none"] {
            XCTAssertTrue(args.contains(token), "missing \(token) in \(args)")
        }
        let timeoutSeconds = await recorder.timeoutSeconds
        XCTAssertGreaterThanOrEqual(timeoutSeconds, 1_200, "apply needs a tenant-scale timeout")
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
        let json = #"[{"name":"WhatsApp Messenger","adamId":"408709785","productType":"App","pricingParam":"STDQ","availableCount":42,"assignedCount":8,"retiredCount":0,"totalCount":50,"deviceAssignable":true,"revocable":true,"supportedPlatforms":["iOS","macOS"]}]"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["vpp assets": MockAbctlRunner.ok(json)]))
        let assets = try await client.vppAssets(token: "tok")
        XCTAssertEqual(assets.count, 1)
        let asset = assets[0]
        XCTAssertEqual(asset.name, "WhatsApp Messenger")
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

    // MARK: singular inspection payloads (Models/Inspect.swift) — fixtures mirror the
    // Go marshaling in internal/cli/inspect.go / get.go / manage.go.

    func testDeviceDetailDecodesAssignedServer() async throws {
        let json = #"{"device":{"type":"orgDevices","id":"d1","attributes":{"serialNumber":"C02XYZ","deviceModel":"MacBook Pro","status":"ASSIGNED"}},"assignedServer":{"type":"mdmServers","id":"s1","attributes":{"serverName":"Built-in MDM"}}}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get device": MockAbctlRunner.ok(json)]))
        let detail = try await client.deviceDetail("C02XYZ")
        XCTAssertEqual(detail.device.attr("serialNumber"), "C02XYZ")
        XCTAssertEqual(detail.device.attr("deviceModel"), "MacBook Pro")
        XCTAssertEqual(detail.assignedServer?.attr("serverName"), "Built-in MDM")
        XCTAssertNil(detail.appleCare, "appleCare key is absent without --applecare")
    }

    func testDeviceDetailUnassignedServerIsNull() async throws {
        let json = #"{"device":{"type":"orgDevices","id":"d1","attributes":{"serialNumber":"C02XYZ","status":"UNASSIGNED"}},"assignedServer":null}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get device": MockAbctlRunner.ok(json)]))
        let detail = try await client.deviceDetail("C02XYZ")
        XCTAssertNil(detail.assignedServer)
    }

    func testDeviceDetailAppleCareFlagAndDecode() async throws {
        actor Recorder { var args: [String] = []; func set(_ a: [String]) { args = a } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(args)
                return MockAbctlRunner.ok(#"{"device":{"type":"orgDevices","id":"d1","attributes":{"serialNumber":"C02XYZ"}},"assignedServer":null,"appleCare":[{"type":"appleCareCoverage","id":"cv1","attributes":{"description":"AppleCare+","status":"ACTIVE","endDateTime":"2027-01-01T00:00:00Z"}}]}"#)
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        let detail = try await client.deviceDetail("C02XYZ", appleCare: true)
        XCTAssertEqual(detail.appleCare?.count, 1)
        XCTAssertEqual(detail.appleCare?.first?.attr("status"), "ACTIVE")
        let args = await recorder.args
        for token in ["get", "device", "C02XYZ", "--applecare", "--json"] {
            XCTAssertTrue(args.contains(token), "missing \(token) in \(args)")
        }
    }

    func testMDMDevicesListDecodes() async throws {
        let json = #"[{"type":"mdmDevices","id":"m1","attributes":{"serialNumber":"C02XYZ","deviceName":"Kim's Mac","productFamily":"Mac","enrolledUserId":"u1"}}]"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get mdmdevices": MockAbctlRunner.ok(json)]))
        let devices = try await client.mdmDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.attr("deviceName"), "Kim's Mac")
        XCTAssertEqual(devices.first?.attr("enrolledUserId"), "u1")
    }

    func testMDMDeviceDetailDecodesPosture() async throws {
        let json = #"{"device":{"type":"mdmDevices","id":"m1","attributes":{"serialNumber":"C02XYZ","deviceName":"Kim's Mac","productFamily":"Mac"}},"details":{"type":"mdmDeviceDetails","id":"m1","attributes":{"platform":"macOS","osVersion":"15.5","isFileVaultEnabled":true,"isFirewallEnabled":false,"lastCheckInDateTime":"2026-07-01T00:00:00Z","storageFreeCapacity":128000000000,"storageTotalCapacity":512000000000,"deviceLockStatus":"UNLOCKED"}}}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get mdmdevice": MockAbctlRunner.ok(json)]))
        let detail = try await client.mdmDeviceDetail("C02XYZ")
        XCTAssertEqual(detail.device.attr("deviceName"), "Kim's Mac")
        XCTAssertEqual(detail.details.attr("osVersion"), "15.5")
        XCTAssertEqual(detail.details.attr("deviceLockStatus"), "UNLOCKED")
    }

    func testUserDetailDecodesAsResource() async throws {
        let json = #"{"type":"users","id":"u1","attributes":{"firstName":"Ada","lastName":"Lovelace","email":"ada@example.com","managedAppleAccount":"ada@x.appleid.com","status":"ACTIVE","isExternalUser":false,"roleOuList":[{"roleName":"Administrator","ouId":"ou1"}]}}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get user": MockAbctlRunner.ok(json)]))
        let user = try await client.userDetail("ada@example.com")
        XCTAssertEqual(user.attr("email"), "ada@example.com")
        XCTAssertEqual(user.attr("managedAppleAccount"), "ada@x.appleid.com")
    }

    func testUserGroupMembersDecode() async throws {
        let json = #"{"group":{"type":"userGroups","id":"g1","attributes":{"name":"Engineering","totalMemberCount":2}},"members":["ada@example.com","grace@example.com"]}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get usergroup": MockAbctlRunner.ok(json)]))
        let detail = try await client.userGroupDetail("Engineering", members: true)
        XCTAssertEqual(detail.group.attr("name"), "Engineering")
        XCTAssertEqual(detail.members, ["ada@example.com", "grace@example.com"])
    }

    func testUserGroupWithoutMembersDecodes() async throws {
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get usergroup": MockAbctlRunner.ok(#"{"group":{"type":"userGroups","id":"g1","attributes":{"name":"Engineering"}}}"#)]))
        let detail = try await client.userGroupDetail("Engineering")
        XCTAssertNil(detail.members, "members key is absent without --members")
    }

    func testAppDetailDecodesAsResource() async throws {
        let json = #"{"type":"apps","id":"a1","attributes":{"name":"Numbers","bundleId":"com.apple.numbers","version":"14.1","isCustomApp":false,"platforms":["macOS","iOS"]}}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get app": MockAbctlRunner.ok(json)]))
        let app = try await client.appDetail("Numbers")
        XCTAssertEqual(app.attr("bundleId"), "com.apple.numbers")
        XCTAssertEqual(app.attr("version"), "14.1")
    }

    func testPackageDetailDecodesAsResource() async throws {
        let json = #"{"type":"packages","id":"p1","attributes":{"name":"LOB Installer","bundleId":"com.example.lob","version":"2.0","isCustomApp":true}}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get package": MockAbctlRunner.ok(json)]))
        let pkg = try await client.packageDetail("LOB Installer")
        XCTAssertEqual(pkg.attr("bundleId"), "com.example.lob")
        XCTAssertEqual(pkg.attr("name"), "LOB Installer")
    }

    func testMDMServerDevicesDecode() async throws {
        let json = #"{"server":{"type":"mdmServers","id":"s1","attributes":{"serverName":"Built-in MDM","serverType":"MDM"}},"devices":["C02AAA","C02BBB"],"deviceCount":2}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get mdmserver": MockAbctlRunner.ok(json)]))
        let detail = try await client.mdmServerDetail("Built-in MDM", devices: true)
        XCTAssertEqual(detail.server.attr("serverName"), "Built-in MDM")
        XCTAssertEqual(detail.devices, ["C02AAA", "C02BBB"])
        XCTAssertEqual(detail.deviceCount, 2)
    }

    func testBlueprintDetailDecodesRelationships() async throws {
        let json = """
        {"blueprint":{"type":"blueprints","id":"b1","attributes":{"name":"Fleet-A","status":"ACTIVE"}},
         "configs":1,"apps":2,"devices":1,"appIds":["a1","a2"],"appLicenseDeficient":true,
         "relationships":{"configurations":["WiFi-Corp.mobileconfig"],"apps":["Numbers","Pages"],"packages":[],
                          "orgDevices":["C02AAA"],"users":[],"userGroups":["Engineering"]}}
        """
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["get blueprint": MockAbctlRunner.ok(json)]))
        let detail = try await client.blueprintDetail("Fleet-A")
        XCTAssertEqual(detail.blueprint.attr("name"), "Fleet-A")
        XCTAssertEqual(detail.configs, 1)
        XCTAssertEqual(detail.apps, 2)
        XCTAssertEqual(detail.appIds, ["a1", "a2"])
        XCTAssertTrue(detail.appLicenseDeficient)
        XCTAssertEqual(detail.relationships["orgDevices"], ["C02AAA"])
        XCTAssertEqual(detail.relationships["packages"], [])
        // Every key abctl emits is covered by the display order the sheets iterate.
        XCTAssertEqual(Set(detail.relationships.keys), Set(BlueprintDetail.relationshipOrder))
    }

    func testDeviceStatusReportDecodes() async throws {
        let json = """
        {"device":{"type":"orgDevices","id":"d1","attributes":{"serialNumber":"C02XYZ","status":"ASSIGNED"}},
         "assignedServer":{"type":"mdmServers","id":"s1","attributes":{"serverName":"Built-in MDM"}},
         "blueprints":[{"blueprint":"Fleet-A","configurations":["VPN","WiFi-Corp"]}],
         "mdm":{"device":{"type":"mdmDevices","id":"m1","attributes":{"serialNumber":"C02XYZ"}},
                "details":{"type":"mdmDeviceDetails","id":"m1","attributes":{"osVersion":"15.5","isFileVaultEnabled":true}}}}
        """
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["status device": MockAbctlRunner.ok(json)]))
        let report = try await client.deviceStatus("C02XYZ")
        XCTAssertEqual(report.device.attr("serialNumber"), "C02XYZ")
        XCTAssertEqual(report.assignedServer?.attr("serverName"), "Built-in MDM")
        XCTAssertEqual(report.blueprints.count, 1)
        XCTAssertEqual(report.blueprints.first?.blueprint, "Fleet-A")
        XCTAssertEqual(report.blueprints.first?.configurations, ["VPN", "WiFi-Corp"])
        XCTAssertEqual(report.mdm?.details?.attr("osVersion"), "15.5")
        XCTAssertNil(report.mdm?.error)
        XCTAssertNil(report.appleCare)
    }

    func testDeviceStatusMDMVariantsDecode() async throws {
        // Not enrolled: mdm is null. Denied: mdm carries only an error string.
        let notEnrolled = #"{"device":{"type":"orgDevices","id":"d1","attributes":{}},"assignedServer":null,"blueprints":[],"mdm":null}"#
        var client = AbctlClient(runner: MockAbctlRunner(responses: ["status device": MockAbctlRunner.ok(notEnrolled)]))
        let bare = try await client.deviceStatus("C02XYZ")
        XCTAssertNil(bare.mdm)
        XCTAssertTrue(bare.blueprints.isEmpty)

        let denied = #"{"device":{"type":"orgDevices","id":"d1","attributes":{}},"assignedServer":null,"blueprints":[],"mdm":{"error":"API 403 (grant device management)"}}"#
        client = AbctlClient(runner: MockAbctlRunner(responses: ["status device": MockAbctlRunner.ok(denied)]))
        let unavailable = try await client.deviceStatus("C02XYZ")
        XCTAssertEqual(unavailable.mdm?.error, "API 403 (grant device management)")
        XCTAssertNil(unavailable.mdm?.device)
    }

    func testDeviceStatusGetsFanOutTimeout() async throws {
        actor Recorder { var timeoutSeconds = 0; func set(_ t: Duration) { timeoutSeconds = Int(t.components.seconds) } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(timeout)
                return MockAbctlRunner.ok(#"{"device":{"type":"orgDevices","id":"d1","attributes":{}},"assignedServer":null,"blueprints":[],"mdm":null}"#)
            }
        }
        let recorder = Recorder()
        _ = try await AbctlClient(runner: RecordingRunner(recorder: recorder)).deviceStatus("C02XYZ")
        let timeoutSeconds = await recorder.timeoutSeconds
        XCTAssertGreaterThanOrEqual(timeoutSeconds, 120, "status device fans out per-blueprint and needs a bigger budget")
    }

    func testFanOutFlagsGetExtendedTimeout() async throws {
        // `get usergroup --members` (one API call per member) and `get mdmserver --devices`
        // (a whole-inventory walk) are the same fan-out shape as `status device`, so the
        // opt-in flags get the same doubled budget; the plain variants keep the 60s read one.
        actor Recorder { var timeoutSeconds = 0; func set(_ t: Duration) { timeoutSeconds = Int(t.components.seconds) } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            let json: String
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(timeout)
                return MockAbctlRunner.ok(json)
            }
        }
        let groupJSON = #"{"group":{"type":"userGroups","id":"g1","attributes":{"name":"Engineering"}},"members":[]}"#
        let groupRecorder = Recorder()
        let groupClient = AbctlClient(runner: RecordingRunner(recorder: groupRecorder, json: groupJSON))
        _ = try await groupClient.userGroupDetail("Engineering", members: true)
        var timeoutSeconds = await groupRecorder.timeoutSeconds
        XCTAssertGreaterThanOrEqual(timeoutSeconds, 120, "--members fans out per member and needs a bigger budget")
        _ = try await groupClient.userGroupDetail("Engineering")
        timeoutSeconds = await groupRecorder.timeoutSeconds
        XCTAssertEqual(timeoutSeconds, 60, "the plain read keeps the default budget")

        let serverJSON = #"{"server":{"type":"mdmServers","id":"s1","attributes":{"serverName":"Built-in MDM"}},"devices":[],"deviceCount":0}"#
        let serverRecorder = Recorder()
        let serverClient = AbctlClient(runner: RecordingRunner(recorder: serverRecorder, json: serverJSON))
        _ = try await serverClient.mdmServerDetail("Built-in MDM", devices: true)
        timeoutSeconds = await serverRecorder.timeoutSeconds
        XCTAssertGreaterThanOrEqual(timeoutSeconds, 120, "--devices walks the whole device inventory and needs a bigger budget")
    }

    func testAssignSendsGatedJSONAndDecodesActivity() async throws {
        actor Recorder { var args: [String] = []; func set(_ a: [String]) { args = a } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(args)
                return MockAbctlRunner.ok(#"{"action":"assign","server":"Built-in MDM","devices":2,"activityId":"act-42"}"#)
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        let outcome = try await client.assignDevices(serials: ["C02AAA", "C02BBB"], server: "Built-in MDM")
        XCTAssertEqual(outcome.action, "assign")
        XCTAssertEqual(outcome.devices, 2)
        XCTAssertEqual(outcome.activityID, "act-42")
        XCTAssertNil(outcome.status, "status is only present with --wait, which abgui never passes")
        let args = await recorder.args
        for token in ["assign", "--server", "Built-in MDM", "C02AAA", "C02BBB", "--yes", "--json"] {
            XCTAssertTrue(args.contains(token), "missing \(token) in \(args)")
        }
    }

    func testUnassignUsesUnassignVerb() async throws {
        let json = #"{"action":"unassign","server":"Built-in MDM","devices":1,"activityId":"act-43"}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["unassign": MockAbctlRunner.ok(json)]))
        let outcome = try await client.unassignDevices(serials: ["C02AAA"], server: "Built-in MDM")
        XCTAssertEqual(outcome.action, "unassign")
        XCTAssertEqual(outcome.activityID, "act-43")
    }

    func testActivityStatusDecodesAsResource() async throws {
        let json = #"{"type":"orgDeviceActivities","id":"act-42","attributes":{"status":"COMPLETED","subStatus":"SUBMITTED_TO_SERVER","createdDateTime":"2026-07-09T00:00:00Z"}}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["status activity": MockAbctlRunner.ok(json)]))
        let activity = try await client.activityStatus("act-42")
        XCTAssertEqual(activity.id, "act-42")
        XCTAssertEqual(activity.attr("status"), "COMPLETED")
        XCTAssertEqual(activity.attr("subStatus"), "SUBMITTED_TO_SERVER")
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
        } catch let error as AbctlError {
            guard case .timedOut = error else { return XCTFail("expected .timedOut, got \(error)") }
        }
    }

    @MainActor
    func testProgressLogIsCappedAndKeepsLatest() {
        let model = AppModel()
        for i in 0..<500 { model.appendProgress("line \(i)") }
        XCTAssertLessThanOrEqual(model.progressLog.count, 200, "progress log must stay bounded")
        XCTAssertEqual(model.progressLog.last, "line 499", "the newest line must be retained")
    }

    func testTimeoutErrorIsActionable() {
        // The message must name likely causes and surface abctl's last output, not just "timed out".
        let err = AbctlError.timedOut(seconds: 120, lastOutput: "  minting token…\n")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("120s"), "should say how long it waited: \(desc)")
        XCTAssertTrue(desc.contains("network") && desc.contains("gitops/"), "should name likely causes: \(desc)")
        XCTAssertTrue(desc.contains("minting token"), "should surface abctl's last output: \(desc)")
    }

    func testContextListDecodes() async throws {
        let json = #"{"contexts":["prod","staging"],"current":"prod"}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["context list": MockAbctlRunner.ok(json)]))
        let list = try await client.contextList()
        XCTAssertEqual(list.contexts, ["prod", "staging"])
        XCTAssertEqual(list.current, "prod")
    }

    func testEmptyContextListDecodes() async throws {
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["context list": MockAbctlRunner.ok(#"{"contexts":[],"current":""}"#)]))
        let list = try await client.contextList()
        XCTAssertTrue(list.contexts.isEmpty)
        XCTAssertEqual(list.current, "")
    }

    func testContextDetailDecodesSnakeCaseAndKeyPath() async throws {
        let json = #"{"context":{"client_id":"BUSINESSAPI.aaa","key":"/keys/prod.pem","api_base":"https://api-business.apple.com/v1/"},"name":"prod"}"#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["context get": MockAbctlRunner.ok(json)]))
        let detail = try await client.contextDetail("prod")
        XCTAssertEqual(detail.name, "prod")
        XCTAssertEqual(detail.context.clientID, "BUSINESSAPI.aaa")
        XCTAssertEqual(detail.context.keyPath, "/keys/prod.pem")
        XCTAssertEqual(detail.context.apiBase, "https://api-business.apple.com/v1/")
    }

    func testContextDetailWithoutApiBaseDecodes() async throws {
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["context get": MockAbctlRunner.ok(#"{"context":{"client_id":"c","key":"/k.pem"},"name":"staging"}"#)]))
        let detail = try await client.contextDetail("staging")
        XCTAssertNil(detail.context.apiBase)
        XCTAssertEqual(detail.context.keyPath, "/k.pem")
    }

    func testSaveContextThreadsFlagsAndNeverAddsContextFlag() async throws {
        actor Recorder { var args: [String] = []; func set(_ a: [String]) { args = a } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(args)
                return MockAbctlRunner.ok("")
            }
        }
        let recorder = Recorder()
        var client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        client.context = "some-selected-context" // must NOT bleed into a context-store write
        try await client.saveContext(name: "prod", clientID: "BUSINESSAPI.aaa",
                                     keyPath: "/keys/prod.pem", apiBase: "https://b/v1/", makeCurrent: true)
        let args = await recorder.args
        XCTAssertEqual(Array(args.prefix(3)), ["context", "set", "prod"])
        for token in ["--client-id", "BUSINESSAPI.aaa", "--key", "/keys/prod.pem", "--api-base", "https://b/v1/", "--use"] {
            XCTAssertTrue(args.contains(token), "missing \(token) in \(args)")
        }
        XCTAssertFalse(args.contains("--context"), "context-store writes must never thread --context: \(args)")
    }

    func testSaveContextOmitsApiBaseAndUseWhenNotSet() async throws {
        actor Recorder { var args: [String] = []; func set(_ a: [String]) { args = a } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(args); return MockAbctlRunner.ok("")
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        try await client.saveContext(name: "s", clientID: "c", keyPath: "/k.pem", apiBase: nil, makeCurrent: false)
        let args = await recorder.args
        XCTAssertFalse(args.contains("--api-base"))
        XCTAssertFalse(args.contains("--use"))
    }

    func testCredentialStoreWritesOwnerOnlyKeyFile() throws {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIGH...\n-----END PRIVATE KEY-----\n"
        let url = try CredentialStore.writeKey(pem: pem, context: "unit-test/../weird name")
        defer { try? FileManager.default.removeItem(at: url) }

        // Written verbatim…
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), pem)
        // …with a filesystem-safe name…
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        // …and owner-only (0600) permissions.
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
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

    func testOSReleaseContractAndArguments() async throws {
        actor Recorder { var args: [String] = []; func set(_ a: [String]) { args = a } }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(args)
                return MockAbctlRunner.ok(#"[{"platform":"macOS","productVersion":"15.4","build":"24E1","postingDate":"2026-07-01","expirationDate":"2026-12-01","supportedDevices":["MacBookPro18,3"],"catalog":"managed","expired":false}]"#)
            }
        }
        let recorder = Recorder()
        let client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        let releases = try await client.osReleases()
        let args = await recorder.args
        XCTAssertEqual(args, ["get", "os-releases", "-o", "json"])
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].id, "managed:macOS:24E1")
        XCTAssertEqual(releases[0].supportedDevices, ["MacBookPro18,3"])
        XCTAssertFalse(releases[0].expired)
    }

    // MARK: pre-sync verification — `abctl validate --json`
    //
    // The golden payloads below ARE the contract between the two halves: every key is a
    // `json:"…"` tag on the Go report types, so a rename on either side breaks a test
    // instead of silently emptying the Verify-configs sheet. Note the totals field is
    // tagged `json:"warnings"` (not `warningCount`) while a profile's `warnings` is the
    // issue array — same word, two shapes, which is exactly why it is pinned here.

    func testValidateGoldenReportDecodesTotalsProfilesAndTreeIssues() async throws {
        // Delivered on exit 1 because abctl exits 1 whenever the report says ok:false —
        // the report is still printed on stdout, so decoding must not be gated on the
        // exit code (that contract is asserted head-on by the next test).
        let json = #"""
        {"ok":false,"libDir":"gitops/lib","checked":3,"passed":2,"failed":1,"warnings":3,
         "profiles":[
           {"name":"WiFi-Corp.mobileconfig","path":"gitops/lib/WiFi-Corp.mobileconfig","bytes":2048,"ok":true,
            "identifier":"com.example.wifi","displayName":"WiFi Corp","payloadTypes":["com.apple.wifi.managed"],
            "errors":[],"warnings":[]},
           {"name":"VPN.mobileconfig","path":"gitops/lib/VPN.mobileconfig","bytes":1048576,"ok":false,
            "identifier":"com.example.vpn","payloadTypes":[],
            "errors":[{"code":"size-cap","message":"profile is 1.0 MiB; Apple Business rejects profiles of 1 MiB or larger."},
                      {"code":"missing-payload-content","message":"no top-level PayloadContent key."}],
            "warnings":[]},
           {"name":"Dock.mobileconfig","path":"gitops/lib/Dock.mobileconfig","bytes":912,"ok":true,
            "identifier":"com.example.dock","payloadTypes":["com.apple.dock"],"errors":[],
            "warnings":[{"code":"missing-display-name","message":"no top-level PayloadDisplayName."},
                        {"code":"missing-payload-uuid","message":"no top-level PayloadUUID."}]}],
         "treeIssues":[
           {"level":"error","scope":"blueprints","target":"Fleet-A","code":"missing-config",
            "message":"blueprint \"Fleet-A\" references configuration \"Kiosk.mobileconfig\", which is not in lib/"},
           {"level":"warning","scope":"lib","target":"notes.txt","code":"ignored-file",
            "message":"notes.txt is ignored by sync (not a .mobileconfig)"}],
         "validator":"built-in"}
        """#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["validate": AbctlResult(stdout: Data(json.utf8), stderr: "", code: 1)]))
        let report = try await client.validateProfiles()
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.libDir, "gitops/lib")
        XCTAssertEqual(report.checked, 3)
        XCTAssertEqual(report.passed, 2)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.warnings, 3) // 2 profile warnings + 1 warning-level tree issue
        XCTAssertEqual(report.profiles.count, 3)
        XCTAssertEqual(Set(report.profiles.map(\.id)).count, 3, "the profile list ForEach needs one stable id per row")

        XCTAssertEqual(report.profiles[0].identifier, "com.example.wifi")
        XCTAssertEqual(report.profiles[0].displayName, "WiFi Corp")
        XCTAssertEqual(report.profiles[0].payloadTypes, ["com.apple.wifi.managed"])

        // A failing profile carries every reason it failed, in the order abctl found them.
        let failing = report.profiles[1]
        XCTAssertFalse(failing.ok)
        XCTAssertEqual(failing.bytes, 1_048_576)
        XCTAssertEqual(failing.errors.map(\.code), ["size-cap", "missing-payload-content"])
        XCTAssertTrue(failing.errors[0].message.contains("1 MiB"), "the message must be actionable: \(failing.errors[0].message)")
        XCTAssertNil(failing.displayName, "displayName is omitempty on the Go side, so it must decode as nil")
        XCTAssertEqual(failing.payloadTypes, [])

        // Warnings never fail a profile — the row stays ok, only the counters move.
        let warned = report.profiles[2]
        XCTAssertTrue(warned.ok)
        XCTAssertTrue(warned.errors.isEmpty)
        XCTAssertEqual(warned.warnings.map(\.code), ["missing-display-name", "missing-payload-uuid"])

        // The high-value pre-sync check: a blueprint pointing at a config that isn't in lib/
        // (sync would silently skip it), plus a warning-level tree issue that must not read
        // as an error in the sheet.
        XCTAssertEqual(report.treeIssues.count, 2)
        let missingConfig = report.treeIssues[0]
        XCTAssertTrue(missingConfig.isError)
        XCTAssertEqual(missingConfig.scope, "blueprints")
        XCTAssertEqual(missingConfig.target, "Fleet-A")
        XCTAssertEqual(missingConfig.code, "missing-config")
        XCTAssertTrue(missingConfig.message.contains("Kiosk.mobileconfig"), "the message must name the missing config: \(missingConfig.message)")
        XCTAssertFalse(report.treeIssues[1].isError)
        XCTAssertEqual(report.treeIssues[1].code, "ignored-file")

        XCTAssertEqual(report.validator, "built-in")
        XCTAssertNil(report.validatorCommand, "no $ABCTL_VALIDATOR was set")
        XCTAssertNil(report.validatorExitCode)
        XCTAssertFalse(report.validatorFailed)

        // What the sheets count: a failing file AND a broken blueprint reference are both
        // problems the user has to look at, even though only one of them is a failed profile.
        XCTAssertEqual(report.problemCount, 2)
    }

    func testValidateReportOnExitOneStillReturns() async throws {
        // `validate` exits 1 on a failed report but prints it on stdout first, so the client
        // decodes stdout BEFORE mapping the exit code: a failed verification must render as a
        // report in the sheet, not as a bare "abctl reported an error". This fixture is the
        // $ABCTL_VALIDATOR path, where a non-zero validator exit folds into ok:false even
        // though every built-in structural check passed.
        let json = #"""
        {"ok":false,"libDir":"gitops/lib","checked":1,"passed":1,"failed":0,"warnings":0,
         "profiles":[{"name":"WiFi-Corp.mobileconfig","path":"gitops/lib/WiFi-Corp.mobileconfig","bytes":2048,"ok":true,
                      "identifier":"com.example.wifi","payloadTypes":["com.apple.wifi.managed"],"errors":[],"warnings":[]}],
         "treeIssues":[],
         "validator":"external","validatorCommand":"/usr/local/bin/mobileconfig-lint gitops/lib",
         "validatorExitCode":2,"validatorOutput":"WiFi-Corp.mobileconfig: unknown payload key\n"}
        """#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["validate": AbctlResult(stdout: Data(json.utf8), stderr: "", code: 1)]))
        let report = try await client.validateProfiles() // must NOT throw .cli on exit 1
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.profiles.allSatisfy(\.ok), "the built-in pass still ran and passed")
        XCTAssertEqual(report.validator, "external")
        XCTAssertEqual(report.validatorCommand, "/usr/local/bin/mobileconfig-lint gitops/lib")
        XCTAssertEqual(report.validatorExitCode, 2)
        let output = report.validatorOutput ?? ""
        XCTAssertTrue(output.contains("unknown payload key"), "the raw validator output is shown verbatim: \(output)")

        // The third route to ok:false — abctl folds a non-zero validator exit into the verdict
        // without touching `failed` or adding a tree issue. The count the views render has to
        // include it, or a failed report renders as "Verification found 0 problem(s)".
        XCTAssertTrue(report.validatorFailed)
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(report.treeErrors.isEmpty)
        XCTAssertEqual(report.problemCount, 1, "a report that is not ok can never count zero problems")
    }

    func testValidateUndecodableStdoutOnExitOneThrowsCLIError() async throws {
        // abctl died before it could print a report (bad flag, unreadable tree). There is
        // nothing to decode, so the user gets the exit-code mapping — stderr — rather than
        // an opaque decode failure.
        let broken = AbctlResult(stdout: Data("Error: unknown flag: --json\n".utf8),
                                 stderr: "Error: unknown flag: --json", code: 1)
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["validate": broken]))
        do {
            _ = try await client.validateProfiles()
            XCTFail("expected an error")
        } catch let AbctlError.cli(message) {
            XCTAssertTrue(message.contains("unknown flag"), "should surface abctl's stderr: \(message)")
        }
    }

    func testValidateArgsRunInWorkspaceWithContext() async throws {
        actor Recorder {
            var args: [String] = []
            var cwd: URL?
            var timeoutSeconds = 0
            func set(_ a: [String], _ c: URL?, _ t: Duration) { args = a; cwd = c; timeoutSeconds = Int(t.components.seconds) }
        }
        struct RecordingRunner: AbctlRunner {
            let recorder: Recorder
            func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
                await recorder.set(args, cwd, timeout)
                return MockAbctlRunner.ok(#"{"ok":true,"libDir":"gitops/lib","checked":0,"passed":0,"failed":0,"warnings":0,"profiles":[],"treeIssues":[],"validator":"built-in"}"#)
            }
        }
        let recorder = Recorder()
        var client = AbctlClient(runner: RecordingRunner(recorder: recorder))
        client.context = "prod"
        client.repoRoot = URL(fileURLWithPath: "/work/ws")
        _ = try await client.validateProfiles()
        let args = await recorder.args
        XCTAssertEqual(args.first, "validate")
        XCTAssertTrue(args.contains("--json"), "missing --json in \(args)")
        XCTAssertEqual(args.suffix(2), ["--context", "prod"]) // threaded through argv(_:) like every other verb
        let cwd = await recorder.cwd
        XCTAssertEqual(cwd?.path, "/work/ws") // the tree being verified is the chosen workspace's
        let timeoutSeconds = await recorder.timeoutSeconds
        XCTAssertGreaterThanOrEqual(timeoutSeconds, 120, "a big lib/ is parsed file by file and needs more than a plain read budget")
    }

    func testValidateOlderReportDecodesWithSafeDefaults() async throws {
        // A bundled abctl that predates the newer keys must not crash the sheet: absent
        // collections decode empty and absent optionals decode nil, so the views can read
        // them unconditionally.
        let json = #"""
        {"ok":true,"libDir":"gitops/lib","checked":1,"passed":1,"failed":0,"warnings":0,
         "profiles":[{"name":"WiFi-Corp.mobileconfig","path":"gitops/lib/WiFi-Corp.mobileconfig","bytes":2048,"ok":true}],
         "validator":"built-in"}
        """#
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["validate": MockAbctlRunner.ok(json)]))
        let report = try await client.validateProfiles()
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.treeIssues.isEmpty, "an absent treeIssues key is an empty section, not a decode failure")
        XCTAssertNil(report.validatorCommand)
        XCTAssertNil(report.validatorExitCode)
        XCTAssertNil(report.validatorOutput)
        XCTAssertEqual(report.profiles.count, 1)
        let profile = report.profiles[0]
        XCTAssertTrue(profile.payloadTypes.isEmpty)
        XCTAssertTrue(profile.errors.isEmpty)
        XCTAssertTrue(profile.warnings.isEmpty)
        XCTAssertNil(profile.identifier)
        XCTAssertNil(profile.displayName)
    }

    // MARK: preview/execute parity — the structural defense against a lying preview
    //
    // abgui shows the abctl command behind every action so an administrator can paste it into a
    // terminal and get the same effect. That promise only holds while the preview and the real
    // call are the SAME code: a preview that drifts from what runs is worse than none, because
    // it teaches a command that never ran. Each test below builds the argv the way a preview
    // does and compares it to what a wrapped runner actually received, so adding a flag to one
    // side alone fails here instead of shipping a wrong example to a support ticket.
    //
    // The builders are deliberately context-free — `--context` is appended by the instance
    // `argv(_:)`, and the previews append it the same way — so the comparisons below use a
    // context-less client except where the suffix itself is under test.

    func testSyncApplyPreviewIsTheArgvThatActuallyRuns() async throws {
        // The whole option surface ApplySheet can produce, including limit-writes 0, which the
        // execute path drops as "unlimited" — a preview that showed `--limit-writes 0` would be
        // advertising a circuit breaker the run does not arm.
        let cases: [(prune: Bool, limit: Int?, git: Bool, refresh: String, verify: String)] = [
            (prune: false, limit: nil, git: false, refresh: "smart", verify: "targeted"),
            (prune: true, limit: 5, git: true, refresh: "full", verify: "none"),
            (prune: true, limit: nil, git: false, refresh: "metadata-only", verify: "full"),
            (prune: false, limit: 0, git: true, refresh: "smart", verify: "targeted"),
            (prune: false, limit: 1, git: false, refresh: "full", verify: "targeted"),
        ]
        let applyJSON = #"{"configs":{"outcomes":[],"writes":0,"errors":0,"skipped":0},"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}"#
        for options in cases {
            let tap = ArgvTap()
            var client = AbctlClient(runner: TappedRunner(tap: tap, json: applyJSON))
            client.repoRoot = URL(fileURLWithPath: "/work/ws")
            _ = try await client.syncApply(prune: options.prune, limitWrites: options.limit,
                                           gitSourceOfTruth: options.git,
                                           refresh: options.refresh, verify: options.verify)
            let sent = await tap.argv
            let previewed = AbctlClient.syncApplyArgs(prune: options.prune, limitWrites: options.limit,
                                                      gitSourceOfTruth: options.git,
                                                      refresh: options.refresh, verify: options.verify)
            XCTAssertEqual(sent.first, "sync", "the gated write must still be a sync: \(sent)")
            XCTAssertEqual(previewed, sent, "preview drifted from execution: shown \(previewed) but ran \(sent)")
        }
    }

    func testValidatePreviewIsTheArgvThatActuallyRunsAndCarriesTheWorkspace() async throws {
        let emptyReport = #"{"ok":true,"libDir":"gitops/lib","checked":0,"passed":0,"failed":0,"warnings":0,"profiles":[],"treeIssues":[],"validator":"built-in"}"#
        let tap = ArgvTap()
        var client = AbctlClient(runner: TappedRunner(tap: tap, json: emptyReport))
        client.repoRoot = URL(fileURLWithPath: "/work/ws")
        _ = try await client.validateProfiles()
        var sent = await tap.argv
        XCTAssertEqual(AbctlClient.validateArgs(), sent)

        // ValidateSheet previews the command with the workspace as cwd, so the `cd` an admin
        // copies has to be the directory the run really used — validate resolves gitops/ from it.
        let cwd = await tap.cwd
        XCTAssertEqual(cwd?.path, "/work/ws")

        // With a context selected the run appends `--context`; the builder must NOT, or the
        // preview would show the flag twice.
        client.context = "prod"
        _ = try await client.validateProfiles()
        sent = await tap.argv
        XCTAssertEqual(AbctlClient.validateArgs() + ["--context", "prod"], sent,
                       "--context is appended by argv(_:), so the builder stays context-free: \(sent)")
    }

    func testAssignPreviewIsTheArgvThatActuallyRunsForBothVerbs() async throws {
        // A gated device write: the serial list, the server name and the verb all have to match,
        // because this is the preview an admin reads right before approving the write.
        let activityJSON = #"{"action":"assign","server":"Built-in MDM","devices":2,"activityId":"act-1"}"#
        let tap = ArgvTap()
        let client = AbctlClient(runner: TappedRunner(tap: tap, json: activityJSON))

        let many = ["C02AAA", "C02BBB"]
        _ = try await client.assignDevices(serials: many, server: "Built-in MDM")
        var sent = await tap.argv
        XCTAssertEqual(sent.first, "assign")
        XCTAssertEqual(AbctlClient.assignArgs(serials: many, server: "Built-in MDM", unassign: false), sent)

        _ = try await client.unassignDevices(serials: ["C02AAA"], server: "Built-in MDM")
        sent = await tap.argv
        XCTAssertEqual(sent.first, "unassign", "unassign must not preview as an assign: \(sent)")
        XCTAssertEqual(AbctlClient.assignArgs(serials: ["C02AAA"], server: "Built-in MDM", unassign: true), sent)
    }

    func testRecordingRunnerRecordsExactlyWhatTheClientSent() async throws {
        // The seam end to end: a real client call through the decorator. The record has to be
        // the argv the runner received — not a re-spelling of it — and has to carry the cwd,
        // since a copied diff/sync without the matching `cd` reconciles the wrong tree.
        let tap = ArgvTap()
        let sink = ParityCommandSink()
        let inner = TappedRunner(tap: tap, json: #"{"configs":[],"blueprints":[]}"#)
        var client = AbctlClient(runner: RecordingRunner(wrapping: inner,
                                                         onStart: { sink.start($0) },
                                                         onFinish: { sink.finish($0, $1) }))
        client.context = "prod"
        client.repoRoot = URL(fileURLWithPath: "/work/ws")
        let plan = try await client.plan(gitSourceOfTruth: true, refresh: "full")
        XCTAssertTrue(plan.isEmpty, "the decorator must forward the payload untouched")

        let sent = await tap.argv
        let started = sink.started
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.argv, sent, "the record must be the argv the runner got")
        XCTAssertEqual(started.first?.argv,
                       AbctlClient.planArgs(gitSourceOfTruth: true, refresh: "full") + ["--context", "prod"],
                       "…and that argv is the preview builder's, plus the context the run used")

        let recordedCwd = started.first?.cwd
        let sentCwd = await tap.cwd
        XCTAssertEqual(recordedCwd?.path, "/work/ws")
        XCTAssertEqual(sentCwd?.path, "/work/ws")
        let script = started.first?.script ?? ""
        XCTAssertTrue(script.hasPrefix("cd /work/ws\n"), "the copyable form must lead with the cd: \(script)")
        XCTAssertTrue(script.contains(CommandFormatter.line(sent)), "…and then the command itself: \(script)")

        let finished = sink.finished
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.0, started.first?.id, "the finish is keyed to the record it closes")
        XCTAssertEqual(finished.first?.1, .succeeded)
    }

    /// The seam the parity tests above do NOT reach: the preview's INPUTS. Those tests pin the
    /// argv builder against the execution, which keeps the two from spelling a flag differently —
    /// but ApplySheet composes the builder's ARGUMENTS from the sheet's toggles and the model,
    /// and `AppModel.apply` composes its run from the same toggles. While the "git-as-truth forces
    /// prune" rule was written out in both of those places, either copy could change alone and
    /// every parity test would still pass while the sheet advertised a command without `--prune`.
    ///
    /// So this drives both expressions from ONE model state and asserts they agree — which is
    /// also what makes the rule's new home (inside `syncApplyArgs`) enforceable.
    @MainActor
    func testApplyPreviewInputsMatchTheApplyPathAcrossTheToggleMatrix() async throws {
        let applyJSON = #"{"configs":{"outcomes":[],"writes":0,"errors":0,"skipped":0},"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}"#
        let model = AppModel()
        model.context = "prod"
        model.verifyMode = "targeted"

        for git in [false, true] {
            for pruneToggle in [false, true] {
                model.gitSourceOfTruth = git
                model.refreshMode = git ? "full" : "smart"

                // ApplySheet.commandPreview, verbatim: the raw toggle, the model's own modes.
                let previewed = model.previewArgv(
                    AbctlClient.syncApplyArgs(prune: pruneToggle,
                                              limitWrites: 5,
                                              gitSourceOfTruth: model.gitSourceOfTruth,
                                              refresh: model.refreshMode,
                                              verify: model.verifyMode))

                // AppModel.apply's own call, through a client carrying the model's context.
                let tap = ArgvTap()
                var client = AbctlClient(runner: TappedRunner(tap: tap, json: applyJSON))
                client.context = model.context
                _ = try await client.syncApply(prune: pruneToggle,
                                               limitWrites: 5,
                                               gitSourceOfTruth: model.gitSourceOfTruth,
                                               refresh: model.refreshMode,
                                               verify: model.verifyMode)
                let sent = await tap.argv

                XCTAssertEqual(previewed, sent,
                               "the sheet previews \(previewed) but Apply runs \(sent)")
                XCTAssertEqual(sent.suffix(2), ["--context", "prod"],
                               "a preview that dropped the context would name the wrong tenant: \(sent)")
                if git {
                    XCTAssertTrue(sent.contains("--prune"),
                                  "git-as-truth forces deletes/detaches on, toggle or not: \(sent)")
                }
            }
        }
    }

    /// `AppModel.previewArgv` and the client's private `argv(_:)` now share one function, and this
    /// pins the half of that rule a copy would most easily get wrong: an unset context means "use
    /// abctl's own current context", so the preview must show NO `--context` flag rather than an
    /// empty one — `abctl validate --json --context ''` is not what runs, and it would not work.
    @MainActor
    func testPreviewArgvThreadsTheContextExactlyLikeTheRun() async throws {
        let emptyReport = #"{"ok":true,"libDir":"gitops/lib","checked":0,"passed":0,"failed":0,"warnings":0,"profiles":[],"treeIssues":[],"validator":"built-in"}"#
        let model = AppModel() // no context chosen — makeClient passes nil, not ""
        let tap = ArgvTap()
        var client = AbctlClient(runner: TappedRunner(tap: tap, json: emptyReport))
        client.context = model.context.isEmpty ? nil : model.context

        _ = try await client.validateProfiles()
        var sent = await tap.argv
        var previewed = model.previewArgv(AbctlClient.validateArgs())
        XCTAssertEqual(previewed, sent, "an unset context must not preview a --context flag: \(previewed)")

        model.context = "prod"
        client.context = "prod"
        _ = try await client.validateProfiles()
        sent = await tap.argv
        previewed = model.previewArgv(AbctlClient.validateArgs())
        XCTAssertEqual(previewed, sent)
        XCTAssertEqual(sent.suffix(2), ["--context", "prod"])
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

/// Captures the argv and cwd the client handed the runner, so a test can hold the preview
/// builder's output up against what execution really passed. An actor because the client calls
/// it from whatever task drove the command.
private actor ArgvTap {
    var argv: [String] = []
    var cwd: URL?
    /// The command budget the client asked for. Recorded because a too-small one is a real
    /// defect with a misleading symptom: `adopt` on the plain 60s read budget died mid-flight
    /// on a live tenant and left the manifest unwritten, reported only as "abctl ran for 60s".
    var timeout: Duration?
    func record(_ a: [String], _ c: URL?, _ t: Duration? = nil) { argv = a; cwd = c; timeout = t }
}


// MARK: - the workspace cwd + adopt contract (the "detach-config forever" bug)

extension ContractTests {
    /// EVERY tree-mutating verb must run in the workspace. abctl roots gitops/ at its process
    /// working directory, so an attach launched from the app bundle's cwd wrote its manifest
    /// somewhere else (or nowhere) while `diff` read the real tree — leaving a `detach-config`
    /// row that came back on every refresh. This is the regression guard: the write verbs are
    /// asserted one by one, because the failure was silent and per-verb.
    func testTreeMutatingVerbsRunInTheWorkspace() async throws {
        let cases: [(String, (AbctlClient) async throws -> Void)] = [
            ("attach", { _ = try await $0.attach(configID: "c1", blueprint: "Fleet") }),
            ("detach", { _ = try await $0.detach(configID: "c1", blueprint: "Fleet") }),
            ("adopt",  { _ = try await $0.adoptMember(kind: "config", name: "WiFi.mobileconfig", blueprint: "Fleet") }),
            ("create", { _ = try await $0.createConfiguration(name: "WiFi.mobileconfig", xml: Data("<x/>".utf8)) }),
            ("replace", { _ = try await $0.replaceConfiguration(id: "c1", xml: Data("<x/>".utf8)) }),
            ("delete", { _ = try await $0.deleteConfiguration(id: "c1") }),
        ]
        let json = #"{"action":"attach","name":"WiFi.mobileconfig","id":"c1","status":"done","treeUpdated":true}"#
        for (label, call) in cases {
            let tap = ArgvTap()
            var client = AbctlClient(runner: TappedRunner(tap: tap, json: json))
            client.repoRoot = URL(fileURLWithPath: "/work/ws")
            try await call(client)
            let cwd = await tap.cwd
            XCTAssertEqual(cwd?.path, "/work/ws", "\(label) did not run in the workspace — its gitops/ write lands in the wrong tree")
        }
    }

    /// `adopt` writes local files only, so it must NOT carry --yes (there is no tenant change to
    /// gate) and must name the member collection abctl expects as its first argument.
    func testAdoptArgvIsLocalOnly() async throws {
        let tap = ArgvTap()
        var client = AbctlClient(runner: TappedRunner(tap: tap, json: #"{"action":"adopt","name":"WiFi.mobileconfig","status":"done","treeUpdated":true}"#))
        client.repoRoot = URL(fileURLWithPath: "/work/ws")
        _ = try await client.adoptMember(kind: "config", name: "WiFi.mobileconfig", blueprint: "Fleet")
        let argv = await tap.argv
        XCTAssertEqual(argv.prefix(5).map { $0 }, ["adopt", "config", "WiFi.mobileconfig", "--blueprint", "Fleet"])
        XCTAssertFalse(argv.contains("--yes"), "adopt touches no tenant state and must not be gated: \(argv)")
    }

    /// A tenant write whose local tree update failed exits 0 and reports treeUpdated:false. It
    /// used to report true unconditionally, which is how a green attach left git untouched.
    func testTreeErrorSurfacesAsAWarningNotASuccess() throws {
        let failed = try JSONDecoder().decode(WriteOutcome.self, from: Data(#"""
        {"action":"attach","name":"WiFi.mobileconfig","id":"c1","status":"done","blueprint":"Fleet",
         "treeUpdated":false,"treeError":"mkdir /gitops/blueprints: read-only file system"}
        """#.utf8))
        XCTAssertNotNil(failed.treeWarning)
        XCTAssertTrue(failed.treeWarning?.contains("read-only file system") == true)

        // A clean write says nothing, and neither does an older abctl that omits the field.
        let clean = try JSONDecoder().decode(WriteOutcome.self, from: Data(
            #"{"action":"attach","name":"WiFi.mobileconfig","status":"done","treeUpdated":true}"#.utf8))
        XCTAssertNil(clean.treeWarning)
    }

    /// The membership verbs are multi-call (resolve blueprint, list configurations for name/id,
    /// read current members, write) and must not run on the plain 60s read budget. `adopt` on
    /// that budget timed out against a real tenant and wrote nothing, while the only symptom was
    /// a generic "abctl ran for 60s" — a timeout that reads as a broken feature.
    func testMembershipVerbsGetMoreThanTheReadBudget() async throws {
        let json = #"{"action":"adopt","name":"WiFi.mobileconfig","status":"done","treeUpdated":true}"#
        let calls: [(String, (AbctlClient) async throws -> Void)] = [
            ("adopt",  { _ = try await $0.adoptMember(kind: "config", name: "WiFi.mobileconfig", blueprint: "Fleet") }),
            ("attach", { _ = try await $0.attach(configID: "c1", blueprint: "Fleet") }),
            ("detach", { _ = try await $0.detach(configID: "c1", blueprint: "Fleet") }),
        ]
        for (label, call) in calls {
            let tap = ArgvTap()
            var client = AbctlClient(runner: TappedRunner(tap: tap, json: json))
            client.repoRoot = URL(fileURLWithPath: "/work/ws")
            try await call(client)
            let timeout = await tap.timeout
            XCTAssertNotNil(timeout, "\(label) recorded no timeout")
            XCTAssertGreaterThan(timeout ?? .seconds(0), .seconds(60),
                                 "\(label) is a multi-call verb and must not run on the 60s read budget")
        }
    }

    /// Plan rows are classified by PREFIX across all six member collections. Spelling only the
    /// `-config` pair made every app/package/device/user/group row read as blocked.
    func testBlueprintRowClassificationCoversEveryCollection() async throws {
        let json = """
        {"configs":[],
         "blueprints":[{"blueprint":"Fleet","action":"detach-app","config":"Pages","config_id":"a1","detail":"d"},
                       {"blueprint":"Fleet","action":"adopt-config","config":"WiFi.mobileconfig","config_id":"c1","detail":"d"},
                       {"blueprint":"Fleet","action":"attach-user","config":"a@b.com","detail":"blocked"},
                       {"blueprint":"Fleet","action":"blueprint-adopt","detail":"reported"}]}
        """
        let client = AbctlClient(runner: MockAbctlRunner(responses: ["diff": MockAbctlRunner.ok(json)]))
        let rows = try await client.plan().blueprints

        XCTAssertTrue(rows[0].isDetach)
        XCTAssertTrue(rows[0].isActionable)
        XCTAssertEqual(rows[0].memberKind, "app")

        XCTAssertTrue(rows[1].isAdopt)
        XCTAssertTrue(rows[1].isActionable)
        XCTAssertEqual(rows[1].memberKind, "config")

        XCTAssertTrue(rows[2].isAttach)
        XCTAssertFalse(rows[2].isActionable, "an attach with no member id is still blocked")

        // The blueprint-level adopt is a REPORTED row about the blueprint, not a member verb.
        XCTAssertFalse(rows[3].isAdopt)
        XCTAssertNil(rows[3].memberKind)
        XCTAssertFalse(rows[3].isActionable)
    }
}

/// An `AbctlRunner` that taps the invocation and answers with one canned payload — enough for
/// the client to decode and return, so the parity tests exercise the real call path.
private struct TappedRunner: AbctlRunner {
    let tap: ArgvTap
    let json: String
    func run(_ args: [String], cwd: URL?, stdin: Data?, timeout: Duration) async throws -> AbctlResult {
        await tap.record(args, cwd, timeout)
        return MockAbctlRunner.ok(json)
    }
}

/// A lock-guarded collector for `RecordingRunner`'s sinks, which fire off the main thread.
private final class ParityCommandSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [CommandRecord] = []
    private var _finished: [(UUID, CommandRecord.Status)] = []

    var started: [CommandRecord] { lock.withLock { _started } }
    var finished: [(UUID, CommandRecord.Status)] { lock.withLock { _finished } }

    func start(_ record: CommandRecord) { lock.withLock { _started.append(record) } }
    func finish(_ id: UUID, _ status: CommandRecord.Status) { lock.withLock { _finished.append((id, status)) } }
}
