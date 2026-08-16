// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/models/contract.dart';
import 'package:abgui/src/state/connection_store.dart';
import 'package:abgui/src/state/load_token.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

import 'diagnostics_chrome.dart';

/// Settings: which tenant abgui talks to, how its tables look, and which abctl it is driving.
///
/// **Everything here is read-only in the strong sense, and it stays that way in the release that
/// enabled the tenant writes.** The Swift original was a credential EDITOR — it wrote
/// `~/.abctl/contexts.yaml` through `context set`, saved a pasted PEM to disk and offered a
/// Delete button. None of that is ported, and the reason is not sequencing: abgui's writes are
/// scoped to a tenant's configuration, and an app that also rewrote the operator's private key
/// material would be a much larger thing to trust. `AbctlArgs` has no builder for those verbs, so
/// the guarantee is structural rather than a rule this screen keeps. What is left is the half
/// that answers questions — what connections exist, which one is current, what the CLI is.
///
/// Choosing a saved connection here is NOT one of those writes, and the distinction is worth
/// being explicit about: it sets the `--context` tail abgui appends to its own commands
/// (`ActiveContextStore`). It does not run `abctl context use`, so the operator's own terminal
/// still resolves whatever context it did before.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// One generation for the context-detail read: switching tenants twice quickly must not have
  /// the slower answer land under the newer name.
  final LoadGeneration _details = LoadGeneration('settings.contextDetail');

  String _detailName = '';
  ContextDetail? _detail;
  bool _detailLoading = false;

  @override
  void initState() {
    super.initState();
    // Deferred to the END of the frame this screen is built in, not started here.
    //
    // `loadContexts` sets its loading flag SYNCHRONOUSLY before its first await, and Riverpod
    // refuses a provider write inside a widget life-cycle (build/initState/dispose) — two
    // widgets listening to the same provider could otherwise be handed different states within
    // one frame. It throws rather than tolerating it, so this is a crash on screen entry and not
    // a subtle one. (Caught by the screen smoke test, which is why that test exists.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bootstrap());
    });
  }

  Future<void> _bootstrap() async {
    await ref.read(settingsProvider.notifier).loadContexts();
    if (!mounted) return;
    // Only when NOTHING has checked yet. A screen that re-checks on every visit would mint a
    // token against Apple each time the user opened Settings to change the row height.
    if (ref.read(connectionProvider) is ConnectionUnknown) {
      unawaited(ref.read(connectionProvider.notifier).check());
    }
    unawaited(_loadDetail(_effectiveContext()));
  }

  /// The context abgui's commands actually carry: its own choice when it has one, otherwise
  /// whatever abctl considers current. These are two different facts and the screen shows both.
  String _effectiveContext() {
    final String active = ref.read(activeContextProvider);
    return active.isEmpty ? ref.read(settingsProvider).currentContext : active;
  }

  Future<void> _loadDetail(String name) async {
    if (name.isEmpty) {
      if (!mounted) return;
      setState(() {
        _detailName = '';
        _detail = null;
        _detailLoading = false;
      });
      return;
    }
    final token = _details.begin();
    setState(() {
      _detailName = name;
      _detail = null;
      _detailLoading = true;
    });
    // Null on failure by contract — a detail panel that cannot fill in is an empty panel, not a
    // banner across the screen.
    final ContextDetail? detail = await ref
        .read(settingsProvider.notifier)
        .contextDetail(name);
    if (!mounted || token.isStale) return;
    setState(() {
      _detail = detail;
      _detailLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final Settings settings = ref.watch(settingsProvider);
    final String active = ref.watch(activeContextProvider);
    final Connection connection = ref.watch(connectionProvider);
    final String? binary = ref.watch(abctlBinaryProvider);

    // Following the ACTIVE context rather than the tap: `useContext` also orphans the in-flight
    // connection check, and the detail panel has to follow the tenant that actually won.
    ref.listen<String>(activeContextProvider, (String? previous, String next) {
      unawaited(
        _loadDetail(
          next.isEmpty ? ref.read(settingsProvider).currentContext : next,
        ),
      );
    });

    return ScreenScaffold(
      title: 'Settings',
      actions: <Widget>[
        ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Reload connections',
          tooltip: 'Re-read the saved connections from ~/.abctl/contexts.yaml.',
          onPressed: settings.isLoadingContexts
              ? null
              : () => unawaited(
                  ref.read(settingsProvider.notifier).loadContexts(),
                ),
        ),
      ],
      banner: NoticeBanner(
        icon: abIcon('lock'),
        text: 'abgui never writes your saved connections',
        detail:
            'abgui reads your saved connections and never writes them. Create, edit or delete '
            'one with abctl in a terminal.',
      ),
      child: SingleChildScrollView(
        // See the note in `command_log_screen.dart`: screens coexist in the shell's IndexedStack,
        // so none of them may take the window's primary scroll controller.
        primary: false,
        padding: const EdgeInsets.all(AbSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ScreenSection(
              title: 'Saved connections',
              note:
                  'Choosing one appends --context to abgui\'s own commands. It does not run '
                  'abctl context use, so nothing changes for the CLI in your terminal.',
              children: _connectionRows(ab, settings, active),
            ),
            ScreenSection(
              title: 'Selected connection',
              note:
                  'abctl stores the private key as a PATH and reads it on each run. Key '
                  'material is never printed, and abgui never sees it.',
              children: _detailRows(ab),
            ),
            ScreenSection(
              title: 'Appearance',
              note:
                  'Density is the table row height: comfortable to read one blueprint, compact '
                  'to audit five thousand devices. Both choices are remembered.',
              children: <Widget>[
                _choiceRow(
                  label: 'Theme',
                  children: <Widget>[
                    for (final ThemeMode mode in ThemeMode.values)
                      ToolbarButton(
                        icon: _themeIcon(mode),
                        label: _themeLabel(mode),
                        tooltip: _themeTooltip(mode),
                        weight: AbToolbarWeight.titled,
                        selected: settings.themeMode == mode,
                        onPressed: () => unawaited(
                          ref
                              .read(settingsProvider.notifier)
                              .setThemeMode(mode),
                        ),
                      ),
                  ],
                ),
                _choiceRow(
                  label: 'Density',
                  children: <Widget>[
                    for (final AbDensity density in AbDensity.values)
                      ToolbarButton(
                        icon: density == AbDensity.comfortable
                            ? abIcon('arrow.up.left.and.arrow.down.right')
                            : abIcon('arrow.down.right.and.arrow.up.left'),
                        label: density == AbDensity.comfortable
                            ? 'Comfortable'
                            : 'Compact',
                        tooltip:
                            'Table rows are ${density.rowHeight.toStringAsFixed(0)}px tall.',
                        weight: AbToolbarWeight.titled,
                        selected: settings.density == density,
                        onPressed: () => unawaited(
                          ref
                              .read(settingsProvider.notifier)
                              .setDensity(density),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            ScreenSection(
              title: 'Command-line tool',
              note:
                  'abgui drives the abctl that ships inside it, resolved by absolute path — a '
                  'GUI inherits no shell PATH. Set ABGUI_ABCTL to point at a locally built CLI.',
              trailing: ToolbarButton(
                icon: abIcon('arrow.clockwise'),
                label: 'Check',
                tooltip: 'Run abctl version, then ask the tenant who we are.',
                weight: AbToolbarWeight.titled,
                onPressed: connection is ConnectionChecking
                    ? null
                    : () => unawaited(
                        ref.read(connectionProvider.notifier).check(),
                      ),
              ),
              children: <Widget>[
                CopyableField(
                  label: 'Path',
                  value: binary ?? '',
                  placeholder:
                      'not found — reinstalling the app is the fix for a packaging problem',
                ),
                ..._abctlRows(ab, connection),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _connectionRows(AbColors ab, Settings settings, String active) {
    final String? error = settings.contextsError;
    if (error != null) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
          child: Text(
            error,
            style: TextStyle(fontSize: 12, color: ab.danger, height: 1.4),
          ),
        ),
      ];
    }
    if (settings.contexts.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
          child: Text(
            settings.isLoadingContexts
                ? 'Reading ~/.abctl/contexts.yaml…'
                : 'No saved connections. Create one with `abctl context set <name> '
                      '--client-id … --key …` in a terminal, then reload.',
            style: TextStyle(fontSize: 12, color: ab.dim, height: 1.4),
          ),
        ),
      ];
    }
    return <Widget>[
      for (final String name in settings.contexts)
        _ContextRow(
          name: name,
          // Empty means abgui is not scoping its commands at all, in which case the connection
          // in force IS abctl's current one — showing nothing selected there would be a lie.
          isActive: active.isEmpty
              ? name == settings.currentContext
              : name == active,
          isAbctlDefault: name == settings.currentContext,
          onSelect: () =>
              unawaited(ref.read(connectionProvider.notifier).useContext(name)),
        ),
    ];
  }

  List<Widget> _detailRows(AbColors ab) {
    if (_detailName.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
          child: Text(
            'No connection selected.',
            style: TextStyle(fontSize: 12, color: ab.dim),
          ),
        ),
      ];
    }
    if (_detailLoading) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
          child: Text(
            'Reading $_detailName…',
            style: TextStyle(fontSize: 12, color: ab.dim),
          ),
        ),
      ];
    }
    final ContextDetail? detail = _detail;
    if (detail == null) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
          child: Text(
            'Couldn\'t read the stored fields for $_detailName.',
            style: TextStyle(fontSize: 12, color: ab.dim),
          ),
        ),
      ];
    }
    return <Widget>[
      CopyableField(label: 'Name', value: detail.name),
      CopyableField(
        label: 'Client ID',
        value: detail.context.clientID,
        // Not secret — it is an identifier, and it is the first thing a support conversation
        // asks for. `CommandFormatter` deliberately does not redact it for the same reason.
        copyTooltip: 'Copy the Apple Business API client id.',
      ),
      CopyableField(label: 'Key path', value: detail.context.keyPath),
      CopyableField(
        label: 'API base',
        value: detail.context.apiBase ?? '',
        placeholder: 'Apple Business default',
      ),
    ];
  }

  List<Widget> _abctlRows(AbColors ab, Connection connection) {
    switch (connection) {
      case ConnectionConnected(:final VersionInfo version, :final identity):
        return <Widget>[
          CopyableField(label: 'Version', value: version.version),
          CopyableField(
            label: 'Commit',
            value: version.commit ?? '',
            placeholder: 'development build',
          ),
          CopyableField(label: 'Go', value: version.goVersion),
          CopyableField(
            label: 'Capabilities',
            value: '${version.capabilities.length}',
          ),
          CopyableField(
            label: 'Tenant',
            value: identity?.clientID ?? '',
            // `version` touches nothing but the binary while `whoami` reaches Apple for a token,
            // so a working CLI with no credentials is a normal state and not a broken one.
            placeholder:
                'not authenticated — abctl runs, the tenant did not answer',
          ),
        ];
      case ConnectionChecking():
        return <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
            child: Text(
              'Checking…',
              style: TextStyle(fontSize: 12, color: ab.dim),
            ),
          ),
        ];
      case ConnectionFailed(:final String message):
        return <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
            child: SelectableText(
              message,
              style: TextStyle(fontSize: 12, color: ab.danger, height: 1.4),
            ),
          ),
        ];
      case ConnectionUnknown():
        return <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
            child: Text(
              'Not checked yet.',
              style: TextStyle(fontSize: 12, color: ab.dim),
            ),
          ),
        ];
    }
  }

  Widget _choiceRow({required String label, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AbSpace.xs),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(label.toUpperCase(), style: AbType.label(context)),
          ),
          for (final Widget child in children) ...<Widget>[
            child,
            const SizedBox(width: AbSpace.xs),
          ],
        ],
      ),
    );
  }

  static IconData _themeIcon(ThemeMode mode) => switch (mode) {
    ThemeMode.system => abIcon('circle.lefthalf.filled'),
    ThemeMode.light => abIcon('sun.max'),
    ThemeMode.dark => abIcon('moon'),
  };

  static String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'System',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  static String _themeTooltip(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Follow the desktop\'s own light/dark setting.',
    ThemeMode.light => 'The cyanotype print: blue ink on cool paper.',
    ThemeMode.dark => 'The cyanotype itself: pale rules on a deep blue ground.',
  };
}

