// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Decode tests against golden JSON captured from real `abctl … -o json`, ported from the Swift
// app's ContractTests/CSVDocumentTests/CommandRecordTests. These fixtures ARE the contract
// between the two halves: every key here is a `json:"…"` tag on a Go type, so a rename on
// either side breaks a test instead of silently emptying a screen.
//
// Two rules the whole file is built around:
//
//  1. A missing optional key must DECODE, never throw. abgui ships its own abctl, but a user
//     can point at an older binary, and a report that renders thinner beats one that crashes.
//     Every model therefore also gets a `{}` case below.
//  2. Absent and empty are different answers where abctl makes them different (`appleCare`,
//     `members`, `devices`), and the tests say so explicitly.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The formatter lives beside the runner it renders for (`abctl/`), while the record it renders
// is a model — see the consolidation note at the top of `models/command_record.dart`.
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/models/apply_result.dart';
import 'package:abgui/src/models/archive.dart';
import 'package:abgui/src/models/command_line_parser.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:abgui/src/models/command_timing.dart';
import 'package:abgui/src/models/contract.dart';
import 'package:abgui/src/models/csv_document.dart';
import 'package:abgui/src/models/inspect.dart';
import 'package:abgui/src/models/json.dart';
import 'package:abgui/src/models/json_value.dart';
import 'package:abgui/src/models/os_release.dart';
import 'package:abgui/src/models/plan.dart';
import 'package:abgui/src/models/read_only_kind.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/models/run_log_file.dart';
import 'package:abgui/src/models/sync_failure.dart';
import 'package:abgui/src/models/validation.dart';
import 'package:abgui/src/models/vpp.dart';
import 'package:abgui/src/models/write_outcome.dart';

Map<String, dynamic> obj(String json) => asJsonMap(jsonDecode(json));

const emptyPhases =
    r'"configs":{"outcomes":[],"writes":1,"errors":0,"skipped":0},'
    r'"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}';

