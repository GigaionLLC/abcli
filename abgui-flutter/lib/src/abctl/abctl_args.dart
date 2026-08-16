// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure argv construction for every abctl verb this release runs.
///
/// This file imports NOTHING — not even the models or the runner. That is the point: argv is
/// the whole safety surface of a CLI wrapper, and it is the one thing worth being able to test
/// with no process, no filesystem and no fakes. A wrong flag here reaches a live Apple Business
/// tenant; a wrong flag in a view reaches it too, but only if a view is allowed to spell one.
///
/// Three invariants are STRUCTURAL here rather than conventional, each because the convention
/// already failed once in the Swift original:
///
///  1. **`--context` is appended in exactly one place** ([contextSuffixed]) and NEVER for the
///     `context …` verbs, which MANAGE the credential store rather than being scoped by it
///     (`abctl context list --context prod` asks the store to list itself as seen through one
///     of its own entries — nonsense abctl rejects). The refusal is data-driven off
///     [contextFreeVerbs] instead of "remember not to call this for context verbs", so a future
///     caller cannot get it wrong by being careless.
///  2. **Every builder is context-FREE.** The preview a sheet shows and the argv a run sends
///     both come from a builder plus one call to [contextSuffixed]; a builder that appended the
///     flag itself would double it on the run path or hide it on the preview path. Swift
///     learned this as `AbctlClient.contextSuffixed` after the preview and the run had already
///     been spelled twice.
///  3. **The destructive flags are not parameters.** `--prune` is never a boolean a caller
///     hands down; it is DERIVED, inside [AbctlArgs.syncApply], from an [ApplyOptions] value
///     whose constructors are named for their consequences. A checkbox cannot be wired to it
///     because there is no prune-shaped argument to wire — which is the fix for the Swift
///     app's arrangement, where the "git-as-truth implies prune" rule was written out in
///     `AppModel.apply` AND again in ApplySheet's preview expression, either copy free to
///     change alone while the preview quietly stopped describing the run.
///  4. **Every gated write carries `--yes`, and `adopt` carries none.** abctl prompts without
///     it and the child then hangs until abgui's watchdog kills it — which the UI reports as
///     a timeout, indistinguishable from a blocked network. `adopt` writes local files only,
///     so there is nothing to gate and the flag would be a lie about what the command does.
///     Both halves are pinned per verb in `write_safety_test.dart`.
///
/// The builders return UNMODIFIABLE lists. A caller that tries to append a flag to one gets an
/// exception instead of a command nobody previewed.
///
/// Note the two spellings of "give me JSON": the plural `get <collection>` verbs take
/// `-o json` (they share the table/CSV output selector with the human-facing renderers) while
/// the singular detail verbs take `--json` (a boolean switch on a command that has no table
/// form). That inconsistency is abctl's contract, not a mistake to normalize here — the
/// contract test pins both.
library;

/// How much live state `diff` re-reads before it plans.
///
/// An enum rather than the Swift original's bare `String` because this value reaches abctl as a
/// flag argument: a typo in a string threaded down from a view becomes a Cobra usage error
/// (exit 2), which maps to [AbctlUsageError] and reads to a user as "abgui is broken" — for a
/// dropdown that offered three choices in the first place.
enum AbctlRefresh {
  /// Re-read what the plan needs. abctl's own default and abgui's.
  smart('smart'),

  /// Re-read everything, including per-profile payloads. Slow on a large tenant.
  full('full'),

  /// Names and ids only — the cheapest plan abctl can build.
  metadataOnly('metadata-only');

  const AbctlRefresh(this.wire);

  /// The token abctl expects after `--refresh`.
  final String wire;
}

