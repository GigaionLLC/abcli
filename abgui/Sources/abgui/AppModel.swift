// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Observation

/// Top-level app state. `@MainActor` so every mutation SwiftUI observes happens on the
/// main thread; the actual work hops onto `ProcessRunner` (its own actor) and back.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case unknown
        case checking
        case connected(VersionInfo, WhoamiResult?)
        case failed(String)
    }

    // Connection
    var connection: Connection = .unknown
    /// Optional abctl context name (blank → abctl uses its own .env / current context).
    var context: String = ""

    // Connection contexts (the credential store, ~/.abctl/contexts.yaml)
    var contexts: [String] = []
    var currentContext: String = ""
    var settingsError: String?
    var settingsBusy = false

    // Browsed inventory (loaded lazily per screen)
    var configurations: [Resource] = []
    var blueprints: [Resource] = []
    var plan: Plan?

    // Read-only resources (Apple Business exposes these for reading only)
    var devices: [Resource] = []
    var mdmDevices: [Resource] = []
    var users: [Resource] = []
    var userGroups: [Resource] = []
    var apps: [Resource] = []
    var packages: [Resource] = []
    var mdmServers: [Resource] = []
    var auditEvents: [Resource] = []
    var auditSince = "7d"
    var osReleases: [OSRelease] = []

    func loadOSReleases() async {
        guard let client = makeClient() else {
            loadError = "abctl was not found in the app bundle."
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do { osReleases = try await client.osReleases() }
        catch { loadError = error.localizedDescription }
    }

    // Apps & Books (VPP) — a separate service; the content token is held in-memory only.
    var vppToken = ""
    var vppConfig: VPPServiceConfig?
    var vppAssets: [VPPAsset] = []
    var vppAssignments: [VPPAssignment] = []
    var vppUsers: [VPPUser] = []
    var vppLoading = false
    var vppError: String?
    var vppConnected: Bool { vppConfig != nil }

    // GitOps workspace (the dir containing gitops/) — required for diff / sync / archive.
    var repoRoot: URL?
    var applyResult: ApplyResult?
    var archiveEntries: [ArchiveEntry] = []
    var gitSourceOfTruth = true
    var refreshMode = "smart"
    var verifyMode = "targeted"
    var needsSeed = false  // workspace chosen but has no gitops/ tree yet → offer to initialize
    var isSeeding = false  // `abctl seed` in flight

    // Pre-flight verification of the local gitops/ profiles (`abctl validate --json`). Reads
    // files only — no tenant call, no credentials — so it can run before anything is synced.
    var validationReport: ValidationReport?
    var isValidating = false
    var validationError: String?
    var lastValidatedAt: Date?

    /// A short-lived, user-visible notice (banner). Posted when a consequential setting
    /// changes, so a flip of Git-source-of-truth is never silent.
    struct Notice: Identifiable, Equatable {
        enum Kind: Equatable { case info, success, warning }
        let id = UUID()
        let kind: Kind
        let title: String
        let message: String
    }

    /// The one notice on screen; a newer post replaces an older one (banners don't stack).
    var notice: Notice?

    func post(_ notice: Notice) { self.notice = notice }

    /// Dismiss by id, so a banner's auto-dismiss timer can't retire a NEWER notice that
    /// replaced it while the timer was still running.
    func dismissNotice(_ id: UUID) {
        if notice?.id == id { notice = nil }
    }

    /// Flip the Git-source-of-truth mode and announce what it now means. The CONFIRMATION
    /// is the caller's job (GitSourceOfTruthControl) — this is the committed change.
    func setGitSourceOfTruth(_ enabled: Bool) {
        gitSourceOfTruth = enabled
        if enabled {
            post(Notice(kind: .warning,
                        title: "Git source of truth is ON",
                        message: "gitops/ is now the complete desired state. Apply will change Apple Business to match your repo — configurations that exist only in Apple are deleted and removed blueprint members are detached."))
        } else {
            post(Notice(kind: .info,
                        title: "Git source of truth is OFF",
                        message: "Sync is additive and newest-wins. Configurations that exist only in Apple are pulled into gitops/ instead of deleted, and nothing is removed unless you enable \"Allow deletes / detaches\"."))
        }
    }

    // Per-screen UI state
    var isLoading = false
    var loadError: String?
    var progressLog: [String] = [] // live stderr narration from abctl during diff/seed
    var applyProgressLog: [String] = [] // live sync/apply progress, separate from final outcomes
    var lastCheckedAt: Date?       // when the plan was last successfully computed (refresh confirmation)
    private var workTask: Task<Void, Never>? // the in-flight diff/seed, so a Cancel button can stop it

    /// Why the last sync did not do what was asked — a SHORT headline plus the full text.
    /// nil after a clean apply. This is the thing the user reads; `applyProgressLog` is the
    /// evidence they read only if they want to (see `SyncFailure`).
    var syncFailure: SyncFailure?

    /// The file the current (or most recent) run's transcript was written to, so the UI can
    /// copy the path and reveal it in Finder. nil when logging is unavailable — the affordance
    /// hides rather than offering a path that leads nowhere.
    private(set) var lastRunLogURL: URL?

    /// The open log for the run in flight. One at a time: abgui runs one operation at a time
    /// (`workTask` is singular, apply is awaited), so both progress channels narrate into
    /// whichever run is currently open.
    private var runLog: RunLog?

    /// Append a progress line (called from abctl's stderr stream), capped so it can't grow unbounded.
    /// The on-disk log is written FIRST and is deliberately uncapped-by-count: the cap here exists
    /// so a long run can't grow a SwiftUI list without bound, and truncating the evidence for the
    /// same reason would defeat the point of having a log at all.
    func appendProgress(_ line: String) {
        runLog?.line(line)
        progressLog.append(line)
        if progressLog.count > 200 { progressLog.removeFirst(progressLog.count - 200) }
    }

    func appendApplyProgress(_ line: String) {
        runLog?.line(line)
        applyProgressLog.append(line)
        if applyProgressLog.count > 300 { applyProgressLog.removeFirst(applyProgressLog.count - 300) }
    }

    func clearApplyOutput() {
        applyProgressLog = []
        applyResult = nil
        lastWriteError = nil
        syncFailure = nil
        // lastRunLogURL survives on purpose: clearing what is on SCREEN must not make the file
        // that is still on disk unreachable.
    }

    // MARK: the run log (~/Library/Logs/abgui) — see Backend/RunLog.swift
    //
    // Opening one is fire-and-forget in spirit: `RunLog.begin` cannot throw and returns nil on
    // any failure, and every write site is `runLog?.line(…)`, so a machine that cannot write
    // logs runs exactly as it does today.

    /// Open a log for `verb`. `argv` is the same pure-builder output the preview shows; it is
    /// laundered through `CommandRecord` (which REDACTS at construction) so the header can only
    /// ever contain the redacted form — no callsite can hand `RunLog` a raw secret-bearing arg.
    /// This record is a redaction vehicle only; the Command Log's records still come from the
    /// `RecordingRunner`, which sees the real invocation.
    private func beginRunLog(_ verb: RunLog.Verb, argv: [String]) async {
        // Belt and braces: a run that somehow never reached its `finishRunLog` would otherwise
        // hold an open file handle and leave a footerless file. At most one log is ever open.
        await finishRunLog("superseded by a new run")
        let redacted = CommandRecord(argv: argv, cwd: repoRoot)
        var version: VersionInfo?
        if case .connected(let info, _) = connection { version = info }
        runLog = await RunLog.begin(RunLog.Header(verb: verb,
                                                  command: redacted.commandLine,
                                                  workspace: repoRoot,
                                                  context: context,
                                                  abctlVersion: version?.version,
                                                  abctlCommit: version?.commit,
                                                  stdin: redacted.stdin))
        // Deliberately assigned even when nil: this URL names the CURRENT run, and pointing at
        // the previous run's file would be worse than offering nothing.
        lastRunLogURL = runLog?.url
    }

    /// Close the open log with its outcome. `lastRunLogURL` is kept — the file is the point.
    private func finishRunLog(_ outcome: String) async {
        guard let log = runLog else { return }
        runLog = nil
        await log.finish(outcome: outcome)
    }

    // MARK: the command trail — every abctl invocation abgui has made this session
    //
    // abgui is a thin facade over the CLI, so this doubles as the answer to "how would I do
    // that in a terminal?": the Command Log replays it, the GitOps screens narrate it inline,
    // and the sheets preview it before they run it. Nothing here is instrumented per callsite —
    // `makeClient` wraps the runner in a `RecordingRunner`, so every verb is captured for free.

    /// Newest LAST (append order), capped like the progress logs so a long session can't grow
    /// unbounded. Records arrive already redacted — a secret cannot reach this array.
    var commands: [CommandRecord] = []

    /// The most recent invocation — what the footer shows as "the last thing abgui ran".
    var lastCommand: CommandRecord? { commands.last }

    private static let commandLimit = 200

    func recordCommandStart(_ record: CommandRecord) {
        commands.append(record)
        if commands.count > Self.commandLimit { commands.removeFirst(commands.count - Self.commandLimit) }
    }

    /// Stamp the terminal status and hand the finished record back, so the caller can narrate
    /// `→ exit 0 in 2.4s` from `CommandRecord.finishLogLine` instead of re-deriving that text.
    /// nil means the record already aged out of the cap (or never started) — nothing to say.
    @discardableResult
    func recordCommandFinish(_ id: UUID, _ status: CommandRecord.Status) -> CommandRecord? {
        guard let index = commands.lastIndex(where: { $0.id == id }) else { return nil }
        commands[index].finishedAt = Date()
        commands[index].status = status
        return commands[index]
    }

    func clearCommands() { commands = [] }

    /// The argv a preview should DISPLAY: a pure builder's output plus the `--context` suffix the
    /// run appends. Previews route through here so the line on screen names the same connection
    /// the real run will use — a preview that silently dropped `--context` would be a command the
    /// administrator could paste and have hit the wrong tenant.
    ///
    /// The suffix itself comes from `AbctlClient.contextSuffixed` — the very function the client's
    /// private `argv(_:)` calls — rather than a second copy of the rule here, so the preview and
    /// the execution cannot disagree about the tail (or about empty meaning "omit it").
    func previewArgv(_ base: [String]) -> [String] {
        AbctlClient.contextSuffixed(base, context: context)
    }

    // Write state (v2)
    var isWriting = false
    var lastWriteError: String?

    /// Which GitOps transcript a client narrates into. The `$ …` command lines and abctl's own
    /// stderr have to share ONE log or a screen shows two half-stories side by side, so this
    /// picks both sinks at once — they cannot be wired to different logs by mistake.
    private enum Narration: Sendable { case silent, progress, apply }

    /// The line sink for a channel — deliberately the very appenders the stderr stream uses, so
    /// `$ abctl diff …`, abctl's narration and `→ exit 0 in 2.4s` interleave into one transcript
    /// in real time. `.silent` (the default) still RECORDS the command; it just doesn't narrate,
    /// which is right for the list screens that have no progress log to narrate into.
    ///
    /// This is the STDERR sink (it is handed to `ProcessRunner`, which calls it off the main
    /// thread and therefore needs the hop each closure performs). The command's own `$ …` / `→ …`
    /// lines do NOT go through it — see `narrate(_:into:)`.
    private func commandSink(into narration: Narration) -> (@Sendable (String) -> Void)? {
        switch narration {
        case .silent: return nil
        case .progress: return progressSink
        case .apply: return applyProgressSink
        }
    }

    /// Append a command's own transcript line to the log that channel narrates into. Already ON
    /// the main actor, so it appends DIRECTLY rather than routing through `commandSink`, whose
    /// closures each wrap their append in another `Task { @MainActor }`.
    ///
    /// That second hop is not cosmetic: it would push `→ exit 0 in 2.4s` a full main-actor job
    /// PAST the state change it describes — after `isLoading`/`isSeeding` flip (so the GitOps
    /// progress log is torn down before the line lands) and after the next run's
    /// `progressLog = []` (so it reappears at the TOP of the following transcript). Appending
    /// here keeps the line in the same turn as `recordCommandFinish`, which is the only ordering
    /// that reads truthfully.
    private func narrate(_ line: String, into narration: Narration) {
        switch narration {
        case .silent: break
        case .progress: appendProgress(line)
        case .apply: appendApplyProgress(line)
        }
    }

    /// Build a client for the current context + workspace, or nil if abctl isn't found.
    /// `narrating` streams abctl's stderr AND the command's own `$ …` / `→ …` lines into one of
    /// the GitOps progress logs (used by diff/seed/apply for live progress).
    ///
    /// Every client records what it runs: the `ProcessRunner` is wrapped in a `RecordingRunner`,
    /// which is why the Command Log needs no per-verb code and picks up verbs added later.
    private func makeClient(narrating narration: Narration = .silent) -> AbctlClient? {
        guard let binary = AbctlLocator.resolve() else { return nil }
        let transcript = commandSink(into: narration)
        let process = ProcessRunner(executable: binary, onStderrLine: transcript)
        // The recorder's sinks fire off the main thread (its documented contract), so each hops
        // back itself — the same shape as progressSink/applyProgressSink below.
        let runner = RecordingRunner(
            wrapping: process,
            onStart: { [weak self] record in
                Task { @MainActor in
                    guard let self else { return }
                    self.recordCommandStart(record)
                    self.narrate(record.startLogLine, into: narration)
                }
            },
            onFinish: { [weak self] id, status in
                Task { @MainActor in
                    // No record (aged out of the cap) means there is nothing truthful to print.
                    guard let self, let record = self.recordCommandFinish(id, status) else { return }
                    self.narrate(record.finishLogLine, into: narration)
                }
            })
        var client = AbctlClient(runner: runner)
        client.context = context.isEmpty ? nil : context
        client.repoRoot = repoRoot
        return client
    }

    /// A progress sink that streams abctl's stderr into `progressLog` on the main actor.
    private var progressSink: (@Sendable (String) -> Void) {
        { [weak self] line in Task { @MainActor in self?.appendProgress(line) } }
    }

    private var applyProgressSink: (@Sendable (String) -> Void) {
        { [weak self] line in Task { @MainActor in self?.appendApplyProgress(line) } }
    }

    private static let workspaceKey = "abgui.workspacePath"

    /// Point at a GitOps workspace (the dir containing `gitops/`) and recompute drift. The path
    /// is remembered so the next launch reopens it (see `restoreWorkspace`).
    func setWorkspace(_ url: URL) {
        repoRoot = url
        plan = nil
        applyResult = nil
        archiveEntries = []
        needsSeed = false // recomputed by loadPlan
        loadError = nil
        // A new workspace's verification state is unknown — never carry the last folder's
        // green light over to files nobody has checked.
        validationReport = nil
        validationError = nil
        lastValidatedAt = nil
        UserDefaults.standard.set(url.path, forKey: Self.workspaceKey)
    }

    /// Reopen the last-used workspace on launch. abgui is non-sandboxed, so a plain saved path
    /// works (no security-scoped bookmark needed). A path that no longer exists is ignored.
    func restoreWorkspace() {
        guard repoRoot == nil,
              let path = UserDefaults.standard.string(forKey: Self.workspaceKey), !path.isEmpty else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            repoRoot = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Start (or restart) computing the plan as a cancellable task, so the UI can offer Cancel.
    func refreshPlan() {
        workTask?.cancel()
        workTask = Task { await loadPlan() }
    }

    /// Cancel an in-flight diff/seed (terminates the abctl subprocess).
    func cancelWork() { workTask?.cancel() }

    /// Scan the workspace's gitops/archive/ tree (pure filesystem — no abctl).
    func loadArchive() {
        guard let root = repoRoot else { archiveEntries = []; return }
        archiveEntries = ArchiveScanner.scan(root: root)
    }

    /// Roll back: restore an archived live version by replacing the live config with it
    /// (which archives the CURRENT live version first — a reversible undo).
    func restore(_ entry: ArchiveEntry) async -> Bool {
        guard let data = try? Data(contentsOf: entry.fileURL),
              let xml = String(data: data, encoding: .utf8) else {
            lastWriteError = "couldn't read the archived profile at \(entry.fileURL.lastPathComponent)."
            return false
        }
        return await replaceConfiguration(id: entry.configName, xml: xml)
    }

    /// Reconcile the tenant to the workspace git state. Returns true on a clean apply.
    ///
    /// The outcome is reported through `syncFailure`: a SHORT headline plus the full text,
    /// rather than the old `error.localizedDescription`, which for a failed sync was abctl's
    /// entire stderr. Two things had to change for that to be possible — `AbctlClient.syncApply`
    /// now decodes stdout before mapping the exit code (so a partially-failed apply arrives as
    /// per-item rows instead of narration), and a partially-failed apply — which used to return
    /// false while setting NO error at all — now names what failed.
    func apply(prune: Bool, limitWrites: Int?) async -> Bool {
        guard let client = makeClient(narrating: .apply) else {
            let message = "abctl was not found in the app bundle."
            lastWriteError = message
            syncFailure = SyncFailure(kind: .aborted, headline: message,
                                      details: "abgui runs the embedded CLI at abgui.app/Contents/Resources/abctl.")
            return false
        }
        isWriting = true
        lastWriteError = nil
        syncFailure = nil
        applyResult = nil
        // Same ordering rule as loadPlan: reset here, above the await, so the `$ abctl sync
        // --apply …` and `→ exit 0 in 12.3s` lines the recorder emits from inside syncApply(...)
        // land after it — and, because the finish line is appended on the recorder's own
        // main-actor turn, before the outcome rows below rather than trailing them.
        applyProgressLog = []
        // Open the on-disk log BEFORE the first narrated line, so the file is the complete
        // transcript and not the tail of one. The argv comes from the same pure builder the
        // run below uses (via `previewArgv`, which adds the `--context` tail the run adds),
        // so the header names the command that actually executed.
        await beginRunLog(.sync, argv: previewArgv(AbctlClient.syncApplyArgs(prune: prune,
                                                                            limitWrites: limitWrites,
                                                                            gitSourceOfTruth: gitSourceOfTruth,
                                                                            refresh: refreshMode,
                                                                            verify: verifyMode)))
        appendApplyProgress("starting sync --apply")
        if let plan {
            for item in plan.configs {
                appendApplyProgress("planned config \(item.action): \(item.name)")
            }
            for item in plan.blueprints {
                let target = item.config.map { "\(item.blueprint) / \($0)" } ?? item.blueprint
                let prefix = item.isActionable ? "planned blueprint" : "blocked blueprint"
                appendApplyProgress("\(prefix) \(item.action): \(target)")
            }
        }
        do {
            // The raw toggle: `AbctlClient.syncApplyArgs` is what forces --prune on under
            // git-as-truth, so this callsite (and ApplySheet's preview of it) never re-derives it.
            // `syncApplyRun` keeps the exit code + stderr next to the decoded rows: abctl can
            // report every item `done` and still exit non-zero when post-apply verification
            // finds Apple didn't persist a write, and that verdict lives only on stderr.
            let run = try await client.syncApplyRun(prune: prune,
                                                    limitWrites: limitWrites,
                                                    gitSourceOfTruth: gitSourceOfTruth,
                                                    refresh: refreshMode,
                                                    verify: verifyMode)
            let result = run.result
            applyResult = result
            appendApplyProgress("sync --apply finished: \(result.totalWrites) write(s), \(result.totalErrors) error(s), \(result.totalSkipped) skipped")
            for row in result.rows {
                appendApplyProgress("\(row.status): \(row.action) \(row.name) - \(row.detail)")
            }
            // nil ⇔ every item succeeded AND abctl exited 0, so this IS the pass/fail test
            // rather than a second condition that could disagree with the one below.
            let failure = SyncFailure.from(applyResult: result, exitCode: run.code,
                                           stderr: run.stderr, transcript: applyProgressLog)
            syncFailure = failure
            lastWriteError = failure?.headline // the short form; the blob is never the message
            isWriting = false
            let outcome = failure.map { "failed — \($0.headline)" }
                ?? "succeeded: \(result.totalWrites) write(s), \(result.totalSkipped) skipped"
            await finishRunLog(outcome)
            // The refresh below belongs to the sync the user just ran, so it does NOT open a
            // second log file — `lastRunLogURL` must keep naming the sync the UI is reporting.
            await loadPlan(newRunLog: false) // refresh drift
            await loadConfigurations()       // the tenant changed
            return failure == nil
        } catch {
            let failure = SyncFailure.from(error: error, transcript: applyProgressLog)
            syncFailure = failure
            lastWriteError = failure.headline
            // Only the HEADLINE goes into the transcript: abctl's stderr was already streamed
            // into it line by line by ProcessRunner, so appending the whole blob again was
            // duplicating the log the user was complaining about.
            appendApplyProgress("sync --apply failed: \(failure.headline)")
            isWriting = false // drop the spinner before the log's final write, not after it
            await finishRunLog("failed — \(failure.headline)")
            return false
        }
    }

    /// Validate the VPP content token and load the Apps & Books inventory. Config failure
    /// = not connected; the per-list calls tolerate individual endpoint failures.
    func vppConnect() async {
        guard let client = makeClient(), !vppToken.isEmpty else {
            vppError = "Enter a content token."
            return
        }
        vppLoading = true
        vppError = nil
        defer { vppLoading = false }
        do {
            vppConfig = try await client.vppConfig(token: vppToken)
            vppAssets = (try? await client.vppAssets(token: vppToken)) ?? []
            vppAssignments = (try? await client.vppAssignments(token: vppToken)) ?? []
            vppUsers = (try? await client.vppUsers(token: vppToken)) ?? []
        } catch {
            vppError = error.localizedDescription
            vppConfig = nil
        }
    }

    func vppDisconnect() {
        vppConfig = nil
        vppAssets = []
        vppAssignments = []
        vppUsers = []
        vppError = nil
    }

    /// Verify the embedded abctl runs and read its version + (best-effort) identity.
    func check() async {
        connection = .checking
        guard let client = makeClient() else {
            connection = .failed("abctl was not found in the app bundle (Contents/Resources/abctl).")
            return
        }
        do {
            let version = try await client.version()
            let identity = try? await client.whoami() // no creds yet is a normal first run
            connection = .connected(version, identity)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    // MARK: connection settings (credential store) — see SettingsView

    /// Load the saved connection contexts + the current one (for the settings picker/footer).
    func loadContexts() async {
        guard let client = makeClient() else { return }
        if let list = try? await client.contextList() {
            contexts = list.contexts
            currentContext = list.current
        }
    }

    /// A saved context's fields, to pre-fill the settings form. Returns only the client id +
    /// key PATH (abctl never exposes key material), or nil if it can't be read.
    func contextDetail(_ name: String) async -> ContextDetail? {
        guard let client = makeClient() else { return nil }
        return try? await client.contextDetail(name)
    }

    /// Save a connection from the settings form, then verify it end-to-end (mint a token +
    /// hit the API via `whoami`). A pasted `keyPEM` is written to a protected file; otherwise
    /// `keyPath` (an existing .pem on disk) is used as-is. On success the context becomes
    /// current and abgui reconnects. Returns true iff the credentials actually authenticate.
    func saveConnection(name: String, clientID: String, keyPEM: String, keyPath: String, apiBase: String) async -> Bool {
        guard let client = makeClient() else {
            settingsError = "abctl was not found in the app bundle."
            return false
        }
        settingsBusy = true
        settingsError = nil
        defer { settingsBusy = false }

        let ctxName = name.trimmingCharacters(in: .whitespaces)
        let cid = clientID.trimmingCharacters(in: .whitespaces)
        guard !ctxName.isEmpty, !cid.isEmpty else {
            settingsError = "Connection name and Client ID are required."
            return false
        }

        // Resolve the key: a pasted PEM is written to a user-only file; else an on-disk path.
        var resolvedKeyPath = keyPath.trimmingCharacters(in: .whitespaces)
        let pem = keyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pem.isEmpty {
            guard pem.contains("PRIVATE KEY") else {
                settingsError = "That doesn't look like a PEM private key (expected a -----BEGIN … PRIVATE KEY----- block)."
                return false
            }
            do {
                resolvedKeyPath = try CredentialStore.writeKey(pem: pem, context: ctxName).path
            } catch {
                settingsError = "Couldn't save the private key: \(error.localizedDescription)"
                return false
            }
        }
        guard !resolvedKeyPath.isEmpty else {
            settingsError = "Provide the private key — paste the PEM or choose a .pem file."
            return false
        }

        do {
            try await client.saveContext(name: ctxName, clientID: cid, keyPath: resolvedKeyPath,
                                         apiBase: apiBase.trimmingCharacters(in: .whitespaces), makeCurrent: true)
        } catch {
            settingsError = error.localizedDescription
            return false
        }

        // Browse through the new context, then verify the credentials really authenticate.
        context = ctxName
        await loadContexts()
        guard let verify = makeClient() else { return false }
        do {
            _ = try await verify.whoami()
        } catch {
            settingsError = "Saved, but the connection test failed: \(error.localizedDescription)"
            await check()
            return false
        }
        await check()
        return true
    }

    /// Switch the current context (the credential store's active tenant) and reconnect.
    func useConnection(_ name: String) async {
        guard let client = makeClient() else { return }
        try? await client.useContext(name)
        context = name
        await loadContexts()
        await check()
    }

    /// Delete a saved connection. (Does not remove any pasted key file — a no-op for on-disk
    /// keys; a stale keys/<name>.pem is harmless and overwritten on the next save.)
    func deleteConnection(_ name: String) async {
        guard let client = makeClient() else { return }
        try? await client.deleteContext(name)
        if context == name { context = "" }
        await loadContexts()
        await check()
    }

    // MARK: loads (each spawns a fresh abctl; errors surface in loadError)

    func loadConfigurations() async { await run { self.configurations = try await $0.configurations() } }
    func loadBlueprints() async { await run { self.blueprints = try await $0.blueprints() } }

    /// Compute the 3-way plan. `resetLog: false` keeps whatever is already in `progressLog` and
    /// appends this run's transcript underneath it — the seed → diff hand-off, where wiping the
    /// log would throw away the `$ abctl seed` / `→ exit 0` lines the user just watched scroll by
    /// (the seed and the diff it triggers are one operation from the screen's point of view).
    ///
    /// `newRunLog: false` says the same thing about the file on disk: the caller already owns an
    /// open `RunLog` and this diff belongs in it (the seed hand-off) — or the caller's log is
    /// already closed and this refresh must not steal `lastRunLogURL` from it (the post-apply
    /// refresh, where that URL is what the sync's failure UI offers to copy).
    func loadPlan(resetLog: Bool = true, newRunLog: Bool = true) async {
        // Fast pre-flight: diff resolves the tree at <workspace>/gitops. If that's absent, the
        // folder isn't a GitOps workspace yet — surface the "needs seed" state (DiffView offers
        // to initialize it) instead of waiting out a network diff that has nothing to compare.
        if let root = repoRoot, !Self.hasGitopsTree(root) {
            plan = nil
            loadError = nil
            needsSeed = true
            return
        }
        needsSeed = false
        guard let client = makeClient(narrating: .progress) else {
            loadError = "abctl was not found in the app bundle."
            return
        }
        isLoading = true
        loadError = nil
        // Clearing the log MUST stay above the await: both transcript lines are emitted from
        // inside client.plan(...) on later main-actor hops, so this reset can only ever run
        // before them, never wipe them.
        if resetLog { progressLog = [] }
        defer { isLoading = false }
        if newRunLog {
            await beginRunLog(.diff, argv: previewArgv(AbctlClient.planArgs(gitSourceOfTruth: gitSourceOfTruth,
                                                                           refresh: refreshMode)))
        }
        var outcome = "plan computed"
        do {
            plan = try await client.plan(gitSourceOfTruth: gitSourceOfTruth, refresh: refreshMode)
            lastCheckedAt = Date() // stamp every successful check, so a refresh confirms even when in sync
        } catch is CancellationError {
            // user cancelled — clear the in-flight state, no error shown
            outcome = "cancelled"
        } catch {
            if Task.isCancelled {
                outcome = "cancelled" // a race: cancelled just after the process returned
            } else {
                loadError = error.localizedDescription
                outcome = "failed — \(SyncFailure.from(error: error, transcript: progressLog).headline)"
            }
        }
        // Only the call that OPENED a log closes it: the seed hand-off's diff writes into the
        // seed's file and lets `seedWorkspace` stamp the single outcome both phases share.
        if newRunLog { await finishRunLog(outcome) }
    }

    /// Seed the workspace as a cancellable task (so the Cancel button can stop it).
    func startSeed() {
        workTask?.cancel()
        workTask = Task { _ = await seedWorkspace() }
    }

    /// Initialize the chosen workspace's `gitops/` tree from the tenant (`abctl seed` — reads
    /// live, writes local files), then compute drift. This is what turns a plain folder into a
    /// GitOps workspace from inside the app. Returns true on success.
    func seedWorkspace() async -> Bool {
        guard repoRoot != nil, let client = makeClient(narrating: .progress) else {
            loadError = "Choose a workspace folder first."
            return false
        }
        isSeeding = true
        loadError = nil
        progressLog = [] // before the await, so the seed's own transcript survives it (see loadPlan)
        await beginRunLog(.seed, argv: previewArgv(AbctlClient.seedArgs()))
        do {
            _ = try await client.seed()
        } catch is CancellationError {
            isSeeding = false
            await finishRunLog("cancelled")
            return false
        } catch {
            isSeeding = false
            loadError = "Couldn't initialize the workspace from the tenant: \(error.localizedDescription)"
            await finishRunLog("failed — \(SyncFailure.from(error: error, transcript: progressLog).headline)")
            return false
        }
        isSeeding = false
        needsSeed = false
        // tree exists now → drift (a fresh seed should read back in sync). The log is NOT reset:
        // the seed's `$ abctl seed` / `→ exit 0` lines and the diff's belong to one transcript,
        // and clearing here would erase the command the user just ran the instant it finished.
        // The FILE follows the same rule (`newRunLog: false`) — one operation, one log.
        await loadPlan(resetLog: false, newRunLog: false)
        await finishRunLog("workspace initialized")
        return true
    }

    /// True when `root/gitops/` exists and is a directory (the abctl tree root).
    private static func hasGitopsTree(_ root: URL) -> Bool {
        var isDir: ObjCBool = false
        let path = root.appendingPathComponent("gitops", isDirectory: true).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Run `abctl validate --json` against the workspace: the local, credential-free check of
    /// gitops/lib/ plus the blueprint references that point at it, meant to run BEFORE a sync
    /// pushes a broken profile to Apple. Returns true when the report is clean.
    /// Owns its own busy/error state (like the inspect sheets) so verifying never blanks the
    /// diff screen's spinner or overwrites its error.
    @discardableResult
    func validateProfiles() async -> Bool {
        guard repoRoot != nil else {
            validationError = "Choose a GitOps workspace folder first."
            return false
        }
        guard let client = makeClient() else {
            validationError = "abctl was not found in the app bundle."
            return false
        }
        isValidating = true
        validationError = nil
        defer { isValidating = false }
        do {
            let report = try await client.validateProfiles()
            validationReport = report
            lastValidatedAt = Date() // stamped on every completed check, clean or not
            return report.ok
        } catch is CancellationError {
            return false // sheet dismissed / cancelled — the last good report stands
        } catch {
            if Task.isCancelled { return false } // a race: cancelled just after abctl returned
            // A check that failed to complete leaves the verification state UNKNOWN, not
            // "whatever it was last time": keeping the old report would render a green
            // "Verified" row (and hold Apply's one-click path open) on the strength of a run
            // that never produced a verdict. Same rule setWorkspace(_:) follows.
            validationReport = nil
            lastValidatedAt = nil
            validationError = error.localizedDescription
            return false
        }
    }

    /// The currently-loaded rows for a read-only resource.
    func readItems(_ kind: ReadOnlyKind) -> [Resource] {
        switch kind {
        case .devices: return devices
        case .mdmDevices: return mdmDevices
        case .users: return users
        case .userGroups: return userGroups
        case .apps: return apps
        case .packages: return packages
        case .mdmServers: return mdmServers
        case .audit: return auditEvents
        }
    }

    /// Load a read-only resource (a live GET; never writes).
    func loadReadOnly(_ kind: ReadOnlyKind) async {
        await run { client in
            switch kind {
            case .devices: self.devices = try await client.devices()
            case .mdmDevices: self.mdmDevices = try await client.mdmDevices()
            case .users: self.users = try await client.users()
            case .userGroups: self.userGroups = try await client.userGroups()
            case .apps: self.apps = try await client.apps()
            case .packages: self.packages = try await client.packages()
            case .mdmServers: self.mdmServers = try await client.mdmServers()
            case .audit: self.auditEvents = try await client.audit(since: self.auditSince)
            }
        }
    }

    /// Fetch a config's raw profile XML (used by the profile inspector / editor).
    func profile(for id: String) async throws -> String {
        guard let client = makeClient() else { throw AbctlError.cli("abctl not found in the app bundle.") }
        return try await client.configurationProfile(id)
    }

    // MARK: singular inspection fetches — throwing passthroughs to the abctl detail verbs
    // (Views/InspectSheets.swift). Each detail sheet owns its own loading/error state,
    // so these throw instead of toggling the shared isLoading/loadError.

    private func inspectClient() throws -> AbctlClient {
        guard let client = makeClient() else { throw AbctlError.cli("abctl not found in the app bundle.") }
        return client
    }

    /// One org device + its assigned server (+ AppleCare coverage with `appleCare`).
    func deviceDetail(_ serialOrID: String, appleCare: Bool = false) async throws -> DeviceDetail {
        try await inspectClient().deviceDetail(serialOrID, appleCare: appleCare)
    }

    /// One built-in-MDM device + its last-reported posture.
    func mdmDeviceDetail(_ serialOrID: String) async throws -> MDMDeviceDetail {
        try await inspectClient().mdmDeviceDetail(serialOrID)
    }

    /// One user (read-only; identity is not API-writable).
    func userDetail(_ emailOrID: String) async throws -> Resource {
        try await inspectClient().userDetail(emailOrID)
    }

    /// One user group (+ member emails with `members` — one API call per member).
    func userGroupDetail(_ nameOrID: String, members: Bool = false) async throws -> UserGroupDetail {
        try await inspectClient().userGroupDetail(nameOrID, members: members)
    }

    /// One owned app (Apps & Books) — a plain Resource.
    func appDetail(_ nameOrID: String) async throws -> Resource {
        try await inspectClient().appDetail(nameOrID)
    }

    /// One package (custom app/pkg) — a plain Resource.
    func packageDetail(_ nameOrID: String) async throws -> Resource {
        try await inspectClient().packageDetail(nameOrID)
    }

    /// One MDM server (+ its assigned device serials with `devices`).
    func mdmServerDetail(_ nameOrID: String, devices: Bool = false) async throws -> MDMServerDetail {
        try await inspectClient().mdmServerDetail(nameOrID, devices: devices)
    }

    /// One blueprint + the six name-resolved member collections.
    func blueprintDetail(_ nameOrID: String) async throws -> BlueprintDetail {
        try await inspectClient().blueprintDetail(nameOrID)
    }

    /// One device end-to-end (`status device` — fans out per blueprint, the slowest read).
    func deviceStatus(_ serialOrID: String) async throws -> DeviceStatusReport {
        try await inspectClient().deviceStatus(serialOrID)
    }

    // MARK: device assignment — gated writes returning the accepted orgDeviceActivity
    // (Apple processes assignment asynchronously; the id is polled via activityStatus).
    // These throw and leave the shared isWriting/lastWriteError alone: AssignSheet owns
    // its own busy/error state, like the inspect sheets.

    /// Assign org devices to an MDM server (AssignSheet's button is the confirm gate).
    func assignDevices(_ serials: [String], server: String) async throws -> ActivityOutcome {
        try await inspectClient().assignDevices(serials: serials, server: server)
    }

    /// Unassign org devices from an MDM server.
    func unassignDevices(_ serials: [String], server: String) async throws -> ActivityOutcome {
        try await inspectClient().unassignDevices(serials: serials, server: server)
    }

    /// Poll one assign/unassign activity (attributes: status / subStatus / createdDateTime).
    func activityStatus(_ id: String) async throws -> Resource {
        try await inspectClient().activityStatus(id)
    }

    /// Fetch the MDM-server list into the shared cache, THROWING on failure. AssignSheet
    /// owns its own busy/error state (like the inspect sheets), so this leaves the shared
    /// isLoading/loadError to the list screens.
    func refreshMDMServers() async throws {
        mdmServers = try await inspectClient().mdmServers()
    }

    // MARK: writes (v2) — each returns success so a sheet can dismiss; abctl is gated with
    // --yes, so the caller MUST show its own confirm first. Config writes refresh the list.

    func createConfiguration(name: String, xml: String) async -> Bool {
        let ok = await runWrite { _ = try await $0.createConfiguration(name: name, xml: Data(xml.utf8)) }
        if ok { await loadConfigurations() }
        return ok
    }

    func replaceConfiguration(id: String, xml: String) async -> Bool {
        let ok = await runWrite { _ = try await $0.replaceConfiguration(id: id, xml: Data(xml.utf8)) }
        if ok { await loadConfigurations() }
        return ok
    }

    func deleteConfiguration(id: String) async -> Bool {
        let ok = await runWrite { _ = try await $0.deleteConfiguration(id: id) }
        if ok { await loadConfigurations() }
        return ok
    }

    func attach(configID: String, blueprint: String) async -> Bool {
        await runWrite { _ = self.announceTreeGap(try await $0.attach(configID: configID, blueprint: blueprint)) }
    }

    func detach(configID: String, blueprint: String) async -> Bool {
        await runWrite { _ = self.announceTreeGap(try await $0.detach(configID: configID, blueprint: blueprint)) }
    }

    /// Surface a write that reached Apple Business but not gitops/. abctl exits 0 for this (the
    /// tenant write DID succeed), so without this the GUI reports an unqualified success and the
    /// operator only learns about it as a drift row later — the exact shape of the bug where a
    /// GUI attach never reached the manifest. Returns the outcome so it can wrap a call inline.
    @discardableResult
    private func announceTreeGap(_ outcome: WriteOutcome) -> WriteOutcome {
        if let warning = outcome.treeWarning {
            post(Notice(kind: .warning, title: "Written to Apple, not to git", message: warning))
        }
        return outcome
    }

    /// Record a drift row's member in the blueprint's git manifest, so the reconcile stops
    /// proposing to remove it. This is the answer to "this config belongs here — stop telling me
    /// to detach it": it writes `gitops/blueprints/<bp>.yml` and never the tenant, which is why
    /// there is no confirmation gate. The plan is recomputed after, so the row it acted on
    /// disappears (or, if abctl refused, stays put with the reason in `lastWriteError`).
    func adoptMember(_ change: BlueprintChange) async -> Bool {
        guard let kind = change.memberKind, let name = change.config, !name.isEmpty else {
            lastWriteError = "This row doesn't name a blueprint member to adopt."
            return false
        }
        let ok = await runWrite {
            _ = try await $0.adoptMember(kind: kind, name: name, blueprint: change.blueprint)
        }
        if ok {
            post(Notice(kind: .success, title: "Recorded in git",
                        message: "\(name) is now declared on \(change.blueprint) in gitops/blueprints/. "
                               + "Commit gitops/ to keep it — an uncommitted manifest is only true on this machine."))
            refreshPlan()
        }
        return ok
    }

    /// Shared write wrapper: toggles isWriting, clears/sets lastWriteError, returns success.
    private func runWrite(_ body: (AbctlClient) async throws -> Void) async -> Bool {
        guard let client = makeClient() else {
            lastWriteError = "abctl was not found in the app bundle."
            return false
        }
        isWriting = true
        lastWriteError = nil
        defer { isWriting = false }
        do {
            try await body(client)
            return true
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }
    }

    /// Bumped by every `run` so a stale load can't stomp a newer one's shared state
    /// (the dashboard's sequential pass can overlap a destination screen's own .task).
    private var loadGeneration = 0

    /// Shared load wrapper: toggles isLoading, clears/sets loadError, runs `body`.
    /// Cancellation (navigating away terminates the abctl child) is swallowed like
    /// loadPlan's — never shown as an error — and only the LATEST run may write the
    /// shared isLoading/loadError, so an overlapping older run can't clear a live
    /// load's spinner or overwrite its error with a stale one.
    private func run(_ body: (AbctlClient) async throws -> Void) async {
        guard let client = makeClient() else {
            loadError = "abctl was not found in the app bundle."
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil
        do {
            try await body(client)
        } catch is CancellationError {
            // user navigated away / cancelled — clear the in-flight state, no error shown
        } catch {
            if !Task.isCancelled, generation == loadGeneration {
                loadError = error.localizedDescription
            }
        }
        if generation == loadGeneration { isLoading = false }
    }
}

/// The model owns the notice type; the banner that renders it spells it plainly.
typealias Notice = AppModel.Notice
