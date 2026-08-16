// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The configuration WRITE surface: create, replace (the GUI's "edit"), and delete.
///
/// Everything reachable from here changes a live Apple Business Manager tenant belonging to a
/// real company. That is not a reason for extra dialogs; it is the reason for four specific
/// rules, each of which is here because the alternative has already gone wrong somewhere:
///
///  1. **The bytes that are checked are the bytes that are sent.** The editor holds a `String`;
///     [_ConfigEditorDialogState._save] encodes it to UTF-8 ONCE and hands the same `List<int>`
///     to [ProfilePreflight.check] and to the client. A check run on a separately-encoded copy
///     is a check on a different document than the one Apple receives.
///  2. **A hard finding blocks the write outright**, before abctl is invoked at all — see
///     [ProfilePreflight] for why the check is a port rather than a call to `validate --json`,
///     which cannot see an unsaved buffer.
///  3. **The XML travels on stdin.** `AbctlArgs` spells `-f -`, `AbctlClient` passes the bytes
///     to `ProcessRunner`, and a partial stdin write comes back as an `AbctlCliError` saying
///     abctl may have received only part of the profile. That error is displayed verbatim and
///     is NEVER downgraded to a warning: a truncated `create` is worse than no create at all,
///     and the exit code alone cannot tell "created what you meant" from "created half of it".
///  4. **Nothing here reports success from its own optimism.** After a write the affected
///     resource is RE-READ — the list, and the profile itself — and what is shown is abctl's
///     own [WriteOutcome], including `treeUpdated` and the read-back verdict. Apple answers a
///     write carrying an out-of-spec profile with a 2xx and then silently declines to store it,
///     so a clean exit is an acknowledgement, not evidence.
///
/// The Swift `ConfigEditorView` this replaces did none of 1, 2 or 4: it validated nothing,
/// dismissed itself the moment `replaceConfiguration` returned true, and threw the outcome
/// document away — so `treeUpdated:false` (Apple written, git not) was invisible until it
/// resurfaced as a drift row days later with nothing connecting the two.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:abgui/src/models/profile_check.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/models/validation.dart';
import 'package:abgui/src/models/write_outcome.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/load_token.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/text_labels.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/copy_button.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The starter profile the New dialog can insert.
///
/// It is INSERTED on request rather than pre-filled, and the difference matters: a buffer that
/// arrives pre-populated is a buffer an operator can push without having read it, and this one
/// carries placeholder identifiers. Pressing a button to get it is one deliberate act; finding
/// it already there is none.
///
/// The template passes [ProfilePreflight] with no errors AND no warnings — pinned by a test,
/// because shipping a starter that abgui's own check complains about would teach the operator
/// that the report is noise on the very first thing they ever validate.
const String starterProfileTemplate =
    '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>PayloadType</key>
