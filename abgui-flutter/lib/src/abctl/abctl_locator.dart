// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'abctl_error.dart';

/// Finds the abctl binary that ships INSIDE the app.
///
/// Always by absolute path, derived from `Platform.resolvedExecutable`, and never by a `PATH`
/// lookup: an app launched from Finder / Explorer / a desktop file inherits a minimal
/// environment on all three platforms, so `PATH` resolution is a coin flip that happens to
/// come up heads on the machine of whoever wrote it. It also matters that the binary is the
/// EMBEDDED one — abgui and abctl ship as a matched pair, and picking up whatever `abctl` a
/// developer happens to have in `/usr/local/bin` would silently mix versions.
///
/// The Swift original was one line (`Bundle.main.url(forResource:)`) because macOS has
/// exactly one answer. Three platforms have three bundle layouts and no `Bundle` API, so the
/// candidate list is spelled out below and every path that was tried survives into the error.
///
/// `$ABGUI_ABCTL` overrides everything, pointing at a locally built CLI. It deliberately does
/// NOT fall back to the bundled binary when it is wrong: a developer who typo'd the path is
/// far better served by an error naming their override than by a silent, correct-looking run
/// against the shipped build they were trying to bypass.
abstract final class AbctlLocator {
  /// The developer override. Same name as the Swift app's, so a dev's existing shell profile
  /// keeps working across the rewrite.
  static const String envOverride = 'ABGUI_ABCTL';

  /// Resolve the binary, or throw [AbctlMissingBinary] listing everywhere it looked.
  ///
  /// The parameters exist for testing: `Platform.resolvedExecutable` under `flutter test` is
  /// the test harness, not the app, and the layout of a Windows bundle has to be verifiable
  /// from a macOS CI machine and vice versa.
  static String resolve({
    Map<String, String>? environment,
    String? resolvedExecutable,
    AbctlPlatform? platform,
  }) {
    final env = environment ?? Platform.environment;
    final os = platform ?? AbctlPlatform.current;
    final exe = resolvedExecutable ?? Platform.resolvedExecutable;

    final override = env[envOverride];
    if (override != null && override.isNotEmpty) {
      if (isRunnable(override, platform: os)) return override;
      throw AbctlMissingBinary(
        searched: [override],
        detail:
            '\$$envOverride is set to "$override", but nothing runnable is there. '
            'Fix the path or unset it to use the copy that ships with the app.',
      );
    }

    final searched = candidates(resolvedExecutable: exe, platform: os);
    for (final candidate in searched) {
      if (isRunnable(candidate, platform: os)) return candidate;
    }
    throw AbctlMissingBinary(searched: searched);
  }

  /// The nil-returning form, for a caller that wants to render its own empty state (a
  /// Settings page saying "not found" rather than a thrown banner at launch).
  static String? tryResolve({
    Map<String, String>? environment,
    String? resolvedExecutable,
    AbctlPlatform? platform,
  }) {
    try {
      return resolve(
        environment: environment,
        resolvedExecutable: resolvedExecutable,
        platform: platform,
      );
    } on AbctlMissingBinary {
      return null;
    }
  }

