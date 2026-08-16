// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:abgui/src/abctl/run_log.dart';
import 'package:abgui/src/platform/app_paths.dart';
import 'package:abgui/src/state/connection_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

import 'diagnostics_chrome.dart';

/// The screen a user is asked to paste into a bug report.
///
/// It exists because the first three replies to any GUI issue are always the same questions —
/// which build, which CLI, which machine, which folder — and answering them one at a time turns
/// a five-minute diagnosis into a two-day thread. So every field is here, every field is
/// individually copyable, and one button takes the lot.
///
/// **The copy block is DERIVED from the same list the screen renders.** That is the whole design
/// constraint: a hand-written report string is a second copy of these facts, and the copy that
/// goes stale is always the one nobody looks at — which is precisely the one that ends up in the
/// ticket.
class SystemHealthScreen extends ConsumerStatefulWidget {
  const SystemHealthScreen({super.key});

  @override
  ConsumerState<SystemHealthScreen> createState() => _SystemHealthScreenState();
}

class _SystemHealthScreenState extends ConsumerState<SystemHealthScreen> {
  /// abgui's own version, read from the packaged bundle. The provider is the primary source (the
  /// app overrides it in `main()`); this is the fallback for a container that did not, and it is
  /// wrapped because a plugin channel is exactly the thing that is missing under `flutter test`
  /// and on a host where the platform implementation failed to register.
  String? _packageVersion;

  /// Resolved AND created, so a first run shows the real directory rather than a path that does
  /// not exist yet. Null means abgui has nowhere to write logs at all, which is itself the most
  /// interesting line in the report.
  String? _logDirectory;

