// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The pre-write structural check, pinned against abctl's OWN fixtures.
//
// `ProfilePreflight` is a port of `checkProfile` → `inspectProfile` from
// `internal/cli/validate.go`, and a port is only worth having while it still agrees with the
// original. So the cases below are lifted from `internal/cli/validate_test.go` — the same
// documents, the same expected codes, the same threshold boundaries — rather than invented
// here. When Go's table gains a row, this one has to gain it too, and a divergence shows up as
// a failing test instead of as a profile abgui waved through.
//
// The stakes are asymmetric and the tests are written knowing it: abgui never passes `--force`,
// so abctl re-runs this exact inspector over the exact bytes before it writes. A check that is
// too STRICT here blocks a write in the GUI; one that is too LOOSE lets a document reach abctl,
// which blocks it anyway. Neither can push a bad profile — but only the strict direction leaves
// the operator with a report they can act on, which is why the boundary tests are exact.

import 'dart:convert';

import 'package:abgui/src/models/profile_check.dart';
import 'package:abgui/src/models/validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a clean profile passes silently', () {
    test('no errors, no warnings, and the identity fields are parsed', () {
      // TestValidateGoodProfilePasses.
      final ProfileReport report = _check(_goodProfile('com.example.wifi'));

      expect(report.ok, isTrue);
      expect(report.errors, isEmpty);
      expect(
        report.warnings,
        isEmpty,
        reason: 'the check may not add noise to a healthy profile',
      );
      expect(report.identifier, 'com.example.wifi');
      expect(report.displayName, 'Corp Wi-Fi');
      expect(report.payloadTypes, <String>['com.apple.wifi.managed']);
      expect(report.bytes, greaterThan(0));
    });

    test('the bytes counted are the bytes that would be sent', () {
      // The size cap is a statement about the document Apple receives, so the count has to come
      // from the same encoding the write puts on stdin. A profile with non-ASCII text is where
      // a character count and a byte count part company.
      final List<int> bytes = utf8.encode(
        _goodProfile('com.example.wifi').replaceAll('Corp Wi-Fi', 'Café Wi-Fi'),
      );
      final ProfileReport report = ProfilePreflight.check(
        bytes,
        name: 'WiFi-Corp.mobileconfig',
      );

      expect(report.bytes, bytes.length);
      expect(report.displayName, 'Café Wi-Fi');
    });
  });

  group('the error table', () {
    // TestValidateProfileErrors, verbatim: each malformed shape fails with its own code.
    final Map<String, (String, String)> cases = <String, (String, String)>{
      'empty': ('', 'empty'),
      'malformed xml': (
        '<plist><dict><key>PayloadType</key></plist>',
        'xml-parse',
      ),
      'not a plist': (
        '<?xml version="1.0"?>\n<manifest><item/></manifest>\n',
        'not-plist',
      ),
      'no payload content': (
        _profileXml(
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.nc</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
        'missing-payload-content',
      ),
      'no payload type': (
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.nt</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
        'missing-payload-type',
      ),
      'wrong payload type': (
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<key>PayloadType</key>\n\t<string>com.apple.wifi.managed</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.wt</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
        'not-configuration',
      ),
      'no identifier': (
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
        'missing-payload-identifier',
      ),
    };

    cases.forEach((String name, (String, String) expected) {
      test('$name fails as ${expected.$2}', () {
        final ProfileReport report = _check(expected.$1);
        expect(_codes(report.errors), contains(expected.$2));
        expect(
          report.ok,
          isFalse,
          reason: 'an error must fail the profile, not merely annotate it',
        );
      });
    });

    test('a binary plist is named as one, on its bytes', () {
      // Byte-level, and unreachable by typing: a `plutil -convert binary1` file pasted through
      // a clipboard is what produces this, and telling the operator to convert it is the whole
      // value of the check.
      final ProfileReport report = ProfilePreflight.check(<int>[
        ...utf8.encode('bplist00'),
        0x00,
        0x01,
        0x02,
      ], name: 'Binary.mobileconfig');
      expect(_codes(report.errors), contains('binary-plist'));
      expect(report.errors.single.message, contains('plutil -convert xml1'));
    });

    test('a signed DER profile is named as one, on its first byte', () {
      final ProfileReport report = ProfilePreflight.check(<int>[
        0x30,
        0x82,
        0x01,
        0x02,
        ...utf8.encode('signed'),
      ], name: 'Signed.mobileconfig');
      expect(_codes(report.errors), contains('signed-profile'));
    });
  });

  group('the PayloadVersion rule', () {
    // TestValidateOuterPayloadVersion. This is the check that exists because of a live
    // incident: Apple answers a PATCH carrying an out-of-spec outer PayloadVersion with a 2xx
    // and then silently does not store the profile. It is the single most important reason
    // this pre-flight is worth running BEFORE the write rather than reading about afterwards.
    test('an outer PayloadVersion of 2 is a hard error', () {
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.v2</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>2</integer>',
        ),
      );

      expect(report.ok, isFalse);
      expect(_codes(report.errors), <String>['payload-version']);
      expect(report.errors.single.message, contains('exactly 1'));
      expect(
        report.errors.single.message,
        contains('2xx'),
        reason:
            'the message has to explain why a successful-looking write is not one',
      );
    });

    test('a missing outer PayloadVersion is a hard error too', () {
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.nov</string>',
        ),
      );
      expect(_codes(report.errors), <String>['payload-version']);
    });

    test('a non-scalar value is described by its element, not as blank', () {
      // describeScalar: reporting `<true/>` as "" would read as "the key is missing", which is
      // a different fix.
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.bool</string>\n'
          '\t<key>PayloadVersion</key>\n\t<true/>',
        ),
      );
      expect(report.errors.single.message, contains('<true>'));
    });

    test('an inner payload version only WARNS', () {
      // TestValidateInnerPayloadVersionWarns: only the OUTER value is known to trigger the
      // silent drop, so an inner one must not block a write.
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array>\n\t\t<dict>\n'
          '\t\t\t<key>PayloadType</key>\n\t\t\t<string>com.apple.dock</string>\n'
          '\t\t\t<key>PayloadVersion</key>\n\t\t\t<integer>2</integer>\n'
          '\t\t</dict>\n\t\t<dict>\n'
          '\t\t\t<key>PayloadType</key>\n\t\t\t<string>com.apple.finder</string>\n'
          '\t\t\t<key>PayloadVersion</key>\n\t\t\t<integer>1</integer>\n'
          '\t\t</dict>\n\t</array>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.inner</string>\n'
          '\t<key>PayloadUUID</key>\n\t<string>U</string>\n'
          '\t<key>PayloadDisplayName</key>\n\t<string>Inner</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
      );

      expect(report.ok, isTrue);
      final List<ValidationIssue> flagged = report.warnings
          .where(
            (ValidationIssue issue) => issue.code == 'inner-payload-version',
          )
          .toList();
      expect(
        flagged,
        hasLength(1),
        reason: 'the compliant payload is fine and must stay silent',
      );
      expect(flagged.single.message, contains('"com.apple.dock"'));
      expect(report.payloadTypes, <String>[
        'com.apple.dock',
        'com.apple.finder',
      ]);
    });
  });

  group('warnings never fail a profile', () {
    test('the thin-but-legal minimum only warns', () {
      // TestValidateWarningsDoNotFail: this is the minimum Apple accepts, so a check that
      // failed it would block a legitimate write.
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.thin</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
      );

      expect(report.ok, isTrue);
      expect(report.errors, isEmpty);
      expect(
        _codes(report.warnings),
        containsAll(<String>[
          'missing-payload-uuid',
          'missing-display-name',
          'no-inner-payloads',
        ]),
      );
    });

    test('an untyped inner payload warns and is named by position', () {
      // TestValidateInnerPayloadVersionUntyped.
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array>\n\t\t<dict>\n'
          '\t\t\t<key>PayloadVersion</key>\n\t\t\t<integer>3</integer>\n'
          '\t\t</dict>\n\t</array>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.untyped</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
      );

      expect(report.ok, isTrue);
      expect(_codes(report.warnings), contains('inner-payload-version'));
      expect(
        report.warnings
            .firstWhere(
              (ValidationIssue i) => i.code == 'inner-payload-version',
            )
            .message,
        contains('#1'),
      );
      expect(_codes(report.warnings), contains('inner-payload-missing-type'));
    });

    test('a non-dict inner payload is reported by its element', () {
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array>\n\t\t<string>nope</string>\n\t</array>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.nondict</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
      );
      expect(report.ok, isTrue);
      expect(
        report.warnings
            .firstWhere(
              (ValidationIssue i) => i.code == 'inner-payload-missing-type',
            )
            .message,
        contains('<string>'),
      );
      expect(report.payloadTypes, isEmpty);
    });
  });

  group('the size thresholds are exact', () {
    // TestValidateSizeCapBoundary. An off-by-one is invisible in ordinary fixtures and is
    // exactly what turns "abgui said it was fine" into an Apple rejection: the cap is 1 MiB OR
    // MORE, so 1<<20 must fail and 1<<20-1 must not.
    for (final (String name, int size, bool wantFail, bool wantWarn)
        in <(String, int, bool, bool)>[
          (
            'just under the warn threshold',
            ProfilePreflight.sizeWarn - 1,
            false,
            false,
          ),
          (
            'exactly at the warn threshold',
            ProfilePreflight.sizeWarn,
            false,
            true,
          ),
          ('one byte under the cap', ProfilePreflight.sizeCap - 1, false, true),
          ('exactly at the cap', ProfilePreflight.sizeCap, true, false),
          ('one byte over the cap', ProfilePreflight.sizeCap + 1, true, false),
        ]) {
      test(name, () {
        final List<int> bytes = _profileOfSize(size);
        expect(bytes, hasLength(size), reason: 'the fixture must be exact');

        final ProfileReport report = ProfilePreflight.check(
          bytes,
          name: 'Sized.mobileconfig',
        );

        expect(_codes(report.errors).contains('size-cap'), wantFail);
        expect(
          _codes(report.warnings).contains('approaching-size-cap'),
          wantWarn,
        );
        expect(report.ok, !wantFail);
      });
    }
  });

  group('the plist reader walks what abctl walks', () {
    test('dicts, arrays, nested dicts and valueless scalars', () {
      // TestParsePlistWalksDictsAndArrays: the nested dict and the `<true/>` are the two shapes
      // a naive reader gets wrong, and both appear in real profiles.
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array>\n\t\t<dict>\n'
          '\t\t\t<key>PayloadType</key>\n\t\t\t<string>com.apple.dock</string>\n'
          '\t\t\t<key>Nested</key>\n\t\t\t<dict>\n'
          '\t\t\t\t<key>Deep</key>\n\t\t\t\t<string>value</string>\n'
          '\t\t\t</dict>\n\t\t</dict>\n\t</array>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.dock</string>\n'
          '\t<key>PayloadUUID</key>\n\t<string>U</string>\n'
          '\t<key>PayloadDisplayName</key>\n\t<string>Dock</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>\n'
          '\t<key>Removable</key>\n\t<true/>',
        ),
      );

      expect(report.ok, isTrue);
      expect(report.warnings, isEmpty);
      expect(report.payloadTypes, <String>['com.apple.dock']);
    });

    test('an unclosed document is a parse error, not a silent pass', () {
      final ProfileReport report = _check('<plist><dict><key>a</key></dict>');
      expect(_codes(report.errors), contains('xml-parse'));
    });

    test('the Apple DOCTYPE and XML declaration are not markup to trip over', () {
      // Every .mobileconfig Apple's tools emit opens with both. A reader that choked on the
      // DTD line would reject every real profile in the fleet.
      final ProfileReport report = _check(_goodProfile('com.example.doctype'));
      expect(report.ok, isTrue);
      expect(_codes(report.errors), isEmpty);
    });

    test('entities and CDATA are decoded, not treated as text', () {
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.a&amp;b</string>\n'
          '\t<key>PayloadUUID</key>\n\t<string>U</string>\n'
          '\t<key>PayloadDisplayName</key>\n'
          '\t<string><![CDATA[Sales & Marketing]]></string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
      );

      expect(report.identifier, 'com.example.a&b');
      expect(report.displayName, 'Sales & Marketing');
    });

    test('a comment between keys does not break the walk', () {
      final ProfileReport report = _check(
        _profileXml(
          '\t<key>PayloadContent</key>\n\t<array/>\n'
          '\t<!-- the type Apple requires -->\n'
          '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
          '\t<key>PayloadIdentifier</key>\n\t<string>com.example.comment</string>\n'
          '\t<key>PayloadVersion</key>\n\t<integer>1</integer>',
        ),
      );
      expect(_codes(report.errors), isEmpty);
      expect(report.identifier, 'com.example.comment');
    });

    test('a > inside a quoted attribute does not end the tag', () {
      final ProfileReport report = _check(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<plist version="1.0" note="a > b">\n<dict>\n'
        '\t<key>PayloadContent</key>\n\t<array/>\n'
        '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
        '\t<key>PayloadIdentifier</key>\n\t<string>com.example.attr</string>\n'
        '\t<key>PayloadVersion</key>\n\t<integer>1</integer>\n'
        '</dict>\n</plist>\n',
      );
      expect(_codes(report.errors), isEmpty);
    });

    test('an unquoted attribute value is a parse error', () {
      // Found by diffing this port against the Go inspector over a fixture corpus, and worth a
      // permanent test because it was a divergence in the DANGEROUS direction: the first
      // scanner raced to the next `>` and waved `version=1.0` through, so abgui reported a
      // clean pre-flight for a document abctl's strict decoder refuses. A green report followed
      // by a failed write is the one outcome this screen must never produce.
      final ProfileReport report = _check('<plist version=1.0><dict/></plist>');
      expect(_codes(report.errors), <String>['xml-parse']);
    });

    test('a namespace prefix is dropped, as Go reports Name.Local', () {
      // The other divergence the corpus found. abctl compares against `Name.Local`, so
      // `<p:plist>` IS a plist element to the authority; reading it as `not-plist` here would
      // have the two disagree about what the document is before any check even ran.
      final ProfileReport report = _check(
        '<p:plist xmlns:p="u"><dict/></p:plist>',
      );
      expect(_codes(report.errors), isNot(contains('not-plist')));
      expect(_codes(report.errors), contains('missing-payload-type'));
    });

    test('a dict holding something other than a key is a parse error', () {
      final ProfileReport report = _check(
        '<plist><dict><string>stray</string></dict></plist>',
      );
      expect(_codes(report.errors), contains('xml-parse'));
      expect(report.errors.single.message, contains('<key> was expected'));
    });

    test('a plist wrapping a non-dict reads as every key missing', () {
      // Apple would reject it and so does the check — but as the specific list of absent keys,
      // which is what tells the operator what to add.
      final ProfileReport report = _check('<plist><array/></plist>');
      expect(
        _codes(report.errors),
        containsAll(<String>[
          'missing-payload-content',
          'missing-payload-type',
          'payload-version',
          'missing-payload-identifier',
        ]),
      );
    });

    test('runaway nesting is refused instead of exhausting the stack', () {
      final StringBuffer deep = StringBuffer('<plist>');
      for (int i = 0; i <= ProfilePreflight.maxDepth + 2; i++) {
        deep.write('<array>');
      }
      for (int i = 0; i <= ProfilePreflight.maxDepth + 2; i++) {
        deep.write('</array>');
      }
      deep.write('</plist>');

      final ProfileReport report = _check(deep.toString());
      expect(_codes(report.errors), contains('xml-parse'));
      expect(report.errors.single.message, contains('nested deeper'));
    });
  });
}