  /// Every place the binary could be, in probe order, for one platform's bundle layout.
  /// Pure: it touches no filesystem, so the layouts are testable from any host.
  static List<String> candidates({
    required String resolvedExecutable,
    required AbctlPlatform platform,
  }) {
    final sep = platform.separator;
    final name = platform.binaryName;
    final exeDir = _dirname(resolvedExecutable, platform);

    switch (platform) {
      case AbctlPlatform.macOS:
        // `abgui.app/Contents/MacOS/abgui` — so the bundle's Resources directory is one level
        // up and across. This is where the release script copies the universal binary, and it
        // is inside the code signature, which is the reason it must not be anywhere else:
        // a hardened-runtime app can only spawn a binary that its own signature covers.
        final contents = _dirname(exeDir, platform);
        return [
          _join(contents, ['Resources', name], sep),
          // An unbundled dev build (`flutter run -d macos` before packaging, or a bare
          // `dart run`) has no Contents/Resources — take a sibling of the executable.
          _join(exeDir, [name], sep),
        ];

      case AbctlPlatform.windows:
        // The Flutter Windows bundle is flat: `abgui.exe` beside `flutter_windows.dll` and a
        // `data\` directory. Packaging copies `abctl.exe` next to the app exe, which is also
        // where Windows' own DLL search starts, so nothing extra has to be told about it.
        return [
          _join(exeDir, [name], sep),
          _join(exeDir, ['data', name], sep),
          // If a future packaging step declares the binary as a Flutter asset instead, it
          // lands under data\flutter_assets\<the path declared in pubspec.yaml>.
          _join(exeDir, ['data', 'flutter_assets', name], sep),
        ];

      case AbctlPlatform.linux:
        // A Flutter Linux bundle is `<root>/abgui` + `<root>/lib/*.so` + `<root>/data/`. A
        // DISTRIBUTION package instead splits those into /usr/bin and /usr/lib, which is why
        // the parent's lib/ is probed as well — same relationship, one directory further out.
        final parent = _dirname(exeDir, platform);
        return [
          _join(exeDir, [name], sep),
          _join(exeDir, ['lib', name], sep),
          _join(parent, ['lib', name], sep),
          _join(exeDir, ['data', 'flutter_assets', name], sep),
        ];
    }
  }

  /// Does a runnable file exist at [path]?
  ///
  /// Existence is not enough on POSIX: a binary copied by an installer that forgot `chmod +x`
  /// exists perfectly well and fails at spawn time with an errno the user cannot act on. The
  /// mode check turns that into a message naming the file. Windows has no execute bit — the
  /// only real gate is the file extension, so existence IS the check there.
  ///
  /// The POSIX test is any-execute-bit rather than a proper `access(X_OK)` (which dart:io does
  /// not expose): it can say yes to a file only ANOTHER user may run. That errs toward
  /// attempting the spawn and reporting the OS's own refusal, which is the better failure of
  /// the two — refusing to try is unrecoverable, trying and failing is diagnosable.
  static bool isRunnable(String path, {AbctlPlatform? platform}) {
    final os = platform ?? AbctlPlatform.current;
    final file = File(path);
    // False for a directory, which matters: `data/abctl` could plausibly be a folder.
    if (!file.existsSync()) return false;
    if (os == AbctlPlatform.windows) return true;
    try {
      return file.statSync().mode & _anyExecuteBit != 0;
    } on FileSystemException {
      return false;
    }
  }

  /// 0o111 — Dart has no octal literals.
  static const int _anyExecuteBit = 0x49;

  static String _dirname(String path, AbctlPlatform platform) {
    var cut = path.lastIndexOf(platform.separator);
    if (platform == AbctlPlatform.windows) {
      // Windows accepts forward slashes everywhere, and a path that reached us through a
      // config file or an env var is quite likely to use them.
      final alt = path.lastIndexOf('/');
      if (alt > cut) cut = alt;
    }
    if (cut <= 0) return path;
    return path.substring(0, cut);
  }

  static String _join(String base, List<String> parts, String sep) {
    final trimmed = base.endsWith(sep)
        ? base.substring(0, base.length - 1)
        : base;
    return [trimmed, ...parts].join(sep);
  }
}

/// The three desktop targets, as a value the locator can be handed.
///
/// `Platform.isWindows` is read once, here, instead of at each decision point: the layouts
/// have to be unit-testable on a machine that is only ever one of the three, and a scattering
/// of `Platform.is*` checks is exactly what makes that impossible.
enum AbctlPlatform {
  macOS(separator: '/', binaryName: 'abctl'),
  windows(separator: r'\', binaryName: 'abctl.exe'),
  linux(separator: '/', binaryName: 'abctl');

  const AbctlPlatform({required this.separator, required this.binaryName});

  final String separator;

  /// abctl builds as `abctl` everywhere and `abctl.exe` on Windows — where the extension is
  /// not decoration: `Process.start` will not run an extensionless file.
  final String binaryName;

  static AbctlPlatform get current {
    if (Platform.isWindows) return AbctlPlatform.windows;
    if (Platform.isMacOS) return AbctlPlatform.macOS;
    return AbctlPlatform.linux;
  }
}
