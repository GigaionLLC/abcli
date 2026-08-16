// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The structural check that runs on a `.mobileconfig` BEFORE abgui sends it to a live tenant.
///
/// **Why this exists at all, and why it is not `abctl validate --json`.** The obvious way to
/// verify an edited profile is to ask abctl. It cannot be asked: `validate` takes
/// `cobra.NoArgs` and reads `gitops/lib/*.mobileconfig` off disk (`internal/cli/validate.go`),
/// so it can only ever report on files that are already in the workspace. An unsaved editor
/// buffer is not one of them. The two ways to make `validate` see it are both worse than this
/// file:
///
///   * write the buffer into `gitops/lib/` first — that mutates the operator's git tree before
///     they have approved anything, and overwrites the very copy they would need to go back to;
///   * run `validate` anyway and present its verdict as the buffer's — that reports on OTHER
///     files. A green report about the tree while the buffer carries the one profile shape Apple
///     silently drops is worse than no report, because it is a false all-clear on the exact
///     failure this check exists to catch.
///
/// So the check is ported. [ProfilePreflight.check] is `checkProfile` → `inspectProfile` from
/// `internal/cli/validate.go`, in the same order, with abctl's own codes and abctl's own
/// sentences — the operator sees the same words here that `abctl validate` would print, because
/// they ARE the same words.
///
/// **abctl is still the authority, and that asymmetry is the safety argument.** abgui never
/// passes `--force`, so `create config` and `replace config` run abctl's `validateProfile` — the
/// same inspector, over the same bytes, with Go's own XML parser — and refuse the write on a
/// hard error (`internal/cli/imperative.go`). That makes the two possible disagreements
/// unequal:
///
///   * this file accepts something abctl rejects → abctl blocks the write. Nothing reaches
///     Apple.
///   * this file rejects something abctl would accept → a valid write is blocked in the GUI.
///     Annoying, recoverable from a terminal, and NOT a tenant change.
///
/// Neither direction can push a bad profile, which is why blocking is the direction this file
/// errs in.
///
/// **What is deliberately NOT checked here.** abctl's `flagDuplicateIdentifiers` compares every
/// profile in `lib/` against every other, and a duplicate `PayloadIdentifier` is an error
/// because two profiles sharing one overwrite each other on the device. That check needs the
/// whole tree, and one editor buffer is not a tree — Apple's list endpoint returns metadata with
/// no payload, so the identifiers of the other live configurations are not in hand either.
/// Claiming an identifier is unique when nothing checked would be the worse half of the trade.
library;

import 'dart:convert';

import 'validation.dart';

/// abgui's copy of abctl's pre-write structural pass over one `.mobileconfig`.
abstract final class ProfilePreflight {
  /// Apple Business's per-configuration limit. A profile at or above it is rejected on upload,
  /// so it is a hard local failure too (`profileSizeCap`).
  static const int sizeCap = 1 << 20;

  /// "Getting close to the cap" — half of it (`profileSizeWarn`).
  static const int sizeWarn = 512 << 10;

  /// Stops the recursive walker on a pathologically nested document instead of exhausting the
  /// stack (`maxPlistDepth`).
  static const int maxDepth = 64;

