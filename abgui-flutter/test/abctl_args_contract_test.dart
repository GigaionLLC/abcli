// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// THE SPECIFICATION. Every assertion here is a line of abctl's command-line contract, ported
// from the frozen Swift app's `Tests/abguiTests/ContractTests.swift` (each ported case names
// the Swift test it comes from). It needs no process, no fake and no async, which is what makes
// it the cheapest test in the project and the one most worth keeping exhaustive: a wrong flag
// reaches a live Apple Business tenant, and this file is the only thing between a refactor and
// that outcome.
//
// The argv assertions are written as WHOLE-LIST equality wherever the Swift original used
// `args.contains(token)`. Containment was the weaker check available to a test that ran through
// a client; here the builders are pure, so order — `--applecare` BEFORE `--json`, `--refresh`
// AFTER `--git-source-of-truth` — is pinned too. Order matters for a reason beyond pedantry:
// the Command Log's copy button hands an administrator this exact line to paste.

import 'dart:io';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('identity + version', () {
    // ContractTests.testVersionDecodesAndReadsCapabilities / testContextIsThreadedAsFlag.
    test('version and whoami ask for JSON with the collection selector', () {
      expect(AbctlArgs.version(), ['version', '-o', 'json']);
      expect(AbctlArgs.whoami(), ['auth', 'whoami', '-o', 'json']);
    });
  });

  group('plural reads', () {
    // ContractTests.testPackagesUsesGetPackages — the noun is the contract; `get package`
    // (singular) is a different verb that answers a different shape.
    test('every collection is `get <noun> -o json`', () {
      expect(AbctlArgs.configurations(), [
        'get',
        'configurations',
        '-o',
        'json',
      ]);
      expect(AbctlArgs.blueprints(), ['get', 'blueprints', '-o', 'json']);
      expect(AbctlArgs.devices(), ['get', 'devices', '-o', 'json']);
      expect(AbctlArgs.mdmDevices(), ['get', 'mdmdevices', '-o', 'json']);
      expect(AbctlArgs.users(), ['get', 'users', '-o', 'json']);
      expect(AbctlArgs.userGroups(), ['get', 'usergroups', '-o', 'json']);
      expect(AbctlArgs.apps(), ['get', 'apps', '-o', 'json']);
      expect(AbctlArgs.packages(), ['get', 'packages', '-o', 'json']);
      expect(AbctlArgs.mdmServers(), ['get', 'mdmservers', '-o', 'json']);
    });

    test('audit carries the window abctl was given, verbatim', () {
      expect(AbctlArgs.audit(since: '7d'), [
        'get',
        'audit',
        '--since',
        '7d',
        '-o',
        'json',
      ]);
      // An ISO instant is just as valid a window; abgui does not parse or normalize it,
      // because abctl owns what a window means and a second definition would drift.
      expect(AbctlArgs.audit(since: '2026-01-01T00:00:00Z'), [
        'get',
        'audit',
        '--since',
        '2026-01-01T00:00:00Z',
        '-o',
        'json',
      ]);
    });

    // ContractTests.testOSReleaseContractAndArguments — asserted there as a whole list too.
    test('os-releases is a plural get, hyphen and all', () {
      expect(AbctlArgs.osReleases(), ['get', 'os-releases', '-o', 'json']);
    });
  });

  group('singular detail reads', () {
    // ContractTests.testDeviceDetailAppleCareFlagAndDecode.
    test('device detail puts the opt-in flag before --json', () {
      expect(AbctlArgs.deviceDetail('C02XYZ'), [
        'get',
        'device',
        'C02XYZ',
        '--json',
      ]);
      expect(AbctlArgs.deviceDetail('C02XYZ', appleCare: true), [
        'get',
        'device',
        'C02XYZ',
        '--applecare',
        '--json',
      ]);
    });

    test('the flagless details are `get <noun> <subject> --json`', () {
      expect(AbctlArgs.mdmDeviceDetail('C02XYZ'), [
        'get',
        'mdmdevice',
        'C02XYZ',
        '--json',
      ]);
      expect(AbctlArgs.userDetail('ada@example.com'), [
        'get',
        'user',
        'ada@example.com',
        '--json',
      ]);
      expect(AbctlArgs.appDetail('Numbers'), [
        'get',
        'app',
        'Numbers',
        '--json',
      ]);
      expect(AbctlArgs.packageDetail('LOB Installer'), [
        'get',
        'package',
        'LOB Installer',
        '--json',
      ]);
      expect(AbctlArgs.blueprintDetail('Fleet-A'), [
        'get',
        'blueprint',
        'Fleet-A',
        '--json',
      ]);
    });

    // ContractTests.testUserGroupMembersDecode / testUserGroupWithoutMembersDecodes /
    // testMDMServerDevicesDecode: the flag's presence is what makes `members`/`devices` decode
    // as null-vs-empty on the other side, so it is asserted in both states.
    test('the fan-out flags are opt-in and never implied', () {
      expect(AbctlArgs.userGroupDetail('Engineering'), [
        'get',
        'usergroup',
        'Engineering',
        '--json',
      ]);
      expect(AbctlArgs.userGroupDetail('Engineering', members: true), [
        'get',
        'usergroup',
        'Engineering',
        '--members',
        '--json',
      ]);
      expect(AbctlArgs.mdmServerDetail('Built-in MDM'), [
        'get',
        'mdmserver',
        'Built-in MDM',
        '--json',
      ]);
      expect(AbctlArgs.mdmServerDetail('Built-in MDM', devices: true), [
        'get',
        'mdmserver',
        'Built-in MDM',
        '--devices',
        '--json',
      ]);
    });

    test('the profile read asks for XML, so it carries no JSON selector', () {
      expect(AbctlArgs.configurationProfile('c1'), [
        'get',
        'configuration',
        'c1',
        '--profile',
      ]);
    });
  });

  group('status reads', () {
    // ContractTests.testDeviceStatusReportDecodes / testActivityStatusDecodesAsResource.
    test('status verbs use the singular --json switch', () {
      expect(AbctlArgs.deviceStatus('C02XYZ'), [
        'status',
        'device',
        'C02XYZ',
        '--json',
      ]);
      expect(AbctlArgs.activityStatus('act-42'), [
        'status',
        'activity',
        'act-42',
        '--json',
      ]);
    });

    test('status device does not thread --applecare', () {
      // abctl accepts it; abgui fetches coverage through `get device --applecare` instead, so
      // the extra Apple call belongs to the button that asked for it. Swift made the same
      // choice, and a future "just add the flag" would silently double the cost of every
      // device sheet open.
      expect(AbctlArgs.deviceStatus('C02XYZ'), isNot(contains('--applecare')));
    });
  });

  group('the workspace verbs', () {
    // ContractTests.testPlanArgsIncludeGitSourceOfTruth.
    test('diff spells the plan options in a fixed order', () {
      expect(AbctlArgs.plan(), ['diff', '--json', '--refresh', 'smart']);
      expect(
        AbctlArgs.plan(gitSourceOfTruth: true, refresh: AbctlRefresh.full),
        ['diff', '--json', '--git-source-of-truth', '--refresh', 'full'],
      );
      expect(AbctlArgs.plan(refresh: AbctlRefresh.metadataOnly), [
        'diff',
        '--json',
        '--refresh',
        'metadata-only',
      ]);
    });

    test('every refresh mode spells the token abctl expects', () {
      expect(AbctlRefresh.values.map((r) => r.wire).toList(), [
        'smart',
        'full',
        'metadata-only',
      ]);
    });

    // ContractTests.testValidatePreviewIsTheArgvThatActuallyRunsAndCarriesTheWorkspace.
    test('validate is the whole command — no credentials, no options', () {
      expect(AbctlArgs.validate(), ['validate', '--json']);
    });
  });

  group('the write verbs', () {
    // THE VERB TABLE. Every argv here is transcribed from the frozen Swift client
    // (`Sources/abgui/Backend/AbctlClient.swift`) and pinned by ContractTests.swift; each case
    // names the Swift test it comes from. Whole-list equality, not `contains`: the Swift tests
    // could only check containment because they ran through a client, while these builders are
    // pure, so ORDER is pinned too — and order is what an administrator pastes out of the
    // Command Log when they reproduce a write by hand.

    // ContractTests.testCreateSendsGatedJSONWithStdin. `-f -` is "the profile is on stdin":
    // the XML never becomes a temp file, so a profile carrying certificates or a Wi-Fi
    // passphrase is never readable on disk or in a process listing.
    test('create config feeds the profile on stdin, gated, in JSON', () {
      expect(AbctlArgs.createConfiguration('WiFi'), [
        'create',
        'config',
        'WiFi',
        '-f',
        '-',
        '--yes',
        '--json',
      ]);
    });

    // ContractTests.testReplaceSendsGatedJSONWithStdin — the same shape addressed by id,
    // because replace edits a config that already exists.
    test('replace config takes an id and the same stdin pair', () {
      expect(AbctlArgs.replaceConfiguration('id-1'), [
        'replace',
        'config',
        'id-1',
        '-f',
        '-',
        '--yes',
        '--json',
      ]);
    });

    // ContractTests.testDeleteOutcomeDecodesArchive.
    test('delete config carries no file argument', () {
      expect(AbctlArgs.deleteConfiguration('id-1'), [
        'delete',
        'config',
        'id-1',
        '--yes',
        '--json',
      ]);
    });

    // ContractTests.testTreeMutatingVerbsRunInTheWorkspace (the argv half).
    test('attach and detach differ in exactly one token', () {
      const attach = ['attach', 'config', 'c1', '--blueprint', 'Fleet'];
      expect(
        AbctlArgs.attachConfiguration(configId: 'c1', blueprint: 'Fleet'),
        [...attach, '--yes', '--json'],
      );
      expect(
        AbctlArgs.detachConfiguration(configId: 'c1', blueprint: 'Fleet'),
        ['detach', ...attach.skip(1), '--yes', '--json'],
      );
      // A blueprint named with a space is the ordinary case, not the exotic one — the
      // positional/flag split has to survive it, since nothing here quotes.
      expect(
        AbctlArgs.attachConfiguration(
          configId: 'c1',
          blueprint: 'Fleet A / EU',
        ),
        [
          'attach',
          'config',
          'c1',
          '--blueprint',
          'Fleet A / EU',
          '--yes',
          '--json',
        ],
      );
    });

    // ContractTests.testAdoptArgvIsLocalOnly — the kind is the FIRST argument, and there is
    // no `--yes` because nothing about the tenant changes.
    test('adopt names the member collection and is never gated', () {
      expect(
        AbctlArgs.adoptMember(
          kind: AbctlMemberKind.config,
          name: 'WiFi.mobileconfig',
          blueprint: 'Fleet',
        ),
        [
          'adopt',
          'config',
          'WiFi.mobileconfig',
          '--blueprint',
          'Fleet',
          '--json',
        ],
      );
      expect(
        AbctlArgs.adoptMember(
          kind: AbctlMemberKind.user,
          name: 'ada@example.com',
          blueprint: 'Fleet',
        ),
        ['adopt', 'user', 'ada@example.com', '--blueprint', 'Fleet', '--json'],
      );
    });

    // The six nouns are `internal/cli/deploy.go`'s own list
    // (`adopt <config|app|package|device|user|group>`), and they are also the suffixes of a
    // plan row's action (`adopt-user` → `user`), which is where the value really comes from.
    test('every member kind spells the noun abctl accepts', () {
      expect(AbctlMemberKind.values.map((k) => k.wire).toList(), [
        'config',
        'app',
        'package',
        'device',
        'user',
        'group',
      ]);
      expect(AbctlMemberKind.fromWire('group'), AbctlMemberKind.group);
      // An unknown collection is null rather than a guess: a newer abctl may manage a
      // seventh, and inventing a noun for it means a usage error after the command ran.
      expect(AbctlMemberKind.fromWire('printer'), isNull);
      expect(AbctlMemberKind.fromWire(''), isNull);
    });

    // ContractTests.testAssignSendsGatedJSONAndDecodesActivity /
    // testAssignPreviewIsTheArgvThatActuallyRunsForBothVerbs.
    test('assign and unassign put the serials between server and gate', () {
      expect(
        AbctlArgs.assignment(
          action: AbctlAssignment.assign,
          server: 'Built-in MDM',
          serials: const ['C02AAA', 'C02BBB'],
        ),
        [
          'assign',
          '--server',
          'Built-in MDM',
          'C02AAA',
          'C02BBB',
          '--yes',
          '--json',
        ],
      );
      expect(
        AbctlArgs.assignment(
          action: AbctlAssignment.unassign,
          server: 'Built-in MDM',
          serials: const ['C02AAA'],
        ),
        ['unassign', '--server', 'Built-in MDM', 'C02AAA', '--yes', '--json'],
      );
      // An empty serial list still builds a well-formed command; refusing it is the caller's
      // job, and a builder that silently dropped `--yes` for it would be worse.
      expect(
        AbctlArgs.assignment(
          action: AbctlAssignment.assign,
          server: 'Built-in MDM',
          serials: const [],
        ),
        ['assign', '--server', 'Built-in MDM', '--yes', '--json'],
      );
    });

    // ContractTests.testSeedRunsSeedInWorkspaceWithContext — `seed` is the whole command.
    // Human text on stdout, so no output selector; local files only, so no gate.
    test('seed is the bare verb', () {
      expect(AbctlArgs.seed(), ['seed']);
    });

    // ContractTests.testApplyArgsIncludePruneAndLimit. The flag ORDER here is the contract:
    // gate first, then the two mode-selecting flags, then the modes, then the breaker.
    test('sync --apply spells its options in a fixed order', () {
      expect(AbctlArgs.syncApply(const ApplyOptions.additive()), [
        'sync',
        '--apply',
        '--yes',
        '--json',
        '--refresh',
        'smart',
        '--verify',
        'targeted',
      ]);
      expect(
        AbctlArgs.syncApply(
          const ApplyOptions.gitAuthoritative(
            refresh: AbctlRefresh.full,
            verify: AbctlVerify.none,
            limitWrites: 5,
          ),
        ),
        [
          'sync',
          '--apply',
          '--yes',
          '--json',
          '--git-source-of-truth',
          '--prune',
          '--refresh',
          'full',
          '--verify',
          'none',
          '--limit-writes',
          '5',
        ],
      );
      expect(
        AbctlArgs.syncApply(
          const ApplyOptions.additiveAllowingDeletes(
            refresh: AbctlRefresh.metadataOnly,
            verify: AbctlVerify.full,
          ),
        ),
        [
          'sync',
          '--apply',
          '--yes',
          '--json',
          '--prune',
          '--refresh',
          'metadata-only',
          '--verify',
          'full',
        ],
      );
    });

    // ContractTests.testSyncApplyPreviewIsTheArgvThatActuallyRuns pinned this case
    // explicitly: the execute path drops a limit of 0 as "unlimited", so a preview showing
    // `--limit-writes 0` advertises a circuit breaker the run does not arm.
    test('a non-positive write limit emits no flag at all', () {
      for (final limit in <int?>[null, 0, -1]) {
        expect(
          AbctlArgs.syncApply(ApplyOptions.additive(limitWrites: limit)),
          isNot(contains('--limit-writes')),
          reason: 'limitWrites: $limit',
        );
      }
      expect(
        AbctlArgs.syncApply(const ApplyOptions.additive(limitWrites: 1)),
        containsAllInOrder(['--limit-writes', '1']),
      );
    });

    test('every verify mode spells the token abctl expects', () {
      // `internal/cli/phase1.go` rejects anything else with a Cobra usage error (exit 2),
      // which reaches a user as "abgui is broken" — hence an enum rather than a String.
      expect(AbctlVerify.values.map((v) => v.wire).toList(), [
        'targeted',
        'full',
        'none',
      ]);
    });
  });

  group('Apps & Books (VPP)', () {
    // ContractTests.testVPPTokenIsPassedAsFlag.
    test('the content token travels as --vpp-token on every vpp verb', () {
      expect(AbctlArgs.vppConfig(token: 'sTok'), [
        'vpp',
        'config',
        '-o',
        'json',
        '--vpp-token',
        'sTok',
      ]);
      expect(AbctlArgs.vppAssets(token: 'sTok'), [
        'vpp',
        'assets',
        '-o',
        'json',
        '--vpp-token',
        'sTok',
      ]);
      expect(AbctlArgs.vppAssignments(token: 'sTok'), [
        'vpp',
        'assignments',
        '-o',
        'json',
        '--vpp-token',
        'sTok',
      ]);
      expect(AbctlArgs.vppUsers(token: 'sTok'), [
        'vpp',
        'users',
        '-o',
        'json',
        '--vpp-token',
        'sTok',
      ]);
    });
  });

  group('the context store', () {
    // ContractTests.testContextListDecodes / testContextDetailDecodesSnakeCaseAndKeyPath.
    test('list and get use the collection selector', () {
      expect(AbctlArgs.contextList(), ['context', 'list', '-o', 'json']);
      expect(AbctlArgs.contextDetail('prod'), [
        'context',
        'get',
        'prod',
        '-o',
        'json',
      ]);
    });

    test('an omitted or empty name asks for the CURRENT context', () {
      // Not the same question as "the context named ''" — abctl would reject that, and a
      // Settings screen with no selection has to be able to ask the first question.
      const currentContext = ['context', 'get', '-o', 'json'];
      expect(AbctlArgs.contextDetail(), currentContext);
      expect(AbctlArgs.contextDetail(null), currentContext);
      expect(AbctlArgs.contextDetail(''), currentContext);
    });
  });

  group('the --context tail', () {
    // ContractTests.testContextIsThreadedAsFlag.
    test('is appended once, at the end', () {
      expect(AbctlArgs.contextSuffixed(AbctlArgs.version(), 'prod'), [
        'version',
        '-o',
        'json',
        '--context',
        'prod',
      ]);
    });

    // ContractTests.testPreviewArgvThreadsTheContextExactlyLikeTheRun — an unset context means
    // "use abctl's own current context", so the flag must be ABSENT rather than empty:
    // `abctl validate --json --context ''` is not what runs and would not work.
    test('is omitted entirely when no context is selected', () {
      expect(AbctlArgs.contextSuffixed(AbctlArgs.validate(), null), [
        'validate',
        '--json',
      ]);
      expect(AbctlArgs.contextSuffixed(AbctlArgs.validate(), ''), [
        'validate',
        '--json',
      ]);
    });

    // ContractTests.testSaveContextThreadsFlagsAndNeverAddsContextFlag — the store-write half
    // of that test is out of scope for this read-only release, but its INVARIANT is not: a
    // command that manages the context store must never be scoped by a context, and here the
    // refusal is structural rather than "don't call this for those verbs".
    test('is refused for the context-store verbs, however it is called', () {
      expect(AbctlArgs.contextSuffixed(AbctlArgs.contextList(), 'prod'), [
        'context',
        'list',
        '-o',
        'json',
      ]);
      expect(
        AbctlArgs.contextSuffixed(AbctlArgs.contextDetail('staging'), 'prod'),
        ['context', 'get', 'staging', '-o', 'json'],
      );
      // The rule is keyed on the leading token, so a context sub-verb added later inherits it
      // without anyone remembering to add a case.
      expect(AbctlArgs.contextSuffixed(['context', 'unheard-of'], 'prod'), [
        'context',
        'unheard-of',
      ]);
      expect(AbctlArgs.contextFreeVerbs, contains('context'));
    });

    test('no builder spells the flag itself', () {
      // The preview path appends the tail from the model's context and the run path appends it
      // from the client's; a builder that also carried one would double the flag on a run and
      // name a tenant twice in a copied command.
      _everyCommandInThisRelease().forEach((name, argv) {
        expect(argv, isNot(contains('--context')), reason: '$name: $argv');
      });
    });
  });

  group('the gated-flag allowlist', () {
    // This REPLACES the read-only release's "no builder can emit a gated flag" test, which is
    // what the TODO in abctl_args.dart required before the write verbs could return. Deleting
    // it outright would have left the whole `--yes`/`--prune`/`--apply` surface unguarded; an
    // allowlist keeps the same shape of guarantee — every gated flag sits on a verb that is
    // supposed to carry it, and on no other.
    //
    // There is no ContractTests.swift equivalent: the Swift app shipped these verbs without a
    // rule about WHICH of them may be gated, so `adopt` acquiring a `--yes` (or `diff`
    // acquiring a `--prune`) would have passed every test it had.

    // The flags that make a command destructive or unattended, and the verbs allowed to carry
    // each one. A verb absent from a flag's set may never spell it.
    const allowedBy = <String, Set<String>>{
      '--yes': {
        'sync',
        'create',
        'replace',
        'delete',
        'attach',
        'detach',
        'assign',
        'unassign',
      },
      '--apply': {'sync'},
      '--prune': {'sync'},
      // `diff` is `sync --dry-run`: the flag only chooses which side the plan treats as
      // desired, and nothing is applied, which is why the read release already shipped it.
      '--git-source-of-truth': {'sync', 'diff'},
      '--limit-writes': {'sync'},
    };

    test('no builder carries a gated flag its verb is not allowed', () {
      _everyCommandInThisRelease().forEach((name, argv) {
        final verb = argv.first;
        allowedBy.forEach((flag, verbs) {
          if (verbs.contains(verb)) return;
          expect(
            argv,
            isNot(contains(flag)),
            reason: '$name ($verb) must not carry $flag: $argv',
          );
        });
      });
    });

    test('adopt and seed are ungated, because they write no tenant state', () {
      // The pair it would be most tempting to "fix" by adding `--yes` for consistency. Both
      // write local files only: gating them teaches an operator to read a tenant-write
      // confirmation as routine, which is the opposite of what the gate is for.
      for (final argv in <List<String>>[
        AbctlArgs.adoptMember(
          kind: AbctlMemberKind.config,
          name: 'WiFi.mobileconfig',
          blueprint: 'Fleet',
        ),
        AbctlArgs.seed(),
      ]) {
        expect(argv, isNot(contains('--yes')), reason: '$argv');
      }
    });

    test('every read verb is still free of every gated flag', () {
      // The read surface is where an accidental gate would be least visible: nothing about a
      // `get` would look wrong until it ran.
      _everyCommandInThisRelease().forEach((name, argv) {
        if (_writeVerbs.contains(argv.first)) return;
        for (final flag in allowedBy.keys) {
          if (allowedBy[flag]!.contains(argv.first)) continue;
          expect(argv, isNot(contains(flag)), reason: '$name: $argv');
        }
      });
    });

    test('--prune is spelled exactly once in the whole app', () {
      // The source scan the read-only release used, narrowed to the flag that DELETES things.
      // A per-builder check only covers builders someone remembered to list; this one reads
      // every line of lib/, so a second `--prune` — in a view, a store, a console shortcut —
      // fails here even if nothing in the suite ever calls it. That is invariant 1 in its
      // strongest form: not "callers pass the right boolean" but "there is nowhere else to
      // put the flag".
      //
      // Comments are stripped first: the source's own prose names the flag repeatedly, and a
      // test that forbade explaining itself would be deleted within a week.
      final occurrences = <String>[];
      for (final entry in Directory('lib').listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        for (final line in _strippedLines(entry)) {
          if (line.contains('--prune')) occurrences.add('${entry.path}: $line');
        }
      }
      expect(
        occurrences,
        hasLength(1),
        reason:
            'the destructive flag must have exactly one spelling, inside '
            'AbctlArgs.syncApply, derived from ApplyOptions: $occurrences',
      );
      expect(occurrences.single, contains('abctl_args.dart'));
    });
  });

  group('preview is the executed argv', () {
    // ContractTests.testSyncApplyPreviewIsTheArgvThatActuallyRuns, at the builder level. The
    // half a pure builder cannot prove — that the CLIENT runs what preview returns — is in
    // write_safety_test.dart, against a tapped runner.

    test('preview and contextSuffixed cannot become two rules', () {
      // Two names for one tail is how a preview starts naming a different tenant than the run
      // does. They are pinned to identical output across the whole command surface.
      for (final base in _everyCommandInThisRelease().values) {
        expect(AbctlArgs.preview(base), AbctlArgs.contextSuffixed(base, null));
        expect(
          AbctlArgs.preview(base, context: 'prod'),
          AbctlArgs.contextSuffixed(base, 'prod'),
        );
      }
    });

    test('preview appends the context tail a run appends, and no other', () {
      expect(
        AbctlArgs.preview(
          AbctlArgs.syncApply(const ApplyOptions.additive()),
          context: 'prod',
        ),
        [
          'sync',
          '--apply',
          '--yes',
          '--json',
          '--refresh',
          'smart',
          '--verify',
          'targeted',
          '--context',
          'prod',
        ],
      );
      // An unset context means "abctl's own current context", so no flag at all: a preview
      // showing `--context ''` would teach a command that does not work.
      expect(AbctlArgs.preview(AbctlArgs.deleteConfiguration('c1')), [
        'delete',
        'config',
        'c1',
        '--yes',
        '--json',
      ]);
    });
  });

  group('the frozen-argv guarantee', () {
    test('a builder\'s output cannot be extended by a caller', () {
      // The last structural defense: an unmodifiable argv means any command that runs is one
      // some builder spelled in full, so `argv..add('--yes')` in a view is an exception rather
      // than a tenant write nobody previewed.
      expect(
        () => AbctlArgs.plan().add('--prune'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => AbctlArgs.contextSuffixed(AbctlArgs.version(), 'prod').add('x'),
        throwsA(isA<UnsupportedError>()),
      );
      // The write half, which is where an appended flag would actually cost something: a
      // caller cannot turn a previewed, approved `sync --apply` into a pruning one.
      expect(
        () => AbctlArgs.syncApply(const ApplyOptions.additive()).add('--prune'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => AbctlArgs.adoptMember(
          kind: AbctlMemberKind.config,
          name: 'WiFi.mobileconfig',
          blueprint: 'Fleet',
        ).add('--yes'),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}

/// The verbs that change something. Used to exempt them from the read-surface checks; a write
/// verb missing from this set would be checked as though it were a read and fail loudly, which
/// is the safe direction for a list someone has to maintain by hand.
const Set<String> _writeVerbs = <String>{
  'sync',
  'seed',
  'create',
  'replace',
  'delete',
  'attach',
  'detach',
  'adopt',
  'assign',
  'unassign',
};

/// [file]'s lines with `//` comments removed.
///
/// The source scans below assert that a flag is not SPELLED somewhere, and the source's own
/// prose names those flags constantly — a scan that could not tell code from commentary would
/// forbid the files from explaining themselves. No file in `lib/` contains `//` inside a
/// string literal, which is what makes the cut safe.
Iterable<String> _strippedLines(File file) =>
    file.readAsLinesSync().map((line) {
      final comment = line.indexOf('//');
      return comment < 0 ? line : line.substring(0, comment);
    });

/// Every command this release can build, with sample arguments. Used by the allowlist and
/// preview tests above; a new builder belongs here, and the source scan is what catches it if
/// it is not.
Map<String, List<String>>
_everyCommandInThisRelease() => <String, List<String>>{
  'version': AbctlArgs.version(),
  'whoami': AbctlArgs.whoami(),
  'configurations': AbctlArgs.configurations(),
  'blueprints': AbctlArgs.blueprints(),
  'devices': AbctlArgs.devices(),
  'mdmDevices': AbctlArgs.mdmDevices(),
  'users': AbctlArgs.users(),
  'userGroups': AbctlArgs.userGroups(),
  'apps': AbctlArgs.apps(),
  'packages': AbctlArgs.packages(),
  'mdmServers': AbctlArgs.mdmServers(),
  'audit': AbctlArgs.audit(since: '7d'),
  'osReleases': AbctlArgs.osReleases(),
  'deviceDetail': AbctlArgs.deviceDetail('C02XYZ'),
  'deviceDetail --applecare': AbctlArgs.deviceDetail('C02XYZ', appleCare: true),
  'mdmDeviceDetail': AbctlArgs.mdmDeviceDetail('C02XYZ'),
  'userDetail': AbctlArgs.userDetail('ada@example.com'),
  'userGroupDetail': AbctlArgs.userGroupDetail('Engineering'),
  'userGroupDetail --members': AbctlArgs.userGroupDetail(
    'Engineering',
    members: true,
  ),
  'appDetail': AbctlArgs.appDetail('Numbers'),
  'packageDetail': AbctlArgs.packageDetail('LOB'),
  'mdmServerDetail': AbctlArgs.mdmServerDetail('Built-in MDM'),
  'mdmServerDetail --devices': AbctlArgs.mdmServerDetail(
    'Built-in MDM',
    devices: true,
  ),
  'blueprintDetail': AbctlArgs.blueprintDetail('Fleet-A'),
  'configurationProfile': AbctlArgs.configurationProfile('c1'),
  'deviceStatus': AbctlArgs.deviceStatus('C02XYZ'),
  'activityStatus': AbctlArgs.activityStatus('act-42'),
  'plan': AbctlArgs.plan(),
  'plan git-as-truth': AbctlArgs.plan(
    gitSourceOfTruth: true,
    refresh: AbctlRefresh.full,
  ),
  'validate': AbctlArgs.validate(),
  'vppConfig': AbctlArgs.vppConfig(token: 'tok'),
  'vppAssets': AbctlArgs.vppAssets(token: 'tok'),
  'vppAssignments': AbctlArgs.vppAssignments(token: 'tok'),
  'vppUsers': AbctlArgs.vppUsers(token: 'tok'),
  'contextList': AbctlArgs.contextList(),
  'contextDetail': AbctlArgs.contextDetail('prod'),
  'contextDetail (current)': AbctlArgs.contextDetail(),
  // The writes. Every reachable ApplyOptions state is listed, because the allowlist test
  // is only as complete as this map — an option combination absent here is a `--prune`
  // nobody checked.
  'syncApply additive': AbctlArgs.syncApply(const ApplyOptions.additive()),
  'syncApply additive + deletes': AbctlArgs.syncApply(
    const ApplyOptions.additiveAllowingDeletes(),
  ),
  'syncApply git-as-truth': AbctlArgs.syncApply(
    const ApplyOptions.gitAuthoritative(
      refresh: AbctlRefresh.full,
      verify: AbctlVerify.none,
      limitWrites: 5,
    ),
  ),
  'seed': AbctlArgs.seed(),
  'createConfiguration': AbctlArgs.createConfiguration('WiFi'),
  'replaceConfiguration': AbctlArgs.replaceConfiguration('c1'),
  'deleteConfiguration': AbctlArgs.deleteConfiguration('c1'),
  'attachConfiguration': AbctlArgs.attachConfiguration(
    configId: 'c1',
    blueprint: 'Fleet',
  ),
  'detachConfiguration': AbctlArgs.detachConfiguration(
    configId: 'c1',
    blueprint: 'Fleet',
  ),
  'adoptMember': AbctlArgs.adoptMember(
    kind: AbctlMemberKind.config,
    name: 'WiFi.mobileconfig',
    blueprint: 'Fleet',
  ),
  'assign': AbctlArgs.assignment(
    action: AbctlAssignment.assign,
    server: 'Built-in MDM',
    serials: const ['C02AAA'],
  ),
  'unassign': AbctlArgs.assignment(
    action: AbctlAssignment.unassign,
    server: 'Built-in MDM',
    serials: const ['C02AAA'],
  ),
};
