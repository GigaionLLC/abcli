// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The client's behaviour against a canned runner: exit-code mapping, decode order, the per-verb
// budgets and the workspace cwd. Ported from `Tests/abguiTests/ContractTests.swift`, whose fake
// (`MockAbctlRunner`/`TappedRunner`) this file's `_FakeRunner` replaces — each case names the
// Swift test it comes from.
//
// The argv SHAPES live next door in abctl_args_contract_test.dart, which needs no fake at all.
// What is asserted here is the half a pure builder cannot prove: that the client actually calls
// those builders, threads the context and the workspace onto them, and spends the right budget.

import 'dart:convert';
import 'dart:typed_data';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/abctl_client.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reads decode through the models', () {
    // ContractTests.testVersionDecodesAndReadsCapabilities.
    test('version reads the capability tokens abgui gates on', () async {
      final runner = _FakeRunner(
        stdout:
            '{"version":"1.2.3","commit":"abc123",'
            '"buildTime":"2026-01-02T03:04:05Z","goVersion":"go1.26",'
            '"capabilities":["write-json","plan-json"]}',
      );
      final version = await AbctlClient(runner: runner).version();

      expect(version.version, '1.2.3');
      expect(version.has('write-json'), isTrue);
      expect(version.has('nope'), isFalse);
      expect(runner.argv, ['version', '-o', 'json']);
    });

    // ContractTests.testWhoamiDecodesSnakeCaseKeys.
    test('whoami decodes abctl\'s snake_case identity keys', () async {
      final runner = _FakeRunner(
        stdout:
            '{"authenticated":true,"client_id":"BUSINESSAPI.x",'
            '"api_base":"https://api","token_expires":"2026-01-01T00:00:00Z",'
            '"configurations":3,"blueprints":2}',
      );
      final who = await AbctlClient(runner: runner).whoami();

      expect(who.clientID, 'BUSINESSAPI.x');
      expect(who.apiBase, 'https://api');
      expect(who.configurations, 3);
    });

    // ContractTests.testEmptyListDecodesToEmptyArray / testPackagesUsesGetPackages.
    test('an empty collection is an empty list, not a failure', () async {
      final runner = _FakeRunner(stdout: '[]');
      final packages = await AbctlClient(runner: runner).packages();

      expect(packages, isEmpty);
      expect(runner.argv.take(2), ['get', 'packages']);
    });

    // ContractTests.testResourceAttributesDecode.
    test('a resource keeps its open attribute bag', () async {
      final runner = _FakeRunner(
        stdout:
            '[{"type":"configurations","id":"id1",'
            '"attributes":{"name":"WiFi-Corp","type":"CUSTOM_SETTING"}}]',
      );
      final list = await AbctlClient(runner: runner).configurations();

      expect(list, hasLength(1));
      expect(list.first.attr('name'), 'WiFi-Corp');
      expect(list.first.attr('missing'), isNull);
    });

    // ContractTests.testOSReleaseContractAndArguments.
    test('os-releases decodes the GDMF rows', () async {
      final runner = _FakeRunner(
        stdout:
            '[{"platform":"macOS","productVersion":"15.4","build":"24E1",'
            '"postingDate":"2026-07-01","expirationDate":"2026-12-01",'
            '"supportedDevices":["MacBookPro18,3"],"catalog":"managed",'
            '"expired":false}]',
      );
      final releases = await AbctlClient(runner: runner).osReleases();

      expect(runner.argv, ['get', 'os-releases', '-o', 'json']);
      expect(releases, hasLength(1));
      expect(releases[0].id, 'managed:macOS:24E1');
      expect(releases[0].supportedDevices, ['MacBookPro18,3']);
      expect(releases[0].expired, isFalse);
    });

    // ContractTests.testDeviceDetailAppleCareFlagAndDecode.
    test('the AppleCare opt-in reaches argv and its records decode', () async {
      final runner = _FakeRunner(
        stdout:
            '{"device":{"type":"orgDevices","id":"d1",'
            '"attributes":{"serialNumber":"C02XYZ"}},"assignedServer":null,'
            '"appleCare":[{"type":"appleCareCoverage","id":"cv1",'
            '"attributes":{"status":"ACTIVE"}}]}',
      );
      final detail = await AbctlClient(
        runner: runner,
      ).deviceDetail('C02XYZ', appleCare: true);

      expect(runner.argv, ['get', 'device', 'C02XYZ', '--applecare', '--json']);
      expect(detail.appleCare, hasLength(1));
      expect(detail.appleCare?.first.attr('status'), 'ACTIVE');
      expect(detail.assignedServer, isNull);
    });

    // ContractTests.testPlanDecodes / testEmptyPlanIsInSync.
    test('the plan decodes and an empty one reads as in-sync', () async {
      final runner = _FakeRunner(
        stdout:
            '{"configs":[{"name":"WiFi-Corp.mobileconfig",'
            '"action":"update-abm","detail":"changed in git"}],'
            '"blueprints":[{"blueprint":"Fleet-A","bp_id":"b1",'
            '"action":"attach-config","config":"WiFi-Corp.mobileconfig",'
            '"config_id":"c1","detail":"attach"}]}',
      );
      final client = AbctlClient(runner: runner);
      final plan = await client.plan();

      expect(plan.isEmpty, isFalse);
      expect(plan.changeCount, 2);
      expect(plan.blueprints.first.bpID, 'b1');

      runner.stdout = '{"configs":[],"blueprints":[]}';
      expect((await client.plan()).isEmpty, isTrue);
    });

    // ContractTests.testPlanArgsIncludeGitSourceOfTruth — the builder's output is pinned next
    // door; what matters here is that the client passes the caller's choices through to it.
    test('plan options reach abctl', () async {
      final runner = _FakeRunner(stdout: '{"configs":[],"blueprints":[]}');
      await AbctlClient(
        runner: runner,
      ).plan(gitSourceOfTruth: true, refresh: AbctlRefresh.full);

      expect(
        runner.argv,
        AbctlArgs.plan(gitSourceOfTruth: true, refresh: AbctlRefresh.full),
      );
    });

    // ContractTests.testVPPAssetDecodes / testVPPTokenIsPassedAsFlag.
    test('the VPP content token travels as a flag and assets decode', () async {
      final runner = _FakeRunner(
        stdout:
            '[{"name":"WhatsApp Messenger","adamId":"408709785",'
            '"availableCount":42,"totalCount":50,"deviceAssignable":true,'
            '"supportedPlatforms":["iOS","macOS"]}]',
      );
      final assets = await AbctlClient(runner: runner).vppAssets(token: 'sTok');

      expect(runner.argv, [
        'vpp',
        'assets',
        '-o',
        'json',
        '--vpp-token',
        'sTok',
      ]);
      expect(assets.single.adamId, '408709785');
      expect(assets.single.availableCount, 42);
      expect(assets.single.supportedPlatforms, ['iOS', 'macOS']);
    });

    test('a configuration profile comes back as raw XML, not JSON', () async {
      final runner = _FakeRunner(stdout: '<?xml version="1.0"?><plist/>');
      final xml = await AbctlClient(runner: runner).configurationProfile('c1');

      expect(runner.argv, ['get', 'configuration', 'c1', '--profile']);
      expect(xml, startsWith('<?xml'));
    });
  });

  group('exit codes', () {
    // ContractTests.testExitCodeMapping — exit 3 is abctl's "changes pending" verdict: drift
    // between git and the tenant, which is a NORMAL state to render as data. It gets its own
    // case precisely so a consumer cannot present drift as breakage, and this asserts the
    // client keeps it apart from the two real failures rather than collapsing "non-zero".
    test('exit 3 is changes-pending, not an error', () async {
      final runner = _FakeRunner(
        stdout: '{"configs":[],"blueprints":[]}',
        stderr: 'plan differs',
        code: 3,
      );

      Object? thrown;
      try {
        await AbctlClient(runner: runner).plan();
      } on AbctlError catch (error) {
        thrown = error;
      }

      expect(thrown, isA<AbctlChangesPending>());
      expect(thrown, isNot(isA<AbctlCliError>()));
      expect(thrown, isNot(isA<AbctlUsageError>()));
      expect((thrown! as AbctlError).message, 'changes pending.');
    });

    // ContractTests.testCliErrorPropagatesThroughClient — abctl already wrote the sentence for
    // a human, so stderr IS the message; paraphrasing it would lose Apple's own status text.
    test('exit 1 carries abctl\'s stderr verbatim', () async {
      final runner = _FakeRunner(stderr: 'API 403 (grant View)', code: 1);

      await expectLater(
        AbctlClient(runner: runner).whoami(),
        throwsA(
          isA<AbctlCliError>().having(
            (e) => e.message,
            'message',
            contains('403'),
          ),
        ),
      );
    });

    test('any other exit is an argv bug on our side', () async {
      // Cobra exits 2 for a usage error, which means abgui built a command abctl rejected —
      // a different bug report from "the tenant said no", hence a different case.
      final runner = _FakeRunner(stderr: 'unknown flag: --nope', code: 2);

      await expectLater(
        AbctlClient(runner: runner).devices(),
        throwsA(isA<AbctlUsageError>()),
      );
    });
  });

  group('validate decodes before it maps the exit code', () {
    // ContractTests.testValidateGoldenReportDecodesTotalsProfilesAndTreeIssues +
    // testValidateReportOnExitOneStillReturns. abctl exits 1 whenever the report says
    // ok:false and STILL prints the whole report on stdout; a failed verification has to
    // render as the list of files to fix, never as "abctl reported an error".
    test('a failing report on exit 1 is returned, not thrown', () async {
      final runner = _FakeRunner(
        stdout:
            '{"ok":false,"libDir":"gitops/lib","checked":3,"passed":2,'
            '"failed":1,"warnings":3,'
            '"profiles":[{"name":"VPN.mobileconfig","path":"gitops/lib/VPN.mobileconfig",'
            '"bytes":1048576,"ok":false,"identifier":"com.example.vpn",'
            '"payloadTypes":[],'
            '"errors":[{"code":"size-cap","message":"profile is 1.0 MiB; Apple Business '
            'rejects profiles of 1 MiB or larger."}],"warnings":[]}],'
            '"treeIssues":[{"level":"error","scope":"blueprints","target":"Fleet-A",'
            '"code":"missing-config","message":"blueprint references Kiosk.mobileconfig, '
            'which is not in lib/"}],'
            '"validator":"built-in"}',
        stderr: 'validation failed',
        code: 1,
      );

      final report = await AbctlClient(runner: runner).validateProfiles();

      expect(report.ok, isFalse);
      expect(report.failed, 1);
      expect(report.profiles.single.errors.map((e) => e.code), ['size-cap']);
      expect(report.treeIssues.single.isError, isTrue);
      // A failing file AND a broken blueprint reference are both things a human must look at.
      expect(report.problemCount, 2);
    });

    test('an external validator failure still returns a report', () async {
      // The third route to ok:false: abctl folds a non-zero $ABCTL_VALIDATOR exit into the
      // verdict without touching `failed` or adding a tree issue.
      final runner = _FakeRunner(
        stdout:
            '{"ok":false,"libDir":"gitops/lib","checked":1,"passed":1,'
            '"failed":0,"warnings":0,"profiles":[],"treeIssues":[],'
            '"validator":"external",'
            '"validatorCommand":"/usr/local/bin/mobileconfig-lint gitops/lib",'
            '"validatorExitCode":2,'
            '"validatorOutput":"WiFi-Corp.mobileconfig: unknown payload key\\n"}',
        code: 1,
      );

      final report = await AbctlClient(runner: runner).validateProfiles();

      expect(report.validatorFailed, isTrue);
      expect(report.validatorOutput, contains('unknown payload key'));
      expect(
        report.problemCount,
        1,
        reason: 'a report that is not ok can never count zero problems',
      );
    });

    // ContractTests.testValidateUndecodableStdoutOnExitOneThrowsCLIError — nothing decodable
    // means the RUN failed (a bad flag, an unreadable tree, an abctl too old to know --json),
    // so abctl's own stderr is the better message than an opaque decode failure.
    test('undecodable stdout on exit 1 surfaces stderr', () async {
      final runner = _FakeRunner(
        stdout: 'Error: unknown flag: --json\n',
        stderr: 'Error: unknown flag: --json',
        code: 1,
      );

      await expectLater(
        AbctlClient(runner: runner).validateProfiles(),
        throwsA(
          isA<AbctlCliError>().having(
            (e) => e.message,
            'message',
            contains('unknown flag'),
          ),
        ),
      );
    });

    // ContractTests.testValidateArgsRunInWorkspaceWithContext.
    test(
      'validate runs in the workspace, with the context, on its own budget',
      () async {
        final runner = _FakeRunner(
          stdout:
              '{"ok":true,"libDir":"gitops/lib","checked":0,"passed":0,'
              '"failed":0,"warnings":0,"profiles":[],"treeIssues":[],'
              '"validator":"built-in"}',
        );
        await AbctlClient(
          runner: runner,
          context: 'prod',
          workspace: '/work/ws',
        ).validateProfiles();

        expect(runner.argv, ['validate', '--json', '--context', 'prod']);
        // The tree being verified is the chosen workspace's — abctl roots gitops/ at its cwd.
        expect(runner.cwd, '/work/ws');
        expect(
          runner.timeout,
          greaterThanOrEqualTo(const Duration(seconds: 120)),
          reason: 'a big lib/ is parsed file by file',
        );
      },
    );
  });

  group('per-verb budgets', () {
    // ContractTests.testDeviceStatusGetsFanOutTimeout.
    test('status device gets the fan-out budget', () async {
      final runner = _FakeRunner(
        stdout:
            '{"device":{"type":"orgDevices","id":"d1","attributes":{}},'
            '"assignedServer":null,"blueprints":[],"mdm":null}',
      );
      await AbctlClient(runner: runner).deviceStatus('C02XYZ');

      expect(
        runner.timeout,
        greaterThanOrEqualTo(AbctlTimeouts.fanOut),
        reason: 'it fans out one relationship call per blueprint',
      );
    });

    // ContractTests.testFanOutFlagsGetExtendedTimeout — the opt-in flags are the fan-out, so
    // the budget follows the FLAG, not the verb. A too-small budget is a real defect with a
    // misleading symptom: the user sees "abctl ran for 60s", which reads as a broken feature.
    test(
      'the fan-out flags earn the bigger budget; the plain reads do not',
      () async {
        final group = _FakeRunner(
          stdout:
              '{"group":{"type":"userGroups","id":"g1",'
              '"attributes":{"name":"Engineering"}},"members":[]}',
        );
        final groupClient = AbctlClient(runner: group);
        await groupClient.userGroupDetail('Engineering', members: true);
        expect(group.timeout, AbctlTimeouts.fanOut);
        await groupClient.userGroupDetail('Engineering');
        expect(group.timeout, AbctlTimeouts.read);

        final server = _FakeRunner(
          stdout:
              '{"server":{"type":"mdmServers","id":"s1",'
              '"attributes":{"serverName":"Built-in MDM"}},"devices":[],'
              '"deviceCount":0}',
        );
        final serverClient = AbctlClient(runner: server);
        await serverClient.mdmServerDetail('Built-in MDM', devices: true);
        expect(server.timeout, AbctlTimeouts.fanOut);
        await serverClient.mdmServerDetail('Built-in MDM');
        expect(server.timeout, AbctlTimeouts.read);
      },
    );

    test('diff gets the tenant-scale plan budget', () async {
      final runner = _FakeRunner(stdout: '{"configs":[],"blueprints":[]}');
      await AbctlClient(runner: runner).plan();

      expect(runner.timeout, AbctlTimeouts.plan);
    });
  });

  group('the context and the workspace', () {
    // ContractTests.testContextIsThreadedAsFlag.
    test('every tenant verb runs in the workspace with the context tail', () async {
      final runner = _FakeRunner(stdout: '[]');
      final client = AbctlClient(
        runner: runner,
        context: 'prod',
        workspace: '/work/ws',
      );

      await client.devices();
      await client.users();

      for (final argv in runner.argvs) {
        expect(argv.skip(argv.length - 2), ['--context', 'prod']);
      }
      // Reads are mostly cwd-insensitive, but a workspace-local `.env` resolves the same way
      // for them as it already does for diff — one tenant per workspace, not one per verb.
      expect(runner.cwds, everyElement('/work/ws'));
    });

    // ContractTests.testSaveContextThreadsFlagsAndNeverAddsContextFlag — the store WRITES are
    // out of scope for this read-only release, but the invariant they pinned is not: a command
    // that manages the context store must never be scoped by one.
    test(
      'context-store reads never thread --context, whatever is selected',
      () async {
        final runner = _FakeRunner(
          stdout: '{"contexts":["prod"],"current":"prod"}',
        );
        final client = AbctlClient(
          runner: runner,
          context: 'some-selected-context',
          workspace: '/work/ws',
        );

        final list = await client.contextList();

        expect(list.contexts, ['prod']);
        expect(runner.argv, ['context', 'list', '-o', 'json']);
        expect(runner.argv, isNot(contains('--context')));
        // The store is ~/.abctl/contexts.yaml, not a tree, so it is not resolved against the
        // workspace — and it is local file I/O, so it gets the short control budget.
        expect(runner.cwd, isNull);
        expect(runner.timeout, AbctlTimeouts.control);
      },
    );

    // ContractTests.testContextDetailDecodesSnakeCaseAndKeyPath.
    test('context get decodes the client id and the key PATH', () async {
      final runner = _FakeRunner(
        stdout:
            '{"context":{"client_id":"BUSINESSAPI.aaa","key":"/keys/prod.pem",'
            '"api_base":"https://api-business.apple.com/v1/"},"name":"prod"}',
      );
      final detail = await AbctlClient(
        runner: runner,
      ).contextDetail(name: 'prod');

      expect(runner.argv, ['context', 'get', 'prod', '-o', 'json']);
      expect(detail.name, 'prod');
      expect(detail.context.clientID, 'BUSINESSAPI.aaa');
      // A PATH, never key material — that is why abctl takes the key this way at all.
      expect(detail.context.keyPath, '/keys/prod.pem');
    });

    // ContractTests.testValidatePreviewIsTheArgvThatActuallyRuns… +
    // testPreviewArgvThreadsTheContextExactlyLikeTheRun. A preview that drifts from the run is
    // worse than none: it teaches a command that never ran.
    test('the previewed argv is the argv that runs, context and all', () async {
      final runner = _FakeRunner(
        stdout:
            '{"ok":true,"libDir":"gitops/lib","checked":0,"passed":0,'
            '"failed":0,"warnings":0,"profiles":[],"treeIssues":[],'
            '"validator":"built-in"}',
      );

      final unset = AbctlClient(runner: runner, workspace: '/work/ws');
      await unset.validateProfiles();
      expect(
        unset.previewArgv(AbctlArgs.validate()),
        runner.argv,
        reason: 'an unset context must not preview a --context flag',
      );

      final scoped = AbctlClient(
        runner: runner,
        context: 'prod',
        workspace: '/work/ws',
      );
      await scoped.validateProfiles();
      expect(scoped.previewArgv(AbctlArgs.validate()), runner.argv);
      expect(runner.argv.skip(2), ['--context', 'prod']);
    });

    test('a cancel token reaches the runner', () async {
      // Cancellation is passed DOWN through signatures in this port (Dart has no structured
      // concurrency), so every layer has to forward it — a client method that dropped it would
      // produce a Cancel button that does nothing, silently.
      final runner = _FakeRunner(stdout: '[]');
      final cancel = CancelToken();
      await AbctlClient(runner: runner).blueprints(cancel: cancel);

      expect(identical(runner.cancels.single, cancel), isTrue);
    });
  });

  group('decode failures name the verb', () {
    // No Swift equivalent: `AbctlError.decode` wrapped a Foundation DecodingError, which names
    // the KEY. Here the parse failure is a FormatException whose message ("Unexpected
    // character" plus an offset) is useless on its own — which command produced it is the half
    // that makes the report actionable, and the half the decoder cannot know.
    test('stdout that is not JSON', () async {
      final runner = _FakeRunner(stdout: 'panic: runtime error\n');

      await expectLater(
        AbctlClient(runner: runner).configurations(),
        throwsA(
          isA<AbctlDecodeError>().having(
            (e) => e.message,
            'message',
            contains('get configurations'),
          ),
        ),
      );
    });

    test('JSON of the wrong shape', () async {
      // The models decode defensively — an absent key is a default, never a throw — so a list
      // where a document belongs would otherwise render as a detail sheet full of blanks with
      // nothing anywhere pointing at the cause.
      final runner = _FakeRunner(stdout: '[]');

      await expectLater(
        AbctlClient(runner: runner).blueprintDetail('Fleet-A'),
        throwsA(
          isA<AbctlDecodeError>().having(
            (e) => e.message,
            'message',
            contains('get blueprint'),
          ),
        ),
      );

      runner.stdout = '{"not":"a list"}';
      await expectLater(
        AbctlClient(runner: runner).devices(),
        throwsA(
          isA<AbctlDecodeError>().having(
            (e) => e.message,
            'message',
            contains('get devices'),
          ),
        ),
      );
    });
  });

  // ContractTests.testRecordingRunnerRecordsExactlyWhatTheClientSent — the seam end to end.
  // The record has to BE the argv the runner received, not a re-spelling of it, and has to
  // carry the cwd: a copied diff without the matching `cd` plans against the wrong tree.
  test('the recording runner records exactly what the client sent', () async {
    final inner = _FakeRunner(stdout: '{"configs":[],"blueprints":[]}');
    final started = <CommandRecord>[];
    final finished = <String, CommandStatus>{};
    final client = AbctlClient(
      runner: RecordingRunner(
        wrapped: inner,
        onStart: started.add,
        onFinish: (id, status) => finished[id] = status,
      ),
      context: 'prod',
      workspace: '/work/ws',
    );

    final plan = await client.plan(
      gitSourceOfTruth: true,
      refresh: AbctlRefresh.full,
    );

    expect(
      plan.isEmpty,
      isTrue,
      reason: 'the decorator must forward the payload untouched',
    );
    expect(started, hasLength(1));
    expect(started.single.argv, inner.argv);
    expect(
      started.single.argv,
      client.previewArgv(
        AbctlArgs.plan(gitSourceOfTruth: true, refresh: AbctlRefresh.full),
      ),
      reason: '…and that argv is the builder\'s, plus the context the run used',
    );
    expect(started.single.cwd, '/work/ws');
    expect(started.single.script, startsWith('cd /work/ws\n'));
    expect(finished[started.single.id], CommandStatus.succeeded);
  });
}

/// A runner that answers with canned bytes and records every invocation.
///
/// It records a LIST of each field rather than only the last, because several cases here call
/// twice through one client to prove the second call differs (the fan-out budgets, the
/// preview-parity pair) — and a fake that only remembers the last call cannot tell "both runs
/// used the big budget" from "the second one did".
class _FakeRunner implements AbctlRunner {
  _FakeRunner({this.stdout = '', this.stderr = '', this.code = 0});

  /// Mutable so one test can change the answer between two calls on the same client.
  String stdout;
  String stderr;
  int code;

  final List<List<String>> argvs = <List<String>>[];
  final List<String?> cwds = <String?>[];
  final List<Duration> timeouts = <Duration>[];
  final List<List<int>?> stdins = <List<int>?>[];
  final List<CancelToken?> cancels = <CancelToken?>[];

  List<String> get argv => argvs.last;
  String? get cwd => cwds.last;
  Duration get timeout => timeouts.last;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    argvs.add(args);
    cwds.add(cwd);
    timeouts.add(timeout);
    stdins.add(stdin);
    cancels.add(cancel);
    return AbctlResult(
      stdout: Uint8List.fromList(utf8.encode(stdout)),
      stderr: stderr,
      code: code,
    );
  }
}
