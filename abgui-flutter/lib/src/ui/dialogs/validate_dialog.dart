// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/models/validation.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/text_labels.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart' show AbRelativeTime;
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/copy_button.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// Pre-sync verification: `abctl validate --json` over the chosen workspace, as a report.
///
/// Local-only and credential-free — it parses `gitops/lib/*.mobileconfig` and checks that the
/// blueprint manifests only reference configurations that actually exist, which makes it the one
/// verb that works before a connection exists.
///
/// **Verification INFORMS; it does not gate.** In the Swift original a failed report never
/// disabled Continue or Apply, it only made the problems visible first. There is no Apply in this
/// build at all, so what survives of that rule is the tone: a failing report is DATA to read, and
/// this dialog's job is to make the difference between an error and a warning unmissable.
///
/// **The report decodes even when the exit code is non-zero, and this dialog depends on it.**
/// `validate` exits 1 whenever it finds a problem and still prints the whole report on stdout;
/// `AbctlClient.validateProfiles` therefore decodes BEFORE it maps the exit code. Without that
/// order every failing verification would arrive here as "abctl reported an error" with the list
/// of files to fix thrown away — which is precisely the report the user opened this for.
class ValidateDialog extends ConsumerStatefulWidget {
  const ValidateDialog({super.key});

  /// Present the dialog. Returns when it is dismissed; the report itself lives in the store, so
  /// nothing is handed back.
  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => const ValidateDialog(),
    );
  }

  @override
  ConsumerState<ValidateDialog> createState() => _ValidateDialogState();
}

class _ValidateDialogState extends ConsumerState<ValidateDialog> {
  /// The external-validator disclosure, once the user has opened or closed it themselves.
  ///
  /// Null = untouched, in which case it follows the report: OPEN when the validator is why the
  /// report failed, because its exit code and output are then the only evidence there is, and
  /// burying that behind a click leaves the verdict unexplained.
  bool? _validatorExpanded;

  @override
  void initState() {
    super.initState();
    // After the frame, not during it: `validate()` publishes a new `GitopsState` the moment it
    // starts, and every abctl run records into `commandLogProvider` before its first await.
    // Riverpod throws if a provider is modified while the tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_firstRun()));
  }

  /// Verify on open — ONCE. Re-opening the dialog must not re-run a possibly slow external
  /// validator, and must not discard a report that is already on screen; Re-run is the explicit
  /// refresh for that.
  Future<void> _firstRun() async {
    if (!mounted) return;
    final ValidationState validation = ref.read(gitopsProvider).validation;
    if (ref.read(workspaceProvider) == null ||
        validation.report != null ||
        validation.isRunning) {
      return;
    }
    await ref.read(gitopsProvider.notifier).validate();
  }

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final ValidationState validation = ref.watch(
      gitopsProvider.select((s) => s.validation),
    );
    final String? workspace = ref.watch(workspaceProvider);

