// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:abgui/src/models/apply_result.dart';
import 'package:abgui/src/models/command_timing.dart';
import 'package:abgui/src/models/contract.dart';
import 'package:abgui/src/models/inspect.dart';
import 'package:abgui/src/models/json.dart';
import 'package:abgui/src/models/os_release.dart';
import 'package:abgui/src/models/plan.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/models/validation.dart';
import 'package:abgui/src/models/vpp.dart';
import 'package:abgui/src/models/write_outcome.dart';

import 'abctl_args.dart';
import 'abctl_error.dart';
import 'process_runner.dart';

/// One `sync --apply` run: the decoded per-item receipt PLUS the raw termination facts.
///
/// The three are inseparable, and that is the whole reason this type exists instead of a bare
/// [ApplyResult]. abctl can print a complete receipt in which EVERY item says `done` and still
/// exit non-zero, because post-apply verification re-read what it wrote and Apple had not
/// persisted it (`internal/cli/phase1.go` → `finishApply`; Apple answers `2xx` to a PATCH it
/// then silently drops). The verdict for that lives only on stderr. Handing a caller the
/// receipt alone would let it report a clean sync for a tenant that does not match git, so the
/// caller gets both halves and `SyncFailure` decides which one is the story.
class ApplyRun {
  const ApplyRun({
    required this.result,
    required this.code,
    required this.stderr,
  });

  /// The per-item receipt abctl printed on stdout. Present even for a failed run — that is
  /// the point of decoding before the exit code is mapped.
  final ApplyResult result;

  /// abctl's exit status. NOT the pass/fail test on its own; see the class comment.
  final int code;

  /// abctl's stderr, verbatim. Carries the verification verdict, which is in no other stream.
  final String stderr;
}

/// The typed facade: one method per abctl verb.
///
/// Everything a view is allowed to know about abctl is here. A method builds its argv with
/// [AbctlArgs] (never inline), runs it through the injected [AbctlRunner] (never `Process`),
/// maps the exit code through [AbctlError.checkExit], and decodes stdout into a `models/` type.
/// Views therefore never see a flag, an exit code or a JSON key.
///
/// **The write verbs reach a live tenant.** `sync --apply`, `create`/`replace`/`delete config`,
/// `attach`/`detach`, `assign`/`unassign` change a real company's Apple Business configuration;
/// `adopt` and `seed` change the workspace's git tree. What makes that safe is not care at the
/// callsites — it is that argv comes from [AbctlArgs] (where `--prune` is derived from
/// [ApplyOptions] and cannot be passed in), that the preview a dialog shows is [previewArgv]'s
/// own output, and that `write_safety_test.dart` pins each of those rules to the incident it
/// came from.
///
/// **Every verb runs in the workspace.** abctl resolves `gitops/` against its process working
/// directory (a context is a connection, not a repo location), so a tree verb run from
/// anywhere else reads — or in the write release, writes — a different tree, or none. The
/// Swift original defaulted the WHOLE surface to the workspace rather than adding a cwd at
/// each tree callsite, precisely so the next verb someone adds cannot forget it; that choice
/// is ported verbatim. The plain reads are unaffected by cwd except that a workspace-local
/// `.env` resolves the same way for them as it already did for `diff`.
class AbctlClient {
  const AbctlClient({required this.runner, this.context, this.workspace});

  /// The seam. In the app this is a [RecordingRunner] wrapping a [ProcessRunner]; in tests it
  /// is a fake, and nothing above this class can tell the difference.
  final AbctlRunner runner;

  /// The connection context, threaded as `--context <ctx>` by [AbctlArgs.contextSuffixed].
  /// Null or empty means "whatever abctl's own current context is" — see that function for
  /// why an empty string must not become an empty flag.
  final String? context;

  /// The GitOps workspace: the directory CONTAINING `gitops/`. Used as cwd for every verb.
  final String? workspace;