/// How much of what a `sync --apply` just wrote is read back before the run is called clean
/// (`internal/cli/phase1.go`, `verifyApply`).
///
/// This exists because Apple answers `2xx` to a PATCH it then silently drops, so "abctl said
/// done" and "the tenant matches git" are different claims. An enum for the same reason
/// [AbctlRefresh] is one: abctl rejects an unknown mode with a Cobra usage error (exit 2),
/// which reaches a user as "abgui is broken".
enum AbctlVerify {
  /// Re-read only what this run wrote. abctl's default and abgui's.
  targeted('targeted'),

  /// Re-read the whole tenant and compare it against git.
  full('full'),

  /// Skip the read-back entirely — no reads, and no verdict. NOT the same as a clean
  /// verdict, which is why `Verification` distinguishes "checked and matched" from
  /// "never checked" rather than defaulting to success.
  none('none');

  const AbctlVerify(this.wire);

  /// The token abctl expects after `--verify`.
  final String wire;
}

/// The member collections `abctl adopt` addresses — its FIRST argument
/// (`internal/cli/deploy.go`: `adopt <config|app|package|device|user|group> …`).
///
/// A closed set rather than the Swift original's bare `String`, because the value that
/// reaches it comes from a plan row's `action` (`adopt-user` → `user`, via
/// `BlueprintChange.memberKind`) — i.e. from a wire document abgui does not control. An
/// unrecognized noun must fail HERE, where the caller can say "this row names no member abgui
/// can adopt", rather than as a usage error from a command that already ran.
enum AbctlMemberKind {
  config('config'),
  app('app'),
  package('package'),
  device('device'),
  user('user'),
  group('group');

  const AbctlMemberKind(this.wire);

  /// The noun abctl expects.
  final String wire;

