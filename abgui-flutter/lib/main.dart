// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Process entry point: read the two things the first frame needs, then hand off to [AbguiApp].
///
/// **Everything here happens BEFORE `runApp`, and there is very little of it.** The two reads
/// below are the only work this app is willing to do ahead of its first frame, and both are
/// bounded local operations that answer in single-digit milliseconds. Nothing that reaches a
/// tenant, a network or the abctl binary belongs here: those are per-screen loads, deliberately,
/// so a slow or broken CLI produces a window that explains itself rather than a launch that
/// hangs on a splash screen with no way to report what it is waiting for.
///
/// Neither read can fail the launch. A version that will not resolve is a run-log header with a
/// null in it; a preferences store that will not open leaves the defaults, which are the same
/// defaults a first run gets. An app that refused to start over either would be refusing to start
/// over nothing.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:abgui/app.dart';
import 'package:abgui/src/state/providers.dart';

Future<void> main() async {
  // Required before any plugin channel is touched, and both reads below are plugin reads.
  WidgetsFlutterBinding.ensureInitialized();

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      // Injected rather than read inside the provider, so that layer — and every test of it —
      // stays free of plugin channels: a plain `test()` has no Flutter binding to serve one.
      abguiVersionProvider.overrideWithValue(await _version()),
    ],
  );

  // Awaited, and this is the one thing worth blocking a frame for: the theme is persisted, and a
  // theme that arrives one frame late is a white flash on every launch for a user who chose dark.
  // `restore` swallows its own failures, so this cannot become a launch that never proceeds.
  await container.read(settingsProvider.notifier).restore();

  runApp(
    UncontrolledProviderScope(container: container, child: const AbguiApp()),
  );
}

/// abgui's own version, for the run-log header and the System Health screen.
///
/// Null on failure rather than a guess: the header prints the version so a bug report can be
/// matched to a build, and a made-up value there is worse than an absent one. The release build
/// injects the real version from `git describe` (see `scripts/build-gui-flutter.sh`), so what
/// `pubspec.yaml` carries is only ever what a bare `flutter run` shows.
Future<String?> _version() async {
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    final String version = info.version;
    return version.isEmpty ? null : version;
  } catch (_) {
    // A platform with no package metadata (or a plugin that failed to register) must not be a
    // launch failure — the version is a diagnostic, not a dependency.
    return null;
  }
}