  /// Check [bytes] and report what abctl would report for them.
  ///
  /// [bytes] and not a `String`, deliberately: the size cap, the binary-plist magic and the
  /// signed-profile sniff are all statements about BYTES, and — far more importantly — these
  /// have to be the same bytes the write sends on stdin. A check run on a string that is encoded
  /// separately afterwards is a check on a different document than the one Apple receives.
  ///
  /// [name] is only the label the report carries; nothing here derives meaning from it.
  static ProfileReport check(List<int> bytes, {required String name}) {
    final List<ValidationIssue> errors = <ValidationIssue>[];
    final List<ValidationIssue> warnings = <ValidationIssue>[];
    final List<String> payloadTypes = <String>[];
    String identifier = '';
    String displayName = '';

    void fail(String code, String message) =>
        errors.add(ValidationIssue(code: code, message: message));
    void warn(String code, String message) =>
        warnings.add(ValidationIssue(code: code, message: message));

    ProfileReport report() => ProfileReport(
      name: name,
      bytes: bytes.length,
      // Exactly abctl's rule: warnings are advice and never fail a profile, so `ok` is precisely
      // "this profile can be pushed to Apple Business".
      ok: errors.isEmpty,
      identifier: identifier.isEmpty ? null : identifier,
      displayName: displayName.isEmpty ? null : displayName,
      payloadTypes: List<String>.unmodifiable(payloadTypes),
      errors: List<ValidationIssue>.unmodifiable(errors),
      warnings: List<ValidationIssue>.unmodifiable(warnings),
    );

    // abctl's `unreadable` case has no analogue here — there is no file to fail to read, the
    // buffer is in memory. Every other finding below is reported in abctl's order, because that
    // order is what makes one run name every problem in the document rather than the first.
    if (bytes.isEmpty) {
      fail('empty', 'the file is empty.');
      return report();
    }
    final int kib = bytes.length ~/ 1024;
    if (bytes.length >= sizeCap) {
      fail(
        'size-cap',
        'the profile is $kib KiB; Apple Business rejects a configuration of 1 MiB or more.',
      );
    } else if (bytes.length >= sizeWarn) {
      warn(
        'approaching-size-cap',
        'the profile is $kib KiB, close to the 1 MiB Apple Business cap.',
      );
    }
    // The two non-XML shapes worth naming precisely: a converted binary plist and an exported
    // *signed* profile are what operators most often paste in.
    if (_hasPrefix(bytes, _binaryPlistMagic)) {
      fail(
        'binary-plist',
        'this is a binary plist; Apple Business expects an XML .mobileconfig '
            '(convert it with `plutil -convert xml1`).',
      );
      return report();
    }
    if (bytes.first == 0x30) {
      fail(
        'signed-profile',
        'this looks like a signed (DER/PKCS#7) profile; Apple Business expects '
            'the unsigned XML .mobileconfig.',
      );
      return report();
    }

    // `allowMalformed` rather than a throw: bad bytes are a finding to report, not an exception
    // to leak out of a validator. What survives decoding is then judged by the parser below,
    // which is where "this is not XML" gets said in the report's own vocabulary.
    final _PlistDocument document = _parsePlist(
      utf8.decode(bytes, allowMalformed: true),
    );
    final String? parseError = document.error;
    if (parseError != null) {
      fail('xml-parse', 'the XML is malformed: $parseError');
      return report();
    }
    if (document.root != 'plist') {
      if (document.root.isEmpty) {
        fail(
          'not-plist',
          'the file has no XML root element; an XML <plist> document was expected.',
        );
      } else {
        fail(
          'not-plist',
          'the root element is <${document.root}>, not <plist>.',
        );
      }
      return report();
    }

    // A <plist> wrapping something other than a <dict> leaves an empty map here, which reads as
    // "every top-level key is missing" — exactly the right verdict, and the same one abctl's nil
    // map produces.
    final _PlistValue top = document.value;
    identifier = top.dict['PayloadIdentifier']?.text ?? '';
    displayName = top.dict['PayloadDisplayName']?.text ?? '';

    final _PlistValue? content = top.dict['PayloadContent'];
    if (content == null) {
      fail(
        'missing-payload-content',
        'the top-level dictionary has no PayloadContent key.',
      );
    }
    final _PlistValue? payloadType = top.dict['PayloadType'];
    if (payloadType == null) {
      fail(
        'missing-payload-type',
        'the top-level dictionary has no PayloadType key.',
      );
    } else if (payloadType.text != 'Configuration') {
      fail(
        'not-configuration',
        'the top-level PayloadType is "${payloadType.text}"; '
            'Apple Business requires "Configuration".',
      );
    }
    // The one check that exists because it already burned someone, and the reason this whole
    // file is worth its weight. Apple pins the OUTER PayloadVersion to exactly 1 — it versions
    // the profile FORMAT, not the operator's content — and Apple Business answers a PATCH
    // carrying any other value with a 2xx and then does not persist the profile. The live bytes
    // never move, so a GitOps run recomputes the identical change forever and archives a
    // snapshot every pass. It is an ERROR here, before anything is ever pushed.
    final _PlistValue? payloadVersion = top.dict['PayloadVersion'];
    if (payloadVersion == null) {
      fail(
        'payload-version',
        'the top-level dictionary has no PayloadVersion; Apple requires it to be exactly 1 '
            '(https://developer.apple.com/documentation/devicemanagement/toplevel). '
            'Add <key>PayloadVersion</key><integer>1</integer>.',
      );
    } else if (payloadVersion.text != '1') {
      fail(
        'payload-version',
        'the top-level PayloadVersion is ${_describeScalar(payloadVersion)}; Apple requires '
            'exactly 1 — it is the version of the profile FORMAT, not of your content '
            '(https://developer.apple.com/documentation/devicemanagement/toplevel). Apple '
            'Business accepts an upload carrying any other value with a 2xx and then silently '
            'does not store the profile, so the live copy never changes and every sync '
            'recomputes the same change forever. Set it back to <integer>1</integer> and track '
            'your own revisions in git.',
      );
    }
    // Missing and present-but-blank are the same failure to Apple: the identifier is how a
    // profile is addressed on the device.
    if (identifier.isEmpty) {
      fail(
        'missing-payload-identifier',
        'the top-level dictionary has no PayloadIdentifier; '
            'Apple Business identifies a profile by it.',
      );
    }
    if (!top.dict.containsKey('PayloadUUID')) {
      warn(
        'missing-payload-uuid',
        'the top-level dictionary has no PayloadUUID.',
      );
    }
    if (displayName.isEmpty) {
      warn(
        'missing-display-name',
        'the top-level dictionary has no PayloadDisplayName, '
            'so the console shows the file name instead.',
      );
    }
    if (content != null) {
      if (content.array.isEmpty) {
        warn(
          'no-inner-payloads',
          'the profile carries no inner payloads, so it configures nothing.',
        );
      }
      for (int i = 0; i < content.array.length; i++) {
        final _PlistValue item = content.array[i];
        // A nil map on a non-dict item reads as "" — same as abctl.
        final String type = item.dict['PayloadType']?.text ?? '';
        if (item.kind != 'dict') {
          warn(
            'inner-payload-missing-type',
            'inner payload #${i + 1} is a <${item.kind}>, not a <dict>.',
          );
        } else if (type.isEmpty) {
          warn(
            'inner-payload-missing-type',
            'inner payload #${i + 1} has no PayloadType.',
          );
        } else {
          payloadTypes.add(type);
        }
        // Apple documents the per-payload PayloadVersion as a schema version whose allowed value
        // is 1 as well, so a 2 here is still wrong — but only the OUTER one is known to trigger
        // the silent drop, so this stays a warning. A payload that simply omits the key is not
        // flagged: the observed failure needs a present, out-of-spec value.
        final _PlistValue? innerVersion = item.dict['PayloadVersion'];
        if (innerVersion != null && innerVersion.text != '1') {
          warn(
            'inner-payload-version',
            'inner payload ${_innerPayloadLabel(i, type)} has PayloadVersion '
                '${_describeScalar(innerVersion)}; Apple defines the per-payload PayloadVersion '
                'as a schema version whose value is 1.',
          );
        }
      }
    }
    return report();
  }
}