    return Dialog(
      backgroundColor: ab.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AbSpace.radius),
        side: BorderSide(color: ab.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 780,
          // Never taller than the window it is in — a fixed 660 on a small laptop screen puts
          // the Close button below the fold.
          maxHeight: math.min(680, MediaQuery.sizeOf(context).height - 80),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(ab, validation, workspace),
            Divider(height: 1, color: ab.line),
            // Flexible, not Expanded: a two-line report shrink-wraps the dialog, a long one
            // grows it to the cap above and scrolls inside.
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AbSpace.md),
                child: _content(ab, validation, workspace),
              ),
            ),
            Divider(height: 1, color: ab.line),
            _CommandPreview(workspace: workspace),
            _footer(ab),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------------------------
  // chrome
  // -----------------------------------------------------------------------------------------

  Widget _header(AbColors ab, ValidationState validation, String? workspace) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.md,
        AbSpace.sm,
        AbSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Verify configurations',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: ab.text,
                  ),
                ),
                Tooltip(
                  message: workspace ?? 'No workspace chosen',
                  child: MonoText(
                    workspace == null
                        ? 'no workspace chosen'
                        : folderLabel(workspace),
                    size: 11,
                    color: ab.faint,
                  ),
                ),
              ],
            ),
          ),
          if (validation.isRunning)
            Padding(
              padding: const EdgeInsets.only(right: AbSpace.sm),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: ab.accent,
                ),
              ),
            ),
          ToolbarButton(
            icon: abIcon('arrow.clockwise'),
            label: 'Re-run',
            weight: AbToolbarWeight.titled,
            tooltip:
                'Re-read gitops/lib/ and the blueprint manifests. No credentials, no tenant call.',
            onPressed: validation.isRunning || workspace == null
                ? null
                : () => unawaited(ref.read(gitopsProvider.notifier).validate()),
          ),
        ],
      ),
    );
  }

  Widget _footer(AbColors ab) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.sm,
        AbSpace.md,
        AbSpace.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          // No "Continue to Apply…". The Swift footer offered it because this sheet sat in front
          // of a write; there is no write here to continue to, and a button that led nowhere
          // would be worse than its absence.
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------------------------
  // the report
  // -----------------------------------------------------------------------------------------

  Widget _content(AbColors ab, ValidationState validation, String? workspace) {
    if (workspace == null) {
      return const EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'No GitOps workspace',
        message:
            'Choose the folder that contains your gitops/ tree on the Diff / Drift screen. '
            'Verification reads gitops/lib/*.mobileconfig and the blueprint manifests — no '
            'credentials and no tenant calls.',
      );
    }

    final ValidationReport? report = validation.report;
    if (validation.error != null && report == null) {
      return EmptyState(
        icon: abIcon('exclamationmark.triangle'),
        title: 'Couldn\'t verify the configurations',
        message: validation.error,
        tone: AbSeverity.danger,
        action: ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Try Again',
          weight: AbToolbarWeight.titled,
          tooltip: 'Run `abctl validate --json` again.',
          onPressed: () =>
              unawaited(ref.read(gitopsProvider.notifier).validate()),
        ),
      );
    }

    if (report == null) {
      if (validation.isRunning) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: AbSpace.xl),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      return EmptyState(
        icon: abIcon('checkmark.shield'),
        title: 'Not verified yet',
        message:
            'Parse every profile in gitops/lib/ and confirm the blueprints only reference '
            'configurations that exist.',
        action: ToolbarButton(
          icon: abIcon('checkmark.shield'),
          label: 'Verify Now',
          weight: AbToolbarWeight.titled,
          tooltip: 'Run `abctl validate --json` in this workspace.',
          onPressed: () =>
              unawaited(ref.read(gitopsProvider.notifier).validate()),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _verdict(ab, report, validation.checkedAt),
        if (report.treeIssues.isNotEmpty) ...<Widget>[
          const SizedBox(height: AbSpace.lg),
          _treeSection(ab, report),
        ],
        if (report.profiles.isNotEmpty) ...<Widget>[
          const SizedBox(height: AbSpace.lg),
          _profileSection(ab, report),
        ],
        if (report.usesExternalValidator) ...<Widget>[
          const SizedBox(height: AbSpace.lg),
          _validatorSection(ab, report),
        ],
        if (report.libDir.isNotEmpty) ...<Widget>[
          const SizedBox(height: AbSpace.lg),
          // Always say WHAT was checked: a report with no rows to show — clean, or failed only
          // on the external validator — is otherwise indistinguishable from having pointed at
          // the wrong folder.
          Row(
            children: <Widget>[
              Icon(abIcon('folder'), size: 13, color: ab.faint),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(
                  report.libDir,
                  style: AbType.mono(context, size: 11, color: ab.faint),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _verdict(AbColors ab, ValidationReport report, DateTime? checkedAt) {
    final AbSeverity tone = report.ok ? AbSeverity.ok : AbSeverity.danger;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AbSpace.md),
      decoration: BoxDecoration(
        color: tone.ground(ab),
        border: Border.all(color: tone.edge(ab)),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The glyph and its tint are the whole verdict at a glance, so they are also spoken.
          Semantics(
            label: report.ok ? 'Passed' : 'Failed',
            child: Icon(
              abIcon(
                report.ok
                    ? 'checkmark.seal.fill'
                    : 'exclamationmark.triangle.fill',
              ),
              size: 20,
              color: tone.ink(ab),
            ),
          ),
          const SizedBox(width: AbSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SelectableText(
                  _verdictText(report),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ab.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _verdictDetail(report, checkedAt),
                  style: TextStyle(fontSize: 11, color: ab.dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The headline verdict.
  ///
  /// `ok` can be false with every profile parsing fine — a blueprint referencing a missing
  /// config, or a failed external validator — and each of those gets its own sentence. Naming the
  /// wrong culprit ("the tree has problems" when the tree is fine) sends the user looking for
  /// something that is not there.
  String _verdictText(ValidationReport report) {
    if (report.ok) return 'All ${report.checked} profile(s) passed';
    if (report.validatorFailed &&
        report.failed == 0 &&
        report.treeErrors.isEmpty) {
      return '${report.checked} profile(s) passed the built-in checks, but the external '
          'validator failed';
    }
    if (report.failed == 0) {
      return '${report.checked} profile(s) parsed, but the tree has problems';
    }
    return '${report.failed} of ${report.checked} profile(s) have problems';
  }

  String _verdictDetail(ValidationReport report, DateTime? checkedAt) {
    final List<String> parts = <String>['${report.warnings} warning(s)'];
    if (report.treeErrors.isNotEmpty) {
      parts.add('${report.treeErrors.length} blueprint/tree error(s)');
    }
    // The only numeric evidence when $ABCTL_VALIDATOR is what failed the report.
    if (report.validatorFailed && report.validatorExitCode != null) {
      parts.add('validator exit ${report.validatorExitCode}');
    }
    if (checkedAt != null) {
      parts.add('checked ${AbRelativeTime.absolute(checkedAt)}');
    }
    return parts.join(' — ');
  }

  Widget _treeSection(AbColors ab, ValidationReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _sectionTitle(ab, 'Blueprint / tree issues'),
        for (final TreeIssue issue in _errorsFirst(report.treeIssues))
          Padding(
            padding: const EdgeInsets.only(top: AbSpace.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // The glyph is the ONLY thing separating an error from a warning here, so it is
                // labelled: colour alone is not a channel, and Flutter's macOS accessibility is
                // thin enough that an unlabelled icon is simply absent to a screen reader.
                Semantics(
                  label: issue.isError ? 'Error' : 'Warning',
                  child: Icon(
                    abIcon(
                      issue.isError
                          ? 'xmark.circle'
                          : 'exclamationmark.triangle',
                    ),
                    size: 14,
                    color: issue.isError ? ab.danger : ab.drift,
                  ),
                ),
                const SizedBox(width: AbSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SelectableText(
                        issue.message,
                        style: TextStyle(fontSize: 12, color: ab.text),
                      ),
                      SelectableText(
                        // "blueprints · missing-config · Standard Mac" — where it came from, in
                        // abctl's own words, which are also the words the docs and `grep` use.
                        <String>[
                          issue.scope,
                          issue.code,
                          if ((issue.target ?? '').isNotEmpty) issue.target!,
                        ].where((String p) => p.isNotEmpty).join(' · '),
                        style: AbType.mono(
                          context,
                          size: 10.5,
                          color: ab.faint,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _profileSection(AbColors ab, ValidationReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            _sectionTitle(ab, 'Profiles'),
            const Spacer(),
            Text(
              '${report.checked} checked — ${report.passed} ok, ${report.failed} failed',
              style: TextStyle(fontSize: 11, color: ab.faint),
            ),
          ],
        ),
        for (final ProfileReport profile in _problemsFirst(report.profiles))
          _ProfileRow(profile: profile),
      ],
    );
  }

  Widget _validatorSection(AbColors ab, ValidationReport report) {
    final bool expanded = _validatorExpanded ?? report.validatorFailed;
    final String output = report.validatorOutput ?? '';
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: ab.lineSoft),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _validatorExpanded = !expanded),
            child: Padding(
              padding: const EdgeInsets.all(AbSpace.sm),
              child: Row(
                children: <Widget>[
                  Icon(abIcon('terminal'), size: 14, color: ab.dim),
                  const SizedBox(width: AbSpace.sm),
                  Text(
                    'External validator',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                  const SizedBox(width: AbSpace.sm),
                  if (report.validatorExitCode != null)
                    AbBadge(
                      label: 'exit ${report.validatorExitCode}',
                      severity: report.validatorFailed
                          ? AbSeverity.danger
                          : AbSeverity.ok,
                    ),
                  const Spacer(),
                  Icon(
                    abIcon(expanded ? 'chevron.up' : 'chevron.down'),
                    size: 15,
                    color: ab.dim,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbSpace.sm,
                0,
                AbSpace.sm,
                AbSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '\$ABCTL_VALIDATOR ran in addition to the built-in structural checks; a '
                    'non-zero exit fails this report on its own, without touching the profile '
                    'counts above.',
                    style: TextStyle(fontSize: 11, color: ab.faint),
                  ),
                  if ((report.validatorCommand ?? '').isNotEmpty) ...<Widget>[
                    const SizedBox(height: AbSpace.sm),
                    SelectableText(
                      report.validatorCommand!,
                      style: AbType.mono(context, size: 11, color: ab.dim),
                    ),
                  ],
                  if (output.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AbSpace.sm),
                    Row(
                      children: <Widget>[
                        Text('Validator output', style: AbType.label(context)),
                        const Spacer(),
                        CopyButton(
                          text: () => output,
                          weight: AbToolbarWeight.compact,
                          tooltip:
                              'Copy the validator\'s output. When \$ABCTL_VALIDATOR is why this '
                              'report failed, this is the only evidence there is.',
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 220),
                      padding: const EdgeInsets.all(AbSpace.sm),
                      decoration: BoxDecoration(
                        color: ab.sunken,
                        border: Border.all(color: ab.lineSoft),
                        borderRadius: BorderRadius.circular(AbSpace.radius),
                      ),
                      // NOT scrolled to the bottom: this output is finished when it appears, and
                      // opening it at the last line would hide the first failure.
                      child: SingleChildScrollView(
                        child: SelectableText(
                          output,
                          style: AbType.mono(context, size: 11, color: ab.dim),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(AbColors ab, String text) => Text(
    text,
    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ab.text),
  );
}

// ---------------------------------------------------------------------------------------------
// ordering — problems first, abctl's own order within a tier
// ---------------------------------------------------------------------------------------------

/// Errors before warnings.
List<TreeIssue> _errorsFirst(List<TreeIssue> issues) =>
    _stableSorted<TreeIssue>(
      issues,
      (TreeIssue a, TreeIssue b) =>
          a.isError == b.isError ? 0 : (a.isError ? -1 : 1),
    );

/// Failing profiles first, then merely-warning ones, then the clean majority — a long lib/ must
/// not make the user scroll to find what is broken.
List<ProfileReport> _problemsFirst(List<ProfileReport> profiles) =>
    _stableSorted<ProfileReport>(
      profiles,
      (ProfileReport a, ProfileReport b) => _tier(a).compareTo(_tier(b)),
    );

int _tier(ProfileReport profile) {
  if (!profile.ok) return 0;
  return profile.warnings.isEmpty ? 2 : 1;
}

/// Sort by [compare], with the original index as the final tiebreak.
///
/// Dart's `List.sort` is introsort and therefore NOT stable, exactly like Swift's — and within a
/// tier abctl's order is meaningful, so equal keys must not be free to rearrange themselves
/// between two rebuilds of identical data.
List<T> _stableSorted<T>(List<T> items, int Function(T a, T b) compare) {
  final List<int> order = List<int>.generate(items.length, (int i) => i);
  order.sort((int x, int y) {
    final int result = compare(items[x], items[y]);
    return result != 0 ? result : x - y;
  });
  return <T>[for (final int i in order) items[i]];
}

// ---------------------------------------------------------------------------------------------
// rows
// ---------------------------------------------------------------------------------------------

/// One `lib/` profile: status, what it declares, and every problem beneath it.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.profile});

  final ProfileReport profile;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final (String symbol, Color ink, String spoken) = switch (profile) {
      final ProfileReport p when !p.ok => ('xmark.circle', ab.danger, 'Failed'),
      final ProfileReport p when p.warnings.isNotEmpty => (
        'exclamationmark.triangle',
        ab.drift,
        'Passed with warnings',
      ),
      _ => ('checkmark.circle', ab.ok, 'Passed'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ab.lineSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Symbol plus tint IS the whole verdict for a row with no messages under it, so it has
          // to be spoken as well as drawn.
          Semantics(
            label: spoken,
            child: Icon(abIcon(symbol), size: 14, color: ink),
          ),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SelectableText(
                  profile.name,
                  style: TextStyle(fontSize: 12.5, color: ab.text),
                ),
                SelectableText(
                  _subtitle(profile),
                  style: AbType.mono(context, size: 10.5, color: ab.faint),
                ),
                for (final ValidationIssue issue in profile.errors)
                  _IssueLine(issue: issue, isError: true),
                for (final ValidationIssue issue in profile.warnings)
                  _IssueLine(issue: issue, isError: false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Identifier, size and the inner payload types — enough to recognize the profile without
  /// opening it. The size matters on its own: Apple Business caps a profile at 1 MiB.
  String _subtitle(ProfileReport profile) {
    final List<String> parts = <String>[];
    final String identifier = profile.identifier ?? '';
    final String display = profile.displayName ?? '';
    if (identifier.isNotEmpty) parts.add(identifier);
    if (display.isNotEmpty && display != profile.name) parts.add(display);
    parts.add(byteSizeLabel(profile.bytes));
    if (profile.payloadTypes.isNotEmpty) {
      parts.add(profile.payloadTypes.join(', '));
    }
    return parts.join(' — ');
  }
}

/// One error/warning under a profile: abctl's code as a chip (it is what you grep for and what
/// the docs list), then the one-sentence message.
class _IssueLine extends StatelessWidget {
  const _IssueLine({required this.issue, required this.isError});

  final ValidationIssue issue;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final AbSeverity tone = isError ? AbSeverity.danger : AbSeverity.drift;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The chip's label already says which it is in words ("error"/"warning" would be
          // redundant with the code) — the severity is spoken here so the colour is never the
          // only carrier.
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What Verify / Re-run actually shells out, from the client's own argv builder.
///
/// The cwd is load-bearing rather than decoration: `validate` resolves `gitops/lib/` against the
/// directory abctl runs in, so the copied form has to carry the `cd` to check the same tree this
/// dialog did. Shown even with no workspace chosen — it is reference material, and the reader
/// then supplies the directory themselves, which is exactly how they would run it in a terminal.
class _CommandPreview extends ConsumerWidget {
  const _CommandPreview({required this.workspace});

  final String? workspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    // Through the client, not spelled here: `previewArgv` is the same function the run itself
    // uses, so the command shown carries the same `--context` tail as the command that executed.
    final List<String> argv = ref
        .watch(abctlClientProvider)
        .previewArgv(AbctlArgs.validate());
    final String script = CommandFormatter.script(argv: argv, cwd: workspace);

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
                text: () => script,
                weight: AbToolbarWeight.compact,
                tooltip: workspace == null
                    ? 'Copy this command to the clipboard.'
                    : 'Copy this command, with the cd into the workspace, to the clipboard.',
              ),
            ],
          ),
          // Displayed as it actually executes; the `cd` lives in the copied form, which is where
          // it is useful and where it cannot make the displayed line untrue.
          SelectableText(
            CommandFormatter.line(argv),
            style: AbType.mono(context, size: 11, color: ab.dim),
          ),
          Text(
            workspace == null
                ? 'Reads local files only — no credentials and no tenant calls.'
                : 'Reads local files only — no credentials and no tenant calls. '
                      'Runs in ${folderLabel(workspace!)}; the copied form includes the cd.',
            style: TextStyle(fontSize: 10.5, color: ab.faint),
          ),
        ],
      ),
    );
  }
}