/// One saved connection.
///
/// It carries two independent facts, which is why there are two markers: whether abgui's commands
/// are scoped to this context, and whether abctl itself considers it current. They are usually
/// the same and are allowed not to be — abgui scopes explicitly, and this release cannot change
/// abctl's own choice.
class _ContextRow extends StatelessWidget {
  const _ContextRow({
    required this.name,
    required this.isActive,
    required this.isAbctlDefault,
    required this.onSelect,
  });

  final String name;
  final bool isActive;
  final bool isAbctlDefault;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return Semantics(
      button: true,
      selected: isActive,
      label: '$name${isAbctlDefault ? ', abctl\'s current context' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: isActive ? null : onSelect,
        borderRadius: BorderRadius.circular(AbSpace.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AbSpace.xs,
            vertical: 5,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                abIcon(isActive ? 'checkmark.circle.fill' : 'circle'),
                size: 14,
                color: isActive ? ab.accent : ab.faint,
              ),
              const SizedBox(width: AbSpace.sm),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbType.mono(
                    context,
                    color: isActive ? ab.text : ab.dim,
                    weight: isActive ? FontWeight.w600 : null,
                  ),
                ),
              ),
              if (isAbctlDefault)
                const AbBadge(label: 'abctl default', fontSize: 10),
            ],
          ),
        ),
      ),
    );
  }
}