void main() {
  group('contract — version, whoami, contexts', () {
    test('version decodes and reads capabilities', () {
      final version = VersionInfo.fromJson(
        obj(
          r'''{"version":"1.2.3","commit":"abc123","buildTime":"2026-01-02T03:04:05Z","goVersion":"go1.26","capabilities":["write-json","plan-json"]}''',
        ),
      );
      expect(version.version, '1.2.3');
      expect(version.has('write-json'), isTrue);
      expect(version.has('nope'), isFalse);
    });

    test('version without optional build identity still decodes', () {
      final version = VersionInfo.fromJson(
        obj(r'''{"version":"x","goVersion":"go1.26","capabilities":[]}'''),
      );
      expect(version.commit, isNull);
      expect(version.buildTime, isNull);
      expect(version.has('anything'), isFalse);
    });

    test('whoami decodes snake_case keys', () {
      final who = WhoamiResult.fromJson(
        obj(
          r'''{"authenticated":true,"client_id":"BUSINESSAPI.x","api_base":"https://api","token_expires":"2026-01-01T00:00:00Z","configurations":3,"blueprints":2}''',
        ),
      );
      expect(who.clientID, 'BUSINESSAPI.x');
      expect(who.apiBase, 'https://api');
      expect(who.configurations, 3);
      expect(who.authenticated, isTrue);
    });

    test('context list decodes', () {
      final list = ContextList.fromJson(
        obj(r'''{"contexts":["prod","staging"],"current":"prod"}'''),
      );
      expect(list.contexts, ['prod', 'staging']);
      expect(list.current, 'prod');
    });

    test('empty context list decodes', () {
      final list = ContextList.fromJson(
        obj(r'''{"contexts":[],"current":""}'''),
      );
      expect(list.contexts, isEmpty);
      expect(list.current, '');
    });

    test('context detail decodes snake_case and the key PATH', () {
      final detail = ContextDetail.fromJson(
        obj(
          r'''{"context":{"client_id":"BUSINESSAPI.aaa","key":"/keys/prod.pem","api_base":"https://api-business.apple.com/v1/"},"name":"prod"}''',
        ),
      );
      expect(detail.name, 'prod');
      expect(detail.context.clientID, 'BUSINESSAPI.aaa');
      expect(detail.context.keyPath, '/keys/prod.pem');
      expect(detail.context.apiBase, 'https://api-business.apple.com/v1/');
    });

    test('context detail without api_base decodes', () {
      final detail = ContextDetail.fromJson(
        obj(
          r'''{"context":{"client_id":"c","key":"/k.pem"},"name":"staging"}''',
        ),
      );
      expect(detail.context.apiBase, isNull);
      expect(detail.context.keyPath, '/k.pem');
    });
  });

  group('resource + the read-only tables', () {
    test('an empty list decodes to an empty array', () {
      expect(Resource.listFromJson(jsonDecode('[]')), isEmpty);
    });

    test('resource attributes decode', () {
      final list = Resource.listFromJson(
        jsonDecode(
          r'''[{"type":"configurations","id":"id1","attributes":{"name":"WiFi-Corp","type":"CUSTOM_SETTING"}}]''',
        ),
      );
      expect(list.length, 1);
      expect(list.first.attr('name'), 'WiFi-Corp');
      expect(list.first.attr('type'), 'CUSTOM_SETTING');
      expect(list.first.attr('missing'), isNull);
    });

    // The attribute is `managedAppleAccount`. A fixture that says `managedAppleId` invents its
    // own input — Apple never emits that key — and can only ever confirm the bug it was
    // written beside.
    test('user roles decode and drive the columns', () {
      final user = Resource.fromJson(
        obj(
          r'''{"type":"users","id":"u1","attributes":{"firstName":"Ada","lastName":"Lovelace","managedAppleAccount":"ada@x.appleid.com","email":"ada@corp.example","status":"ACTIVE","roles":[{"role":"Administrator","organizationalUnit":"HQ"},{"role":"Manager"}]}}''',
        ),
      );
      expect(user.roleNames(), 'Administrator, Manager');
      final columns = ReadOnlyKind.users.columns;
      String column(String header) =>
          columns.firstWhere((c) => c.header == header).value(user);
      expect(column('Name'), 'Ada Lovelace');
      expect(column('Roles'), 'Administrator, Manager');
      // The managed account WINS over the corporate email — that is the distinction the
      // column's header promises, and reading `email` first would quietly break it again.
      expect(column('Managed Apple ID'), 'ada@x.appleid.com');
    });

    test('a user with no managed account falls back to email', () {
      final user = Resource.fromJson(
        obj(
          r'''{"type":"users","id":"u2","attributes":{"firstName":"Grace","lastName":"Hopper","email":"grace@corp.example"}}''',
        ),
      );
      final column = ReadOnlyKind.users.columns.firstWhere(
        (c) => c.header == 'Managed Apple ID',
      );
      expect(column.value(user), 'grace@corp.example');
    });

    // A non-string attribute is NOT rendered as text: the apps table's Custom column reads a
    // boolean and must show the em dash, exactly as the Swift accessor did.
    test('a non-string attribute reads as absent', () {
      final app = Resource.fromJson(
        obj(
          r'''{"type":"apps","id":"a1","attributes":{"name":"Numbers","isCustomApp":false}}''',
        ),
      );
      expect(app.attr('isCustomApp'), isNull);
      final column = ReadOnlyKind.apps.columns.firstWhere(
        (c) => c.header == 'Custom',
      );
      expect(column.value(app), '—');
    });

    test('a resource with no attributes still renders every column', () {
      final bare = Resource.fromJson(
        obj(r'''{"type":"orgDevices","id":"d9"}'''),
      );
      expect(bare.attributes, isNull);
      expect(bare.roleNames(), '');
      expect(bare.displayName(), 'd9');
      for (final kind in ReadOnlyKind.browsable) {
        for (final column in kind.columns) {
          expect(
            column.value(bare),
            isNotEmpty,
            reason: '${kind.wire}/${column.header} blanked on a bare resource',
          );
        }
      }
    });

    test('an unknown persisted kind degrades instead of throwing', () {
      expect(ReadOnlyKind.fromWire('mdmServers'), ReadOnlyKind.mdmServers);
      expect(ReadOnlyKind.fromWire('vpp-assets'), ReadOnlyKind.unknown);
      expect(ReadOnlyKind.browsable.contains(ReadOnlyKind.unknown), isFalse);
      expect(ReadOnlyKind.browsable.length, 8);
    });

    test('JSONValue keeps unknown shapes and compares by value', () {
      final a = JSONValue.fromJson(
        jsonDecode(
          r'''{"name":"x","nested":{"k":[1,2,3]},"flag":true,"nothing":null}''',
        ),
      );
      final b = JSONValue.fromJson(
        jsonDecode(
          r'''{"name":"x","nested":{"k":[1,2,3]},"flag":true,"nothing":null}''',
        ),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.string('name'), 'x');
      expect(a.string('flag'), isNull, reason: 'a bool is not a string');
      expect(a.array('missing'), isNull);
      expect(a.object('nested')?.array('k')?.length, 3);
    });
  });

  group('plan — abctl diff --json', () {
    test('plan decodes', () {
      final plan = Plan.fromJson(
        obj(r'''
        {"configs":[{"name":"WiFi-Corp.mobileconfig","action":"update-abm","detail":"changed in git"}],
         "blueprints":[{"blueprint":"Fleet-A","bp_id":"b1","action":"attach-config","config":"WiFi-Corp.mobileconfig","config_id":"c1","detail":"attach"}]}
      '''),
      );
      expect(plan.isEmpty, isFalse);
      expect(plan.changeCount, 2);
      expect(plan.configs.first.action, 'update-abm');
      expect(plan.blueprints.first.bpID, 'b1');
      expect(plan.blueprints.first.config, 'WiFi-Corp.mobileconfig');
    });

    test('an empty plan is in sync', () {
      final plan = Plan.fromJson(obj(r'''{"configs":[],"blueprints":[]}'''));
      expect(plan.isEmpty, isTrue);
    });

    // Older abctl builds emitted null for an empty list, and the key can be missing entirely.
    test('null/absent plan collections decode as empty, not as a throw', () {
      expect(
        Plan.fromJson(obj(r'''{"configs":null,"blueprints":null}''')).isEmpty,
        isTrue,
      );
      expect(Plan.fromJson(obj('{}')).isEmpty, isTrue);
    });

    test('an attach with no member id counts as blocked', () {
      final plan = Plan.fromJson(
        obj(r'''
        {"configs":[],
         "blueprints":[{"blueprint":"Fleet","action":"attach-config","config":"New.mobileconfig","detail":"blocked: config is listed on this blueprint but has no ABM id"},
                       {"blueprint":"Fleet","action":"attach-config","config":"WiFi.mobileconfig","config_id":"c1","detail":"attach"}]}
      '''),
      );
      expect(plan.changeCount, 2);
      expect(plan.actionableChangeCount, 1);
      expect(plan.blockedChangeCount, 1);
      expect(plan.blueprints[0].isActionable, isFalse);
      expect(plan.blueprints[1].isActionable, isTrue);
    });

    /// Rows are classified by PREFIX across all six member collections. Spelling only the
    /// `-config` pair made every app/package/device/user/group row read as blocked.
    test('row classification covers every member collection', () {
      final rows = Plan.fromJson(
        obj(r'''
        {"configs":[],
         "blueprints":[{"blueprint":"Fleet","action":"detach-app","config":"Pages","config_id":"a1","detail":"d"},
                       {"blueprint":"Fleet","action":"adopt-config","config":"WiFi.mobileconfig","config_id":"c1","detail":"d"},
                       {"blueprint":"Fleet","action":"attach-user","config":"a@b.com","detail":"blocked"},
                       {"blueprint":"Fleet","action":"blueprint-adopt","detail":"reported"}]}
      '''),
      ).blueprints;

      expect(rows[0].isDetach, isTrue);
      expect(rows[0].isActionable, isTrue);
      expect(rows[0].memberKind, 'app');

      expect(rows[1].isAdopt, isTrue);
      expect(rows[1].isActionable, isTrue);
      expect(rows[1].memberKind, 'config');

      expect(rows[2].isAttach, isTrue);
      expect(
        rows[2].isActionable,
        isFalse,
        reason: 'an attach with no member id is still blocked',
      );

      // The blueprint-level adopt is a REPORTED row about the blueprint, not a member verb.
      expect(rows[3].isAdopt, isFalse);
      expect(rows[3].memberKind, isNull);
      expect(rows[3].isActionable, isFalse);
    });

    test('the pull family is counted as a local write', () {
      final plan = Plan.fromJson(
        obj(r'''
        {"configs":[{"name":"A","action":"pull-git","detail":""},
                    {"name":"B","action":"delete-git","detail":""},
                    {"name":"C","action":"update-abm","detail":""}],
         "blueprints":[{"blueprint":"Fleet","action":"adopt-config","config":"A","detail":""}]}
      '''),
      );
      expect(plan.localChangeCount, 3);
    });
  });

  group('write outcomes', () {
    test('a create outcome decodes', () {
      final outcome = WriteOutcome.fromJson(
        obj(
          r'''{"action":"create","name":"WiFi.mobileconfig","id":"id-9","status":"done","treeUpdated":true}''',
        ),
      );
      expect(outcome.action, 'create');
      expect(outcome.id, 'id-9');
      expect(outcome.treeUpdated, isTrue);
      expect(outcome.treeWarning, isNull);
    });

    test('a delete outcome decodes its archive path', () {
      final outcome = WriteOutcome.fromJson(
        obj(
          r'''{"action":"delete","name":"Old.mobileconfig","id":"id-1","status":"done","archive":"gitops/archive/Old/ts.mobileconfig","treeUpdated":true}''',
        ),
      );
      expect(outcome.action, 'delete');
      expect(outcome.archive, 'gitops/archive/Old/ts.mobileconfig');
    });

    /// A tenant write whose local tree update failed exits 0 and reports treeUpdated:false. It
    /// used to report true unconditionally, which is how a green attach left git untouched.
    test('a tree error surfaces as a warning, not as a success', () {
      final failed = WriteOutcome.fromJson(
        obj(r'''
        {"action":"attach","name":"WiFi.mobileconfig","id":"c1","status":"done","blueprint":"Fleet",
         "treeUpdated":false,"treeError":"mkdir /gitops/blueprints: read-only file system"}
      '''),
      );
      expect(failed.treeWarning, isNotNull);
      expect(failed.treeWarning, contains('read-only file system'));
      expect(failed.treeWarning, contains('keep showing as drift'));

      // A clean write says nothing, and neither does an older abctl that omits the field.
      final clean = WriteOutcome.fromJson(
        obj(
          r'''{"action":"attach","name":"WiFi.mobileconfig","status":"done","treeUpdated":true}''',
        ),
      );
      expect(clean.treeWarning, isNull);
    });

    test('an empty document decodes with conservative defaults', () {
      final bare = WriteOutcome.fromJson(obj('{}'));
      expect(bare.treeUpdated, isFalse);
      expect(bare.id, isNull);
      expect(
        bare.treeWarning,
        isNull,
        reason: 'no treeError means nothing to warn about',
      );
    });

    /// The read-back verdict — the field that answers "was the 2xx proof?". Apple accepts a
    /// write carrying an out-of-spec profile and then silently keeps the old bytes, so abctl
    /// re-reads after every create/replace and records what was actually stored
    /// (`internal/reconcile/apply.go`). `confirmed` and `unconfirmed` are DIFFERENT CLAIMS and
    /// the model must not let a caller collapse them: one is evidence, the other is its absence.
    test('a read-back verdict is proof only when it says confirmed', () {
      final confirmed = WriteOutcome.fromJson(
        obj(
          r'''{"action":"replace","name":"WiFi.mobileconfig","id":"c1","status":"done","treeUpdated":true,"verified":"confirmed"}''',
        ),
      );
      expect(confirmed.confirmedStored, isTrue);
      expect(confirmed.unconfirmedWarning, isNull);

      final unconfirmed = WriteOutcome.fromJson(
        obj(
          r'''{"action":"replace","name":"WiFi.mobileconfig","id":"c1","status":"done","treeUpdated":true,"verified":"unconfirmed"}''',
        ),
      );
      expect(unconfirmed.confirmedStored, isFalse);
      expect(unconfirmed.unconfirmedWarning, isNotNull);
      expect(
        unconfirmed.unconfirmedWarning,
        contains('not evidence the write failed'),
        reason:
            'unconfirmed means the read-back gave no answer — reporting it as a '
            'failure sends an operator chasing a write that very likely landed',
      );

      // An older abctl omits the field entirely. Silence is not a pass, so it is neither
      // confirmed nor the unconfirmed sentence — the UI is left to say that nothing was
      // reported, which is the only true statement available.
      final silent = WriteOutcome.fromJson(
        obj(
          r'''{"action":"create","name":"WiFi.mobileconfig","status":"done","treeUpdated":true}''',
        ),
      );
      expect(silent.confirmedStored, isFalse);
      expect(silent.unconfirmedWarning, isNull);
      expect(silent.verified, isNull);
    });
  });

  group('apply result — sync --apply --json', () {
    test('the receipt decodes and counts both phases', () {
      final result = ApplyResult.fromJson(
        obj(r'''
        {"configs":{"outcomes":[{"name":"WiFi.mobileconfig","action":"update","status":"done","detail":"PATCH","archive":"a/b"}],"writes":1,"errors":0,"skipped":0},
         "blueprints":{"outcomes":[{"blueprint":"Fleet","config":"WiFi.mobileconfig","action":"attach","status":"done","detail":"attached"}],"writes":1,"errors":0,"skipped":0}}
      '''),
      );
      expect(result.totalWrites, 2);
      expect(result.totalErrors, 0);
      expect(result.rows.length, 2);
      // A blueprint row names itself with `blueprint` (+ `config`); folding both spellings
      // into `name` is what lets one row type report both phases.
      expect(
        result.rows.any((r) => r.name == 'Fleet / WiFi.mobileconfig'),
        isTrue,
      );
      expect(result.rows.first.archive, 'a/b');
    });

    test('a blueprint-level row falls back to the blueprint name alone', () {
      final row = OutcomeRow.fromJson(
        obj(
          r'''{"blueprint":"Fleet","action":"blueprint-new","status":"done","detail":"created"}''',
        ),
      );
      expect(row.name, 'Fleet');
      expect(row.failed, isFalse);
    });

    /// abctl publishes its verdict as DATA (`internal/cli/phase1.go` verificationReport). abgui
    /// used to re-derive it by grepping stderr for the word FAILED against a hand-maintained
    /// list of abctl's narration strings — so rewording one Go sentence silently downgraded the
    /// GUI's verdict. Decoding the key is what makes that impossible.
    test('the verification verdict decodes', () {
      final result = ApplyResult.fromJson(
        obj('''
        {$emptyPhases,
         "verification":{"mode":"targeted","written":3,"verified":2,
           "mismatches":[{"name":"WiFi.mobileconfig","detail":"still differs","observed":true}]}}
      '''),
      );
      final verification = result.verification!;
      expect(verification.mode, 'targeted');
      expect(verification.written, 3);
      expect(verification.verified, 2);
      expect(verification.hasMismatches, isTrue);
      expect(verification.headline, contains('did not land'));
    });

    /// A write Apple ACKNOWLEDGED and dropped is the whole reason this exists: every counter
    /// reads clean and the run still failed. `observed` is what separates that from a write
    /// abctl merely could not check, and collapsing the two would report a network blip as data
    /// loss — abctl keeps them apart deliberately.
    test('observed separates a dropped write from an unchecked one', () {
      final dropped = ApplyResult.fromJson(
        obj('''
        {$emptyPhases,
         "verification":{"mode":"targeted","written":1,"verified":0,
           "mismatches":[{"name":"A","detail":"stored profile still differs","observed":true}]}}
      '''),
      );
      expect(dropped.verification!.mismatches.first.observed, isTrue);
      expect(dropped.verification!.headline, contains('did not land'));

      final unchecked = ApplyResult.fromJson(
        obj('''
        {$emptyPhases,
         "verification":{"mode":"targeted","written":1,"verified":0,
           "mismatches":[{"name":"A","detail":"read-back failed","observed":false}]}}
      '''),
      );
      expect(unchecked.verification!.mismatches.first.observed, isFalse);
      expect(
        unchecked.verification!.headline,
        contains('could not be checked'),
      );
      expect(unchecked.verification!.unchecked, 0);
    });

    /// `--verify=none` checked nothing; that is not a failure and must not read as one.
    test('verify=none is not a failure', () {
      final result = ApplyResult.fromJson(
        obj(
          '{$emptyPhases,"verification":{"mode":"none","written":2,"verified":0,"mismatches":[]}}',
        ),
      );
      expect(result.verification!.hasMismatches, isFalse);
      expect(result.verification!.headline, contains('not verified'));
      expect(
        result.verification!.unchecked,
        2,
        reason: 'nothing was checked, so nothing was established either way',
      );
    });

    /// An older abctl — or a run that died before verification — emits no key at all. That must
    /// decode, not throw, or the GUI loses the per-item receipt as well as the verdict.
    test('an absent verification key decodes to null', () {
      final result = ApplyResult.fromJson(obj('{$emptyPhases}'));
      expect(result.verification, isNull);
      expect(result.totalWrites, 1);
    });

    test('a verification with no keys at all still answers', () {
      final result = ApplyResult.fromJson(
        obj('{$emptyPhases,"verification":{}}'),
      );
      expect(result.verification!.mode, 'unknown');
      expect(result.verification!.hasMismatches, isFalse);
      expect(result.verification!.written, 0);
    });

    test('an empty receipt decodes to empty phases', () {
      final result = ApplyResult.fromJson(obj('{}'));
      expect(result.rows, isEmpty);
      expect(result.totalWrites, 0);
      expect(result.totalErrors, 0);
    });
  });

  group('validation — abctl validate --json', () {
    // The golden payload: every key is a `json:"…"` tag on the Go report types. Note that the
    // totals field is tagged `warnings` while a profile's `warnings` is the issue ARRAY — same
    // word, two shapes, which is exactly why it is pinned here.
    const golden = r'''
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
    ''';

    test('the golden report decodes totals, profiles and tree issues', () {
      final report = ValidationReport.fromJson(obj(golden));
      expect(report.ok, isFalse);
      expect(report.libDir, 'gitops/lib');
      expect(report.checked, 3);
      expect(report.passed, 2);
      expect(report.failed, 1);
      expect(
        report.warnings,
        3,
      ); // 2 profile warnings + 1 warning-level tree issue
      expect(report.profiles.length, 3);
      expect(
        report.profiles.map((p) => p.id).toSet().length,
        3,
        reason: 'the profile list needs one stable id per row',
      );

      expect(report.profiles[0].identifier, 'com.example.wifi');
      expect(report.profiles[0].displayName, 'WiFi Corp');
      expect(report.profiles[0].payloadTypes, ['com.apple.wifi.managed']);

      // A failing profile carries every reason it failed, in the order abctl found them.
      final failing = report.profiles[1];
      expect(failing.ok, isFalse);
      expect(failing.bytes, 1048576);
      expect(failing.errors.map((e) => e.code).toList(), [
        'size-cap',
        'missing-payload-content',
      ]);
      expect(failing.errors[0].message, contains('1 MiB'));
      expect(
        failing.displayName,
        isNull,
        reason:
            'displayName is omitempty on the Go side, so it decodes as null',
      );
      expect(failing.payloadTypes, isEmpty);

      // Warnings never fail a profile — the row stays ok, only the counters move.
      final warned = report.profiles[2];
      expect(warned.ok, isTrue);
      expect(warned.errors, isEmpty);
      expect(warned.passedWithWarnings, isTrue);
      expect(warned.warnings.map((w) => w.code).toList(), [
        'missing-display-name',
        'missing-payload-uuid',
      ]);

      // The high-value pre-sync check: a blueprint pointing at a config that isn't in lib/
      // (sync would silently skip it), plus a warning-level tree issue that must not read as
      // an error in the sheet.
      expect(report.treeIssues.length, 2);
      final missingConfig = report.treeIssues[0];
      expect(missingConfig.isError, isTrue);
      expect(missingConfig.scope, 'blueprints');
      expect(missingConfig.target, 'Fleet-A');
      expect(missingConfig.code, 'missing-config');
      expect(missingConfig.message, contains('Kiosk.mobileconfig'));
      expect(report.treeIssues[1].isError, isFalse);
      expect(report.treeIssues[1].code, 'ignored-file');

      expect(report.validator, 'built-in');
      expect(report.validatorCommand, isNull);
      expect(report.validatorExitCode, isNull);
      expect(report.validatorFailed, isFalse);

      // What the sheets count: a failing file AND a broken blueprint reference are both
      // problems the user has to look at, even though only one is a failed profile.
      expect(report.problemCount, 2);
      expect(report.errorCount, 3, reason: '2 profile errors + 1 tree error');
    });

    /// The `$ABCTL_VALIDATOR` path, where a non-zero validator exit folds into ok:false even
    /// though every built-in structural check passed — the third, otherwise invisible, route
    /// to a failed report.
    test('an external validator failure is counted as a problem', () {
      final report = ValidationReport.fromJson(
        obj(r'''
        {"ok":false,"libDir":"gitops/lib","checked":1,"passed":1,"failed":0,"warnings":0,
         "profiles":[{"name":"WiFi-Corp.mobileconfig","path":"gitops/lib/WiFi-Corp.mobileconfig","bytes":2048,"ok":true,
                      "identifier":"com.example.wifi","payloadTypes":["com.apple.wifi.managed"],"errors":[],"warnings":[]}],
         "treeIssues":[],
         "validator":"external","validatorCommand":"/usr/local/bin/mobileconfig-lint gitops/lib",
         "validatorExitCode":2,"validatorOutput":"WiFi-Corp.mobileconfig: unknown payload key\n"}
      '''),
      );
      expect(report.ok, isFalse);
      expect(
        report.profiles.every((p) => p.ok),
        isTrue,
        reason: 'the built-in pass still ran and passed',
      );
      expect(report.validator, 'external');
      expect(report.usesExternalValidator, isTrue);
      expect(
        report.validatorCommand,
        '/usr/local/bin/mobileconfig-lint gitops/lib',
      );
      expect(report.validatorExitCode, 2);
      expect(report.validatorOutput, contains('unknown payload key'));
      expect(report.validatorFailed, isTrue);
      expect(report.failed, 0);
      expect(report.treeErrors, isEmpty);
      expect(
        report.problemCount,
        1,
        reason: 'a report that is not ok can never count zero problems',
      );
    });

    /// A bundled abctl that predates the newer keys must not crash the sheet: absent
    /// collections decode empty and absent optionals decode null, so the views can read them
    /// unconditionally.
    test('an older report decodes with safe defaults', () {
      final report = ValidationReport.fromJson(
        obj(r'''
        {"ok":true,"libDir":"gitops/lib","checked":1,"passed":1,"failed":0,"warnings":0,
         "profiles":[{"name":"WiFi-Corp.mobileconfig","path":"gitops/lib/WiFi-Corp.mobileconfig","bytes":2048,"ok":true}],
         "validator":"built-in"}
      '''),
      );
      expect(report.ok, isTrue);
      expect(
        report.treeIssues,
        isEmpty,
        reason:
            'an absent treeIssues key is an empty section, not a decode failure',
      );
      expect(report.validatorCommand, isNull);
      expect(report.validatorExitCode, isNull);
      expect(report.validatorOutput, isNull);
      final profile = report.profiles.single;
      expect(profile.payloadTypes, isEmpty);
      expect(profile.errors, isEmpty);
      expect(profile.warnings, isEmpty);
      expect(profile.identifier, isNull);
      expect(profile.displayName, isNull);
    });

    /// Every total is derivable from the rows, so a payload that omits one still adds up
    /// instead of reporting a confident zero — and `ok` is answered the way abctl answers it.
    test('missing totals are derived from the rows', () {
      final report = ValidationReport.fromJson(
        obj(r'''
        {"libDir":"gitops/lib",
         "profiles":[{"name":"A","path":"lib/A","errors":[{"code":"x","message":"m"}]},
                     {"name":"B","path":"lib/B","warnings":[{"code":"w","message":"m"}]}],
         "treeIssues":[{"level":"warning","scope":"lib","code":"ignored-file","message":"m"}]}
      '''),
      );
      expect(report.checked, 2);
      expect(report.passed, 1, reason: 'B has no errors, so it passed');
      expect(report.failed, 1, reason: 'A has an error, so it failed');
      expect(
        report.warnings,
        2,
        reason: '1 profile warning + 1 warning-level tree issue',
      );
      expect(report.ok, isFalse, reason: 'a profile failed');
      expect(report.validator, 'built-in');
      expect(report.problemCount, 1);
    });

    test('an unclassifiable tree issue is shown as an error', () {
      final issue = TreeIssue.fromJson(obj(r'''{"code":"mystery"}'''));
      expect(
        issue.isError,
        isTrue,
        reason:
            'a verification tool must not downgrade what it does not understand',
      );
    });

    test('an empty report decodes', () {
      final report = ValidationReport.fromJson(obj('{}'));
      expect(report.ok, isTrue, reason: 'nothing checked, nothing wrong');
      expect(report.profiles, isEmpty);
      expect(report.problemCount, 0);
    });
  });

  group('inspection payloads', () {
    test('device detail decodes its assigned server', () {
      final detail = DeviceDetail.fromJson(
        obj(
          r'''{"device":{"type":"orgDevices","id":"d1","attributes":{"serialNumber":"C02XYZ","deviceModel":"MacBook Pro","status":"ASSIGNED"}},"assignedServer":{"type":"mdmServers","id":"s1","attributes":{"serverName":"Built-in MDM"}}}''',
        ),
      );
      expect(detail.device.attr('serialNumber'), 'C02XYZ');
      expect(detail.device.attr('deviceModel'), 'MacBook Pro');
      expect(detail.assignedServer?.attr('serverName'), 'Built-in MDM');
      expect(
        detail.appleCare,
        isNull,
        reason: 'the appleCare key is absent without --applecare',
      );
    });

    test('an unassigned device has a null server', () {
      final detail = DeviceDetail.fromJson(
        obj(
          r'''{"device":{"type":"orgDevices","id":"d1","attributes":{"serialNumber":"C02XYZ","status":"UNASSIGNED"}},"assignedServer":null}''',
        ),
      );
      expect(detail.assignedServer, isNull);
    });

    test('appleCare coverage decodes when asked for', () {
      final detail = DeviceDetail.fromJson(
        obj(
          r'''{"device":{"type":"orgDevices","id":"d1","attributes":{"serialNumber":"C02XYZ"}},"assignedServer":null,"appleCare":[{"type":"appleCareCoverage","id":"cv1","attributes":{"description":"AppleCare+","status":"ACTIVE","endDateTime":"2027-01-01T00:00:00Z"}}]}''',
        ),
      );
      expect(detail.appleCare?.length, 1);
      expect(detail.appleCare?.first.attr('status'), 'ACTIVE');
    });

    // Absent vs empty: asked-and-none is not the same answer as never-asked.
    test('an empty appleCare array is not the same as an absent one', () {
      final asked = DeviceDetail.fromJson(
        obj(r'''{"device":{"type":"orgDevices","id":"d1"},"appleCare":[]}'''),
      );
      expect(asked.appleCare, isNotNull);
      expect(asked.appleCare, isEmpty);
    });

    test('the enrolled-device list decodes', () {
      final devices = Resource.listFromJson(
        jsonDecode(
          r'''[{"type":"mdmDevices","id":"m1","attributes":{"serialNumber":"C02XYZ","deviceName":"Kim's Mac","productFamily":"Mac","enrolledUserId":"u1"}}]''',
        ),
      );
      expect(devices.length, 1);
      expect(devices.first.attr('deviceName'), "Kim's Mac");
      expect(devices.first.attr('enrolledUserId'), 'u1');
    });

    test('mdm device detail decodes the posture bag', () {
      final detail = MDMDeviceDetail.fromJson(
        obj(
          r'''{"device":{"type":"mdmDevices","id":"m1","attributes":{"serialNumber":"C02XYZ","deviceName":"Kim's Mac","productFamily":"Mac"}},"details":{"type":"mdmDeviceDetails","id":"m1","attributes":{"platform":"macOS","osVersion":"15.5","isFileVaultEnabled":true,"isFirewallEnabled":false,"lastCheckInDateTime":"2026-07-01T00:00:00Z","storageFreeCapacity":128000000000,"storageTotalCapacity":512000000000,"deviceLockStatus":"UNLOCKED"}}}''',
        ),
      );
      expect(detail.device.attr('deviceName'), "Kim's Mac");
      expect(detail.details.attr('osVersion'), '15.5');
      expect(detail.details.attr('deviceLockStatus'), 'UNLOCKED');
    });

    test('a user detail is a plain resource', () {
      final user = Resource.fromJson(
        obj(
          r'''{"type":"users","id":"u1","attributes":{"firstName":"Ada","lastName":"Lovelace","email":"ada@example.com","managedAppleAccount":"ada@x.appleid.com","status":"ACTIVE","isExternalUser":false,"roleOuList":[{"roleName":"Administrator","ouId":"ou1"}]}}''',
        ),
      );
      expect(user.attr('email'), 'ada@example.com');
      expect(user.attr('managedAppleAccount'), 'ada@x.appleid.com');
    });

    test('user group members decode', () {
      final detail = UserGroupDetail.fromJson(
        obj(
          r'''{"group":{"type":"userGroups","id":"g1","attributes":{"name":"Engineering","totalMemberCount":2}},"members":["ada@example.com","grace@example.com"]}''',
        ),
      );
      expect(detail.group.attr('name'), 'Engineering');
      expect(detail.members, ['ada@example.com', 'grace@example.com']);
    });

    test('a group without --members has no member list at all', () {
      final detail = UserGroupDetail.fromJson(
        obj(
          r'''{"group":{"type":"userGroups","id":"g1","attributes":{"name":"Engineering"}}}''',
        ),
      );
      expect(
        detail.members,
        isNull,
        reason: 'the members key is absent without --members',
      );
    });

    test('app and package details are plain resources', () {
      final app = Resource.fromJson(
        obj(
          r'''{"type":"apps","id":"a1","attributes":{"name":"Numbers","bundleId":"com.apple.numbers","version":"14.1","isCustomApp":false,"platforms":["macOS","iOS"]}}''',
        ),
      );
      expect(app.attr('bundleId'), 'com.apple.numbers');
      expect(app.attr('version'), '14.1');

      final pkg = Resource.fromJson(
        obj(
          r'''{"type":"packages","id":"p1","attributes":{"name":"LOB Installer","bundleId":"com.example.lob","version":"2.0","isCustomApp":true}}''',
        ),
      );
      expect(pkg.attr('bundleId'), 'com.example.lob');
      expect(pkg.attr('name'), 'LOB Installer');
    });

    test('mdm server devices decode', () {
      final detail = MDMServerDetail.fromJson(
        obj(
          r'''{"server":{"type":"mdmServers","id":"s1","attributes":{"serverName":"Built-in MDM","serverType":"MDM"}},"devices":["C02AAA","C02BBB"],"deviceCount":2}''',
        ),
      );
      expect(detail.server.attr('serverName'), 'Built-in MDM');
      expect(detail.devices, ['C02AAA', 'C02BBB']);
      expect(detail.deviceCount, 2);
    });

    test('a server without --devices carries neither list nor count', () {
      final detail = MDMServerDetail.fromJson(
        obj(
          r'''{"server":{"type":"mdmServers","id":"s1","attributes":{"serverName":"Built-in MDM"}}}''',
        ),
      );
      expect(detail.devices, isNull);
      expect(detail.deviceCount, isNull);
    });

    test('blueprint detail decodes every relationship', () {
      final detail = BlueprintDetail.fromJson(
        obj(r'''
        {"blueprint":{"type":"blueprints","id":"b1","attributes":{"name":"Fleet-A","status":"ACTIVE"}},
         "configs":1,"apps":2,"devices":1,"appIds":["a1","a2"],"appLicenseDeficient":true,
         "relationships":{"configurations":["WiFi-Corp.mobileconfig"],"apps":["Numbers","Pages"],"packages":[],
                          "orgDevices":["C02AAA"],"users":[],"userGroups":["Engineering"]}}
      '''),
      );
      expect(detail.blueprint.attr('name'), 'Fleet-A');
      expect(detail.configs, 1);
      expect(detail.apps, 2);
      expect(detail.appIds, ['a1', 'a2']);
      expect(detail.appLicenseDeficient, isTrue);
      expect(detail.relationships['orgDevices'], ['C02AAA']);
      expect(detail.relationships['packages'], isEmpty);
      // Every key abctl emits is covered by the display order the sheets iterate.
      expect(
        detail.relationships.keys.toSet(),
        BlueprintDetail.relationshipOrder.toSet(),
      );
    });

    test('device status decodes membership and posture', () {
      final report = DeviceStatusReport.fromJson(
        obj(r'''
        {"device":{"type":"orgDevices","id":"d1","attributes":{"serialNumber":"C02XYZ","status":"ASSIGNED"}},
         "assignedServer":{"type":"mdmServers","id":"s1","attributes":{"serverName":"Built-in MDM"}},
         "blueprints":[{"blueprint":"Fleet-A","configurations":["VPN","WiFi-Corp"]}],
         "mdm":{"device":{"type":"mdmDevices","id":"m1","attributes":{"serialNumber":"C02XYZ"}},
                "details":{"type":"mdmDeviceDetails","id":"m1","attributes":{"osVersion":"15.5","isFileVaultEnabled":true}}}}
      '''),
      );
      expect(report.device.attr('serialNumber'), 'C02XYZ');
      expect(report.assignedServer?.attr('serverName'), 'Built-in MDM');
      expect(report.blueprints.length, 1);
      expect(report.blueprints.first.blueprint, 'Fleet-A');
      expect(report.blueprints.first.configurations, ['VPN', 'WiFi-Corp']);
      expect(report.mdm?.details?.attr('osVersion'), '15.5');
      expect(report.mdm?.error, isNull);
      expect(report.appleCare, isNull);
    });

    /// Not enrolled: mdm is null. Denied: mdm carries only an error string. The two are
    /// different findings and the report has to keep them apart.
    test('the mdm section distinguishes not-enrolled from denied', () {
      final notEnrolled = DeviceStatusReport.fromJson(
        obj(
          r'''{"device":{"type":"orgDevices","id":"d1","attributes":{}},"assignedServer":null,"blueprints":[],"mdm":null}''',
        ),
      );
      expect(notEnrolled.mdm, isNull);
      expect(notEnrolled.blueprints, isEmpty);

      final denied = DeviceStatusReport.fromJson(
        obj(
          r'''{"device":{"type":"orgDevices","id":"d1","attributes":{}},"assignedServer":null,"blueprints":[],"mdm":{"error":"API 403 (grant device management)"}}''',
        ),
      );
      expect(denied.mdm?.error, 'API 403 (grant device management)');
      expect(denied.mdm?.device, isNull);
    });

    test('an assign outcome decodes the activity id', () {
      final outcome = ActivityOutcome.fromJson(
        obj(
          r'''{"action":"assign","server":"Built-in MDM","devices":2,"activityId":"act-42"}''',
        ),
      );
      expect(outcome.action, 'assign');
      expect(outcome.devices, 2);
      expect(outcome.activityID, 'act-42');
      expect(
        outcome.status,
        isNull,
        reason: 'status is only present with --wait, which abgui never passes',
      );
      expect(outcome.subStatus, isNull);
    });

    test('an unassign outcome keeps its verb', () {
      final outcome = ActivityOutcome.fromJson(
        obj(
          r'''{"action":"unassign","server":"Built-in MDM","devices":1,"activityId":"act-43"}''',
        ),
      );
      expect(outcome.action, 'unassign');
      expect(outcome.activityID, 'act-43');
    });

    test('an activity status is a plain resource', () {
      final activity = Resource.fromJson(
        obj(
          r'''{"type":"orgDeviceActivities","id":"act-42","attributes":{"status":"COMPLETED","subStatus":"SUBMITTED_TO_SERVER","createdDateTime":"2026-07-09T00:00:00Z"}}''',
        ),
      );
      expect(activity.id, 'act-42');
      expect(activity.attr('status'), 'COMPLETED');
      expect(activity.attr('subStatus'), 'SUBMITTED_TO_SERVER');
    });

    test('every composite payload survives an empty document', () {
      expect(DeviceDetail.fromJson(obj('{}')).device.id, '');
      expect(MDMDeviceDetail.fromJson(obj('{}')).details.attr('x'), isNull);
      expect(UserGroupDetail.fromJson(obj('{}')).members, isNull);
      expect(MDMServerDetail.fromJson(obj('{}')).devices, isNull);
      final blueprint = BlueprintDetail.fromJson(obj('{}'));
      expect(blueprint.relationships, isEmpty);
      expect(blueprint.appIds, isEmpty);
      expect(blueprint.appLicenseDeficient, isFalse);
      final status = DeviceStatusReport.fromJson(obj('{}'));
      expect(status.blueprints, isEmpty);
      expect(status.mdm, isNull);
      expect(ActivityOutcome.fromJson(obj('{}')).activityID, '');
    });
  });

  group('os releases', () {
    test('the release contract decodes', () {
      final releases = OSRelease.listFromJson(
        jsonDecode(
          r'''[{"platform":"macOS","productVersion":"15.4","build":"24E1","postingDate":"2026-07-01","expirationDate":"2026-12-01","supportedDevices":["MacBookPro18,3"],"catalog":"managed","expired":false}]''',
        ),
      );
      expect(releases.length, 1);
      expect(releases[0].id, 'managed:macOS:24E1');
      expect(releases[0].supportedDevices, ['MacBookPro18,3']);
      expect(releases[0].expired, isFalse);
    });

    test('a release without an expiry or a device list decodes', () {
      final release = OSRelease.fromJson(
        obj(
          r'''{"platform":"iOS","productVersion":"19.0","build":"23A1","postingDate":"2026-09-01","catalog":"public","expired":true}''',
        ),
      );
      expect(release.expirationDate, isNull);
      expect(release.supportedDevices, isNull);
      expect(release.expired, isTrue);
    });
  });

  group('apps & books (vpp)', () {
    test('an asset decodes with its license counts', () {
      final assets =
          (jsonDecode(
                    r'''[{"name":"WhatsApp Messenger","adamId":"408709785","productType":"App","pricingParam":"STDQ","availableCount":42,"assignedCount":8,"retiredCount":0,"totalCount":50,"deviceAssignable":true,"revocable":true,"supportedPlatforms":["iOS","macOS"]}]''',
                  )
                  as List)
              .map((e) => VPPAsset.fromJson(asJsonMap(e)))
              .toList();
      expect(assets.length, 1);
      final asset = assets.first;
      expect(asset.name, 'WhatsApp Messenger');
      expect(asset.adamId, '408709785');
      expect(asset.availableCount, 42);
      expect(asset.totalCount, 50);
      expect(asset.deviceAssignable, isTrue);
      expect(asset.supportedPlatforms, ['iOS', 'macOS']);
      expect(asset.id, '408709785STDQ');
    });

    test(
      'an unresolved asset name decodes as null, not as an empty string',
      () {
        final asset = VPPAsset.fromJson(
          obj(r'''{"adamId":"1","totalCount":3}'''),
        );
        expect(asset.name, isNull);
        expect(asset.availableCount, isNull);
        expect(asset.supportedPlatforms, isNull);
      },
    );

    test('the service config decodes urls and limits', () {
      final config = VPPServiceConfig.fromJson(
        obj(
          r'''{"locationName":"HQ","tokenExpirationDate":"2027-01-01T00:00:00Z","urls":{"getAssets":"https://vpp/assets"},"limits":{"maxAssets":25}}''',
        ),
      );
      expect(config.locationName, 'HQ');
      expect(config.urls?['getAssets'], 'https://vpp/assets');
      expect(config.limits?['maxAssets'], 25);
    });

    test('assignments and users decode', () {
      final assignment = VPPAssignment.fromJson(
        obj(
          r'''{"adamId":"408709785","pricingParam":"STDQ","serialNumber":"C02AAA"}''',
        ),
      );
      expect(assignment.id, '408709785C02AAA');
      expect(assignment.clientUserId, isNull);

      final user = VPPUser.fromJson(
        obj(
          r'''{"clientUserId":"u-1","email":"ada@example.com","status":"Registered"}''',
        ),
      );
      expect(user.id, 'u-1');
      expect(user.status, 'Registered');
    });
  });

  group('sync failure — ranking, never discarding', () {
    test('a clean run that exited 0 is not a failure', () {
      final result = ApplyResult.fromJson(obj('{$emptyPhases}'));
      expect(SyncFailure.fromApplyResult(result), isNull);
    });

    test(
      'failed items lead the headline and every row lands in the details',
      () {
        final result = ApplyResult.fromJson(
          obj(r'''
        {"configs":{"outcomes":[
           {"name":"WiFi.mobileconfig","action":"update-abm","status":"error","detail":"403 forbidden"},
           {"name":"VPN.mobileconfig","action":"create-abm","status":"error","detail":"payload rejected"}],
          "writes":0,"errors":2,"skipped":0},
         "blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}
      '''),
        );
        final failure = SyncFailure.fromApplyResult(result, exitCode: 1)!;
        expect(failure.kind, SyncFailureKind.itemsFailed);
        expect(failure.headline, contains('2 of 2 changes failed'));
        expect(
          failure.headline,
          contains('update-abm WiFi.mobileconfig: 403 forbidden'),
        );
        expect(failure.details, contains('VPN.mobileconfig'));
        expect(failure.copyableText, startsWith(failure.headline));
      },
    );

    /// The counters and the rows move together, but if a future abctl reports errors without
    /// rows, "no rows" must not be read as "clean".
    test('errors without rows still fail the run', () {
      final result = ApplyResult.fromJson(
        obj(
          r'''{"configs":{"outcomes":[],"writes":0,"errors":2,"skipped":1},"blueprints":{"outcomes":[],"writes":0,"errors":0,"skipped":0}}''',
        ),
      );
      final failure = SyncFailure.fromApplyResult(result)!;
      expect(failure.headline, contains('without saying which items failed'));
      expect(failure.details, contains('skipped: 1'));
    });

    /// Every item said `done` and abctl still exited non-zero: post-apply verification. The
    /// verdict is only on stderr, and the FAILED lines outrank the narration that shares their
    /// prefix.
    test('a non-zero exit with clean rows mines the verdict off stderr', () {
      final result = ApplyResult.fromJson(obj('{$emptyPhases}'));
      const stderr =
          'building plan: fetching configurations\n'
          'post-apply verification: re-reading 1 configuration\n'
          'post-apply verification FAILED: WiFi.mobileconfig still differs\n';
      final failure = SyncFailure.fromApplyResult(
        result,
        exitCode: 1,
        stderr: stderr,
      )!;
      expect(failure.kind, SyncFailureKind.exitedNonZero);
      expect(
        failure.headline,
        'post-apply verification FAILED: WiFi.mobileconfig still differs',
      );
      expect(
        failure.details,
        contains('building plan'),
        reason: 'the evidence is kept whole under the summary',
      );
    });

    test('several verdicts are counted rather than picked from', () {
      final failure = SyncFailure.fromNonZeroExit(
        code: 1,
        stderr: 'check A FAILED: one\ncheck B FAILED: two\n',
      );
      expect(
        failure.headline,
        startsWith('2 checks failed — check A FAILED: one'),
      );
    });

    /// Rule 1 of the extractor: the LAST `Error:` line is the outermost wrap, i.e. the most
    /// contextual sentence.
    test('an abort takes the last marked error line', () {
      final failure = SyncFailure.fromAbort(
        stderr: '''
building plan: fetching configurations
Error: listing configurations
Error: ab: 403 (grant the View permission)
''',
      );
      expect(failure.kind, SyncFailureKind.aborted);
      expect(failure.headline, 'ab: 403 (grant the View permission)');
    });

    /// Rule 2: no marked line, so the last line that is not progress narration wins.
    test('an unmarked abort falls through to the last meaningful line', () {
      final failure = SyncFailure.fromAbort(
        stderr: '''
building plan: fetching configurations
applying config WiFi.mobileconfig
aborted — no changes applied.
''',
      );
      expect(failure.headline, 'aborted — no changes applied.');
    });

    /// Rule 3: everything printed was narration, so name WHERE it stopped rather than
    /// inventing a cause.
    test('narration-only stderr names where abctl stopped', () {
      final failure = SyncFailure.fromAbort(
        stderr: '''
building plan: fetching configurations
verifying the stored configuration in ABM: WiFi.mobileconfig
''',
      );
      expect(
        failure.headline,
        'abctl stopped during: verifying the stored configuration in ABM: WiFi.mobileconfig',
      );
    });

    test(
      'an empty stderr falls back to the transcript, then to a plain sentence',
      () {
        final withTranscript = SyncFailure.fromAbort(
          stderr: '   \n',
          transcript: const [r'$ abctl sync --apply', 'boom'],
        );
        expect(
          withTranscript.headline,
          'boom',
          reason: 'the transcript is the last resort, not the first',
        );
        expect(withTranscript.details, contains(r'$ abctl sync --apply'));

        final withNothing = SyncFailure.fromAbort(stderr: '');
        expect(
          withNothing.headline,
          'abctl stopped without applying the plan and printed no error.',
        );
      },
    );

    test('the headline is collapsed and cut at a word boundary', () {
      final long = 'Apple said: ${'verylongdetail ' * 40}';
      final short = SyncFailure.shorten(long);
      expect(short.length, lessThanOrEqualTo(SyncFailure.headlineLimit + 1));
      expect(short, endsWith('…'));
      expect(short, isNot(contains('\n')));

      expect(
        SyncFailure.shorten('a\n b\tc'),
        'a b c',
        reason: 'embedded newlines in Apple\'s raw body collapse to one line',
      );
    });

    test('the other abctl outcomes keep their own classification', () {
      expect(SyncFailure.fromCancellation().kind, SyncFailureKind.cancelled);
      expect(
        SyncFailure.fromTimeout(seconds: 120).headline,
        contains('ran for 120s'),
      );
      expect(
        SyncFailure.fromTimeout(seconds: 120).kind,
        SyncFailureKind.timedOut,
      );
      expect(SyncFailure.fromDecodeFailure().kind, SyncFailureKind.unreadable);
      expect(SyncFailure.fromChangesPending().headline, contains('exit 3'));
      expect(
        SyncFailure.fromUsageRejection(
          stderr: 'Error: unknown flag: --nope',
        ).headline,
        'abctl rejected the command abgui built — unknown flag: --nope',
      );
      expect(SyncFailure.fromError('').headline, 'Sync failed.');
    });

    test('an unknown persisted kind degrades instead of throwing', () {
      expect(
        SyncFailureKind.fromWire('itemsFailed'),
        SyncFailureKind.itemsFailed,
      );
      expect(SyncFailureKind.fromWire('nonsense'), SyncFailureKind.unknown);
    });
  });

  // CSV export must emit the same RFC-4180 quoting + formula-injection hardening as abctl's
  // printCSV/csvSanitize (internal/cli/output.go).
  group('csv export', () {
    test('plain rows and headers', () {
      expect(
        csvDocument(
          headers: ['Serial', 'Name'],
          rows: [
            ['C02XX', 'Mac mini'],
            ['F9FYY', 'iPad'],
          ],
        ),
        'Serial,Name\nC02XX,Mac mini\nF9FYY,iPad\n',
      );
    });

    test('quotes comma, quote and newline, doubling embedded quotes', () {
      expect(
        csvDocument(
          headers: ['Name'],
          rows: [
            ['a,b'],
            ['say "hi"'],
            ['line1\nline2'],
          ],
        ),
        'Name\n"a,b"\n"say ""hi"""\n"line1\nline2"\n',
      );
    });

    test('neutralizes formula prefixes like abctl', () {
      // Same set as csvSanitize: '=', '+', '-', '@', tab, CR get a leading quote.
      expect(
        csvDocument(
          headers: ['V'],
          rows: [
            ['=1+2'],
            ['+x'],
            ['-x'],
            ['@x'],
            ['\tx'],
            ['\rx'],
            ['safe'],
            [''],
          ],
        ),
        'V\n\'=1+2\n\'+x\n\'-x\n\'@x\n\'\tx\n"\'\rx"\nsafe\n\n',
      );
    });

    test('headers are quoted but never formula-prefixed', () {
      // Headers are our own literals; prefixing them would corrupt the column name.
      expect(csvDocument(headers: ['=Total'], rows: const []), '=Total\n');
    });
  });

  group('command transparency', () {
    // Redaction is the security-critical invariant: a secret-bearing value can never enter a
    // record, so nothing downstream can leak one.
    test('redaction hides the VPP token in both spellings', () {
      expect(
        CommandFormatter.redact([
          'vpp',
          'config',
          '--vpp-token',
          's3cret-token',
        ]),
        ['vpp', 'config', '--vpp-token', '****'],
      );
      expect(
        CommandFormatter.redact(['vpp', 'config', '--vpp-token=s3cret-token']),
        ['vpp', 'config', '--vpp-token=****'],
      );
    });

    test('the secret never appears in any rendered form', () {
      const secret = 's3cret-token';
      final record = CommandRecord(
        argv: const ['vpp', 'assets', '--vpp-token', secret, '-o', 'json'],
        cwd: '/tmp/ws',
      );
      expect(
        record.argv.contains(secret),
        isFalse,
        reason: 'the raw token was stored on the record',
      );
      expect(record.commandLine.contains(secret), isFalse);
      expect(record.script.contains(secret), isFalse);
      expect(record.startLogLine.contains(secret), isFalse);
      expect(record.commandLine, contains('****'));
    });

    test('redaction is idempotent', () {
      final once = CommandFormatter.redact([
        'vpp',
        'config',
        '--vpp-token',
        'abc',
      ]);
      expect(CommandFormatter.redact(once), once);
    });

    test('identifiers are not redacted, so the copied command still runs', () {
      final line = CommandFormatter.line([
        'context',
        'set',
        'prod',
        '--client-id',
        'BUSINESSAPI.x',
        '--key',
        '/keys/p.pem',
      ]);
      expect(line, contains('BUSINESSAPI.x'));
      expect(line, contains('/keys/p.pem'));
      expect(line.contains('****'), isFalse);
    });

    test('quoting leaves safe tokens bare and quotes the rest', () {
      expect(CommandFormatter.quote('sync'), 'sync');
      expect(CommandFormatter.quote('--limit-writes'), '--limit-writes');
      expect(CommandFormatter.quote('/tmp/a-b_c.txt'), '/tmp/a-b_c.txt');
      expect(CommandFormatter.quote('WiFi Corp'), "'WiFi Corp'");
      expect(CommandFormatter.quote(''), "''");
      expect(CommandFormatter.quote("it's"), r"'it'\''s'");
    });

    test('the line prefixes abctl and quotes arguments', () {
      expect(
        CommandFormatter.line([
          'get',
          'configuration',
          'WiFi Corp',
          '--profile',
        ]),
        "abctl get configuration 'WiFi Corp' --profile",
      );
    });

    test('the script leads with the cd when the command is tree-relative', () {
      expect(
        CommandFormatter.script(
          argv: ['diff', '--json'],
          cwd: '/Users/me/fleet repo',
        ),
        "cd '/Users/me/fleet repo'\nabctl diff --json",
      );
    });

    test('the script omits the cd when there is no workspace', () {
      expect(
        CommandFormatter.script(argv: ['get', 'devices', '-o', 'json']),
        'abctl get devices -o json',
      );
    });

    test('the script rewrites stdin into a real path so it can be pasted', () {
      final script = CommandFormatter.script(
        argv: ['create', 'config', 'WiFi Corp', '-f', '-', '--yes', '--json'],
        // Named `bytes:` since the consolidation — the size is the only thing this type ever
        // carries, so the call site says which number it is.
        stdin: const CommandStdin.profile(bytes: 2048),
      );
      expect(
        script,
        contains('-f ./WiFi-Corp.mobileconfig'),
        reason: 'stdin was not translated to a file path',
      );
      expect(
        script.contains('-f -'),
        isFalse,
        reason: 'a pasted `-f -` would hang on an empty terminal',
      );
      expect(script, contains('2048 bytes'));
      expect(
        script,
        contains('#'),
        reason: 'the translation must be explained in a comment',
      );
    });

    test('the finish line reports the exit code and the duration', () {
      final start = DateTime.utc(2026, 8, 13, 20, 44, 45);
      final record = CommandRecord(argv: ['diff', '--json'], startedAt: start)
          .copyWith(
            finishedAt: start.add(const Duration(milliseconds: 2400)),
            status: CommandStatus.succeeded,
          );
      expect(record.startLogLine, r'$ abctl diff --json');
      expect(record.finishLogLine, '→ exit 0 in 2.4s');
      expect(record.isFailure, isFalse);
    });

    test('status text covers every terminal outcome', () {
      CommandRecord withStatus(CommandStatus status) =>
          CommandRecord(argv: ['sync'], status: status);
      expect(withStatus(CommandStatus.running).statusText, 'running');
      expect(withStatus(const CommandStatus.failed(3)).statusText, 'exit 3');
      expect(withStatus(CommandStatus.cancelled).statusText, 'cancelled');
      expect(withStatus(CommandStatus.timedOut).statusText, 'timed out');
      expect(withStatus(CommandStatus.timedOut).isFailure, isTrue);
      expect(withStatus(const CommandStatus.failed(1)).isFailure, isTrue);
      expect(withStatus(CommandStatus.cancelled).isFailure, isFalse);
    });

    test('long durations read as minutes and seconds', () {
      final start = DateTime.utc(2026, 1, 1);
      final record = CommandRecord(argv: ['sync', '--apply'], startedAt: start)
          .copyWith(
            finishedAt: start.add(const Duration(seconds: 125)),
            status: CommandStatus.succeeded,
          );
      expect(record.durationText, '2m 5s');
    });

    test('closing a record keeps its identity', () {
      final record = CommandRecord(argv: ['diff']);
      final finished = record.copyWith(
        finishedAt: record.startedAt,
        status: CommandStatus.succeeded,
      );
      expect(finished.id, record.id);
      expect(finished.duration, Duration.zero);
      expect(record.duration, isNull, reason: 'the original is untouched');
    });
  });

  // Quoting has to be honoured here because no shell is involved: a config named
  // "Corp WiFi.mobileconfig" must arrive as ONE argument, or the command fails for a reason
  // that looks nothing like the cause.
  group('console command line', () {
    test('quoting and escapes', () {
      expect(CommandLineParser.tokenize('get blueprints'), [
        'get',
        'blueprints',
      ]);
      expect(CommandLineParser.tokenize('  get   blueprints  '), [
        'get',
        'blueprints',
      ]);
      expect(
        CommandLineParser.tokenize(
          'adopt config "Corp WiFi.mobileconfig" --blueprint \'Default MacOS Group\'',
        ),
        [
          'adopt',
          'config',
          'Corp WiFi.mobileconfig',
          '--blueprint',
          'Default MacOS Group',
        ],
      );
      expect(CommandLineParser.tokenize(r'get config Corp\ WiFi'), [
        'get',
        'config',
        'Corp WiFi',
      ]);
      expect(CommandLineParser.tokenize(''), isEmpty);
      expect(CommandLineParser.tokenize('   '), isEmpty);
    });

    test('a leading binary name is dropped', () {
      expect(CommandLineParser.tokenize('abctl get devices'), [
        'get',
        'devices',
      ]);
      expect(CommandLineParser.tokenize('ABCTL get devices'), [
        'get',
        'devices',
      ]);
      // …but only as the FIRST token — an argument that happens to be "abctl" survives.
      expect(CommandLineParser.tokenize('get config abctl'), [
        'get',
        'config',
        'abctl',
      ]);
    });

    test('an explicitly quoted empty argument survives', () {
      expect(CommandLineParser.tokenize('context set name --api-base ""'), [
        'context',
        'set',
        'name',
        '--api-base',
        '',
      ]);
    });

    /// Drives abgui's own confirmation. It exists to catch a typed `--yes`, which is the only
    /// route in the app to a tenant write that no button asked about.
    test('approved tenant writes are detected', () {
      expect(
        CommandLineParser.isApprovedTenantWrite([
          'delete',
          'config',
          'X',
          '--yes',
        ]),
        isTrue,
      );
      expect(
        CommandLineParser.isApprovedTenantWrite(['sync', '--apply', '--yes']),
        isTrue,
      );
      expect(
        CommandLineParser.isApprovedTenantWrite([
          'assign',
          '--server',
          'S',
          'C02',
          '--yes',
        ]),
        isTrue,
      );

      // A bare sync is a DRY RUN — confirming it would train people to click through.
      expect(
        CommandLineParser.isApprovedTenantWrite(['sync', '--yes']),
        isFalse,
      );
      expect(
        CommandLineParser.isApprovedTenantWrite(['diff', '--json']),
        isFalse,
      );
      expect(
        CommandLineParser.isApprovedTenantWrite(['get', 'devices']),
        isFalse,
      );
      // adopt writes local files only.
      expect(
        CommandLineParser.isApprovedTenantWrite([
          'adopt',
          'config',
          'X',
          '--blueprint',
          'B',
        ]),
        isFalse,
      );
    });

    /// The other half: a write typed WITHOUT --yes aborts, because abctl asks on stdin and the
    /// console gives it none. Safe, but the user should be told before pressing Run.
    test('unapproved writes are flagged', () {
      expect(
        CommandLineParser.isUnapprovedWrite(['delete', 'config', 'X']),
        isTrue,
      );
      expect(CommandLineParser.isUnapprovedWrite(['sync', '--apply']), isTrue);
      expect(
        CommandLineParser.isUnapprovedWrite(['delete', 'config', 'X', '--yes']),
        isFalse,
      );
      expect(
        CommandLineParser.isUnapprovedWrite(['get', 'blueprints']),
        isFalse,
      );
      expect(CommandLineParser.isUnapprovedWrite([]), isFalse);
    });
  });

  group('command timing', () {
    CommandRecord record(
      List<String> argv, {
      Duration? took,
      bool failed = false,
    }) {
      final start = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);
      final base = CommandRecord(argv: argv, startedAt: start);
      if (took == null) return base;
      return base.copyWith(
        finishedAt: start.add(took),
        status: failed
            ? const CommandStatus.failed(1)
            : CommandStatus.succeeded,
      );
    }

    /// A verb is named by its leading NON-flag tokens, so repeated runs of one operation land
    /// in one row. Splitting on flags would scatter `adopt config X --blueprint A` and
    /// `adopt config Y --blueprint B` into separate rows and hide that the verb is slow.
    test('the verb key stops at the first flag', () {
      expect(
        CommandTiming.verbKey(['diff', '--json', '--refresh', 'smart']),
        'diff',
      );
      expect(
        CommandTiming.verbKey(['get', 'configurations', '-o', 'json']),
        'get configurations',
      );
      expect(
        CommandTiming.verbKey([
          'adopt',
          'config',
          'WiFi.mobileconfig',
          '--blueprint',
          'Fleet',
        ]),
        'adopt config',
      );
      expect(CommandTiming.verbKey(['sync', '--apply', '--yes']), 'sync');
      expect(CommandTiming.verbKey([]), 'abctl');
    });

    /// Slowest verb first — that is the whole point of the panel, and it must not be perturbed
    /// by an in-flight command (which has no duration to contribute yet).
    test('the roll-up aggregates and orders by slowest', () {
      final rolled = CommandTiming.rollUp([
        record(['diff', '--json'], took: const Duration(milliseconds: 1400)),
        record(['diff', '--json'], took: const Duration(seconds: 9)),
        record([
          'get',
          'configurations',
        ], took: const Duration(milliseconds: 500)),
        record(
          ['adopt', 'config', 'X'],
          took: const Duration(seconds: 61),
          failed: true,
        ),
        record(['sync', '--apply']), // still running
      ]);

      expect(rolled.map((t) => t.verb).toList(), [
        'adopt config',
        'diff',
        'get configurations',
        'sync',
      ]);

      final diff = rolled.firstWhere((t) => t.verb == 'diff');
      expect(diff.runs, 2);
      expect(diff.slowest, const Duration(seconds: 9));
      expect(diff.average, const Duration(milliseconds: 5200));

      // An unfinished command counts as RUNNING and contributes no duration — otherwise a
      // command that never returns would read as instant.
      final sync = rolled.firstWhere((t) => t.verb == 'sync');
      expect(sync.running, 1);
      expect(sync.runs, 0);
      expect(sync.slowest, Duration.zero);

      expect(rolled.firstWhere((t) => t.verb == 'adopt config').failures, 1);
    });

    /// `elapsed` is what makes "still running" legible: a finished record reports its real
    /// duration, an unfinished one reports how long it has been going as of now.
    test('elapsed ticks while running and freezes when done', () {
      final start = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true);
      final running = CommandRecord(argv: ['diff'], startedAt: start);
      expect(
        running.elapsed(asOf: start.add(const Duration(seconds: 30))),
        const Duration(seconds: 30),
      );
      expect(
        running.isSlow(asOf: start.add(const Duration(seconds: 30))),
        isTrue,
      );
      expect(
        running.isSlow(asOf: start.add(const Duration(seconds: 1))),
        isFalse,
      );

      final done = record(['diff'], took: const Duration(seconds: 2));
      expect(
        done.elapsed(asOf: start.add(const Duration(seconds: 999))),
        const Duration(seconds: 2),
      );
    });

    test('duration text switches to minutes', () {
      expect(DurationText.short(const Duration(milliseconds: 1440)), '1.4s');
      expect(DurationText.short(const Duration(seconds: 95)), '1m 35s');
    });
  });

  group('the run-log index', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('abgui-logs-');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    File write(String name, String body, {DateTime? modified}) {
      final file = File('${dir.path}/$name')..writeAsStringSync(body);
      if (modified != null) file.setLastModifiedSync(modified);
      return file;
    }

    /// The list is built from FILENAMES, so a full read is never needed to populate it.
    test('parses the verb and the UTC start out of the filename', () {
      expect(
        RunLogIndex.verbFromName('diff-20260813T204445Z-b37749.log'),
        'diff',
      );
      expect(
        RunLogIndex.verbFromName('sync-20260813T204445Z-b37749.log'),
        'sync',
      );

      final parsed = RunLogIndex.startDateFromName(
        'diff-20260813T204445Z-b37749.log',
      );
      expect(parsed, DateTime.utc(2026, 8, 13, 20, 44, 45));
      expect(parsed!.isUtc, isTrue);

      expect(RunLogIndex.startDateFromName('not-a-log.log'), isNull);
    });

    /// The verdict comes from a bounded TAIL read, so listing fifty logs never loads fifty
    /// transcripts. This is the property that keeps the screen cheap to open.
    test(
      'reads the outcome from the footer without reading the whole file',
      () {
        final filler = 'building plan: reusing cached profile hash: x\n' * 5000;
        final file = write('diff-20260813T204445Z-b37749.log', '''
# abgui run log
---
$filler
---
finished: 2026-08-13T20:44:46Z
duration: 1.5s
outcome: plan computed
lines: 106
''');
        final footer = RunLogIndex.readFooter(file.path);
        expect(footer.outcome, 'plan computed');
        expect(footer.duration, '1.5s');
        expect(file.lengthSync(), greaterThan(RunLogIndex.footerProbeBytes));
      },
    );

    /// A run that died before the footer was written is a real state worth showing, not an
    /// error to swallow — it is what an app killed mid-sync leaves behind.
    test('a footerless log reads as unfinished', () {
      write(
        'sync-20260813T204445Z-aaaaaa.log',
        '# abgui run log\n---\nbuilding plan: ...\n',
      );
      final scanned = RunLogIndex.scan(dir.path);
      expect(scanned.length, 1);
      expect(scanned[0].isUnfinished, isTrue);
      expect(scanned[0].outcome, isNull);
    });

    /// Newest first, and only abgui's own files. The directory is a shared OS location, so a
    /// stray file must not appear as a run — the same rule the pruner follows before DELETING.
    test('the scan is newest first and ignores foreign files', () {
      write(
        'diff-20260813T204400Z-aaaaaa.log',
        'outcome: older\n',
        modified: DateTime.utc(2026, 8, 13, 20, 44),
      );
      write(
        'sync-20260813T204500Z-bbbbbb.log',
        'outcome: newer\n',
        modified: DateTime.utc(2026, 8, 13, 20, 45),
      );
      write('some-other-tool.log', 'not ours\n');
      write('notes.txt', 'not ours either\n');

      expect(RunLogIndex.scan(dir.path).map((f) => f.verb).toList(), [
        'sync',
        'diff',
      ]);
    });

    /// A failed run has to be identifiable at a glance in the list, from the footer prose the
    /// plan/seed paths actually write.
    test('failure classification', () {
      write(
        'diff-20260813T204400Z-aaaaaa.log',
        'outcome: failed — abctl timed out\n',
      );
      write('sync-20260813T204500Z-bbbbbb.log', 'outcome: plan computed\n');
      final byVerb = <String, RunLogFile>{
        for (final f in RunLogIndex.scan(dir.path)) f.verb: f,
      };
      expect(byVerb['diff']?.isFailure, isTrue);
      expect(byVerb['sync']?.isFailure, isFalse);
    });

    test('sizes read in the unit a human wants', () {
      final base = RunLogFile(
        path: 'x',
        verb: 'diff',
        modifiedAt: DateTime.utc(2026),
        sizeBytes: 900,
      );
      expect(base.sizeText, '900 bytes');
      expect(
        RunLogFile(
          path: 'x',
          verb: 'diff',
          modifiedAt: DateTime.utc(2026),
          sizeBytes: 2048,
        ).sizeText,
        '2 KB',
      );
      expect(
        RunLogFile(
          path: 'x',
          verb: 'diff',
          modifiedAt: DateTime.utc(2026),
          sizeBytes: 3 * 1024 * 1024,
        ).sizeText,
        '3.0 MB',
      );
    });

    test('a missing directory is an empty list, not a crash', () {
      expect(RunLogIndex.scan('${dir.path}/nope'), isEmpty);
      expect(RunLogIndex.contents('${dir.path}/nope.log'), isNull);
    });
  });

  group('the archive tree', () {
    test('the scanner reads the sidecar for the real config name', () {
      final root = Directory.systemTemp.createTempSync('abgui-arch-');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/gitops/archive/WiFi-Corp')
        ..createSync(recursive: true);

      const stem = '20260101T000000Z--replaced';
      File('${dir.path}/$stem.mobileconfig').writeAsStringSync('<plist/>');
      File('${dir.path}/$stem.json').writeAsStringSync(
        '{"name":"WiFi-Corp.mobileconfig","reason":"replaced",'
        '"archivedAt":"2026-01-01T00:00:00Z","file":"$stem.mobileconfig"}',
      );

      final entries = ArchiveScanner.scan(root.path);
      expect(entries.length, 1);
      expect(entries.first.configName, 'WiFi-Corp.mobileconfig');
      expect(entries.first.reason, 'replaced');
      expect(entries.first.id, endsWith('$stem.mobileconfig'));
      expect(
        entries.first.hasSidecar,
        isTrue,
        reason:
            'the name came from the sidecar, so it is the one Apple Business knows — which is '
            'what makes this entry restorable',
      );
    });

    /// A corrupt or missing sidecar must not hide the archived profile it describes — that
    /// file is the only copy of the pre-overwrite bytes.
    test('a profile with no readable sidecar still lists', () {
      final root = Directory.systemTemp.createTempSync('abgui-arch-');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/gitops/archive/VPN')
        ..createSync(recursive: true);
      File(
        '${dir.path}/20260101T000000Z--deleted.mobileconfig',
      ).writeAsStringSync('<plist/>');
      File(
        '${dir.path}/20260101T000000Z--deleted.json',
      ).writeAsStringSync('not json at all');

      final entries = ArchiveScanner.scan(root.path);
      expect(entries.length, 1);
      expect(
        entries.first.configName,
        'VPN',
        reason: 'the directory name is the fallback',
      );
      expect(entries.first.archivedAt, '');
      // And it is flagged, because that fallback is a SLUG. `replace config VPN` resolves against
      // the live tenant, so a slug that happens to match a different configuration would overwrite
      // that one with these bytes — the Archive screen refuses to restore an entry that says
      // false here.
      expect(entries.first.hasSidecar, isFalse);
    });

    test('newest first, and a missing tree is empty', () {
      final root = Directory.systemTemp.createTempSync('abgui-arch-');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final entry in const [
        ('A', '2026-01-01T00:00:00Z'),
        ('B', '2026-06-01T00:00:00Z'),
      ]) {
        final dir = Directory('${root.path}/gitops/archive/${entry.$1}')
          ..createSync(recursive: true);
        File('${dir.path}/x.mobileconfig').writeAsStringSync('<plist/>');
        File('${dir.path}/x.json').writeAsStringSync(
          '{"name":"${entry.$1}","reason":"replaced","archivedAt":"${entry.$2}"}',
        );
      }
      expect(ArchiveScanner.scan(root.path).map((e) => e.configName).toList(), [
        'B',
        'A',
      ]);
      expect(ArchiveScanner.scan('${root.path}/missing'), isEmpty);
    });
  });
}
