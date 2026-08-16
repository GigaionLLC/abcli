// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/resource.dart';
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

/// One configuration's raw `.mobileconfig` XML, from `abctl get configuration <id> --profile`.
///
/// **The one read whose stdout is not JSON.** `AbctlClient.configurationProfile` maps the exit
/// code and hands the text back verbatim rather than decoding and re-encoding it — a profile this
/// app only ever displays must not pass through a transform that could change it — so what is on
/// screen here is byte-for-byte what abctl printed.
///
/// **Read-only, and that is the whole feature.** The Swift original called this "read-only in v1;
/// the in-app editor + `replace` lands in v2"; `replace` is a write verb with no builder in
/// `AbctlArgs`, so v2 has not landed and this dialog offers no edit affordance to disable.
class ProfileDialog extends ConsumerStatefulWidget {
  const ProfileDialog({super.key, required this.config});

  /// The configuration to fetch, as it came from `abctl get configurations`. The whole resource
  /// rather than an id, because the header names it the way the list that opened this did — an id
  /// alone would make the dialog title a UUID.
  final Resource config;

  static Future<void> show(
    BuildContext context, {
    required Resource config,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => ProfileDialog(config: config),
    );
  }

  @override
  ConsumerState<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends ConsumerState<ProfileDialog> {
  /// The fetched XML. Loaded ONCE, into state — never from `build`, which runs again on every
  /// theme change, window resize and scroll-driven repaint, and would spawn an abctl process for
  /// each one.
  String? _xml;
  String? _error;
  bool _loading = true;

  /// Kills the abctl child if the dialog is dismissed while the fetch is in flight. A profile
  /// read is short, but a tenant behind a slow VPN can make it long enough to notice, and a
  /// process nobody is waiting for is a process that should not be running.
  final CancelToken _cancel = CancelToken();

  final ScrollController _vertical = ScrollController();

  @override
  void initState() {
    super.initState();
    // After the frame, not during it: every abctl run is recorded into `commandLogProvider` by
    // `RecordingRunner.onStart`, synchronously, before its first await — and Riverpod throws if a
    // provider is modified while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _cancel.cancel();
    _vertical.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final String xml = await ref
          .read(abctlClientProvider)
          .configurationProfile(widget.config.id, cancel: _cancel);
      if (!mounted) return;
      setState(() {
        _xml = xml;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // One sentence, from the one place that turns a thrown abctl failure into one — the same
        // text the stores put in their error slots, so a fetch that fails here reads exactly like
        // a fetch that fails on a list screen.
        _error = loadErrorText(error);
        _loading = false;
      });
    }
  }

  String get _title =>
      widget.config.attr('name') ?? widget.config.displayName();

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
        // A fixed pane rather than one that shrink-wraps its content: this is a viewer, and a
        // dialog that resized itself to each profile would jump every time one was opened.
        width: math.min(900, math.max(360, window.width - 80)),
        height: math.min(720, math.max(320, window.height - 80)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(ab),
            NoticeBanner(
              icon: abIcon('lock'),
              text: 'Read-only',
              detail:
                  'This build shows a profile; it cannot edit or replace one.',
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
          Icon(abIcon('doc.text'), size: 15, color: ab.dim),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                ),
                // The id, because that is what the command took and what a bug report needs.
                MonoText(widget.config.id, size: 11, color: ab.faint),
              ],
            ),
          ),
          CopyButton(
            text: () => _xml ?? '',
            enabled: (_xml ?? '').isNotEmpty,
            label: 'Copy XML',
            weight: AbToolbarWeight.titled,
            tooltip:
                'Copy the whole profile to the clipboard, exactly as abctl printed it.',
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

    final String? error = _error;
    if (error != null) {
      return EmptyState(
        icon: abIcon('exclamationmark.triangle'),
        title: 'Couldn\'t load the profile',
        message: error,
        tone: AbSeverity.danger,
        action: ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Try Again',
          weight: AbToolbarWeight.titled,
          tooltip:
              'Run `abctl get configuration ${widget.config.id} --profile` again.',
          onPressed: () => unawaited(_load()),
        ),
      );
    }

    final String xml = _xml ?? '';
    if (xml.trim().isEmpty) {
      return const EmptyState(
        icon: Icons.description_outlined,
        title: 'Empty profile',
        message:
            'abctl returned no payload for this configuration. It exists in Apple Business, but '
            'there is nothing to show.',
      );
    }

    // Vertical is the axis with the scrollbar; the horizontal viewport inside it is what stops
    // the XML wrapping. Wrapping a `.mobileconfig` is not cosmetic — a wrapped base64 payload or
    // a wrapped `<string>` makes it impossible to see where one element ends, which is the whole
    // reason to look at raw XML in the first place. (A horizontal scrollbar nested INSIDE the
    // vertical viewport would scroll away with the content, so there is deliberately only one.)
    return Scrollbar(
      controller: _vertical,
      child: SingleChildScrollView(
        controller: _vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(AbSpace.md),
          child: SelectableText(
            xml,
            // Monospaced because it is machine data, and selectable because the useful thing to
            // do with a profile you are reading is take one payload out of it.
            style: AbType.mono(context, size: 11.5, color: ab.text),
          ),
        ),
      ),
    );
  }

  Widget _footer(AbColors ab) {
    final String xml = _xml ?? '';
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
          if (xml.isNotEmpty)
            Expanded(
              // How much there is to read. The profile's SIZE — the number that matters against
              // Apple Business's 1 MiB cap — is deliberately not restated here: Verify Configs
              // reports it per profile, and a second byte count computed a second way is a second
              // number to disagree with the first.
              child: MonoText(
                '${lineCount(xml)} lines',
                size: 11,
                color: ab.faint,
              ),
            )
          else
            const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