\t<string>Configuration</string>
\t<!-- PayloadVersion is the version of the profile FORMAT, not of your content, and Apple
\t     requires exactly 1. Apple Business accepts any other value with a 2xx and then never
\t     stores the profile. Track your own revisions in git. -->
\t<key>PayloadVersion</key>
\t<integer>1</integer>
\t<key>PayloadIdentifier</key>
\t<string>com.example.$_placeholder</string>
\t<key>PayloadUUID</key>
\t<string>$_placeholder-WITH-A-UUID</string>
\t<key>PayloadDisplayName</key>
\t<string>$_placeholder</string>
\t<key>PayloadContent</key>
\t<array>
\t\t<dict>
\t\t\t<key>PayloadType</key>
\t\t\t<string>com.apple.$_placeholder</string>
\t\t\t<key>PayloadVersion</key>
\t\t\t<integer>1</integer>
\t\t\t<key>PayloadIdentifier</key>
\t\t\t<string>com.example.$_placeholder.payload</string>
\t\t\t<key>PayloadUUID</key>
\t\t\t<string>$_placeholder-WITH-A-UUID</string>
\t\t</dict>
\t</array>
</dict>
</plist>
''';

const String _placeholder = 'REPLACE-ME';

/// The file name abctl will store this configuration under.
///
/// abctl's `configName` (`internal/cli/imperative.go`): a name that already has an extension is
/// left alone, anything else gains `.mobileconfig`. Mirrored here — and shown under the name
/// field — because that string becomes the file in `gitops/lib/`, the key every blueprint
/// manifest references, and the name in every later plan. Its own trap is reproduced rather than
/// smoothed over: `Wi-Fi 6.1` already "has an extension" (`.1`), so it is stored verbatim and
/// never matches a manifest entry saying `Wi-Fi 6.1.mobileconfig`. An operator finds that out
/// here, before the write, or three screens later.
String abctlStoredConfigName(String typed) {
  final String name = typed.trim();
  if (name.isEmpty) return '';
  for (int i = name.length - 1; i >= 0; i--) {
    final String c = name[i];
    if (c == '/' || c == r'\') break;
    if (c == '.') return name;
  }
  return '$name.mobileconfig';
}

/// Why a configuration write must not run right now, or null when it may.
///
/// **The workspace is a precondition for a WRITE in a way it never was for a read.** abctl roots
/// `gitops/` at its own working directory, and every one of these verbs writes the tree as well
/// as the tenant: `create` and `replace` drop the profile into `gitops/lib/` and record a
/// baseline, `delete` archives into `gitops/archive/` first. With no workspace chosen, abgui
/// passes no cwd, abctl resolves `gitops/` against whatever directory the app was launched from,
/// and the result is the worst shape this codebase knows — Apple Business changed, a manifest
/// written into a tree nobody will ever look at, and `treeUpdated:true` reported for it. The same
/// mismatch produced the `detach-config` row that came back on every refresh with nothing in the
/// GUI able to clear it; there the tree was merely wrong, here it would also be the only copy of
/// a profile that was just deleted.
///
/// Shared by the dialogs (which enforce it) and the screen (which disables its controls with it),
/// so a disabled button and a refused write give the same reason in the same words.
String? configWriteBlocker(String? workspace) {
  if (workspace != null && workspace.isNotEmpty) return null;
  return 'No GitOps workspace is chosen. abctl resolves gitops/ against its working directory, '
      'so a write from here would change Apple Business and then put the archive, the profile '
      'and the baseline into whatever folder abgui happens to be running in. Choose the '
      'workspace on the Diff / Drift screen first.';
}

// =============================================================================================
// the editor
// =============================================================================================

/// Create a configuration, or replace an existing one's profile.
class ConfigEditorDialog extends ConsumerStatefulWidget {
  const ConfigEditorDialog({super.key, this.existing});

  /// Null creates; non-null replaces that configuration's profile.
  final Resource? existing;

  /// Present the dialog. Answers whether a write reached Apple Business, so the caller can act
  /// on it — the dialog re-reads the configuration list itself either way.
  static Future<bool> show(BuildContext context, {Resource? existing}) async {
    final bool? wrote = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => ConfigEditorDialog(existing: existing),
    );
    return wrote ?? false;
  }

  @override
  ConsumerState<ConfigEditorDialog> createState() => _ConfigEditorDialogState();
}

class _ConfigEditorDialogState extends ConsumerState<ConfigEditorDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _xml = TextEditingController();

  /// Cancels the profile READ only.
  ///
  /// There is deliberately no cancel token on the write. A `replace` is archive → PATCH →
  /// write the git tree → read back; killing abctl part way through leaves the tenant and the
  /// workspace disagreeing with each other and nothing on screen able to say where it stopped.
  /// A read can be abandoned safely because abandoning it changes nothing.
  final CancelToken _readCancel = CancelToken();

  /// Loaded ONCE into state. Never from `build`, which runs again on every theme change, window
  /// resize and keystroke — one abctl process per repaint.
  bool _loading = false;
  String? _loadError;

  /// The last pre-flight, and the exact text it judged. Keeping the text is what makes a stale
  /// report detectable: edit one character and the verdict on screen is no longer about the
  /// buffer. [_save] re-checks regardless, so this is presentation, not the gate.
  ProfileReport? _report;
  String? _checkedText;

  bool _writing = false;

  /// The post-write re-read. Its own flag, because it must NOT hold the dialog open the way
  /// [_writing] does — see [_rereadAfterWrite].
  bool _rereading = false;

  /// One generation for the reads that refill the editor, so a completion can tell whether it is
  /// still the current answer.
  ///
  /// **Both reads write `_xml.text`, which is the document the next write SENDS — so a stale one
  /// landing is not a stale label, it is the wrong bytes going to Apple.** Two shapes needed it.
  /// `_canWrite` did not gate on [_rereading] and `_write` clears `_writing` before awaiting the
  /// re-read, so "Check & Replace" was live again from the moment the PATCH returned: a second
  /// press started a second write, and the FIRST re-read then stamped Apple's pre-second-write
  /// copy over the editor mid-flight and cleared the pre-flight verdict for the bytes actually
  /// being sent. The two re-reads then raced with nothing to arbitrate, so the "what Apple
  /// actually stored" evidence — the entire point of the re-read — could end up being the older
  /// fetch. Separately, `_load`'s "Try Again" could stack reads that each overwrote the buffer.
  ///
  /// `archive_screen.dart` uses a dedicated generation for the same shape of problem and explains
  /// why; this file already imported `load_token.dart`, but only for `loadErrorText`.
  final LoadGeneration _reads = LoadGeneration('configEditor.read');

  String? _writeError;
  WriteOutcome? _outcome;
  String? _rereadError;
  bool _wrote = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    // After the frame, not during it: every abctl run records into `commandLogProvider`
    // synchronously before its first await, and Riverpod throws if a provider is modified while
    // the widget tree is building.
    if (_isEdit) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
    }
    // A rebuild per keystroke, so the pre-flight verdict can be marked stale and the byte count
    // stays honest while the operator types.
    _xml.addListener(_onEdited);
    _name.addListener(_onEdited);
  }

  @override
  void dispose() {
    _readCancel.cancel();
    _xml.removeListener(_onEdited);
    _name.removeListener(_onEdited);
    _xml.dispose();
    _name.dispose();
    super.dispose();
  }

  void _onEdited() {
    if (mounted) setState(() {});
  }

  /// Fetch the live profile with `get configuration <id> --profile`.
  Future<void> _load() async {
    final Resource? existing = widget.existing;
    if (existing == null || !mounted) return;
    // Re-entrancy, not just a spinner: "Try Again" is a plain button beside an error, and every
    // press that got through started another read whose completion overwrote `_xml.text`.
    if (_loading) return;
    final LoadToken token = _reads.begin();
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final String live = await ref
          .read(abctlClientProvider)
          .configurationProfile(existing.id, cancel: _readCancel);
      if (!mounted || token.isStale) return;
      setState(() {
        // Verbatim, exactly as abctl printed it. This is the document that will be PATCHed back
        // if the operator changes one line of it, so anything that reformatted it on the way in
        // would silently rewrite a profile nobody asked to rewrite.
        _xml.text = live;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || token.isStale) return;
      setState(() {
        _loadError = loadErrorText(error);
        _loading = false;
      });
    }
  }

  /// Run the pre-flight and, if it is clean, write.
  ///
  /// The check happens HERE rather than being trusted from [_report], so an operator who edits
  /// after checking, or who never checks at all, still cannot reach abctl with a profile that
  /// has a hard finding.
  Future<void> _save() async {
    if (_writing) return;
    // Re-checked at the moment of the write, not only when the button was drawn: the workspace
    // can be cleared from another screen while this dialog is open.
    if (configWriteBlocker(ref.read(workspaceProvider)) != null) return;
    final String text = _xml.text;
    // ONE encoding. These bytes are judged below and, unchanged, are the bytes on stdin.
    final List<int> bytes = utf8.encode(text);
    final ProfileReport report = ProfilePreflight.check(bytes, name: _fileName);
    setState(() {
      _report = report;
      _checkedText = text;
      _writeError = null;
      _rereadError = null;
      _outcome = null;
    });
    if (!report.ok) return; // blocked: abctl is never invoked
    await _write(bytes);
  }

  /// Check without writing, for an operator who wants the report first.
  void _check() {
    final String text = _xml.text;
    setState(() {
      _report = ProfilePreflight.check(utf8.encode(text), name: _fileName);
      _checkedText = text;
    });
  }

  Future<void> _write(List<int> bytes) async {
    setState(() => _writing = true);
    String? failure;
    WriteOutcome? outcome;
    try {
      final Resource? existing = widget.existing;
      outcome = existing == null
          ? await ref
                .read(abctlClientProvider)
                .createConfiguration(name: _name.text.trim(), xml: bytes)
          : await ref
                .read(abctlClientProvider)
                .replaceConfiguration(id: existing.id, xml: bytes);
    } catch (error) {
      // Includes the truncated-stdin case, which `ProcessRunner` raises as an `AbctlCliError`
      // saying abctl may have received only part of the profile. It is shown as it arrives:
      // there is no safe way to summarize "the tenant may hold half a profile".
      failure = loadErrorText(error);
    }
    if (!mounted) return;
    setState(() {
      _writing = false;
      _outcome = outcome;
      _writeError = failure;
      _wrote = _wrote || outcome != null;
    });
    if (outcome != null) await _rereadAfterWrite(outcome);
  }

  /// Re-read what the write touched: the configuration list, then the profile itself.
  ///
  /// Nothing is inferred from the fact that the command succeeded. The list is re-fetched rather
  /// than patched in place, and the editor is refilled from Apple's copy rather than from the
  /// buffer that was sent — so what is on screen afterwards is what the tenant holds, which for
  /// a write Apple acknowledged and did not store is a different thing entirely.
  Future<void> _rereadAfterWrite(WriteOutcome outcome) async {
    // Not folded into `_writing`: that flag holds the dialog open (see the PopScope), and a READ
    // must never do that. Abandoning a read costs nothing, while abandoning a write mid-flight is
    // the one state nothing on screen could describe.
    // Shares the generation with [_load]: both end in `_xml.text = live`, so "is my answer still
    // the current one" is one question, not two. A second write started while this is in flight
    // takes the generation, and this read then publishes nothing.
    final LoadToken token = _reads.begin();
    setState(() => _rereading = true);
    await ref
        .read(inventoryProvider.notifier)
        .load(InventoryPane.configurations);
    if (!mounted || token.isStale) return;

    final String id = widget.existing?.id ?? outcome.id ?? '';
    if (id.isEmpty) {
      setState(() => _rereading = false);
      return;
    }
    try {
      // No cancel token: this read is short, and its answer is the only independent evidence on
      // the screen about what Apple actually stored.
      final String live = await ref
          .read(abctlClientProvider)
          .configurationProfile(id);
      if (!mounted || token.isStale) return;
      setState(() {
        _xml.text = live;
        // The report described the document that was SENT. Apple's copy is a different document
        // until proven otherwise, so the old verdict is cleared rather than left to look current.
        _report = null;
        _checkedText = null;
        _rereading = false;
      });
    } catch (error) {
      if (!mounted || token.isStale) return;
      // A failed re-read is not a failed write, and saying so is the whole point of keeping this
      // in its own slot.
      setState(() {
        _rereadError = loadErrorText(error);
        _rereading = false;
      });
    }
  }

  // -----------------------------------------------------------------------------------------
  // derived state
  // -----------------------------------------------------------------------------------------

  String get _fileName {
    final Resource? existing = widget.existing;
    if (existing != null) {
      return existing.attr('name') ?? existing.displayName();
    }
    final String derived = abctlStoredConfigName(_name.text);
    return derived.isEmpty ? 'profile.mobileconfig' : derived;
  }

  /// The argv a preview renders and the client runs — one builder, so they cannot disagree.
  List<String> get _argv {
    final Resource? existing = widget.existing;
    return existing == null
        ? AbctlArgs.createConfiguration(_name.text.trim())
        : AbctlArgs.replaceConfiguration(existing.id);
  }

  bool get _reportIsStale => _checkedText != null && _checkedText != _xml.text;

  bool get _canWrite {
    // [_rereading] belongs in this list even though it is only a READ. `_write` clears `_writing`
    // before it awaits the re-read, so without this the button came back to life the instant the
    // PATCH returned — while the fetch that is meant to be the independent evidence of what Apple
    // stored was still in flight, and would land on top of whatever the operator typed next.
    if (_writing || _loading || _rereading) return false;
    if (configWriteBlocker(ref.watch(workspaceProvider)) != null) return false;
    // A create that already succeeded must not be repeatable from the same dialog. There is no
    // id in a POST to make it idempotent, so a second press is a second configuration — same
    // name, same PayloadIdentifier, two rows in Apple Business that overwrite each other on the
    // device. Replace has none of that: it names an id, so pressing it again re-archives and
    // re-PATCHes the same configuration, which is a legitimate second round of editing.
    if (_outcome != null && !_isEdit) return false;
    if (_xml.text.trim().isEmpty) return false;
    if (!_isEdit && _name.text.trim().isEmpty) return false;
    return true;
  }

  /// Placeholders from the starter template still sitting in the buffer.
  ///
  /// abgui's own advice, kept OUT of the [ProfileReport] on purpose: that report carries abctl's
  /// codes and abctl's sentences, and mixing an abgui heuristic into it would make the two
  /// indistinguishable in a screenshot. It is a warning rather than a block because
  /// `REPLACE-ME` is a string match, and a string match must not be able to veto a write.
  bool get _hasTemplatePlaceholders => _xml.text.contains(_placeholder);

  // -----------------------------------------------------------------------------------------
  // chrome
  // -----------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Size window = MediaQuery.sizeOf(context);
    // Encoded ONCE per build and shared by the footer and the CLI preview. Two call sites each
    // measuring the buffer their own way is how the size beside the 1 MiB cap and the size in
    // the copyable command came to disagree — and `length` on a `String` is a count of UTF-16
    // code units, which for any profile carrying a non-ASCII display name is not the number of
    // bytes Apple receives.
    final int bytes = utf8.encode(_xml.text).length;
    return PopScope(
      // Not dismissible mid-write — not even by the barrier or Escape. abctl is between an
      // archive, a tenant call and a git write; closing the window would leave that running with
      // nowhere to report, and the operator with no record of what happened.
      canPop: !_writing,
      child: Dialog(
        backgroundColor: ab.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AbSpace.radius),
          side: BorderSide(color: ab.line),
        ),
        child: SizedBox(
          width: math.min(940, math.max(360, window.width - 80)),
          height: math.min(760, math.max(320, window.height - 80)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(ab),
              _banner(),
              if (!_isEdit) _nameField(ab),
              Expanded(child: _editor(ab)),
              _findings(ab),
              _CommandPreview(argv: _argv, stdinBytes: bytes),
              _footer(ab, bytes),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(AbColors ab) {
    final Resource? existing = widget.existing;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.sm,
        AbSpace.sm,
        AbSpace.sm,
      ),
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border(bottom: BorderSide(color: ab.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(abIcon(_isEdit ? 'pencil' : 'plus'), size: 15, color: ab.dim),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    existing == null
                        ? 'New configuration'
                        : 'Edit ${existing.attr('name') ?? existing.displayName()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                ),
                MonoText(
                  existing?.id ?? 'Apple Business assigns the id on create',
                  size: 11,
                  color: ab.faint,
                ),
              ],
            ),
          ),
          if (!_isEdit)
            ToolbarButton(
              icon: abIcon('doc.on.doc'),
              label: 'Starter template',
              tooltip: _xml.text.trim().isEmpty
                  ? 'Insert a minimal, valid .mobileconfig to edit. It carries '
                        'REPLACE-ME placeholders you must change before creating it.'
                  : 'Unavailable while the editor holds something — the template '
                        'would replace it. Clear the editor first.',
              // Disabled rather than silently declining: a button that swallows the click is
              // indistinguishable from a broken one, and the reason it is unavailable (it would
              // overwrite work) is exactly what the operator needs to hear.
              onPressed: _writing || _xml.text.trim().isNotEmpty
                  ? null
                  : _insertTemplate,
            ),
          CopyButton(
            text: () => _xml.text,
            enabled: _xml.text.isNotEmpty,
            label: 'Copy XML',
            tooltip: 'Copy the profile in the editor to the clipboard.',
          ),
        ],
      ),
    );
  }

  void _insertTemplate() {
    // Never over the top of work. Replacing a buffer someone has typed into — or a live profile
    // just fetched — with a template is the one irreversible thing this button could do.
    if (_xml.text.trim().isNotEmpty) return;
    setState(() {
      _xml.text = starterProfileTemplate;
      _report = null;
      _checkedText = null;
    });
  }

  Widget _banner() {
    // Watched, not read: choosing (or clearing) the workspace on another screen has to change
    // this dialog's answer while it is open, because it changes whether the write is safe.
    final String? blocked = configWriteBlocker(ref.watch(workspaceProvider));
    if (blocked != null) {
      return NoticeBanner(
        icon: abIcon('folder.badge.questionmark'),
        tone: AbSeverity.danger,
        text: 'No workspace — writing is unavailable',
        detail: blocked,
      );
    }
    if (_isEdit) {
      return NoticeBanner(
        icon: abIcon('exclamationmark.triangle'),
        tone: AbSeverity.drift,
        text: 'Replaces the live profile',
        detail:
            'abctl archives the current version into gitops/archive/ first, then PATCHes '
            'Apple Business. A 2xx from Apple is not proof it was stored — the outcome below '
            'reports what abctl read back.',
      );
    }
    return NoticeBanner(
      icon: abIcon('exclamationmark.triangle'),
      tone: AbSeverity.drift,
      text: 'Creates a configuration in Apple Business',
      detail:
          'Checked here first, then POSTed. A 2xx from Apple is not proof it was stored — the '
          'outcome below reports what abctl read back.',
    );
  }

  Widget _nameField(AbColors ab) {
    final String stored = abctlStoredConfigName(_name.text);
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AbSpace.radius),
      borderSide: BorderSide(color: ab.line),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.md,
        AbSpace.md,
        AbSpace.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 260,
            height: 28,
            child: TextField(
              controller: _name,
              enabled: !_writing,
              style: TextStyle(fontSize: 12, color: ab.text),
              cursorColor: ab.accent,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: ab.surface,
                hintText: 'Name (e.g. WiFi-Corp)',
                hintStyle: TextStyle(fontSize: 12, color: ab.faint),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AbSpace.sm,
                  vertical: 6,
                ),
                border: border,
                enabledBorder: border,
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AbSpace.radius),
                  borderSide: BorderSide(color: ab.accent),
                ),
              ),
            ),
          ),
          const SizedBox(width: AbSpace.md),
          Expanded(
            child: MonoText(
              stored.isEmpty ? 'stored as …' : 'stored as $stored',
              size: 11,
              color: ab.faint,
            ),
          ),
        ],
      ),
    );
  }

  Widget _editor(AbColors ab) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final String? loadError = _loadError;
    if (loadError != null) {
      return EmptyState(
        icon: abIcon('exclamationmark.triangle'),
        title: 'Couldn\'t load the profile',
        message:
            '$loadError\n\nNothing has been written. Editing a profile abgui could not read '
            'would mean replacing a live document with one built from nothing.',
        tone: AbSeverity.danger,
        action: ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Try Again',
          weight: AbToolbarWeight.titled,
          tooltip: 'Fetch the live profile again.',
          onPressed: () => unawaited(_load()),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbSpace.md),
      child: TextField(
        controller: _xml,
        enabled: !_writing,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        // Monospaced because it is machine data. It WRAPS, unlike the read-only Profile viewer
        // next door, which scrolls horizontally so element boundaries stay visible: a caret you
        // cannot reach without a horizontal scrollbar is a worse trade in a field you are
        // typing into. The viewer remains the way to read a profile; this is the way to edit it.
        style: AbType.mono(context, size: 11.5, color: ab.text),
        cursorColor: ab.accent,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: ab.canvas,
          hintText: _isEdit
              ? ''
              : 'Paste a .mobileconfig, or insert the starter template above.',
          hintStyle: AbType.mono(context, size: 11.5, color: ab.faint),
          contentPadding: const EdgeInsets.all(AbSpace.sm),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AbSpace.radius),
            borderSide: BorderSide(color: ab.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AbSpace.radius),
            borderSide: BorderSide(color: ab.line),
          ),
        ),
      ),
    );
  }

  /// The pre-flight report, the write outcome, and every failure that belongs to neither.
  Widget _findings(AbColors ab) {
    final List<Widget> panels = <Widget>[
      if (_hasTemplatePlaceholders)
        const NoticeBanner(
          icon: Icons.edit_note_outlined,
          tone: AbSeverity.drift,
          text: 'The template placeholders are still here',
          detail:
              'REPLACE-ME appears in the profile. Creating it as-is puts a placeholder '
              'PayloadIdentifier and UUID into Apple Business.',
        ),
      if (_writeError != null)
        _Panel(
          tone: AbSeverity.danger,
          symbol: 'xmark.circle',
          title: 'abctl did not complete the write',
          body: _writeError!,
          // The one failure that needs saying twice, because it is the one whose damage is
          // invisible: a stdin write that stopped part way sends Apple a truncated profile.
          footnote:
              'If this says abctl may have received only part of the profile, treat the '
              'configuration as being in an unknown state and check it in Apple Business '
              'before retrying.',
        ),
      if (_rereadError != null)
        _Panel(
          tone: AbSeverity.drift,
          symbol: 'exclamationmark.triangle',
          title: 'The write landed; the read-back did not',
          body: _rereadError!,
          footnote:
              'This says nothing about whether the write succeeded — abctl already reported '
              'on that below. It only means abgui could not fetch the profile again to show '
              'you the stored copy.',
        ),
      if (_outcome != null) _WriteOutcomeReport(outcome: _outcome!),
      if (_report != null)
        _PreflightReport(report: _report!, stale: _reportIsStale),
    ];
    if (panels.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ab.line)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AbSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < panels.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: AbSpace.sm),
              panels[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _footer(AbColors ab, int bytes) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbSpace.md,
        vertical: AbSpace.sm,
      ),
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border(top: BorderSide(color: ab.line)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: MonoText(
              '${lineCount(_xml.text)} lines · ${byteSizeLabel(bytes)}',
              size: 11,
              color: bytes >= ProfilePreflight.sizeWarn ? ab.drift : ab.faint,
            ),
          ),
          if (_writing || _rereading) ...<Widget>[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: ab.accent,
              ),
            ),
            const SizedBox(width: AbSpace.sm),
          ],
          ToolbarButton(
            icon: abIcon('checkmark.shield'),
            label: 'Check profile',
            weight: AbToolbarWeight.titled,
            tooltip:
                'Run the structural check without writing anything. Nothing is '
                'sent to Apple Business.',
            onPressed: _writing || _xml.text.trim().isEmpty ? null : _check,
          ),
          const SizedBox(width: AbSpace.sm),
          TextButton(
            // Disabled, not hidden, while a write is in flight: the operator has to be able to
            // see that closing is unavailable rather than wonder why the click did nothing.
            onPressed: _writing
                ? null
                : () => Navigator.of(context).pop(_wrote),
            child: Text(_outcome == null ? 'Cancel' : 'Close'),
          ),
          const SizedBox(width: AbSpace.xs),
          FilledButton(
            onPressed: _canWrite ? () => unawaited(_save()) : null,
            child: Text(_isEdit ? 'Check & Replace' : 'Check & Create'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================================
// delete
// =============================================================================================

/// Delete a configuration from Apple Business.
///
/// Two phases in one dialog — confirm, then the outcome — because the archive path abctl
/// reports is the location of the ONLY remaining copy of the profile, and a confirmation sheet
/// that dismissed itself on success would throw that away at the exact moment it became the
/// most important string on screen.
class ConfigDeleteDialog extends ConsumerStatefulWidget {
  const ConfigDeleteDialog({super.key, required this.config});

  final Resource config;

  /// Answers whether the delete reached Apple Business.
  static Future<bool> show(
    BuildContext context, {
    required Resource config,
  }) async {
    final bool? deleted = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => ConfigDeleteDialog(config: config),
    );
    return deleted ?? false;
  }

  @override
  ConsumerState<ConfigDeleteDialog> createState() => _ConfigDeleteDialogState();
}

class _ConfigDeleteDialogState extends ConsumerState<ConfigDeleteDialog> {
  bool _deleting = false;
  String? _error;
  WriteOutcome? _outcome;

  String get _name => widget.config.attr('name') ?? widget.config.displayName();

  Future<void> _delete() async {
    if (_deleting) return;
    if (configWriteBlocker(ref.read(workspaceProvider)) != null) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    String? failure;
    WriteOutcome? outcome;
    try {
      // No cancel token, for the same reason the editor's write has none: abctl archives the
      // live profile and only then issues the DELETE, and a kill between the two is the one
      // state nothing on screen could describe.
      outcome = await ref
          .read(abctlClientProvider)
          .deleteConfiguration(widget.config.id);
    } catch (error) {
      failure = loadErrorText(error);
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _outcome = outcome;
      _error = failure;
    });
    if (outcome != null) {
      // Re-read rather than dropping the row locally: the list is what Apple Business says it
      // is, and a row removed on optimism is a row that comes back on the next refresh.
      await ref
          .read(inventoryProvider.notifier)
          .load(InventoryPane.configurations);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final List<String> argv = AbctlArgs.deleteConfiguration(widget.config.id);
    return PopScope(
      canPop: !_deleting,
      child: Dialog(
        backgroundColor: ab.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AbSpace.radius),
          side: BorderSide(color: ab.line),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 680,
            maxHeight: math.min(620, MediaQuery.sizeOf(context).height - 80),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AbSpace.md,
                  AbSpace.md,
                  AbSpace.md,
                  AbSpace.sm,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(abIcon('trash'), size: 15, color: ab.danger),
                    const SizedBox(width: AbSpace.sm),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          _outcome == null
                              ? 'Delete $_name?'
                              : 'Deleted $_name',
                          maxLines: 2,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: ab.text,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: ab.line),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AbSpace.md),
                  child: _body(ab),
                ),
              ),
              Divider(height: 1, color: ab.line),
              _CommandPreview(argv: argv, stdinBytes: null),
              _footer(ab),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(AbColors ab) {
    final WriteOutcome? outcome = _outcome;
    if (outcome != null) return _WriteOutcomeReport(outcome: outcome);

    final String? blocked = configWriteBlocker(ref.watch(workspaceProvider));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (blocked != null) ...<Widget>[
          _Panel(
            tone: AbSeverity.danger,
            symbol: 'folder.badge.questionmark',
            title: 'No workspace — deleting is unavailable',
            body: blocked,
            footnote:
                'The archive abctl writes before the delete is the only copy that survives it. '
                'It has to land in your tree, not in abgui\'s working directory.',
          ),
          const SizedBox(height: AbSpace.md),
        ],
        // The configuration is NAMED, with its id, in the sentence the operator approves. A
        // confirmation that says "delete this configuration?" is approved against whatever the
        // reader believes is selected, which on a filtered table is not always what is.
        _Field(label: 'Configuration', value: _name),
        _Field(label: 'Id', value: widget.config.id, mono: true),
        if (widget.config.attr('type') != null)
          _Field(label: 'Type', value: widget.config.attr('type')!),
        const SizedBox(height: AbSpace.md),
        Text(
          'abctl archives the live profile into gitops/archive/ and only then deletes it from '
          'Apple Business. That archived copy is the only copy that survives this, so the '
          'archive path in the outcome is worth keeping — and if the archive step fails, the '
          'delete is not attempted at all.',
          style: TextStyle(fontSize: 12, color: ab.dim, height: 1.4),
        ),
        const SizedBox(height: AbSpace.sm),
        Text(
          'Any blueprint that still lists this configuration will reference something that no '
          'longer exists. Detach it first if you want the manifests to stay consistent.',
          style: TextStyle(fontSize: 12, color: ab.dim, height: 1.4),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AbSpace.md),
          _Panel(
            tone: AbSeverity.danger,
            symbol: 'xmark.circle',
            title: 'abctl did not complete the delete',
            body: _error!,
            footnote:
                'Nothing was removed unless abctl says otherwise above. Re-read the list '
                'before trying again.',
          ),
        ],
      ],
    );
  }

  Widget _footer(AbColors ab) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbSpace.md,
        vertical: AbSpace.sm,
      ),
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border(top: BorderSide(color: ab.line)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          if (_deleting) ...<Widget>[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: ab.accent,
              ),
            ),
            const SizedBox(width: AbSpace.sm),
          ],
          TextButton(
            onPressed: _deleting
                ? null
                : () => Navigator.of(context).pop(_outcome != null),
            child: Text(_outcome == null ? 'Cancel' : 'Close'),
          ),
          const SizedBox(width: AbSpace.xs),
          if (_outcome == null)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: ab.danger),
              onPressed:
                  _deleting ||
                      configWriteBlocker(ref.watch(workspaceProvider)) != null
                  ? null
                  : () => unawaited(_delete()),
              child: const Text('Delete'),
            ),
        ],
      ),
    );
  }
}

// =============================================================================================
// shared pieces
// =============================================================================================

/// abctl's own account of a write, rendered without editorialising.
///
/// Every field here comes from the outcome document — nothing is inferred from the fact that the
/// command exited 0, because abctl emits this document for a tenant write that succeeded while
/// its local git half failed, and for one Apple acknowledged without storing.
class _WriteOutcomeReport extends StatelessWidget {
  const _WriteOutcomeReport({required this.outcome});

  final WriteOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final String? treeWarning = outcome.treeWarning;
    final String? unconfirmed = outcome.unconfirmedWarning;
    // A create/replace with no verdict at all: an older abctl that does not report one. Silence
    // is not a pass, so it is said.
    final bool expectsVerdict =
        outcome.action == 'create' || outcome.action == 'replace';
    final bool verdictMissing =
        expectsVerdict && (outcome.verified ?? '').isEmpty;

    return Container(
      padding: const EdgeInsets.all(AbSpace.md),
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border.all(color: ab.line),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('WHAT ABCTL REPORTED', style: AbType.label(context)),
              const Spacer(),
              AbBadge(
                label: outcome.status.isEmpty ? 'no status' : outcome.status,
                severity: outcome.status == 'done'
                    ? AbSeverity.ok
                    : AbSeverity.neutral,
                fontSize: 10,
              ),
            ],
          ),
          const SizedBox(height: AbSpace.sm),
          if (outcome.action.isNotEmpty)
            _Field(label: 'Action', value: outcome.action),
          if (outcome.name.isNotEmpty)
            _Field(label: 'Name', value: outcome.name, mono: true),
          if ((outcome.id ?? '').isNotEmpty)
            _Field(label: 'Id', value: outcome.id!, mono: true),
          if ((outcome.updatedDateTime ?? '').isNotEmpty)
            _Field(
              label: 'Apple updated',
              value: outcome.updatedDateTime!,
              mono: true,
            ),
          if ((outcome.archive ?? '').isNotEmpty)
            _Field(label: 'Archived to', value: outcome.archive!, mono: true),
          // Always shown, never only when false: "git was updated" is half of what a write did,
          // and a field that appears only on failure teaches nobody to look for it.
          _Field(
            label: 'gitops/ tree',
            value: outcome.treeUpdated ? 'updated' : 'NOT updated',
            mono: true,
            tone: outcome.treeUpdated ? AbSeverity.ok : AbSeverity.drift,
          ),
          if ((outcome.verified ?? '').isNotEmpty)
            _Field(
              label: 'Apple read-back',
              value: outcome.verified!,
              mono: true,
              tone: outcome.confirmedStored ? AbSeverity.ok : AbSeverity.drift,
            ),
          if (treeWarning != null) ...<Widget>[
            const SizedBox(height: AbSpace.sm),
            AbNote(tone: AbSeverity.drift, text: treeWarning),
          ],
          if (unconfirmed != null) ...<Widget>[
            const SizedBox(height: AbSpace.sm),
            AbNote(tone: AbSeverity.drift, text: unconfirmed),
          ],
          if (verdictMissing) ...<Widget>[
            const SizedBox(height: AbSpace.sm),
            AbNote(
              tone: AbSeverity.drift,
              text:
                  'This abctl reported no read-back verdict, so nothing here is evidence that '
                  'Apple stored the profile. Apple accepts an out-of-spec profile with a 2xx '
                  'and silently keeps the old bytes; open the profile again to see what it '
                  'actually holds.',
            ),
          ],
          if (outcome.confirmedStored) ...<Widget>[
            const SizedBox(height: AbSpace.sm),
            AbNote(
              tone: AbSeverity.ok,
              text:
                  'abctl read the configuration back and Apple\'s stored bytes match the ones '
                  'that were sent.',
            ),
          ],
        ],
      ),
    );
  }
}

/// The pre-flight verdict for the buffer.
class _PreflightReport extends StatelessWidget {
  const _PreflightReport({required this.report, required this.stale});

  final ProfileReport report;

  /// True when the buffer has been edited since this verdict was computed.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final AbSeverity tone = report.ok
        ? (report.warnings.isEmpty ? AbSeverity.ok : AbSeverity.drift)
        : AbSeverity.danger;
    final String headline = switch (report) {
      final ProfileReport r when !r.ok =>
        '${r.errors.length} problem(s) — the write was not attempted',
      final ProfileReport r when r.warnings.isNotEmpty =>
        'No blocking problems, ${r.warnings.length} warning(s)',
      _ => 'No problems found',
    };

    return Container(
      padding: const EdgeInsets.all(AbSpace.md),
      decoration: BoxDecoration(
        color: tone.ground(ab),
        border: Border.all(color: tone.edge(ab)),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Semantics(
                label: report.ok ? 'Passed' : 'Failed',
                child: Icon(
                  abIcon(report.ok ? 'checkmark.circle' : 'xmark.circle'),
                  size: 15,
                  color: tone.ink(ab),
                ),
              ),
              const SizedBox(width: AbSpace.sm),
              Expanded(
                child: Text(
                  headline,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: tone.ink(ab),
                  ),
                ),
              ),
              if (stale)
                const AbBadge(
                  label: 'edited since',
                  severity: AbSeverity.drift,
                  fontSize: 10,
                ),
            ],
          ),
          for (final ValidationIssue issue in report.errors)
            _IssueLine(issue: issue, isError: true),
          for (final ValidationIssue issue in report.warnings)
            _IssueLine(issue: issue, isError: false),
          const SizedBox(height: AbSpace.sm),
          Text(
            report.ok
                ? 'The same structural check abctl runs before it writes. Passing it is not a '
                      'promise Apple will store the profile — only the read-back after the '
                      'write can say that.'
                : 'These are abctl\'s own checks, run before anything left this machine. abctl '
                      'would refuse the same profile, so nothing was sent.',
            style: TextStyle(fontSize: 11, color: ab.dim, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// One finding: abctl's code as a chip (it is what the docs list and what you grep for), then
/// the sentence.
///
/// Deliberately a local copy of the same treatment `validate_dialog.dart` gives an issue, rather
/// than a shared widget: that one is a row inside a per-file tree report, this one is a flat
/// list about a single buffer, and the two have already diverged in what sits around them. A
/// shared widget would have to grow a mode flag to serve both, which is how one screen's layout
/// change silently becomes another's.
class _IssueLine extends StatelessWidget {
  const _IssueLine({required this.issue, required this.isError});

  final ValidationIssue issue;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final AbSeverity tone = isError ? AbSeverity.danger : AbSeverity.drift;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            label: isError ? 'Error' : 'Warning',
            child: AbBadge(label: issue.code, severity: tone, fontSize: 10),
          ),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: SelectableText(
              issue.message,
              style: TextStyle(
                fontSize: 11.5,
                color: isError ? ab.danger : ab.dim,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled value in an outcome or a confirmation.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    this.mono = false,
    this.tone = AbSeverity.neutral,
  });

  final String label;
  final String value;
  final bool mono;
  final AbSeverity tone;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Color ink = tone == AbSeverity.neutral ? ab.text : tone.ink(ab);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 108,
            child: Text(label, style: AbType.label(context)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono
                  ? AbType.mono(context, size: 11.5, color: ink)
                  : TextStyle(fontSize: 12, color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled block for a failure that is not a report.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.tone,
    required this.symbol,
    required this.title,
    required this.body,
    this.footnote,
  });

  final AbSeverity tone;
  final String symbol;
  final String title;
  final String body;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final String? note = footnote;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AbSpace.md),
      decoration: BoxDecoration(
        color: tone.ground(ab),
        border: Border.all(color: tone.edge(ab)),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(abIcon(symbol), size: 14, color: tone.ink(ab)),
              const SizedBox(width: AbSpace.sm),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: tone.ink(ab),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AbSpace.xs),
          // Selectable: abctl's stderr is what gets pasted into a bug report.
          SelectableText(
            body,
            style: AbType.mono(context, size: 11, color: ab.text),
          ),
          if (note != null) ...<Widget>[
            const SizedBox(height: AbSpace.sm),
            Text(
              note,
              style: TextStyle(fontSize: 11, color: ab.dim, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

/// The command this dialog will run, from the same builder the client runs.
///
/// It states, in the strip itself, that the profile goes on STDIN. That is not decoration: `-f -`
/// is the whole reason a `.mobileconfig` — which routinely carries credentials and certificates
/// — never lands in a temp file and never appears in a process listing, and an administrator
/// reading this line has to know the copied form needs a real file where `-f -` stands.
class _CommandPreview extends ConsumerWidget {
  const _CommandPreview({required this.argv, required this.stdinBytes});

  final List<String> argv;

  /// Null for the verbs that send nothing.
  final int? stdinBytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final String? workspace = ref.watch(workspaceProvider);
    // Through the client, so the previewed line carries the same `--context` tail the run does.
    final List<String> previewed = ref
        .watch(abctlClientProvider)
        .previewArgv(argv);
    final int? bytes = stdinBytes;

    return Container(
      width: double.infinity,
      color: ab.raised,
      padding: const EdgeInsets.symmetric(
        horizontal: AbSpace.md,
        vertical: AbSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('Equivalent CLI', style: AbType.label(context)),
              const Spacer(),
              CopyButton(
                text: () => CommandFormatter.script(
                  argv: previewed,
                  cwd: workspace,
                  stdin: bytes == null
                      ? const CommandStdin.none()
                      : CommandStdin.profile(bytes: bytes),
                ),
                weight: AbToolbarWeight.compact,
                tooltip:
                    'Copy this command, with the cd into the workspace, to the clipboard.',
              ),
            ],
          ),
          SelectableText(
            CommandFormatter.line(previewed),
            style: AbType.mono(context, size: 11, color: ab.dim),
          ),
          Text(
            bytes == null
                ? 'Gated with --yes, so abctl does not prompt. Runs in the workspace, because '
                      'abctl roots gitops/ at its working directory.'
                : 'The profile travels on STDIN — that is what `-f -` means — and never on the '
                      'command line, so it stays out of process listings and off disk. The '
                      'copied form names a file instead, because a pasted command has no '
                      'editor buffer to read from.',
            style: TextStyle(fontSize: 10.5, color: ab.faint),
          ),
        ],
      ),
    );
  }
}