ProfileReport _check(String xml) =>
    ProfilePreflight.check(utf8.encode(xml), name: 'WiFi-Corp.mobileconfig');

List<String> _codes(List<ValidationIssue> issues) => <String>[
  for (final ValidationIssue issue in issues) issue.code,
];

/// abctl's `profileXML` test helper, character for character — including the Apple DOCTYPE, so
/// every fixture here exercises the prolog a real profile carries.
String _profileXml(String inner) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0">\n<dict>\n$inner\n</dict>\n</plist>\n';

/// abctl's `goodProfile`: structurally complete, one inner payload, nothing to report.
String _goodProfile(String identifier) => _profileXml(
  '\t<key>PayloadContent</key>\n'
  '\t<array>\n'
  '\t\t<dict>\n'
  '\t\t\t<key>PayloadType</key>\n'
  '\t\t\t<string>com.apple.wifi.managed</string>\n'
  '\t\t\t<key>PayloadIdentifier</key>\n'
  '\t\t\t<string>$identifier.inner</string>\n'
  '\t\t</dict>\n'
  '\t</array>\n'
  '\t<key>PayloadDisplayName</key>\n'
  '\t<string>Corp Wi-Fi</string>\n'
  '\t<key>PayloadIdentifier</key>\n'
  '\t<string>$identifier</string>\n'
  '\t<key>PayloadType</key>\n'
  '\t<string>Configuration</string>\n'
  '\t<key>PayloadUUID</key>\n'
  '\t<string>6E8B0F2A-2E4E-4E3A-9C2F-2A0C7D3B1E55</string>\n'
  '\t<key>PayloadVersion</key>\n'
  '\t<integer>1</integer>',
);

/// abctl's `profileOfSize`: a valid profile padded to EXACTLY [size] bytes, so the cap
/// boundary can be pinned rather than approximated. ASCII padding, so bytes grow one for one.
List<int> _profileOfSize(int size) {
  String body(String pad) => _profileXml(
    '\t<key>PayloadContent</key>\n\t<array/>\n'
    '\t<key>PayloadType</key>\n\t<string>Configuration</string>\n'
    '\t<key>PayloadIdentifier</key>\n\t<string>com.example.sized</string>\n'
    '\t<key>PayloadUUID</key>\n\t<string>SIZED</string>\n'
    '\t<key>PayloadVersion</key>\n\t<integer>1</integer>\n'
    '\t<key>PayloadDisplayName</key>\n\t<string>Sized</string>\n'
    '\t<key>Padding</key>\n\t<string>$pad</string>',
  );
  final int envelope = utf8.encode(body('')).length;
  if (size < envelope) {
    throw ArgumentError.value(
      size,
      'size',
      'the envelope alone is $envelope bytes',
    );
  }
  return utf8.encode(body('A' * (size - envelope)));
}
