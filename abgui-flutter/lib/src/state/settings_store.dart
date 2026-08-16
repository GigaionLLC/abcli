// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/models/contract.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'load_token.dart';
import 'providers.dart';

/// The saved connections abctl knows about, plus the two presentation choices this app persists.
///
/// Both halves are settings in the user's sense of the word, and both are read-only in this
/// release's sense of it: the context list is read FROM `~/.abctl/contexts.yaml` and never written
/// to it (`context set` / `use` / `delete` rewrite an operator's credential file, which is a
/// mutation like any other and has no builder in `AbctlArgs`).
class Settings {
  const Settings({
    this.contexts = const <String>[],
    this.currentContext = '',
    this.isLoadingContexts = false,
    this.contextsError,
    this.themeMode = ThemeMode.system,
    this.density = AbDensity.comfortable,
  });

  /// Every saved connection name, as `abctl context list` reports them.
  final List<String> contexts;

  /// The one abctl itself considers current — what a command with no `--context` would use. This
  /// is abctl's fact about its own store, NOT abgui's choice of tenant; that lives on
  /// `Connection.context`, and the two can legitimately differ while abgui scopes its commands
  /// explicitly.
  final String currentContext;

  final bool isLoadingContexts;

  /// Why the list could not be read.
  ///
  /// It exists because the alternative was measurably worse: a failed list used to leave
  /// `contexts` at its old value with nothing said, and on a first load that renders as "No saved
  /// connections yet" over a store that has several — inviting the user to re-enter credentials
  /// they already have.
  final String? contextsError;

  final ThemeMode themeMode;

  /// Table row height. An admin auditing five thousand devices and one reading a single blueprint
  /// want different answers.
  final AbDensity density;

  Settings copyWith({
    List<String>? contexts,
    String? currentContext,
    bool? isLoadingContexts,
    String? contextsError,
    ThemeMode? themeMode,
    AbDensity? density,
  }) => Settings(
    contexts: contexts ?? this.contexts,
    currentContext: currentContext ?? this.currentContext,
    isLoadingContexts: isLoadingContexts ?? this.isLoadingContexts,
    contextsError: contextsError,
    themeMode: themeMode ?? this.themeMode,
    density: density ?? this.density,
  );

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      identical(other.contexts, contexts) &&
      other.currentContext == currentContext &&
      other.isLoadingContexts == isLoadingContexts &&
      other.contextsError == contextsError &&
      other.themeMode == themeMode &&
      other.density == density;

  /// Identity for the list (it is replaced wholesale, never mutated), values for the rest.
  @override
  int get hashCode => Object.hash(
    identityHashCode(contexts),
    currentContext,
    isLoadingContexts,
    contextsError,
    themeMode,
    density,
  );
}

/// Reads the context store, and owns the two persisted presentation choices.
///
/// Note what [copyWith] does with `contextsError`: it CLEARS unless passed. That is deliberate
/// and the opposite of the other fields — an error is about one attempt, so every transition has
/// to restate it or lose it, which is how a stale message stops outliving the thing it described.
class SettingsStore extends Notifier<Settings> {
  static const String themeKey = 'abgui.themeMode';
  static const String densityKey = 'abgui.density';

  /// Its own generation: two rapid refreshes of the connection list must not have the slower one
  /// clear the faster one's spinner or overwrite its result.
  final LoadGeneration _loads = LoadGeneration('settings.contexts');

  @override
  Settings build() => const Settings();

  /// Restore the persisted presentation choices. Called once at startup, before the first frame
  /// if possible — a theme that arrives late is a visible flash of the wrong one.
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final theme = prefs.getString(themeKey);
      final density = prefs.getString(densityKey);
      state = state.copyWith(
        themeMode: _themeFromWire(theme) ?? state.themeMode,
        density: _densityFromWire(density) ?? state.density,
        contextsError: state.contextsError,
      );
    } catch (_) {
      // A preferences store that will not open leaves the defaults in place, which are the same
      // defaults a first run gets. Nothing to report and nothing to fix.
    }
  }

  /// Read the saved connections + which one abctl considers current.
  Future<void> loadContexts() async {
    final token = _loads.begin();
    state = state.copyWith(isLoadingContexts: true);
    try {
      final list = await ref.read(abctlClientProvider).contextList();
      if (token.isStale) return;
      state = state.copyWith(
        contexts: list.contexts,
        currentContext: list.current,
        isLoadingContexts: false,
      );
    } on AbctlCancelled {
      if (token.isStale) return;
      state = state.copyWith(isLoadingContexts: false);
    } catch (error) {
      if (token.isStale) return;
      state = state.copyWith(
        isLoadingContexts: false,
        contextsError:
            'Couldn\'t read saved connections: ${loadErrorText(error)}',
      );
    }
  }

  /// One saved context's stored fields, to fill in a read-only detail panel.
  ///
  /// Only ever the client id and the key PATH — abctl never prints key material, and the key
  /// travels to it as a path precisely so it cannot leak through a process listing. Returns null
  /// when the read fails: a detail panel that cannot fill in is an empty panel, not a banner
  /// across the settings screen.
  Future<ContextDetail?> contextDetail(String name) async {
    try {
      return await ref.read(abctlClientProvider).contextDetail(name: name);
    } catch (_) {
      return null;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == state.themeMode) return;
    state = state.copyWith(themeMode: mode, contextsError: state.contextsError);
    await _remember(themeKey, mode.name);
  }

  Future<void> setDensity(AbDensity density) async {
    if (density == state.density) return;
    state = state.copyWith(
      density: density,
      contextsError: state.contextsError,
    );
    await _remember(densityKey, density.name);
  }

  /// Persist one choice. The state has ALREADY moved by the time this runs: a toggle that waited
  /// for a disk write to redraw would feel broken on a slow volume, and a write that fails is a
  /// choice that lasts for this session instead of a choice that did not happen.
  Future<void> _remember(String key, String value) async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      await prefs.setString(key, value);
    } catch (_) {
      // See above — deliberately silent.
    }
  }

  /// Null for absent or unrecognized, so a value written by another build (or hand-edited) falls
  /// back to the current setting instead of throwing at startup.
  static ThemeMode? _themeFromWire(String? value) {
    for (final mode in ThemeMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }

  static AbDensity? _densityFromWire(String? value) {
    for (final density in AbDensity.values) {
      if (density.name == value) return density;
    }
    return null;
  }
}