  /// The argv a run of [base] will really use — the function a preview must render (through
  /// `CommandFormatter.line`, which quotes and redacts).
  ///
  /// Public and sharing one implementation with [_run] on purpose: a preview built any other
  /// way drifts from the run the moment a flag changes on one side, and a preview that drifts
  /// is worse than none because it teaches a command that never ran.
  List<String> previewArgv(List<String> base) =>
      AbctlArgs.contextSuffixed(base, context);

  // ---------------------------------------------------------------------------------------
  // identity + version
  // ---------------------------------------------------------------------------------------

  Future<VersionInfo> version({CancelToken? cancel}) =>
      _object(AbctlArgs.version(), VersionInfo.fromJson, cancel: cancel);

  Future<WhoamiResult> whoami({CancelToken? cancel}) =>
      _object(AbctlArgs.whoami(), WhoamiResult.fromJson, cancel: cancel);

  // ---------------------------------------------------------------------------------------
  // plural reads
  // ---------------------------------------------------------------------------------------

  Future<List<Resource>> configurations({CancelToken? cancel}) =>
      _resources(AbctlArgs.configurations(), cancel: cancel);

  Future<List<Resource>> blueprints({CancelToken? cancel}) =>
      _resources(AbctlArgs.blueprints(), cancel: cancel);

  Future<List<Resource>> devices({CancelToken? cancel}) =>
      _resources(AbctlArgs.devices(), cancel: cancel);

  Future<List<Resource>> mdmDevices({CancelToken? cancel}) =>
      _resources(AbctlArgs.mdmDevices(), cancel: cancel);

  Future<List<Resource>> users({CancelToken? cancel}) =>
      _resources(AbctlArgs.users(), cancel: cancel);

  Future<List<Resource>> userGroups({CancelToken? cancel}) =>
      _resources(AbctlArgs.userGroups(), cancel: cancel);

  Future<List<Resource>> apps({CancelToken? cancel}) =>
      _resources(AbctlArgs.apps(), cancel: cancel);

  Future<List<Resource>> packages({CancelToken? cancel}) =>
      _resources(AbctlArgs.packages(), cancel: cancel);

  Future<List<Resource>> mdmServers({CancelToken? cancel}) =>
      _resources(AbctlArgs.mdmServers(), cancel: cancel);

  /// The audit trail since [since] (abctl's window spelling: `7d`, `24h`, an ISO date).
  Future<List<Resource>> audit({required String since, CancelToken? cancel}) =>
      _resources(AbctlArgs.audit(since: since), cancel: cancel);

  /// Apple's published OS releases (GDMF). Not a tenant read — it needs no credentials.
  Future<List<OSRelease>> osReleases({CancelToken? cancel}) async {
    final base = AbctlArgs.osReleases();
    final decoded = await _payload(base, cancel: cancel);
    if (decoded is! List) throw _notA('a list', base, decoded);
    return OSRelease.listFromJson(decoded);
  }

  // ---------------------------------------------------------------------------------------
  // singular detail reads
  // ---------------------------------------------------------------------------------------

