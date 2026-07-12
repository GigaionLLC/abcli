// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

// Typed, read-only detail sheets for the browsable entities (device, enrolled device,
// user, user group, app, package, MDM server, blueprint). Each renders a labeled grid
// of the attributes abctl's singular `get …` commands print, keeps the expensive extra
// API calls (AppleCare, `status device`, group members, a server's device list) behind
// explicit buttons, and offers the full raw JSON via ResourceDetailView as a fallback.
// The JSON shapes come from abctl (internal/cli/inspect.go / get.go); the composite
// payloads decode via Models/Inspect.swift.

// MARK: - shared scaffolding

/// One label/value row of a detail grid. Labels double as ForEach ids, so they must be
/// unique within a grid (they are — each grid mirrors one abctl printKV block).
private struct DetailField: Identifiable {
    let label: String
    let value: String
    var id: String { label }
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A labeled attribute grid — the GUI sibling of abctl's printKV. Empty values render
/// as an em dash so every expected field stays visible (matching the list columns).
private struct DetailGrid: View {
    let fields: [DetailField]
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(fields) { field in
                GridRow {
                    Text(field.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(field.value.isEmpty ? "—" : field.value)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }
}

/// A titled section inside a detail sheet.
private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

/// The small red error line the write sheets use.
private struct ErrorText: View {
    let message: String
    init(_ message: String) { self.message = message }
    var body: some View { Text(message).foregroundStyle(.red).font(.caption) }
}

/// Shared chrome for the typed sheets: a lock-badged read-only header, a "Raw JSON"
/// fallback (the full ResourceDetailView), a Done button, and a scrolling content area.
private struct InspectSheetFrame<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// The resource the Raw JSON fallback shows (the freshest copy of the main entity).
    let raw: Resource
    @ViewBuilder let content: Content
    @State private var rawTarget: Resource?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(title) — read-only", systemImage: "lock")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button("Raw JSON") { rawTarget = raw }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .sheet(item: $rawTarget) { ResourceDetailView(title: title, resource: $0) }
    }
}

// Attribute readers the typed sheets need beyond Resource.attr (string-only): booleans,
// numbers, and joined lists — mirroring abctl's boolAttr / intAttr / attrJoin renderers.
private extension Resource {
    /// enabled / disabled for a boolean posture attribute ("" when unreported).
    func enabledText(_ key: String) -> String {
        guard case .object(let o)? = attributes, case .bool(let b)? = o[key] else { return "" }
        return b ? "enabled" : "disabled"
    }

    /// true / false for a boolean attribute ("" when absent).
    func boolText(_ key: String) -> String {
        guard case .object(let o)? = attributes, case .bool(let b)? = o[key] else { return "" }
        return b ? "true" : "false"
    }

    /// A numeric attribute, or nil.
    func number(_ key: String) -> Double? {
        guard case .object(let o)? = attributes, case .number(let n)? = o[key] else { return nil }
        return n
    }

    /// A list attribute comma-joined (imei[], phoneNumbers[], platforms[]).
    func joined(_ key: String) -> String {
        guard let items = attributes?.array(key) else { return "" }
        return items.compactMap { item -> String? in
            if case .string(let s) = item { return s }
            if case .number(let n) = item { return String(Int(n)) }
            return nil
        }.joined(separator: ", ")
    }

    /// "used of total" in GB (1 decimal) from the byte-count posture attributes —
    /// the same numbers abctl's storageUsed prints (internal/cli/inspect.go), so the
    /// GUI and CLI never disagree about the same device.
    func storageText() -> String {
        guard let free = number("storageFreeCapacity"),
              let total = number("storageTotalCapacity"), total > 0 else { return "" }
        return String(format: "%.1f GB used of %.1f GB", (total - free) / 1e9, total / 1e9)
    }