  /// The kind [wire] names, or null when this build does not know it. Null is a real answer,
  /// not a failure to report: a newer abctl may manage a seventh collection, and the caller's
  /// job is then to refuse the row rather than to guess a noun.
  static AbctlMemberKind? fromWire(String wire) {
    for (final kind in values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// What a member attached in Apple Business but absent from the git manifest MEANS for a run
/// (`internal/reconcile/blueprint.go`, `MembershipMode`).
///
/// One flag, one meaning on both halves of the reconcile: `--git-source-of-truth` makes git
/// the complete desired state for configs AND for blueprint membership. Without that mapping
/// the switch governed configs only, and a config attached through Apple's console re-proposed
/// the same detach on every run with no in-product way to say "this belongs in git".
enum AbctlMembershipMode {
  /// The default. Sync is additive: an ABM-only member is ADOPTED into the manifest.
  bidirectional,

  /// `--git-source-of-truth`. The manifest is the complete desired state, so an ABM-only
  /// member is DETACHED — gated behind `--prune`, which is why [ApplyOptions.gitAuthoritative]
  /// cannot be built without it.
  gitAuthoritative,
}

/// Everything a `sync --apply` needs, as ONE value — and the only thing that can put `--prune`
/// on a command line.
///
/// **Why this is a type and not five parameters.** `--prune` is the flag that lets a reconcile
/// DELETE a configuration and DETACH a member from a live tenant. Passed as a `bool` it is one
/// mis-wired checkbox, one inverted condition or one argument transposed at a callsite away
/// from being on when nobody asked; and because the rule "git-as-truth implies prune" has to
/// live somewhere, a bool also guarantees at least two places that spell it (the Swift app had
/// exactly two, and they were free to disagree).
///
/// So there is no `prune` parameter anywhere in this file. The three constructors below are
/// the complete set of reachable option states, each NAMED for what it permits:
///
///  * [ApplyOptions.additive] — nothing is deleted or detached. The safe default.
///  * [ApplyOptions.additiveAllowingDeletes] — the operator explicitly allowed removals while
///    git is still only one of two inputs.
///  * [ApplyOptions.gitAuthoritative] — git is the complete desired state, so removals are
///    IMPLIED and [prune] is true with no way to ask otherwise. Applying git-as-truth without
///    prune would half-apply a desired state, which is not a mode worth being able to spell.
///
/// The fourth combination (git-as-truth, no prune) is therefore not representable, and
/// [prune] is a derived getter with no setter: reading it to warn an operator is encouraged,
/// and there is nothing to write.
final class ApplyOptions {
  const ApplyOptions._({
    required this.membershipMode,
    required this.prune,
    required this.refresh,
    required this.verify,
    required this.limitWrites,
  });

  /// Additive reconcile: git and the tenant are both inputs, and nothing is removed. An
  /// ABM-only config is pulled into git and an ABM-only member is adopted into its manifest.
  const ApplyOptions.additive({
    AbctlRefresh refresh = AbctlRefresh.smart,
    AbctlVerify verify = AbctlVerify.targeted,
    int? limitWrites,
  }) : this._(
         membershipMode: AbctlMembershipMode.bidirectional,
         prune: false,
         refresh: refresh,
         verify: verify,
         limitWrites: limitWrites,
       );

  /// Additive, but removals are permitted — the raw "allow deletes/detaches" choice, spelled
  /// out. The name is the confirmation: a caller cannot reach this state without writing the
  /// word `Deletes`.
  const ApplyOptions.additiveAllowingDeletes({
    AbctlRefresh refresh = AbctlRefresh.smart,
    AbctlVerify verify = AbctlVerify.targeted,
    int? limitWrites,
  }) : this._(
         membershipMode: AbctlMembershipMode.bidirectional,
         prune: true,
         refresh: refresh,
         verify: verify,
         limitWrites: limitWrites,
       );

  /// git is the complete desired state (`--git-source-of-truth`): anything in the tenant that
  /// git does not declare is removed. [prune] is true and is not a parameter here.
  const ApplyOptions.gitAuthoritative({
    AbctlRefresh refresh = AbctlRefresh.smart,
    AbctlVerify verify = AbctlVerify.targeted,
    int? limitWrites,
  }) : this._(
         membershipMode: AbctlMembershipMode.gitAuthoritative,
         prune: true,
         refresh: refresh,
         verify: verify,
         limitWrites: limitWrites,
       );

  /// What an ABM-only blueprint member means for this run. Follows the same choice that
  /// governs configs, because in abctl they are one flag — see [AbctlMembershipMode].
  final AbctlMembershipMode membershipMode;

  /// Whether this run may DELETE configurations and DETACH members. Derived from the
  /// constructor; there is deliberately no way to set it independently.
  final bool prune;

  /// How much live state is re-read before the plan is built.
  final AbctlRefresh refresh;

  /// How much of the result is read back afterwards.
  final AbctlVerify verify;

  /// The circuit breaker: at most N writes. Null (or a non-positive number) means unlimited,
  /// and the builder emits NO flag for it — a preview showing `--limit-writes 0` would be
  /// advertising a breaker the run does not arm.
  final int? limitWrites;

  /// Whether `--git-source-of-truth` is on. One expression of the same choice as
  /// [membershipMode], kept as a getter so no caller re-derives it from the flag list.
  bool get gitSourceOfTruth =>
      membershipMode == AbctlMembershipMode.gitAuthoritative;

  /// True when [limitWrites] will actually reach abctl.
  bool get limitsWrites => (limitWrites ?? 0) > 0;

  @override
  bool operator ==(Object other) =>
      other is ApplyOptions &&
      other.membershipMode == membershipMode &&
      other.prune == prune &&
      other.refresh == refresh &&
      other.verify == verify &&
      other.limitWrites == limitWrites;

  @override
  int get hashCode =>
      Object.hash(membershipMode, prune, refresh, verify, limitWrites);

  @override
  String toString() =>
      'ApplyOptions(${membershipMode.name}, prune: $prune, '
      'refresh: ${refresh.wire}, verify: ${verify.wire}, '
      'limitWrites: ${limitWrites ?? 0})';
}

/// `assign` vs `unassign` — the two halves of the gated device write, as a choice rather than
/// a boolean.
///
/// The Swift original took `unassign: Bool`, which is a word whose negation is the other verb:
/// `unassign: false` at a callsite reads as "do not unassign" and MEANS "assign". For a command
/// that moves real devices between MDM servers, the verb should be unmissable at the callsite.
enum AbctlAssignment {
  assign('assign'),
  unassign('unassign');

  const AbctlAssignment(this.verb);

  /// The abctl verb — also the leading token of the command.
  final String verb;
}

/// The argv builders. One per verb, each returning the complete command MINUS the `--context`
/// tail (see [contextSuffixed]).
abstract final class AbctlArgs {
  // The gated verbs live at the bottom of this file, under "writes". They were absent for the
  // whole read-only release; what replaced that absence is not a policy but a test battery —
  // `write_safety_test.dart`, one test per invariant, each named after the thing it defends.
  // Read it before touching anything below the "writes" banner.

  // ---------------------------------------------------------------------------------------
  // identity + version
  // ---------------------------------------------------------------------------------------

  /// `version -o json` — build identity and the capability tokens abgui gates features on.
  static List<String> version() => _frozen(['version', '-o', 'json']);

  /// `auth whoami -o json` — the typed "test connection". Reaches Apple for a token.
  static List<String> whoami() => _frozen(['auth', 'whoami', '-o', 'json']);

  // ---------------------------------------------------------------------------------------
  // plural reads — every one a live GET, none of them writable
  // ---------------------------------------------------------------------------------------

  static List<String> configurations() => _pluralGet('configurations');
  static List<String> blueprints() => _pluralGet('blueprints');
  static List<String> devices() => _pluralGet('devices');

  /// Built-in-MDM device inventory: devices enrolled in the BUILT-IN device management
  /// service, carrying last-reported posture. A different collection from [devices] (org
  /// devices), which is why the noun is not shared.
  static List<String> mdmDevices() => _pluralGet('mdmdevices');

  static List<String> users() => _pluralGet('users');
  static List<String> userGroups() => _pluralGet('usergroups');
  static List<String> apps() => _pluralGet('apps');
  static List<String> packages() => _pluralGet('packages');
  static List<String> mdmServers() => _pluralGet('mdmservers');

  /// `get audit --since <window> -o json`. [since] is abctl's own window spelling (`7d`,
  /// `24h`, an ISO date); it is passed through verbatim rather than parsed, because abctl —
  /// not abgui — owns what a valid window is, and re-implementing that here would be a second
  /// definition to keep in step.
  static List<String> audit({required String since}) =>
      _frozen(['get', 'audit', '--since', since, '-o', 'json']);

  /// `get os-releases -o json` — Apple's GDMF feed, not a tenant read.
  static List<String> osReleases() => _pluralGet('os-releases');

  // ---------------------------------------------------------------------------------------
  // singular detail reads (abctl Phase A). Flag ORDER is part of the contract test: the
  // opt-in flag precedes `--json`, exactly as the Swift client built it, so a copied command
  // from the Command Log is byte-for-byte what abgui ran.
  // ---------------------------------------------------------------------------------------

  /// `get device <serial|id> [--applecare] --json`.
  ///
  /// [appleCare] costs one extra Apple call for coverage records, which is why it is an
  /// explicit opt-in here and behind an explicit button in the UI rather than always-on.
  static List<String> deviceDetail(
    String serialOrId, {
    bool appleCare = false,
  }) => _detail('device', serialOrId, flag: appleCare ? '--applecare' : null);

  /// `get mdmdevice <serial|id> --json` — one enrolled device + its last-reported posture.
  static List<String> mdmDeviceDetail(String serialOrId) =>
      _detail('mdmdevice', serialOrId);

  /// `get user <email|id> --json`. Identity is not API-writable; this is read-only at source.
  static List<String> userDetail(String emailOrId) =>
      _detail('user', emailOrId);

  /// `get usergroup <name|id> [--members] --json`.
  ///
  /// [members] resolves each member with its own API call, so it is opt-in and carries the
  /// fan-out timeout at the client (`AbctlTimeouts.fanOut`), not the plain read budget.
  static List<String> userGroupDetail(
    String nameOrId, {
    bool members = false,
  }) => _detail('usergroup', nameOrId, flag: members ? '--members' : null);

  /// `get app <name|id> --json` — one owned Apps & Books title.
  static List<String> appDetail(String nameOrId) => _detail('app', nameOrId);

  /// `get package <name|id> --json` — one custom app/pkg.
  static List<String> packageDetail(String nameOrId) =>
      _detail('package', nameOrId);

  /// `get mdmserver <name|id> [--devices] --json`.
  ///
  /// [devices] walks the whole org device inventory on the abctl side to resolve serials —
  /// same fan-out shape, same doubled budget, same reason it is opt-in.
  static List<String> mdmServerDetail(
    String nameOrId, {
    bool devices = false,
  }) => _detail('mdmserver', nameOrId, flag: devices ? '--devices' : null);

  /// `get blueprint <name|id> --json` — member counts plus all six name-resolved collections.
  static List<String> blueprintDetail(String nameOrId) =>
      _detail('blueprint', nameOrId);

  /// `get configuration <id> --profile` — the raw `.mobileconfig` XML.
  ///
  /// The one read whose stdout is NOT JSON, which is why it has no `--json`/`-o json` tail and
  /// why the client hands it back as text rather than decoding it.
  static List<String> configurationProfile(String id) =>
      _frozen(['get', 'configuration', id, '--profile']);

  // ---------------------------------------------------------------------------------------
  // status reads
  // ---------------------------------------------------------------------------------------

  /// `status device <serial|id> --json` — one device end to end: assigned MDM server,
  /// blueprint/config membership (desired state) and built-in-MDM posture (last reported).
  ///
  /// abctl also accepts `--applecare` here; abgui deliberately does not thread it, fetching
  /// coverage through [deviceDetail] instead so the extra call is attached to the button that
  /// asked for it. Same choice the Swift client made.
  static List<String> deviceStatus(String serialOrId) =>
      _frozen(['status', 'device', serialOrId, '--json']);

  /// `status activity <id> --json` — poll one assign/unassign activity.
  ///
  /// Kept even though this release cannot START one: an activity id outlives the run that
  /// created it, so an operator with an id from the CLI can still be told what became of it.
  static List<String> activityStatus(String id) =>
      _frozen(['status', 'activity', id, '--json']);

  // ---------------------------------------------------------------------------------------
  // the workspace verbs — read-only members of the GitOps family
  // ---------------------------------------------------------------------------------------

  /// `diff --json [--git-source-of-truth] --refresh <mode>` — the 3-way plan.
  ///
  /// `diff` is `sync --dry-run`: it makes live API calls and computes what a reconcile WOULD
  /// change, then writes nothing. That is what makes it the one GitOps verb this release ships.
  /// [gitSourceOfTruth] only reverses which side the plan treats as desired — it applies
  /// nothing, so it is safe here even though the flag's twin on `sync --apply` is not.
  ///
  /// Resolved against the workspace cwd by the client: abctl roots `gitops/` at its process
  /// working directory, so a plan computed from the wrong cwd describes a different tree.
  static List<String> plan({
    bool gitSourceOfTruth = false,
    AbctlRefresh refresh = AbctlRefresh.smart,
  }) => _frozen([
    'diff',
    '--json',
    if (gitSourceOfTruth) '--git-source-of-truth',
    '--refresh',
    refresh.wire,
  ]);

  /// `validate --json` — the pre-sync check of the workspace's OWN files.
  ///
  /// Local-only: it reads `gitops/lib/*.mobileconfig` and the blueprint manifests, makes no
  /// tenant call and needs no credentials, which makes it the one verb that works before a
  /// connection exists. See `AbctlClient.validateProfiles` for why its exit code is mapped
  /// AFTER its payload is decoded.
  static List<String> validate() => _frozen(['validate', '--json']);

  // =======================================================================================
  // WRITES
  // =======================================================================================
  //
  // Everything below reaches a live Apple Business tenant, a real company's device fleet, or
  // the workspace's git tree. Four rules govern the section, and every one of them is a test
  // in `write_safety_test.dart` rather than a note someone has to remember:
  //
  //   * `--yes` on every TENANT write, because abctl otherwise prompts and the child hangs
  //     until the watchdog kills it — reported to the user as a timeout, which is what a
  //     blocked network looks like too. `adopt` and `seed` touch no tenant state and carry no
  //     `--yes`: a gate on a command that changes nothing local is a false claim about it.
  //   * `--prune` comes from [ApplyOptions] and nowhere else (see that type).
  //   * flag ORDER is contract, not taste. The Command Log's copy button hands an
  //     administrator this exact line, and the parity tests compare whole lists.
  //   * every one of these runs with the WORKSPACE as its cwd, enforced by `AbctlClient`.
  //     abctl roots `gitops/` at its process working directory, so an attach launched from
  //     the app bundle's cwd wrote its manifest into a different tree (or none) while `diff`
  //     read the real one — leaving a `detach-config` row that came back on every refresh
  //     with nothing in the GUI able to clear it.

  /// The gated converge: `sync --apply --yes --json`, then `--git-source-of-truth` and
  /// `--prune` when this run removes things, then `--refresh` / `--verify` / `--limit-writes`.
  ///
  /// The ONE place `--prune` is spelled in this app. It is emitted from [options] rather than
  /// from an argument, so the rule "git-as-truth implies removals" exists once, inside the
  /// same function that spells the flags — a preview and a run cannot disagree about the most
  /// destructive flag this command has, because they are the same call.
  ///
  /// `--limit-writes` is omitted for a null or non-positive limit: abctl treats "no flag" as
  /// unlimited, and a preview showing `--limit-writes 0` would advertise a circuit breaker the
  /// run does not arm.
  static List<String> syncApply(ApplyOptions options) => _frozen([
    'sync',
    '--apply',
    '--yes',
    '--json',
    if (options.gitSourceOfTruth) '--git-source-of-truth',
    if (options.prune) '--prune',
    '--refresh',
    options.refresh.wire,
    '--verify',
    options.verify.wire,
    if (options.limitsWrites) ...['--limit-writes', '${options.limitWrites}'],
  ]);

  /// `seed` — initialize (or refresh) the workspace tree from live tenant state.
  ///
  /// Reads the tenant and writes LOCAL files only, so there is no `--yes`: nothing about the
  /// tenant changes and there is no tenant confirmation to give. Its output is human text, not
  /// JSON, which is why it carries no output selector either.
  static List<String> seed() => _frozen(['seed']);

  /// `create config <name> -f - --yes --json` — a new CUSTOM_SETTING configuration.
  ///
  /// `-f -` means "the profile XML arrives on stdin". It stays stdin rather than a temp file
  /// so a `.mobileconfig` — which routinely carries credentials and certificates — never
  /// touches disk outside the workspace, and never appears in a process listing.
  static List<String> createConfiguration(String name) =>
      _frozen(['create', 'config', name, '-f', '-', '--yes', '--json']);

  /// `replace config <id> -f - --yes --json` — archive the live profile, then PATCH it. The
  /// GUI's "edit".
  static List<String> replaceConfiguration(String id) =>
      _frozen(['replace', 'config', id, '-f', '-', '--yes', '--json']);

  /// `delete config <id> --yes --json` — archive the live profile, then DELETE it.
  static List<String> deleteConfiguration(String id) =>
      _frozen(['delete', 'config', id, '--yes', '--json']);

  /// `attach config <id> --blueprint <bp> --yes --json` — additive membership.
  static List<String> attachConfiguration({
    required String configId,
    required String blueprint,
  }) => _membership('attach', configId: configId, blueprint: blueprint);

  /// `detach config <id> --blueprint <bp> --yes --json` — remove a member from a blueprint.
  static List<String> detachConfiguration({
    required String configId,
    required String blueprint,
  }) => _membership('detach', configId: configId, blueprint: blueprint);

  /// `adopt <kind> <name> --blueprint <bp> --json` — record an ALREADY-attached member in the
  /// blueprint's git manifest.
  ///
  /// **No `--yes`, and that is the contract, not an oversight.** This writes
  /// `gitops/blueprints/<bp>.yml` and never the tenant: Apple Business already has the member,
  /// and this is the answer to "stop proposing to detach it". Gating a local file write behind
  /// a tenant-write confirmation would teach an operator that the two are the same risk.
  static List<String> adoptMember({
    required AbctlMemberKind kind,
    required String name,
    required String blueprint,
  }) => _frozen(['adopt', kind.wire, name, '--blueprint', blueprint, '--json']);

  /// `assign|unassign --server <server> <serials…> --yes --json` — move org devices between
  /// MDM servers.
  ///
  /// One builder for both verbs, deliberately: they differ in a single token, and two builders
  /// would be two chances to get a gated device write's argv wrong. The serials go BETWEEN the
  /// server and the gate flags, exactly as abctl's positional list expects.
  ///
  /// Apple processes assignment asynchronously — the outcome carries an activity id, which is
  /// what [activityStatus] polls.
  static List<String> assignment({
    required AbctlAssignment action,
    required String server,
    required List<String> serials,
  }) =>
      _frozen([action.verb, '--server', server, ...serials, '--yes', '--json']);

  /// `attach`/`detach config <id> --blueprint <bp> --yes --json`. Shared so the two membership
  /// verbs cannot drift into different flag orders.
  static List<String> _membership(
    String verb, {
    required String configId,
    required String blueprint,
  }) => _frozen([
    verb,
    'config',
    configId,
    '--blueprint',
    blueprint,
    '--yes',
    '--json',
  ]);

  // ---------------------------------------------------------------------------------------
  // Apps & Books (VPP) — a separate service from the Business API, read-only here
  // ---------------------------------------------------------------------------------------

  /// `vpp config -o json --vpp-token <token>` — validates the content token and reports limits.
  static List<String> vppConfig({required String token}) =>
      _vpp('config', token);

  /// `vpp assets -o json --vpp-token <token>` — owned titles + license counts.
  static List<String> vppAssets({required String token}) =>
      _vpp('assets', token);

  /// `vpp assignments -o json --vpp-token <token>` — who/what each license is assigned to.
  static List<String> vppAssignments({required String token}) =>
      _vpp('assignments', token);

  /// `vpp users -o json --vpp-token <token>` — registered VPP users.
  static List<String> vppUsers({required String token}) => _vpp('users', token);

  // ---------------------------------------------------------------------------------------
  // the context store (~/.abctl/contexts.yaml)
  // ---------------------------------------------------------------------------------------
  //
  // These MANAGE the store, so they are never scoped by `--context` — [contextSuffixed]
  // refuses structurally. Only the read half exists in this release: `context set`/`use`/
  // `delete` rewrite the operator's credential file, which is a mutation like any other.
  // Note what that does NOT cost us: the private key is passed to `context set` as a file
  // PATH, never as key material on argv, so re-enabling those verbs later changes nothing
  // about how secrets travel.

  /// `context list -o json` — the saved connections + which one is current.
  static List<String> contextList() =>
      _frozen(['context', 'list', '-o', 'json']);

  /// `context get [name] -o json` — one context's stored fields (client id, key PATH, base).
  ///
  /// An omitted or empty [name] asks for the CURRENT context, which is a different question
  /// from "the context named ''" — abctl would reject the latter, so the empty string is
  /// dropped rather than forwarded.
  static List<String> contextDetail([String? name]) => _frozen([
    'context',
    'get',
    if (name != null && name.isNotEmpty) name,
    '-o',
    'json',
  ]);

  // ---------------------------------------------------------------------------------------
  // the one place `--context` is spelled
  // ---------------------------------------------------------------------------------------

  /// Verbs that manage the context store and must therefore never be scoped BY a context.
  ///
  /// A set keyed on the leading token rather than a check at each call site: the rule then
  /// exists once, applies to `context get`/`list` and to any context sub-verb added later, and
  /// cannot be forgotten by whoever adds it.
  static const Set<String> contextFreeVerbs = <String>{'context'};

  /// [base] with `--context <context>` appended — the ONE spelling of that tail in the app.
  ///
  /// Both the run path (`AbctlClient`) and the preview path (`AbctlClient.previewArgv`, which
  /// a sheet renders through `CommandFormatter.line`) call this, so the command an
  /// administrator reads before pressing a button is the command that executes, including
  /// which tenant it names. Two rules live here, both load-bearing:
  ///
  ///  * An absent or EMPTY context means "use abctl's own current context", so no flag is
  ///    emitted. `abctl validate --json --context ''` is not what runs and would not work; a
  ///    preview showing it would teach a broken command.
  ///  * A context-store verb never gets the flag, however it is called ([contextFreeVerbs]).
  static List<String> contextSuffixed(List<String> base, String? context) {
    if (context == null || context.isEmpty) return _frozen(base);
    if (base.isNotEmpty && contextFreeVerbs.contains(base.first)) {
      return _frozen(base);
    }
    return _frozen([...base, '--context', context]);
  }

  /// The DISPLAY form of a command: the exact token list a run of [base] will hand abctl.
  ///
  /// **This is the function a confirmation dialog renders, and it is the same function the run
  /// executes** — `AbctlClient.previewArgv` is this, and `AbctlClient` runs what
  /// `previewArgv` returns. A dialog therefore cannot show a lookalike: the only thing it has
  /// to draw is this list, put through `CommandFormatter.line` (which quotes and redacts, and
  /// is itself the one place argv becomes text). A gated write that showed one command and
  /// sent another would be worse than showing nothing — it would collect an approval for
  /// something the operator never saw.
  ///
  /// Named for the job rather than the mechanism because the mechanism is not the point at the
  /// callsite: a view asks for "the preview", gets the executed argv, and has no second option.
  /// [contextSuffixed] remains the implementation, and a contract test pins the two to the same
  /// output so the pair cannot become two spellings of one rule.
  static List<String> preview(List<String> base, {String? context}) =>
      contextSuffixed(base, context);

  // ---------------------------------------------------------------------------------------
  // shared shapes
  // ---------------------------------------------------------------------------------------

  /// `get <collection> -o json`.
  static List<String> _pluralGet(String collection) =>
      _frozen(['get', collection, '-o', 'json']);

  /// `get <noun> <id> [flag] --json` — the singular detail shape, with the opt-in flag ahead
  /// of `--json` because that is the order the contract pins.
  static List<String> _detail(String noun, String subject, {String? flag}) =>
      _frozen(['get', noun, subject, if (flag != null) flag, '--json']);

  /// `vpp <sub> -o json --vpp-token <token>`.
  ///
  /// The token is a credential ON ARGV, which is unavoidable (abctl's own interface) and is
  /// exactly why `CommandFormatter.redactedFlags` carries `--vpp-token`: every path that
  /// displays or records a command redacts the following token, so it never reaches the
  /// Command Log, a run log or a copied line.
  static List<String> _vpp(String sub, String token) =>
      _frozen(['vpp', sub, '-o', 'json', '--vpp-token', token]);

  /// Freeze the list. An unmodifiable argv is the last structural defense in this file: a
  /// caller cannot append a flag to a builder's output, so any command that runs is a command
  /// some builder here spelled in full.
  static List<String> _frozen(Iterable<String> parts) =>
      List<String>.unmodifiable(parts);
}
