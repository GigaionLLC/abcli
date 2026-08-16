// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The two dialogs the Archive screen opens: read what abctl saved, and confirm putting it back.
///
/// They live together because they are two halves of one decision. Nobody restores a profile they
/// have not read, and the viewer's whole reason to exist is that the reader is about to overwrite
/// a live configuration with these exact bytes — so the confirmation states what the viewer just
/// showed, in the same words.
///
/// **Neither of them writes the archived body anywhere.** The viewer reads the file into memory
/// and shows it; the confirmation reads only its SIZE. An archived `.mobileconfig` is a live
/// profile as Apple Business held it, which routinely means Wi-Fi passwords, VPN shared secrets
/// and certificate payloads — expected here, and the reason there is no export, no temp file and
/// no log line carrying any of it. The restore itself pipes the bytes to abctl on stdin (`-f -`),
/// which is the same rule stated at `AbctlArgs.createConfiguration`: the profile never touches
/// disk outside the workspace and never appears in a process listing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/models/archive.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/command_preview.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

// -----------------------------------------------------------------------------------------------
// reading an archived file — off the platform thread, once
// -----------------------------------------------------------------------------------------------

/// What one archived file turned out to be: its text, or why there is none, plus its size.
typedef ArchivedFileRead = ({String? text, int bytes, String? failure});

/// Read and decode an archived profile. Runs in a worker isolate — see [ArchivedFileDialog].
///
/// Bytes first, then a STRICT UTF-8 decode, rather than `readAsString`. The difference matters:
/// a signed `.mobileconfig` is a PKCS#7 envelope, which is binary and is not text at all, and the
/// two failures need different sentences. `readAsString` collapses them into one throw, and
/// decoding with `allowMalformed` would be worse still — it renders a signed profile as a screen
/// of replacement characters that looks like corruption rather than like a signature.
ArchivedFileRead readArchivedFile(String path) {
  final List<int> bytes;
  try {
    bytes = File(path).readAsBytesSync();
  } on FileSystemException catch (error) {
    return (
      text: null,
      bytes: 0,
      failure: error.osError?.message ?? 'the file could not be read',
    );
  }
  try {
    return (text: utf8.decode(bytes), bytes: bytes.length, failure: null);
  } on FormatException {
    return (
      text: null,
      bytes: bytes.length,
      failure:
          'This archived profile is not UTF-8 text — a signed .mobileconfig is a binary PKCS#7 '
          'envelope. It can still be restored; it just cannot be read here.',
    );
  }
}

/// [readArchivedFile] on a worker isolate, so a large profile on a slow volume — a network share,
/// an encrypted home — cannot stall the window while this dialog opens.
///
/// **A TOP-LEVEL function, and that is load-bearing rather than tidy.** `Isolate.run` SENDS the
/// closure, and a closure written inside a `State` method captures that method's context — which
/// links to `this`, to the `Element`, and from there to the whole widget tree. Dart refuses to
/// send that ("Illegal argument in isolate message: object is unsendable — _CustomZone"), so the
/// read threw instead of running. Declared out here, the closure holds one `String`.
Future<ArchivedFileRead> _readOffThread(String path) =>
    Isolate.run(() => readArchivedFile(path));

// -----------------------------------------------------------------------------------------------
// the viewer
// -----------------------------------------------------------------------------------------------

/// One archived profile's XML, exactly as abctl filed it before overwriting the live copy.
///
/// **Read ONCE, into state, off the platform thread — and both halves of that are a bug fix.**
/// The Swift original loaded the profile with a synchronous `String(contentsOf:)` written inline
/// in the view body, so it re-ran on every body evaluation instead of once per file, on the main
/// actor, for a document that can be a megabyte (Apple's cap). Work that looks free because it is
/// written as an expression. Here the read happens in a post-frame callback, in an [Isolate], and
/// its result lands in state; `build` only ever renders what is already there.
class ArchivedFileDialog extends StatefulWidget {
  const ArchivedFileDialog({super.key, required this.entry});