    /// roleOuList ([{roleName, ouId}]) rendered as "roleName @ ouId" lines.
    func roleAssignments() -> [String] {
        guard let list = attributes?.array("roleOuList") else { return [] }
        return list.compactMap { entry -> String? in
            guard let name = entry.string("roleName"), !name.isEmpty else { return nil }
            if let ou = entry.string("ouId"), !ou.isEmpty { return "\(name) @ \(ou)" }
            return name
        }
    }
}

/// The last-reported posture rows (mirrors abctl's `status device` / `get mdmdevice`
/// human output — same fields, same order).
private func postureFields(_ details: Resource) -> [DetailField] {
    let os = [details.attr("platform"), details.attr("osVersion")].compactMap { $0 }.joined(separator: " ")
    return [
        DetailField("OS", os),
        DetailField("Last check-in", details.attr("lastCheckInDateTime") ?? ""),
        DetailField("FileVault", details.enabledText("isFileVaultEnabled")),
        DetailField("Firewall", details.enabledText("isFirewallEnabled")),
        DetailField("Storage", details.storageText()),
        DetailField("Lock", details.attr("deviceLockStatus") ?? ""),
        DetailField("Erase", details.attr("deviceEraseStatus") ?? ""),
        DetailField("Lost mode", details.attr("lostModeStatus") ?? ""),
    ]
}

/// AppleCare coverage records as grids (mirrors abctl's printAppleCare columns).
@ViewBuilder
private func appleCareList(_ coverage: [Resource]) -> some View {
    if coverage.isEmpty {
        Text("No coverage records.").foregroundStyle(.secondary).font(.callout)
    } else {
        ForEach(coverage) { record in
            DetailGrid(fields: [
                DetailField("Coverage", record.attr("description") ?? record.id),
                DetailField("Status", record.attr("status") ?? ""),
                DetailField("Payment", record.attr("paymentType") ?? ""),
                DetailField("Ends", record.attr("endDateTime") ?? ""),
            ])
        }
    }
}

// MARK: - device

/// One org device: full attributes and the assigned MDM server (same `get device` payload,
/// auto-loaded), plus two opt-in sections behind buttons — AppleCare coverage (an extra
/// API call) and blueprints & posture (`status device`, which fans out per blueprint).
struct DeviceDetailSheet: View {
    @Environment(AppModel.self) private var model
    let resource: Resource

    @State private var detail: DeviceDetail?
    @State private var loadError: String?
    @State private var appleCare: [Resource]?
    @State private var appleCareBusy = false
    @State private var appleCareError: String?
    @State private var report: DeviceStatusReport?
    @State private var reportBusy = false
    @State private var reportError: String?
    @State private var releasesBusy = false

    /// The freshest copy of the device (the row resource until `get device` returns).
    private var device: Resource { detail?.device ?? resource }

    var body: some View {
        InspectSheetFrame(title: "Device", raw: device) {
            if detail == nil && loadError == nil { ProgressView().controlSize(.small) }
            if let loadError { ErrorText(loadError) }
            DetailGrid(fields: deviceFields)
            assignedServerSection
            appleCareSection
            postureSection
        }
        .task {
            do { detail = try await model.deviceDetail(resource.id) }
            catch { loadError = error.localizedDescription }
        }
    }

    // All orgDevice attributes in abctl's `get device` display order.
    private var deviceFields: [DetailField] {
        let d = device
        let purchase = [d.attr("purchaseSourceType"), d.attr("purchaseSourceId")].compactMap { $0 }.joined(separator: " ")
        let releaser = [d.attr("releaserEntityType"), d.attr("releaserId")].compactMap { $0 }.joined(separator: " ")
        return [
            DetailField("Serial", d.attr("serialNumber") ?? d.id),
            DetailField("ID", d.id),
            DetailField("Model", d.attr("deviceModel") ?? ""),
            DetailField("Family", d.attr("productFamily") ?? ""),
            DetailField("Product type", d.attr("productType") ?? ""),
            DetailField("Capacity", d.attr("deviceCapacity") ?? ""),
            DetailField("Color", d.attr("color") ?? ""),
            DetailField("Status", d.attr("status") ?? ""),
            DetailField("Part number", d.attr("partNumber") ?? ""),
            DetailField("Order number", d.attr("orderNumber") ?? ""),
            DetailField("Ordered", d.attr("orderDateTime") ?? ""),
            DetailField("Purchase source", purchase.trimmingCharacters(in: .whitespaces)),
            DetailField("Added to org", d.attr("addedToOrgDateTime") ?? ""),
            DetailField("Released", d.attr("releasedFromOrgDateTime") ?? ""),
            DetailField("Released by", releaser.trimmingCharacters(in: .whitespaces)),
            DetailField("Updated", d.attr("updatedDateTime") ?? ""),
            DetailField("IMEI", d.joined("imei")),
            DetailField("MEID", d.joined("meid")),
            DetailField("EID", d.attr("eid") ?? ""),
            DetailField("Wi-Fi MAC", d.attr("wifiMacAddress") ?? ""),
            DetailField("Bluetooth MAC", d.attr("bluetoothMacAddress") ?? ""),
            DetailField("Ethernet MAC", d.joined("ethernetMacAddress")),
        ]
    }