  /// One org device + its assigned MDM server. [appleCare] adds coverage records at the cost
  /// of one more Apple call, so it stays behind an explicit affordance.
  Future<DeviceDetail> deviceDetail(
    String serialOrId, {
    bool appleCare = false,
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.deviceDetail(serialOrId, appleCare: appleCare),
    DeviceDetail.fromJson,
    cancel: cancel,
  );

  Future<MDMDeviceDetail> mdmDeviceDetail(
    String serialOrId, {
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.mdmDeviceDetail(serialOrId),
    MDMDeviceDetail.fromJson,
    cancel: cancel,
  );

  /// One user — a plain [Resource]; identity is not API-writable, so there is nothing to wrap.
  Future<Resource> userDetail(String emailOrId, {CancelToken? cancel}) =>
      _object(
        AbctlArgs.userDetail(emailOrId),
        Resource.fromJson,
        cancel: cancel,
      );

  /// One user group. [members] resolves member emails with one API call PER MEMBER, so it
  /// spends the fan-out budget; without it the group is a single read.
  Future<UserGroupDetail> userGroupDetail(
    String nameOrId, {
    bool members = false,
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.userGroupDetail(nameOrId, members: members),
    UserGroupDetail.fromJson,
    timeout: members ? AbctlTimeouts.fanOut : AbctlTimeouts.read,
    cancel: cancel,
  );

  Future<Resource> appDetail(String nameOrId, {CancelToken? cancel}) =>
      _object(AbctlArgs.appDetail(nameOrId), Resource.fromJson, cancel: cancel);

  Future<Resource> packageDetail(String nameOrId, {CancelToken? cancel}) =>
      _object(
        AbctlArgs.packageDetail(nameOrId),
        Resource.fromJson,
        cancel: cancel,
      );

  /// One MDM server. [devices] walks the whole org device inventory on the abctl side to
  /// resolve serials — the same fan-out shape as `--members`, and the same budget.
  Future<MDMServerDetail> mdmServerDetail(
    String nameOrId, {
    bool devices = false,
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.mdmServerDetail(nameOrId, devices: devices),
    MDMServerDetail.fromJson,
    timeout: devices ? AbctlTimeouts.fanOut : AbctlTimeouts.read,
    cancel: cancel,
  );

  Future<BlueprintDetail> blueprintDetail(
    String nameOrId, {
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.blueprintDetail(nameOrId),
    BlueprintDetail.fromJson,
    cancel: cancel,
  );

  /// The raw `.mobileconfig` XML for one configuration.
  ///
  /// The only read whose stdout is not JSON, so it maps the exit code and hands the text back
  /// verbatim — re-encoding a profile abgui only ever displays would be a chance to change it.
  Future<String> configurationProfile(String id, {CancelToken? cancel}) async {
    final result = await _run(
      AbctlArgs.configurationProfile(id),
      timeout: AbctlTimeouts.read,
      cancel: cancel,
    );
    result.checkExit();
    return result.stdoutText;
  }

  // ---------------------------------------------------------------------------------------
  // status reads
  // ---------------------------------------------------------------------------------------

  /// One device end to end. Fans out a relationship call per blueprint plus the built-in-MDM
  /// inventory list, hence the doubled budget.
  Future<DeviceStatusReport> deviceStatus(
    String serialOrId, {
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.deviceStatus(serialOrId),
    DeviceStatusReport.fromJson,
    timeout: AbctlTimeouts.fanOut,
    cancel: cancel,
  );

  /// Poll one assign/unassign activity. A plain [Resource] whose attributes carry
  /// `status` / `subStatus` / `createdDateTime`.
  Future<Resource> activityStatus(String id, {CancelToken? cancel}) =>
      _object(AbctlArgs.activityStatus(id), Resource.fromJson, cancel: cancel);

  // ---------------------------------------------------------------------------------------
  // the workspace verbs
  // ---------------------------------------------------------------------------------------

  /// The 3-way plan. `diff --json` prints it and exits 0 — drift is a non-empty plan, not an
  /// exit code, and this release never passes `--exit-on-diff`.
  ///
  /// If abctl nevertheless exits 3 the mapping stands and the caller receives
  /// [AbctlChangesPending], which is a NORMAL outcome to render as drift — never a failure
  /// banner. That case gets no decode-before-map treatment (unlike [validateProfiles]) because
  /// nothing in abctl's contract says a code-3 `diff` printed a plan first; inventing that
  /// would mean rendering a document abgui guessed at.
  ///
  /// Longer budget than a plain read: it fetches across the whole tenant and may mint a token.
  Future<Plan> plan({
    bool gitSourceOfTruth = false,
    AbctlRefresh refresh = AbctlRefresh.smart,
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.plan(gitSourceOfTruth: gitSourceOfTruth, refresh: refresh),
    Plan.fromJson,
    timeout: AbctlTimeouts.plan,
    cancel: cancel,
  );

  /// Validate the workspace's `gitops/` profiles + blueprint references. Local files only, so
  /// it is the one verb that works before a connection exists.
  ///
  /// **The payload is decoded BEFORE the exit code is mapped, and that order is the whole
  /// point.** `validate` exits 1 whenever the report says `ok:false` and STILL prints the
  /// complete report on stdout. Running it through the shared mapping — which checks the exit
  /// code first — would throw the structured report away and raise [AbctlCliError] carrying
  /// whatever narration happened to be on stderr: a failed verification presented as "abctl
  /// reported an error" instead of as the list of files to fix. A failing report is DATA to
  /// render; only a run that produced NO report at all (a bad flag, an unreadable tree, an
  /// abctl too old to know `--json`) falls through to the exit-code mapping, where abctl's own
  /// stderr is the better message.
  ///
  /// Every other verb keeps the ordinary mapping, so [_object] stays untouched. [syncApply] is
  /// the other verb that needs this one — same abctl behaviour, and a far more expensive
  /// mistake, since what gets thrown away there is the receipt for a partly-applied tenant.
  Future<ValidationReport> validateProfiles({CancelToken? cancel}) async {
    final base = AbctlArgs.validate();
    final result = await _run(
      base,
      timeout: AbctlTimeouts.validate,
      cancel: cancel,
    );
    final decoded = _tryParse(result.stdoutText);
    if (decoded is Map) return ValidationReport.fromJson(asJsonMap(decoded));
    result.checkExit();
    // Exit 0 with undecodable stdout: the run "succeeded" and printed something that is not a
    // report, which is a contract break worth naming rather than an empty screen.
    throw _notA('a report', base, decoded);
  }

  // =======================================================================================
  // WRITES
  // =======================================================================================
  //
  // Every method here runs in the workspace, because [_run] gives the WHOLE surface the
  // workspace cwd — not because each of these remembered to ask for it. That choice is ported
  // from the Swift client deliberately: abctl roots `gitops/` at its process working
  // directory, and a tree-mutating verb run from the app bundle's cwd wrote its manifest into
  // a different tree while `diff` read the real one. The symptom was a `detach-config` row
  // that came back on every refresh with nothing in the GUI able to clear it, and it was
  // silent and per-verb — so the defense is a default the next verb cannot forget.

  /// Reconcile the tenant to the workspace's git desired state.
  ///
  /// **stdout is decoded BEFORE the exit code is mapped, and that order is the whole point.**
  /// `sync --apply --json` prints the COMPLETE receipt — with a per-item `status:"error"` and a
  /// detail naming each failure — and only THEN returns `ExitError{1}`
  /// (`internal/cli/phase1.go`), for which `cmd/abctl/main.go` exits SILENTLY. Running that
  /// through the ordinary mapping, which checks the exit code first, threw the structured truth
  /// away and raised [AbctlCliError] carrying whatever was on stderr: a hundred lines of
  /// "building plan: …" narration presented to the operator as "the error", with the per-item
  /// outcomes of a PARTIALLY APPLIED tenant write discarded. A partly-failed apply is DATA to
  /// render. Only a run that produced no receipt at all — bad credentials, no `gitops/` tree,
  /// an Apple 403 while planning — falls through to the exit-code mapping, where abctl's own
  /// stderr is the better message.
  ///
  /// The exit code and stderr come back beside the receipt rather than being consumed here;
  /// see [ApplyRun] for why a clean receipt is not by itself a clean sync.
  ///
  /// [options] is the only way `--prune` can be on — see [ApplyOptions].
  Future<ApplyRun> syncApply(
    ApplyOptions options, {
    CancelToken? cancel,
  }) async {
    final base = AbctlArgs.syncApply(options);
    final result = await _run(
      base,
      timeout: AbctlTimeouts.apply,
      cancel: cancel,
    );
    final decoded = _tryParse(result.stdoutText);
    // A Map is not enough. `ApplyResult.fromJson` defaults BOTH phases to empty when their keys
    // are missing — deliberately, so half a receipt still renders — and that tolerance, applied
    // to a document that is not a receipt at all, manufactured a clean verdict out of nothing:
    // exit 0 plus `{"error":"unsupported --json schema","version":"9"}` decoded to zero writes,
    // zero errors, no failure, and the banner read "Applied 0 change(s)" while the Diff rows kept
    // claiming to describe the current tenant. A version skew that changes the receipt's SHAPE
    // while keeping it JSON is exactly the case `AbctlDecodeError`'s wording is written for, and
    // it was the one case that could not reach it.
    //
    // `finishApply` (internal/cli/phase1.go) builds `{"configs": …, "blueprints": …}` and adds
    // `verification` when it has one; both of the first two are unconditional on every `--json`
    // exit path, including the one that renders a receipt and THEN returns a non-zero cause. So
    // requiring either of them is a structural test of "is this a receipt", not a guess about
    // content — and a document that fails it degrades to `ApplyVerdict.unknown`, which is the
    // honest answer after a run whose output we cannot read.
    if (decoded is Map &&
        (decoded['configs'] != null || decoded['blueprints'] != null)) {
      return ApplyRun(
        result: ApplyResult.fromJson(asJsonMap(decoded)),
        code: result.code,
        stderr: result.stderr,
      );
    }
    // Non-zero first, so a failed run still reports abctl's own stderr rather than abgui's
    // complaint about the shape of what it printed.
    result.checkExit();
    // Exit 0 with stdout that is not a receipt — undecodable, or decodable and the wrong
    // document. abctl "succeeded" and said nothing we can read about a tenant write, which is a
    // contract break worth naming loudly.
    throw _notA('a result document', base, decoded);
  }

  /// Initialize (or refresh) the workspace's `gitops/` tree from live tenant state.
  ///
  /// Reads the tenant and writes LOCAL files, so there is no tenant change to gate. Its output
  /// is human text rather than JSON, which is why it is the one verb here that hands back a
  /// string instead of a decoded document.
  Future<String> seed({CancelToken? cancel}) async {
    final result = await _run(
      AbctlArgs.seed(),
      timeout: AbctlTimeouts.seed,
      cancel: cancel,
    );
    result.checkExit();
    return result.stdoutText;
  }

  /// Create a CUSTOM_SETTING configuration from profile XML (POST), the XML fed on stdin.
  ///
  /// [xml] is bytes, not a `String`: a `.mobileconfig` is a signed-or-not XML document abgui
  /// only relays, and decoding then re-encoding it is an opportunity to change what Apple
  /// stores. `ProcessRunner` reports a partial stdin write as a failure for the same reason —
  /// a truncated profile sent as a `create` is worse than no create at all.
  Future<WriteOutcome> createConfiguration({
    required String name,
    required List<int> xml,
    CancelToken? cancel,
  }) => _writeOutcome(
    AbctlArgs.createConfiguration(name),
    stdin: xml,
    timeout: AbctlTimeouts.write,
    cancel: cancel,
  );

  /// Replace a configuration's profile: archive the live copy, then PATCH. The GUI's "edit".
  Future<WriteOutcome> replaceConfiguration({
    required String id,
    required List<int> xml,
    CancelToken? cancel,
  }) => _writeOutcome(
    AbctlArgs.replaceConfiguration(id),
    stdin: xml,
    timeout: AbctlTimeouts.write,
    cancel: cancel,
  );

  /// Delete a configuration: archive the live copy, then DELETE.
  Future<WriteOutcome> deleteConfiguration(String id, {CancelToken? cancel}) =>
      _writeOutcome(
        AbctlArgs.deleteConfiguration(id),
        timeout: AbctlTimeouts.write,
        cancel: cancel,
      );

  /// Attach a configuration to a blueprint (additive membership).
  ///
  /// Membership budget, not the read budget: this is multi-call on the abctl side (resolve the
  /// blueprint, list configurations for the name↔id map, read current members, then write).
  Future<WriteOutcome> attachConfiguration({
    required String configId,
    required String blueprint,
    CancelToken? cancel,
  }) => _writeOutcome(
    AbctlArgs.attachConfiguration(configId: configId, blueprint: blueprint),
    timeout: AbctlTimeouts.membership,
    cancel: cancel,
  );

  /// Detach a configuration from a blueprint.
  Future<WriteOutcome> detachConfiguration({
    required String configId,
    required String blueprint,
    CancelToken? cancel,
  }) => _writeOutcome(
    AbctlArgs.detachConfiguration(configId: configId, blueprint: blueprint),
    timeout: AbctlTimeouts.membership,
    cancel: cancel,
  );

  /// Record an already-attached member in the blueprint's git manifest — local files only.
  ///
  /// This is the answer to "this config belongs here, stop telling me to detach it". It is
  /// ungated ([AbctlArgs.adoptMember] carries no `--yes`) and still gets the membership budget:
  /// on the plain 60s read budget it died mid-flight against a real tenant and left the
  /// manifest unwritten, with "abctl ran for 60s" as the only symptom — a timeout that reads
  /// exactly like a broken feature.
  Future<WriteOutcome> adoptMember({
    required AbctlMemberKind kind,
    required String name,
    required String blueprint,
    CancelToken? cancel,
  }) => _writeOutcome(
    AbctlArgs.adoptMember(kind: kind, name: name, blueprint: blueprint),
    timeout: AbctlTimeouts.membership,
    cancel: cancel,
  );

  /// Assign or unassign org devices on an MDM server.
  ///
  /// Apple processes this asynchronously, so a `done` here means ACCEPTED, not applied — the
  /// outcome carries the activity id, and [activityStatus] is what says whether Apple finished.
  Future<ActivityOutcome> assignDevices({
    required AbctlAssignment action,
    required String server,
    required List<String> serials,
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.assignment(action: action, server: server, serials: serials),
    ActivityOutcome.fromJson,
    // The write budget, not the read one, and this is the verb the budget matters most for.
    // `assignment` resolves the MDM server, then walks the WHOLE org device inventory to turn
    // serials into ids (the same walk `AbctlTimeouts.fanOut` exists for), and only then POSTs the
    // activity. On 60s, a large tenant loses the race after the POST has gone out — and unlike
    // every other verb here, abgui cannot tell afterwards whether Apple got it. The dialog now
    // says "unknown" in that case instead of "nothing was submitted"; this is what makes the case
    // rare rather than routine.
    timeout: AbctlTimeouts.write,
    cancel: cancel,
  );

  // ---------------------------------------------------------------------------------------
  // the console — argv an operator typed
  // ---------------------------------------------------------------------------------------

  /// Run [argv] as typed, with the connection and the workspace already applied, and hand back
  /// the raw result.
  ///
  /// **The one method here that does not call `checkExit`, and that is the point.** Every other
  /// verb maps its exit code because a caller wants a decoded document or a typed failure; the
  /// console wants what abctl actually said. Mapping exit 1 to [AbctlCliError] would replace
  /// abctl's own stderr — already written for a human — with abgui's paraphrase, and would turn
  /// `diff --exit-on-diff`'s perfectly normal exit 3 into a red banner. Non-zero is DATA here.
  ///
  /// It stays a client method rather than the console store reaching for the runner directly, so
  /// a typed command goes through [previewArgv] (the ONE place `--context` is spelled) and the
  /// workspace cwd. That mismatch — a hand-built command resolving `gitops/` against a different
  /// directory — is the exact bug this whole layer exists to prevent.
  ///
  /// [AbctlTimeouts.console] is generous because the operator chose the command; it is still a
  /// guardrail, so a wedged child cannot hold the console's "running" flag forever.
  ///
  /// This method does NOT decide what may be run. The read-only boundary is enforced by
  /// `ConsoleGuard` before anything reaches here — see `state/console_store.dart`.
  Future<AbctlResult> console(List<String> argv, {CancelToken? cancel}) =>
      _run(argv, timeout: AbctlTimeouts.console, cancel: cancel);

  // ---------------------------------------------------------------------------------------
  // Apps & Books (VPP)
  // ---------------------------------------------------------------------------------------
  //
  // A separate service from the Business API with its own credential: the content token is
  // passed as `--vpp-token`, NOT via the connection context. It is redacted everywhere a
  // command is displayed or recorded (`CommandFormatter.redactedFlags`).

  Future<VPPServiceConfig> vppConfig({
    required String token,
    CancelToken? cancel,
  }) => _object(
    AbctlArgs.vppConfig(token: token),
    VPPServiceConfig.fromJson,
    cancel: cancel,
  );

  Future<List<VPPAsset>> vppAssets({
    required String token,
    CancelToken? cancel,
  }) => _array(
    AbctlArgs.vppAssets(token: token),
    VPPAsset.fromJson,
    cancel: cancel,
  );

  Future<List<VPPAssignment>> vppAssignments({
    required String token,
    CancelToken? cancel,
  }) => _array(
    AbctlArgs.vppAssignments(token: token),
    VPPAssignment.fromJson,
    cancel: cancel,
  );

  Future<List<VPPUser>> vppUsers({
    required String token,
    CancelToken? cancel,
  }) => _array(
    AbctlArgs.vppUsers(token: token),
    VPPUser.fromJson,
    cancel: cancel,
  );

  // ---------------------------------------------------------------------------------------
  // the context store
  // ---------------------------------------------------------------------------------------
  //
  // Read-only here, and run through [_runControl]: no `--context` (these MANAGE the store
  // rather than being scoped by it — [AbctlArgs.contextSuffixed] refuses it structurally as
  // well), no workspace cwd (the store is `~/.abctl/contexts.yaml`, not a tree), and a short
  // budget because nothing here touches the network.

  Future<ContextList> contextList({CancelToken? cancel}) async {
    final base = AbctlArgs.contextList();
    return ContextList.fromJson(await _controlObject(base, cancel: cancel));
  }

  /// One context's stored fields. A null/empty [name] asks for the current one.
  Future<ContextDetail> contextDetail({
    String? name,
    CancelToken? cancel,
  }) async {
    final base = AbctlArgs.contextDetail(name);
    return ContextDetail.fromJson(await _controlObject(base, cancel: cancel));
  }

  // ---------------------------------------------------------------------------------------
  // plumbing
  // ---------------------------------------------------------------------------------------

  /// Run [base] with the context tail appended, in the workspace, on [timeout].
  ///
  /// The cwd is applied HERE rather than at the tree-mutating callsites, so the next verb
  /// someone adds cannot forget it — see the WRITES banner above for the bug that rule is made
  /// of. [stdin] is the profile XML for the `-f -` verbs.
  Future<AbctlResult> _run(
    List<String> base, {
    required Duration timeout,
    List<int>? stdin,
    CancelToken? cancel,
  }) => runner.run(
    previewArgv(base),
    cwd: workspace,
    stdin: stdin,
    timeout: timeout,
    cancel: cancel,
  );

  /// A gated write: run it, map the exit code, decode the outcome document.
  ///
  /// Exit code FIRST here, unlike [syncApply] and [validateProfiles], and the difference is
  /// abctl's contract rather than a preference: those two print a complete report and then
  /// exit non-zero to state a verdict about it, while a failed `create`/`attach`/`delete`
  /// prints no outcome document at all — its stderr is the only account of what happened, and
  /// decoding first would replace it with "did not print an object".
  ///
  /// The decoded [WriteOutcome] is RETURNED rather than reduced to a bool, because a tenant
  /// write can succeed while its git half fails (`treeUpdated:false`), and a caller that only
  /// learns "it worked" has no way to say so. See [WriteOutcome.treeWarning].
  ///
  /// [timeout] is REQUIRED rather than defaulted. Every verb that reaches here writes to a live
  /// tenant, and the read budget is the wrong answer for all of them — a defaulted parameter is
  /// how `create`/`replace`/`delete` came to run on 60s in the first place (see
  /// [AbctlTimeouts.write]). A future write verb now has to state its budget out loud.
  Future<WriteOutcome> _writeOutcome(
    List<String> base, {
    required Duration timeout,
    List<int>? stdin,
    CancelToken? cancel,
  }) async {
    final result = await _run(
      base,
      timeout: timeout,
      stdin: stdin,
      cancel: cancel,
    );
    result.checkExit();
    final decoded = _parse(base, result.stdoutText);
    if (decoded is! Map) throw _notA('an outcome', base, decoded);
    return WriteOutcome.fromJson(asJsonMap(decoded));
  }

  /// Run, map the exit code, parse stdout as JSON. The path every ordinary read takes.
  Future<Object?> _payload(
    List<String> base, {
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    final result = await _run(base, timeout: timeout, cancel: cancel);
    result.checkExit();
    return _parse(base, result.stdoutText);
  }

  Future<T> _object<T>(
    List<String> base,
    T Function(Map<String, dynamic> json) fromJson, {
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    final decoded = await _payload(base, timeout: timeout, cancel: cancel);
    // The models decode defensively — an absent key is a default, never a throw — so this
    // shape check is the only thing standing between "abctl printed a list where a document
    // belongs" and a detail sheet full of blanks with no explanation anywhere.
    if (decoded is! Map) throw _notA('an object', base, decoded);
    return fromJson(asJsonMap(decoded));
  }

  Future<List<T>> _array<T>(
    List<String> base,
    T Function(Map<String, dynamic> json) fromJson, {
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    final decoded = await _payload(base, timeout: timeout, cancel: cancel);
    if (decoded is! List) throw _notA('a list', base, decoded);
    return decoded
        .whereType<Map>()
        .map((e) => fromJson(asJsonMap(e)))
        .toList(growable: false);
  }

  /// The plural `get …` shape. Goes through [Resource.listFromJson] rather than re-spelling
  /// the element mapping, with the top-level shape checked first: the model helper is
  /// deliberately lenient (it answers `[]` for anything that is not a list, because a
  /// malformed member must not empty a table), and that leniency is right INSIDE a document
  /// and wrong for the document itself, where "abctl printed something else entirely" is a
  /// diagnosis the user needs.
  Future<List<Resource>> _resources(
    List<String> base, {
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    final decoded = await _payload(base, timeout: timeout, cancel: cancel);
    if (decoded is! List) throw _notA('a list', base, decoded);
    return Resource.listFromJson(decoded);
  }

  /// A context-store read: raw argv (no context tail — [AbctlArgs.contextSuffixed] refuses it
  /// anyway), no workspace, and the control budget.
  Future<Map<String, dynamic>> _controlObject(
    List<String> base, {
    CancelToken? cancel,
  }) async {
    final result = await runner.run(
      base,
      timeout: AbctlTimeouts.control,
      cancel: cancel,
    );
    result.checkExit();
    final decoded = _parse(base, result.stdoutText);
    if (decoded is! Map) throw _notA('an object', base, decoded);
    return asJsonMap(decoded);
  }

  /// Parse stdout, naming the VERB in the failure.
  ///
  /// `FormatException.message` is "Unexpected character" and an offset — true, and useless in
  /// a bug report on its own. Which command produced it is the half that makes the report
  /// actionable ("`abctl get configurations` printed no JSON" says version skew or a stray
  /// banner on stdout), and it is the half the decoder cannot know. [CommandTiming.verbKey] is
  /// reused for the name so the error, the Command Log and the timing panel all call a verb
  /// the same thing.
  static Object? _parse(List<String> base, String stdout) {
    try {
      return jsonDecode(stdout);
    } on FormatException catch (error) {
      throw AbctlDecodeError(
        '`abctl ${CommandTiming.verbKey(base)}` did not print JSON '
        '(${error.message})',
      );
    }
  }

  /// [_parse] without the throw — for [validateProfiles], where "stdout is not a report" is a
  /// route to the exit-code mapping rather than an error in itself.
  static Object? _tryParse(String stdout) {
    try {
      return jsonDecode(stdout);
    } on FormatException {
      return null;
    }
  }

  static AbctlDecodeError _notA(
    String expected,
    List<String> base,
    Object? decoded,
  ) => AbctlDecodeError(
    '`abctl ${CommandTiming.verbKey(base)}` did not print $expected '
    '(got ${decoded.runtimeType})',
  );
}
