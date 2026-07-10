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
