// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// What changed in this build, and — the half the Swift original left out — what this build
/// deliberately cannot do.
///
/// `WhatsNewView` listed four upcoming features. Keeping only that half here would be a
/// misrepresentation: the port dropped every write verb, so an operator arriving from the macOS
/// app will go looking for New, Edit, Delete, Apply, Attach and Assign and find none of them.
/// Saying so on the one screen whose entire job is "what is different now" is cheaper than the
/// support thread that otherwise follows, and it is the same disclosure the browse screens carry
/// in their banners — stated once, up front, where someone can read it before they need it.
///
/// Static text. No abctl, no providers, nothing to load or to fail.
library;

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/screens/diagnostics_chrome.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';

class WhatsNewScreen extends StatefulWidget {
  const WhatsNewScreen({super.key});

  /// What this release does. The symbols are the same SF Symbol names the rest of the app uses,
  /// through the one translation table.
  static const List<_Feature> _added = <_Feature>[
    _Feature(
      'apple.logo',
      'Apple software releases',
      'Browse the managed, public and Rapid Security Response catalogs, and compare them with '
          'the OS versions your devices last reported.',
    ),
    _Feature(
      'arrow.triangle.branch',
      'Drift you can read',
      'Diff computes a plan between gitops/ and Apple Business and shows every row it would '
          'have changed, with abctl narrating into a live transcript while it works.',
    ),
    _Feature(
      'doc.text.magnifyingglass',
      'Every run, on disk and in the window',
      'Each diff writes a transcript — what ran, what abctl printed, how long each step took, '
          'how it ended — and Logs reads them back without leaving the app.',
    ),
    _Feature(
      'stethoscope',
      'Operational confidence',
      'System Health summarizes the bundled CLI, the tenant connection and the cached '
          'inventory; Command Log shows every abctl invocation this session with its argv and '
          'its timing.',
    ),
    _Feature(
      'square.grid.2x2',
      'One window, three platforms',
      'abgui is now a Flutter application and runs on macOS, Windows and Linux from one source '
          'tree — with per-pane loading, so a slow read on one screen never blanks another.',
    ),
    _Feature(
      'exclamationmark.triangle',
      'Apply, gated',
      'Diff can now execute the plan it computes. The Apply sheet counts the plan by '
          'consequence rather than by row, states separately what would be REMOVED and what of '
          'that is recoverable, shows the exact command it is about to run, and — for any run '
          'that can remove something — will not enable the button until the tenant\'s own name '
          'is typed. abctl\'s per-item receipt is rendered afterwards, and a run that stopped '
          'part way through is reported as unknown rather than as failed.',
    ),
    _Feature(
      'pencil',
      'Configurations, blueprints and devices are editable',
      'Create, edit and delete configuration profiles with a pre-flight check on the exact '
          'bytes that will be sent; attach, detach and adopt blueprint members; assign devices '
          'to an MDM server. Every one of them re-reads what it touched afterwards and shows '
          'what Apple actually stored, because a 2xx is an acknowledgement and not evidence.',
    ),
  ];

  /// What it will not do. Phrased as capability, not as a changelog entry — an operator plans
  /// around what the window CAN'T do, so each of these has to be a fact about the tool rather
  /// than a note about a release.
  ///
  /// **This list used to open with "Nothing here writes to Apple Business", and that entry was
  /// deleted rather than reworded.** It became false the moment Apply shipped, and a positive,
  /// confidently-worded claim that the app cannot change the tenant is the single most dangerous
  /// sentence this screen could carry: it is exactly what an operator would rely on before
  /// clicking through a plan. What remains are the boundaries that did NOT move.
  static const List<_Feature> _absent = <_Feature>[
    _Feature(
      'lock',
      'The console will not run a write',
      'The typed console runs reads, diff and validate. A mutating verb typed there is refused '
          'before anything is spawned, and the refusal names the screen that does perform it. '
          'That is not a missing feature: every write in abgui is reached through a surface '
          'that puts a plan, a confirmation and a receipt around it, and a text field is a '
          'second door past all of that.',
    ),
    _Feature(
      'key.horizontal',
      'Credentials are read, never written',
      'Settings lists the connections abctl already has and says which one is current. It does '
          'not run context set, use or delete — those rewrite ~/.abctl/contexts.yaml, which is '
          'your file to edit, in your terminal.',
    ),
    _Feature(
      'checkmark.shield',
      'Scope unchanged',
      'Apple Business built-in management stays first-class. Legacy DEP and external-MDM VPP '
          'paths remain intentionally excluded — content tokens connect an outside MDM, and '
          'offering them here would read as an endorsement of a path this tool does not manage.',
    ),
  ];

  @override
  State<WhatsNewScreen> createState() => _WhatsNewScreenState();
}

class _WhatsNewScreenState extends State<WhatsNewScreen> {
  /// Its own controller, shared with the scrollbar.
  ///
  /// Every screen is alive at once inside the shell's `IndexedStack`, so a pane that leaves its
  /// scroll view to the inherited PrimaryScrollController is sharing that controller with every
  /// other pane the user has opened — and a `Scrollbar` reading it then finds two positions where
  /// it requires one. Owning the controller keeps the pairing local, and therefore correct.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    return ScreenScaffold(
      title: 'What’s New',
      subtitle: 'abgui — the cross-platform rewrite',
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(AbSpace.xl),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              // A measure, not the window's width. These are paragraphs, and a sentence stretched
              // across a 1600px pane is one the eye loses its place in.
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _heading(ab, 'In this release'),
                  for (final _Feature feature in WhatsNewScreen._added)
                    _FeatureRow(feature: feature),
                  const SizedBox(height: AbSpace.xl),
                  _heading(ab, 'What this build cannot do'),
                  for (final _Feature feature in WhatsNewScreen._absent)
                    _FeatureRow(feature: feature, tone: _Tone.constraint),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _heading(AbColors ab, String text) => Padding(
    padding: const EdgeInsets.only(bottom: AbSpace.md),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: ab.text,
        ),
      ),
    ),
  );
}

/// Whether a row is something gained or something withheld. Two tints of the SAME layout, because
/// they are the same kind of statement — a capability, present or absent — and giving the second
/// group a different shape would read as a warning banner nobody finishes.
enum _Tone { feature, constraint }

@immutable
class _Feature {
  const _Feature(this.symbol, this.title, this.detail);

  final String symbol;
  final String title;
  final String detail;
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.feature, this.tone = _Tone.feature});

  final _Feature feature;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Color ink = tone == _Tone.feature ? ab.accent : ab.dim;
    return Padding(
      padding: const EdgeInsets.only(bottom: AbSpace.lg),
      child: Semantics(
        // One stop per feature. Walking an icon, a heading and a paragraph as three unrelated
        // stops leaves a screen-reader user to reassemble the sentence themselves.
        container: true,
        label: '${feature.title}. ${feature.detail}',
        excludeSemantics: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2, right: AbSpace.md),
              child: Icon(abIcon(feature.symbol), size: 18, color: ink),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    feature.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    feature.detail,
                    style: TextStyle(fontSize: 12, color: ab.dim, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