  final ArchiveEntry entry;

  static Future<void> show(
    BuildContext context, {
    required ArchiveEntry entry,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => ArchivedFileDialog(entry: entry),
    );
  }

  @override
  State<ArchivedFileDialog> createState() => _ArchivedFileDialogState();
}

class _ArchivedFileDialogState extends State<ArchivedFileDialog> {
  ArchivedFileRead? _read;
  bool _loading = true;

  final ScrollController _vertical = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _vertical.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ArchivedFileRead result = await _readOffThread(widget.entry.filePath);
    if (!mounted) return;
    setState(() {
      _read = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Size window = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: ab.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AbSpace.radius),
        side: BorderSide(color: ab.line),
      ),
      child: SizedBox(
        // Fixed, like `ProfileDialog`: a viewer that resized itself to each profile would jump
        // every time one was opened.
        width: math.min(900, math.max(360, window.width - 80)),
        height: math.min(720, math.max(320, window.height - 80)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(ab),
            // Said once, where it cannot be missed. An archived profile is a LIVE profile that
            // was pulled out of Apple Business, so its payload is whatever was deployed —
            // credentials included. That is expected here; being surprised by it is not.
            NoticeBanner(
              icon: abIcon('lock'),
              text: 'Archived copy of a live profile',
              detail:
                  'It can contain Wi-Fi passwords, VPN secrets and certificates. Nothing here '
                  'writes it anywhere new.',
            ),
            Expanded(child: _body(ab)),
            _footer(ab),
          ],
        ),
      ),
    );
  }

  Widget _header(AbColors ab) {
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
          Icon(abIcon('clock.arrow.circlepath'), size: 15, color: ab.dim),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    widget.entry.configName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                ),
                // When, and why abctl kept it — the two facts that tell one archived version
                // apart from the six others of the same configuration.
                MonoText(
                  widget.entry.archivedAt.isEmpty
                      ? 'no sidecar — archived time unknown'
                      : '${widget.entry.archivedAt}  ·  ${widget.entry.reason.isEmpty ? 'unknown reason' : widget.entry.reason}',
                  size: 11,
                  color: ab.faint,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(AbColors ab) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final ArchivedFileRead? result = _read;
    final String? failure = result?.failure;
    if (result == null || failure != null) {
      return EmptyState(
        icon: abIcon('exclamationmark.triangle'),
        title: 'Nothing to show for this file',
        message: failure ?? 'The file could not be read.',
        tone: AbSeverity.drift,
        action: ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Try Again',
          weight: AbToolbarWeight.titled,
          tooltip: 'Read this archived file from disk again.',
          onPressed: () {
            setState(() => _loading = true);
            unawaited(_load());
          },
        ),
      );
    }

    final String text = result.text ?? '';
    if (text.trim().isEmpty) {
      return const EmptyState(
        icon: Icons.description_outlined,
        title: 'Empty archived file',
        message:
            'abctl created this file but wrote nothing into it. There is no version here to '
            'restore.',
      );
    }

    // One scrollbar, on the vertical axis, with the horizontal viewport nested inside it — the
    // arrangement `ProfileDialog` settled on and for the same reason: wrapping a `.mobileconfig`
    // makes it impossible to see where a base64 payload or a `<string>` ends, which is the whole
    // reason anyone opens raw XML.
    return Scrollbar(
      controller: _vertical,
      child: SingleChildScrollView(
        controller: _vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(AbSpace.md),
          child: SelectableText(
            text,
            style: AbType.mono(context, size: 11.5, color: ab.text),
          ),
        ),
      ),
    );
  }

  Widget _footer(AbColors ab) {
    final ArchivedFileRead? result = _read;
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
              // The PATH, not the byte count alone: this is the file the restore will pipe, and
              // an administrator who wants to diff two archived versions needs to be able to
              // name them.
              result == null
                  ? widget.entry.filePath
                  : '${widget.entry.filePath}  ·  ${result.bytes} bytes',
              size: 11,
              color: ab.faint,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------------------------
// the confirmation
// -----------------------------------------------------------------------------------------------

/// The gate in front of a restore: what it will do, to which configuration, with which command.
///
/// **It leads with the reassurance, because the reassurance is the true part that makes this
/// usable.** `replace` archives the CURRENT live version before it PATCHes, so restoring is an
/// undo that is itself undoable — the version being replaced is in the same list, one row newer,
/// the moment this finishes. An operator who does not know that will not press the button; one
/// who is told it without it being true would be far worse off, so the sentence is written from
/// abctl's actual behaviour (`AbctlArgs.replaceConfiguration`, `WriteOutcome.archive`).
///
/// The command comes from [CommandPreview], which appends the `--context` tail through the same
/// `previewArgv` the run uses — so this dialog cannot show a lookalike. What it adds around that
/// line is the one thing the argv cannot say: `-f -` means the profile arrives on stdin, and the
/// bytes in question are the ones named here.
class RestoreArchiveDialog extends ConsumerWidget {
  const RestoreArchiveDialog({
    super.key,
    required this.entry,
    required this.bytes,
  });

  final ArchiveEntry entry;

  /// The archived file's size. Only the size: the body is read after this dialog is answered, and
  /// is never held across a modal it does not need to be held across.
  final int bytes;

  /// Ask. True means restore; a dismissed dialog is a no.
  static Future<bool> confirm(
    BuildContext context, {
    required ArchiveEntry entry,
    required int bytes,
  }) async {
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          RestoreArchiveDialog(entry: entry, bytes: bytes),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final String? workspace = ref.watch(workspaceProvider);

    return AlertDialog(
      backgroundColor: ab.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AbSpace.radius),
        side: BorderSide(color: ab.line),
      ),
      title: Row(
        children: <Widget>[
          Icon(abIcon('arrow.uturn.backward'), size: 16, color: ab.accent),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Text(
              'Restore this archived version?',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: ab.text,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Apple Business\'s copy of "${entry.configName}" is replaced with these '
              '$bytes bytes, archived ${entry.archivedAt.isEmpty ? 'at an unknown time' : entry.archivedAt}.',
              style: TextStyle(fontSize: 12, color: ab.text, height: 1.45),
            ),
            const SizedBox(height: AbSpace.sm),
            Text(
              'abctl archives the version that is live RIGHT NOW before it writes, under '
              'gitops/archive/. So this is a reversible undo: when it finishes, the version you '
              'are replacing will be the newest row in this table, and restoring it puts things '
              'back exactly as they are now.',
              style: TextStyle(fontSize: 12, color: ab.dim, height: 1.45),
            ),
            const SizedBox(height: AbSpace.md),
            CommandPreview(
              // The CONTEXT-FREE argv from the builder. `CommandPreview` appends the tenant tail
              // through the same call the run makes.
              base: AbctlArgs.replaceConfiguration(entry.configName),
              // The workspace, because `replace` writes the gitops/ half of this change as well
              // as the tenant half, and abctl resolves that tree against its working directory.
              cwd: workspace,
              caption:
                  '`-f -` means abgui feeds the profile on stdin — these $bytes bytes — so it '
                  'never touches disk outside the workspace and never appears in a process '
                  'listing. `--yes` is abgui\'s: this dialog is the confirmation.',
            ),
            if (workspace == null) ...<Widget>[
              const SizedBox(height: AbSpace.sm),
              Text(
                'No workspace is chosen, so abctl will run wherever the app was launched from '
                'and its gitops/ half of this write will land in the wrong tree — or nowhere.',
                style: TextStyle(fontSize: 11, color: ab.drift, height: 1.4),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        // Not styled as a destructive action, deliberately: this is the button that PUTS BACK a
        // known-good version, and dressing it in red would make the safe move look like the
        // dangerous one on a screen someone reaches during an incident.
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