  @override
  void initState() {
    super.initState();
    // Deferred to the end of this frame for the same reason as the Settings screen: Riverpod
    // throws on a provider write inside a widget life-cycle, and `check()` sets a checking flag
    // synchronously. It happens to be behind an await today; that is not a property worth
    // depending on when the fix is one line.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final String? directory = await AppPaths.runLogDirectory();
    String? version;
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      version = info.buildNumber.isEmpty
          ? info.version
          : '${info.version}+${info.buildNumber}';
    } catch (_) {
      // MissingPluginException, or a platform with no bundle metadata. "Unknown" is a fine
      // answer for one line of a report and not a reason to fail the screen.
      version = null;
    }
    if (!mounted) return;
    setState(() {
      _logDirectory = directory;
      _packageVersion = version;
    });
    if (!mounted) return;
    // Only when nothing has checked yet — see the same rule on the Settings screen.
    if (ref.read(connectionProvider) is ConnectionUnknown) {
      unawaited(ref.read(connectionProvider.notifier).check());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final Connection connection = ref.watch(connectionProvider);
    final String? binary = ref.watch(abctlBinaryProvider);
    final String? declaredVersion = ref.watch(abguiVersionProvider);
    final String? workspace = ref.watch(workspaceProvider);
    final String activeContext = ref.watch(activeContextProvider);

    final ConnectionConnected? live = connection is ConnectionConnected
        ? connection
        : null;
    final fields = <_HealthField>[
      _HealthField('abgui', declaredVersion ?? _packageVersion ?? ''),
      _HealthField(
        'abctl',
        // The same formatter the run-log header uses, so the version string in a pasted report
        // and the one at the top of an attached transcript are the same string.
        RunLog.abctlDescription(
          version: live?.version.version,
          commit: live?.version.commit,
        ),
      ),
      _HealthField(
        'abctl path',
        binary ?? '',
        placeholder:
            'not found — this is a packaging problem; reinstalling the app is the fix',
      ),
      _HealthField('Go', live?.version.goVersion ?? ''),
      _HealthField(
        'Capabilities',
        live == null ? '' : '${live.version.capabilities.length}',
      ),
      // Cross-platform where the Swift original could only ever say "macOS", and worth a line:
      // half of "it works on my machine" is which machine.
      _HealthField('Platform', RunLog.currentOs()),
      _HealthField(
        'Log directory',
        _logDirectory ?? '',
        placeholder: 'could not be created — nothing is being recorded',
      ),
      _HealthField(
        'Workspace',
        workspace ?? '',
        placeholder: 'no folder chosen',
      ),
      _HealthField(
        'Context',
        activeContext,
        placeholder: 'abctl\'s own current context',
      ),
      _HealthField('Connection', _connectionWord(connection)),
      _HealthField(
        'Tenant',
        live?.identity?.clientID ?? '',
        placeholder: 'not authenticated',
      ),
      _HealthField('API base', live?.identity?.apiBase ?? ''),
      _HealthField('Token expires', live?.identity?.tokenExpires ?? ''),
    ];

    return ScreenScaffold(
      title: 'System Health',
      actions: <Widget>[
        CopyButton(
          text: () => _report(fields),
          label: 'Copy report',
          weight: AbToolbarWeight.titled,
          tooltip:
              'Copy every field below as one block, ready to paste into a bug report.',
        ),
        ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Recheck',
          tooltip: 'Run abctl version again, then ask the tenant who we are.',
          onPressed: connection is ConnectionChecking
              ? null
              : () => unawaited(ref.read(connectionProvider.notifier).check()),
        ),
      ],
      child: SingleChildScrollView(
        // See the note in `command_log_screen.dart`: screens coexist in the shell's IndexedStack,
        // so none of them may take the window's primary scroll controller.
        primary: false,
        padding: const EdgeInsets.all(AbSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ScreenSection(
              title: 'Bug report',
              note:
                  'These lines name your organization and the folder you work in. They contain '
                  'no credentials — abgui never sees key material, and the client id is an '
                  'identifier rather than a secret — but read the block before sending it.',
              children: <Widget>[
                for (final _HealthField field in fields)
                  CopyableField(
                    label: field.label,
                    value: field.value,
                    placeholder: field.placeholder,
                  ),
              ],
            ),
            if (connection is ConnectionFailed)
              ScreenSection(
                title: 'Why the check failed',
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
                    // abctl's own stderr, or the list of paths the locator searched. Verbatim and
                    // selectable: it is already written for a human, and paraphrasing it here
                    // would throw away the one part of a packaging failure that IS the diagnosis.
                    child: SelectableMono(connection.message, color: ab.danger),
                  ),
                ],
              ),
            ScreenSection(
              title: 'Product boundary',
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
                  child: Text(
                    'Apple Business and its built-in device management service. Legacy DEP and '
                    'external-MDM content-token (VPP) operation are intentionally unsupported. '
                    'This build is read-only: it reads, plans (diff) and validates, and applies '
                    'nothing.',
                    style: TextStyle(fontSize: 12, color: ab.dim, height: 1.45),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _connectionWord(Connection connection) => switch (connection) {
    ConnectionConnected(:final identity) =>
      identity?.authenticated ?? false
          ? 'connected and authenticated'
          // A working CLI with no credentials is a NORMAL first-run state, not a broken one:
          // `version` touches only the binary, while `whoami` reaches Apple for a token.
          : 'abctl runs, tenant not authenticated',
    ConnectionChecking() => 'checking',
    ConnectionFailed() => 'failed',
    ConnectionUnknown() => 'not checked',
  };

  /// The whole block, from the same fields the screen just rendered.
  static String _report(List<_HealthField> fields) {
    final buffer = StringBuffer('abgui system report\n');
    for (final _HealthField field in fields) {
      buffer.writeln('${field.label}: ${field.reportValue}');
    }
    return buffer.toString();
  }
}

/// One line of the report: what it is called, what it says, and what to say when it is unknown.
///
/// The placeholder is part of the DATA rather than a rendering detail, because it has to appear
/// in the copied block too: "abctl path: not found" is the most useful line a packaging bug can
/// produce, and a report that silently omitted the field would take that diagnosis with it.
class _HealthField {
  const _HealthField(this.label, this.value, {this.placeholder = 'unknown'});

  final String label;
  final String value;
  final String placeholder;

  String get reportValue => value.trim().isEmpty ? placeholder : value;
}