/// `bplist00` — the magic of a converted binary property list.
const List<int> _binaryPlistMagic = <int>[
  0x62,
  0x70,
  0x6C,
  0x69,
  0x73,
  0x74,
  0x30,
  0x30,
];

bool _hasPrefix(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (int i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

/// What a plist key ACTUALLY holds, for a message an operator can act on: the text of a scalar
/// such as `<integer>2</integer>`, else the element itself — so a `<true/>` or a nested `<dict>`
/// is never reported as an empty value.
String _describeScalar(_PlistValue value) =>
    value.text.isNotEmpty ? value.text : '<${value.kind}>';

/// Names an inner payload the way an operator finds it in the file — by PayloadType, falling
/// back to its position when it has none.
String _innerPayloadLabel(int index, String payloadType) =>
    payloadType.isEmpty ? '#${index + 1}' : '"$payloadType"';

// -----------------------------------------------------------------------------------------
// the plist reader
// -----------------------------------------------------------------------------------------
//
// The sliver of the XML property list data model the checks need: a dict, an array, or a scalar
// kept as its text — the same shape as abctl's `plistValue`, for the same reason. Apple ships
// .mobileconfig as an XML property list, and nothing here needs a general-purpose XML tree.
//
// This reader is STRICT in the same direction Go's `encoding/xml` is, and where it cannot be
// sure it raises a parse error rather than guessing: a document this cannot read is a document
// abgui will not push. See the library comment for why erring toward refusal is the safe half.

/// A parsed value: `kind` is the XML element name, `text` is the scalar content ("" for
/// containers), and `dict`/`array` are empty for everything that is not one.
class _PlistValue {
  const _PlistValue(
    this.kind, {
    this.text = '',
    this.dict = const <String, _PlistValue>{},
    this.array = const <_PlistValue>[],
  });

  final String kind;
  final String text;
  final Map<String, _PlistValue> dict;
  final List<_PlistValue> array;
}

/// The document's root element name and the value inside `<plist>`.
///
/// A root that is not `<plist>` comes back NAMED with a zero value and no error, so the caller
/// can report `not-plist`; an empty name means the file held no elements at all. Both are
/// findings, not failures — only [error] is a failure.
class _PlistDocument {
  const _PlistDocument({required this.root, required this.value, this.error});

  final String root;
  final _PlistValue value;
  final String? error;
}

const _PlistValue _emptyValue = _PlistValue('');

_PlistDocument _parsePlist(String source) {
  try {
    return _XmlScanner(source).document();
  } on _XmlError catch (error) {
    return _PlistDocument(root: '', value: _emptyValue, error: error.message);
  }
}

/// A malformed document. Carries the clause that completes "the XML is malformed: …".
class _XmlError implements Exception {
  const _XmlError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One start or end tag.
class _Tag {
  const _Tag(this.name, {this.isEnd = false, this.selfClosing = false});

  final String name;
  final bool isEnd;
  final bool selfClosing;
}

class _XmlScanner {
  _XmlScanner(this.source);

  final String source;
  int _at = 0;

  /// Find the root element, then the single value inside `<plist>`.
  _PlistDocument document() {
    final _Tag? root = _advanceToTag();
    // No elements at all: an empty file, or one holding nothing but a prolog and whitespace.
    if (root == null) {
      return const _PlistDocument(root: '', value: _emptyValue);
    }
    if (root.isEnd) {
      throw _XmlError('the document opens with the end tag </${root.name}>');
    }
    if (root.name != 'plist') {
      return _PlistDocument(root: root.name, value: _emptyValue);
    }
    // `<plist/>` is well formed and holds nothing, which reads downstream as "every top-level
    // key is missing" rather than as a parse failure.
    if (root.selfClosing) {
      return const _PlistDocument(root: 'plist', value: _emptyValue);
    }
    return _PlistDocument(root: 'plist', value: _nextValue(0) ?? _emptyValue);
  }

  /// The next child VALUE of the element currently being read, or null when that element's own
  /// end tag arrives first.
  _PlistValue? _nextValue(int depth) {
    final _Tag? tag = _advanceToTag();
    // Inside an element, so running out of input means the document is truncated.
    if (tag == null) {
      throw const _XmlError('the document ends inside an unclosed element');
    }
    if (tag.isEnd) return null;
    return _parseValue(tag, depth + 1);
  }

  /// Parse the element whose start tag was just consumed.
  _PlistValue _parseValue(_Tag start, int depth) {
    if (depth > ProfilePreflight.maxDepth) {
      throw _XmlError(
        'nested deeper than ${ProfilePreflight.maxDepth} elements at <${start.name}>',
      );
    }
    // `<dict/>`, `<array/>`, `<true/>`: no children, no text, and legitimately empty.
    if (start.selfClosing) return _PlistValue(start.name);

    switch (start.name) {
      case 'dict':
        final Map<String, _PlistValue> dict = <String, _PlistValue>{};
        while (true) {
          final _PlistValue? key = _nextValue(depth);
          if (key == null) return _PlistValue('dict', dict: dict);
          if (key.kind != 'key') {
            throw _XmlError(
              '<dict> holds <${key.kind}> where a <key> was expected',
            );
          }
          final _PlistValue? value = _nextValue(depth);
          if (value == null) {
            throw _XmlError('<key>${key.text}</key> has no value element');
          }
          dict[key.text] = value;
        }
      case 'array':
        final List<_PlistValue> array = <_PlistValue>[];
        while (true) {
          final _PlistValue? item = _nextValue(depth);
          if (item == null) return _PlistValue('array', array: array);
          array.add(item);
        }
      default:
        return _PlistValue(start.name, text: _readScalar(start.name).trim());
    }
  }

  /// Advance past character data and markup noise to the next start/end tag; null at end of
  /// input.
  _Tag? _advanceToTag() {
    while (true) {
      final int open = source.indexOf('<', _at);
      if (open < 0) {
        _at = source.length;
        return null;
      }
      _at = open;
      if (_skippedNoise()) continue;
      return _readTag();
    }
  }

  /// Consume a comment, CDATA section, processing instruction or DOCTYPE at the cursor.
  /// Returns whether one was there.
  ///
  /// The DOCTYPE case is not hypothetical: every `.mobileconfig` Apple's tools emit opens with
  /// the PropertyList DTD declaration, so a reader that choked on it would reject every real
  /// profile in the fleet.
  bool _skippedNoise() {
    if (source.startsWith('<!--', _at)) {
      _skipPast('-->', 'comment');
      return true;
    }
    if (source.startsWith('<![CDATA[', _at)) {
      _skipPast(']]>', 'CDATA section');
      return true;
    }
    if (source.startsWith('<?', _at)) {
      _skipPast('?>', 'processing instruction');
      return true;
    }
    if (source.startsWith('<!', _at)) {
      _skipDoctype();
      return true;
    }
    return false;
  }

  void _skipPast(String close, String what) {
    final int end = source.indexOf(close, _at);
    if (end < 0) throw _XmlError('an unterminated $what');
    _at = end + close.length;
  }

  /// Skip `<!DOCTYPE …>`, including a bracketed internal subset and any quoted system/public
  /// identifiers — a `>` inside either is not the end of the declaration.
  void _skipDoctype() {
    int i = _at + 2;
    bool inSubset = false;
    while (i < source.length) {
      final String c = source[i];
      if (c == '"' || c == "'") {
        final int close = source.indexOf(c, i + 1);
        if (close < 0) {
          throw const _XmlError(
            'an unterminated quoted string in the DOCTYPE declaration',
          );
        }
        i = close + 1;
        continue;
      }
      if (c == '[') {
        inSubset = true;
      } else if (c == ']') {
        inSubset = false;
      } else if (c == '>' && !inSubset) {
        _at = i + 1;
        return;
      }
      i++;
    }
    throw const _XmlError('an unterminated DOCTYPE declaration');
  }

  /// Read the tag at the cursor.
  ///
  /// Attribute VALUES are discarded — nothing the checks ask about lives in an attribute — but
  /// attribute SYNTAX is enforced, and that is not fussiness. A scanner that merely raced to the
  /// next `>` accepted `<plist version=1.0>`, which Go's strict decoder rejects outright; that is
  /// abgui saying "structurally fine" about a document abctl will refuse, i.e. a green pre-flight
  /// followed by a failed write with no explanation on the screen that promised one. Reading the
  /// quotes properly is also what stops a `>` inside `note="a > b"` from ending the tag early.
  ///
  /// A namespace prefix is dropped, because Go's decoder reports `Name.Local` and abctl compares
  /// against that: `<p:plist>` is a `plist` element to the authority, and it has to be one here
  /// too or the two disagree about what the document even is.
  _Tag _readTag() {
    int i = _at + 1;
    bool isEnd = false;
    if (i < source.length && source[i] == '/') {
      isEnd = true;
      i++;
    }
    final int nameStart = i;
    while (i < source.length && _isNameChar(source.codeUnitAt(i))) {
      i++;
    }
    final String qualified = source.substring(nameStart, i);
    if (qualified.isEmpty) throw const _XmlError('a tag with no element name');
    final int colon = qualified.lastIndexOf(':');
    final String name = colon < 0 ? qualified : qualified.substring(colon + 1);
    if (name.isEmpty) {
      throw _XmlError(
        '<$qualified> has a namespace prefix and no element name',
      );
    }

    while (true) {
      i = _skipSpace(i);
      if (i >= source.length) throw _XmlError('an unterminated <$name> tag');
      final String c = source[i];
      if (c == '>') {
        _at = i + 1;
        return _Tag(name, isEnd: isEnd);
      }
      if (c == '/') {
        if (i + 1 >= source.length || source[i + 1] != '>') {
          throw _XmlError('a stray / inside <$name>');
        }
        _at = i + 2;
        return _Tag(name, isEnd: isEnd, selfClosing: true);
      }
      if (isEnd) {
        throw _XmlError('the end tag </$name> carries more than its name');
      }
      final int attributeStart = i;
      while (i < source.length && _isNameChar(source.codeUnitAt(i))) {
        i++;
      }
      if (i == attributeStart) {
        throw _XmlError('an unparseable attribute in <$name>');
      }
      final String attribute = source.substring(attributeStart, i);
      i = _skipSpace(i);
      if (i >= source.length || source[i] != '=') {
        throw _XmlError('the attribute $attribute in <$name> has no value');
      }
      i = _skipSpace(i + 1);
      if (i >= source.length || (source[i] != '"' && source[i] != "'")) {
        throw _XmlError(
          'the attribute $attribute in <$name> has an unquoted value',
        );
      }
      final String quote = source[i];
      final int close = source.indexOf(quote, i + 1);
      if (close < 0) {
        throw _XmlError('an unterminated attribute value in <$name>');
      }
      i = close + 1;
    }
  }

  int _skipSpace(int from) {
    int i = from;
    while (i < source.length) {
      final int unit = source.codeUnitAt(i);
      if (unit != 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) break;
      i++;
    }
    return i;
  }

  /// The character data of a scalar element, up to its matching end tag.
  ///
  /// A nested element inside a scalar has its subtree consumed and its text DISCARDED, which is
  /// what Go's decoder does when it unmarshals an element into a string. Folding a child's text
  /// into the parent's would invent a value the authority never sees — and the values read here
  /// decide whether a profile is pushed.
  String _readScalar(String name) {
    final StringBuffer text = StringBuffer();
    while (true) {
      final int open = source.indexOf('<', _at);
      if (open < 0) throw _XmlError('unterminated <$name> element');
      text.write(_decodeEntities(source.substring(_at, open)));
      _at = open;
      if (source.startsWith('<![CDATA[', _at)) {
        final int end = source.indexOf(']]>', _at);
        if (end < 0) throw const _XmlError('an unterminated CDATA section');
        text.write(source.substring(_at + '<![CDATA['.length, end));
        _at = end + 3;
        continue;
      }
      if (_skippedNoise()) continue;
      final _Tag tag = _readTag();
      if (tag.isEnd) {
        if (tag.name != name) {
          throw _XmlError('</${tag.name}> closes <$name>');
        }
        return text.toString();
      }
      if (!tag.selfClosing) _skipElement(tag.name);
    }
  }

  /// Consume an element's whole subtree, including nested elements of the same name.
  void _skipElement(String name) {
    int depth = 1;
    while (depth > 0) {
      final int open = source.indexOf('<', _at);
      if (open < 0) throw _XmlError('unterminated <$name> element');
      _at = open;
      if (_skippedNoise()) continue;
      final _Tag tag = _readTag();
      if (tag.selfClosing) continue;
      depth += tag.isEnd ? -1 : 1;
    }
  }

  /// Expand the five predefined entities and numeric character references.
  ///
  /// An entity this does not know is an ERROR rather than passed through literally, matching a
  /// strict parser: `&myEntity;` in a profile means a DTD-defined entity abgui cannot resolve,
  /// and silently keeping the raw text would put a different string in front of the checks than
  /// the one Apple will store.
  String _decodeEntities(String raw) {
    if (!raw.contains('&')) return raw;
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (i < raw.length) {
      final int amp = raw.indexOf('&', i);
      if (amp < 0) {
        out.write(raw.substring(i));
        break;
      }
      out.write(raw.substring(i, amp));
      final int semi = raw.indexOf(';', amp);
      if (semi < 0) throw const _XmlError('an unterminated & entity reference');
      out.write(_entityText(raw.substring(amp + 1, semi)));
      i = semi + 1;
    }
    return out.toString();
  }

  String _entityText(String entity) {
    switch (entity) {
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'amp':
        return '&';
      case 'apos':
        return "'";
      case 'quot':
        return '"';
    }
    if (entity.startsWith('#')) {
      final bool hex =
          entity.length > 1 && (entity[1] == 'x' || entity[1] == 'X');
      final int? code = int.tryParse(
        entity.substring(hex ? 2 : 1),
        radix: hex ? 16 : 10,
      );
      if (code != null && code >= 0 && code <= 0x10FFFF) {
        return String.fromCharCode(code);
      }
    }
    throw _XmlError('an unknown entity reference &$entity;');
  }
}

/// XML name characters, plus everything above ASCII (which XML allows in a name and which no
/// check here needs to distinguish further).
bool _isNameChar(int unit) {
  if (unit >= 0x61 && unit <= 0x7A) return true; // a-z
  if (unit >= 0x41 && unit <= 0x5A) return true; // A-Z
  if (unit >= 0x30 && unit <= 0x39) return true; // 0-9
  if (unit > 0x7F) return true;
  return unit == 0x5F ||
      unit == 0x2D ||
      unit == 0x2E ||
      unit == 0x3A; // _ - . :
}