    @ViewBuilder private var assignedServerSection: some View {
        if let detail {
            DetailSection(title: "Assigned server") {
                if let server = detail.assignedServer {
                    DetailGrid(fields: [
                        DetailField("Name", server.attr("serverName") ?? server.id),
                        DetailField("Type", server.attr("serverType") ?? ""),
                        DetailField("ID", server.id),
                    ])
                } else {
                    Text("Not assigned to an MDM server.").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var appleCareSection: some View {
        DetailSection(title: "AppleCare") {
            if let appleCare {
                appleCareList(appleCare)
            } else {
                HStack(spacing: 8) {
                    Button("Check coverage") {
                        appleCareBusy = true
                        appleCareError = nil
                        Task {
                            do { appleCare = try await model.deviceDetail(resource.id, appleCare: true).appleCare ?? [] }
                            catch { appleCareError = error.localizedDescription }
                            appleCareBusy = false
                        }
                    }
                    .disabled(appleCareBusy)
                    if appleCareBusy { ProgressView().controlSize(.small) }
                }
                Text("One extra API call, so it stays behind this button.")
                    .font(.caption).foregroundStyle(.secondary)
                if let appleCareError { ErrorText(appleCareError) }
            }
        }
    }

    @ViewBuilder private var postureSection: some View {
        DetailSection(title: "Blueprints & posture") {
            if let report {
                // Reuse abctl's framing: this is intent + last report, never live truth.
                Text("Desired-state / assignment intent + last-reported MDM posture — NOT live on-device verification (the Apple Business API cannot report per-device install status).")
                    .font(.caption).foregroundStyle(.secondary)
                if report.blueprints.isEmpty {
                    Text("Blueprints: (none)").foregroundStyle(.secondary).font(.callout)
                } else {
                    ForEach(report.blueprints, id: \.blueprint) { coverage in
                        DetailGrid(fields: [
                            DetailField("Blueprint", coverage.blueprint),
                            DetailField("Configurations", coverage.configurations.joined(separator: ", ")),
                        ])
                    }
                }
                mdmPosture(report)
                releaseComparison(report)
            } else {
                HStack(spacing: 8) {
                    Button("Check blueprints & posture") {
                        reportBusy = true
                        reportError = nil
                        Task {
                            do { report = try await model.deviceStatus(resource.id) }
                            catch { reportError = error.localizedDescription }
                            reportBusy = false
                        }
                    }
                    .disabled(reportBusy)
                    if reportBusy { ProgressView().controlSize(.small) }
                }
                Text("Runs `status device` — one relationship call per blueprint, so it can take a while on large tenants.")
                    .font(.caption).foregroundStyle(.secondary)
                if let reportError { ErrorText(reportError) }
            }
        }
    }

    @ViewBuilder private func releaseComparison(_ report: DeviceStatusReport) -> some View {
        if let details = report.mdm?.details {
            let platform = details.attr("platform") ?? ""
            let installed = details.attr("osVersion") ?? ""
            let product = device.attr("productType") ?? ""
            let matches = model.osReleases.filter { release in
                release.platform.caseInsensitiveCompare(platform) == .orderedSame
                    && (product.isEmpty || (release.supportedDevices ?? []).contains(product))
            }
            let managed = matches.first { $0.catalog == "managed" }
            let publicRelease = matches.first { $0.catalog == "public" }
            DetailSection(title: "Software release comparison") {
                Text("Catalog comparison only — not proof that this device is eligible, scheduled, or updated.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.osReleases.isEmpty {
                    HStack {
                        Button("Load Apple release catalog") {
                            releasesBusy = true
                            Task { await model.loadOSReleases(); releasesBusy = false }
                        }.disabled(releasesBusy)
                        if releasesBusy { ProgressView().controlSize(.small) }
                    }
                } else {
                    DetailGrid(fields: [
                        DetailField("Reported version", installed),
                        DetailField("Newest managed", managed.map { "\($0.productVersion) (\($0.build))" } ?? "No matching catalog entry"),
                        DetailField("Newest public", publicRelease.map { "\($0.productVersion) (\($0.build))" } ?? "No matching catalog entry"),
                        DetailField("Product match", product),
                    ])
                }
            }
        }
    }

    // The four built-in-MDM states of the report: unavailable (listing denied/unreachable),
    // enrolled with posture, enrolled without posture, not enrolled.
    @ViewBuilder private func mdmPosture(_ report: DeviceStatusReport) -> some View {
        if let mdm = report.mdm {
            if let error = mdm.error {
                Text("Built-in MDM: unavailable — \(error)").foregroundStyle(.secondary).font(.callout)
            } else if let details = mdm.details {
                Text("Built-in MDM (last reported)").font(.subheadline.weight(.semibold))
                DetailGrid(fields: postureFields(details))
            } else {
                Text("Built-in MDM: enrolled (posture unavailable).").foregroundStyle(.secondary).font(.callout)
            }
        } else {
            Text("Built-in MDM: not enrolled.").foregroundStyle(.secondary).font(.callout)
        }
    }
}

// MARK: - enrolled (built-in-MDM) device

/// One built-in-MDM device: identity plus its last-reported posture grid (FileVault,
/// firewall, check-in, OS, storage, lock/erase/lost-mode, MACs).
struct MDMDeviceDetailSheet: View {
    @Environment(AppModel.self) private var model
    let resource: Resource

    @State private var detail: MDMDeviceDetail?
    @State private var loadError: String?

    private var device: Resource { detail?.device ?? resource }

    var body: some View {
        InspectSheetFrame(title: "Enrolled device", raw: device) {
            if detail == nil && loadError == nil { ProgressView().controlSize(.small) }
            if let loadError { ErrorText(loadError) }
            DetailGrid(fields: identityFields)
            if let detail {
                DetailSection(title: "Last-reported posture") {
                    Text("As of the device's last check-in — not a live device query.")
                        .font(.caption).foregroundStyle(.secondary)
                    DetailGrid(fields: postureFields(detail.details) + macFields(detail.details))
                }
            }
        }
        .task {
            do { detail = try await model.mdmDeviceDetail(resource.id) }
            catch { loadError = error.localizedDescription }
        }
    }

    private var identityFields: [DetailField] {
        [
            DetailField("Name", device.attr("deviceName") ?? device.id),
            DetailField("Serial", device.attr("serialNumber") ?? ""),
            DetailField("ID", device.id),
            DetailField("Family", device.attr("productFamily") ?? ""),
            DetailField("Model", detail?.details.attr("deviceModel") ?? device.attr("deviceModel") ?? ""),
            DetailField("Enrolled user", device.attr("enrolledUserId") ?? ""),
        ]
    }

    // MACs live on the posture details for enrolled devices; fall back to the row resource.
    private func macFields(_ details: Resource) -> [DetailField] {
        let ethernet = details.joined("ethernetMacAddress")
        return [
            DetailField("Wi-Fi MAC", details.attr("wifiMacAddress") ?? device.attr("wifiMacAddress") ?? ""),
            DetailField("Bluetooth MAC", details.attr("bluetoothMacAddress") ?? device.attr("bluetoothMacAddress") ?? ""),
            DetailField("Ethernet MAC", ethernet.isEmpty ? device.joined("ethernetMacAddress") : ethernet),
        ]
    }
}

// MARK: - user

/// One user. Fetches the singular `get user` payload — it carries fields the list
/// endpoint doesn't (managedAppleAccount, roleOuList, org fields).
struct UserDetailSheet: View {
    @Environment(AppModel.self) private var model
    let resource: Resource

    @State private var detail: Resource?
    @State private var loadError: String?

    private var user: Resource { detail ?? resource }

    var body: some View {
        InspectSheetFrame(title: "User", raw: user) {
            if detail == nil && loadError == nil { ProgressView().controlSize(.small) }
            if let loadError { ErrorText(loadError) }
            DetailGrid(fields: fields)
            rolesSection
            Text("User editing is Apple Business console / SCIM only — the API has no user writes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            do { detail = try await model.userDetail(resource.id) }
            catch { loadError = error.localizedDescription }
        }
    }

    private var fields: [DetailField] {
        let u = user
        let name = [u.attr("firstName"), u.attr("middleName"), u.attr("lastName")]
            .compactMap { $0 }.joined(separator: " ")
        return [
            DetailField("Name", name.trimmingCharacters(in: .whitespaces)),
            DetailField("ID", u.id),
            DetailField("Email", u.attr("email") ?? ""),
            DetailField("Managed account", u.attr("managedAppleAccount") ?? u.attr("managedAppleId") ?? ""),
            DetailField("Status", u.attr("status") ?? ""),
            DetailField("External", u.boolText("isExternalUser")),
            DetailField("Department", u.attr("department") ?? ""),
            DetailField("Job title", u.attr("jobTitle") ?? ""),
            DetailField("Employee number", u.attr("employeeNumber") ?? ""),
            DetailField("Cost center", u.attr("costCenter") ?? ""),
            DetailField("Division", u.attr("division") ?? ""),
            DetailField("Phone", u.joined("phoneNumbers")),
            DetailField("Started", u.attr("startDateTime") ?? ""),
            DetailField("Created", u.attr("createdDateTime") ?? ""),
            DetailField("Updated", u.attr("updatedDateTime") ?? ""),
        ]
    }

    @ViewBuilder private var rolesSection: some View {
        let roles = user.roleAssignments()
        if !roles.isEmpty {
            DetailSection(title: "Roles") {
                ForEach(roles, id: \.self) { Text($0).font(.callout) }
            }
        }
    }
}

// MARK: - user group

/// One user group; member emails load behind a button (`get usergroup --members` makes
/// one API call per member, so it is never automatic).
struct UserGroupDetailSheet: View {
    @Environment(AppModel.self) private var model
    let resource: Resource

    @State private var members: [String]?
    @State private var membersBusy = false
    @State private var membersError: String?

    var body: some View {
        InspectSheetFrame(title: "User group", raw: resource) {
            DetailGrid(fields: fields)
            DetailSection(title: "Members") {
                if let members {
                    if members.isEmpty {
                        Text("No members.").foregroundStyle(.secondary).font(.callout)
                    } else {
                        ForEach(members, id: \.self) { Text($0).font(.callout) }
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Load members") {
                            membersBusy = true
                            membersError = nil
                            Task {
                                do { members = try await model.userGroupDetail(resource.id, members: true).members ?? [] }
                                catch { membersError = error.localizedDescription }
                                membersBusy = false
                            }
                        }
                        .disabled(membersBusy)
                        if membersBusy { ProgressView().controlSize(.small) }
                    }
                    Text("One API call per member, so it stays behind this button.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let membersError { ErrorText(membersError) }
                }
            }
        }
    }

    private var fields: [DetailField] {
        [
            DetailField("Name", resource.attr("name") ?? resource.id),
            DetailField("ID", resource.id),
            DetailField("Type", resource.attr("groupType") ?? ""),
            DetailField("Status", resource.attr("status") ?? ""),
            DetailField("Member count", resource.number("totalMemberCount").map { String(Int($0)) } ?? ""),
        ]
    }
}

// MARK: - app / package

/// Labeled attributes for a catalog item — shared by the app and package sheets (their
/// attribute bags overlap: name, bundle id, version, platforms, custom flag). Fetches
/// the singular payload (`get app` / `get package`) so the grid shows the freshest copy,
/// rendering the cached list row until it arrives.
private struct CatalogItemDetail: View {
    @Environment(AppModel.self) private var model
    let title: String
    let resource: Resource
    /// The singular fetch for this kind (AppModel.appDetail / packageDetail).
    let fetch: (AppModel, String) async throws -> Resource

    @State private var detail: Resource?
    @State private var loadError: String?

    /// The freshest copy of the item (the row resource until the fetch returns).
    private var item: Resource { detail ?? resource }

    var body: some View {
        InspectSheetFrame(title: title, raw: item) {
            if detail == nil && loadError == nil { ProgressView().controlSize(.small) }
            if let loadError { ErrorText(loadError) }
            DetailGrid(fields: fields)
        }
        .task {
            do { detail = try await fetch(model, resource.id) }
            catch { loadError = error.localizedDescription }
        }
    }

    private var fields: [DetailField] {
        let custom = item.boolText("isCustomApp").isEmpty
            ? (item.attr("isCustomApp") ?? "") : item.boolText("isCustomApp")
        let platforms = item.joined("platforms").isEmpty
            ? item.joined("supportedPlatforms") : item.joined("platforms")
        return [
            DetailField("Name", item.attr("name") ?? item.id),
            DetailField("ID", item.id),
            DetailField("Bundle ID", item.attr("bundleId") ?? ""),
            DetailField("Version", item.attr("version") ?? ""),
            DetailField("Platforms", platforms),
            DetailField("Custom app", custom),
            DetailField("Created", item.attr("createdDateTime") ?? ""),
            DetailField("Updated", item.attr("updatedDateTime") ?? ""),
        ]
    }
}

/// One owned app (Apps & Books).
struct AppDetailSheet: View {
    let resource: Resource
    var body: some View {
        CatalogItemDetail(title: "App", resource: resource) { try await $0.appDetail($1) }
    }
}

/// One custom app / package.
struct PackageDetailSheet: View {
    let resource: Resource
    var body: some View {
        CatalogItemDetail(title: "Package", resource: resource) { try await $0.packageDetail($1) }
    }
}

// MARK: - MDM server

/// One MDM server; its assigned device serials load behind a button (`get mdmserver
/// --devices` lists the whole org device inventory to resolve serials).
struct MDMServerDetailSheet: View {
    @Environment(AppModel.self) private var model
    let resource: Resource

    @State private var detail: MDMServerDetail?
    @State private var devicesBusy = false
    @State private var devicesError: String?

    var body: some View {
        InspectSheetFrame(title: "MDM server", raw: detail?.server ?? resource) {
            DetailGrid(fields: fields)
            DetailSection(title: "Assigned devices") {
                if let detail {
                    Text("\(detail.deviceCount ?? detail.devices?.count ?? 0) device(s)").font(.callout)
                    ForEach(detail.devices ?? [], id: \.self) {
                        Text($0).font(.system(.callout, design: .monospaced))
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("List devices") {
                            devicesBusy = true
                            devicesError = nil
                            Task {
                                do { detail = try await model.mdmServerDetail(resource.id, devices: true) }
                                catch { devicesError = error.localizedDescription }
                                devicesBusy = false
                            }
                        }
                        .disabled(devicesBusy)
                        if devicesBusy { ProgressView().controlSize(.small) }
                    }
                    if let devicesError { ErrorText(devicesError) }
                }
            }
        }
    }

    private var fields: [DetailField] {
        let server = detail?.server ?? resource
        return [
            DetailField("Name", server.attr("serverName") ?? server.id),
            DetailField("ID", server.id),
            DetailField("Type", server.attr("serverType") ?? ""),
            DetailField("Created", server.attr("createdDateTime") ?? ""),
            DetailField("Updated", server.attr("updatedDateTime") ?? ""),
        ]
    }
}

// MARK: - blueprint

/// One blueprint: attributes, the Apps & Books license signal, and the Relationships
/// section — all six member collections name-resolved with counts (`get blueprint`).
struct BlueprintDetailSheet: View {
    @Environment(AppModel.self) private var model
    let resource: Resource

    @State private var detail: BlueprintDetail?
    @State private var loadError: String?

    var body: some View {
        InspectSheetFrame(title: "Blueprint", raw: detail?.blueprint ?? resource) {
            if detail == nil && loadError == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching the six member collections…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let loadError { ErrorText(loadError) }
            DetailGrid(fields: fields)
            if let detail {
                if detail.appLicenseDeficient {
                    Label("App-license-deficient — more app licenses needed than available.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                DetailSection(title: "Relationships") {
                    DetailGrid(fields: relationshipFields(detail))
                }
            }
        }
        .task {
            do { detail = try await model.blueprintDetail(resource.id) }
            catch { loadError = error.localizedDescription }
        }
    }

    private var fields: [DetailField] {
        let bp = detail?.blueprint ?? resource
        return [
            DetailField("Name", bp.attr("name") ?? bp.id),
            DetailField("ID", bp.id),
            DetailField("Status", bp.attr("status") ?? ""),
            DetailField("Updated", bp.attr("updatedDateTime") ?? ""),
        ]
    }

    /// The six member collections in abctl's display order, count + resolved names per row.
    private func relationshipFields(_ detail: BlueprintDetail) -> [DetailField] {
        let labels = ["configurations": "Configurations", "apps": "Apps", "packages": "Packages",
                      "orgDevices": "Devices", "users": "Users", "userGroups": "User groups"]
        return BlueprintDetail.relationshipOrder.map { rel in
            let names = detail.relationships[rel] ?? []
            let value = names.isEmpty ? "0 — (none)" : "\(names.count) — \(names.joined(separator: ", "))"
            return DetailField(labels[rel] ?? rel, value)
        }
    }
}
