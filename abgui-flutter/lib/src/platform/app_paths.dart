// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:abgui/src/abctl/credential_store.dart'
    show CredentialStore, FilePermissions;
import 'package:abgui/src/abctl/run_log.dart' show RunLog;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// Where abgui keeps its own files, per platform, created on demand.
///
/// **This type does not INVENT any layout.** The two directories that matter were each decided
/// in the file that had to live with the consequence — `CredentialStore` for key material,
/// `RunLog` for the transcript — and both decisions are load-bearing (see the security header
/// in `credential_store.dart` and [RunLog.defaultDirectory]). Restating the three-branch rule
/// here would mean two answers to "local or roaming?" that a later edit could split apart, and
/// the way that failure presents is the ugly one: the writer writes to A, the Logs screen lists
/// B, and the app reports "no run logs" for a run that plainly just happened. So this file
/// DELEGATES for the path and adds only what neither of those files does — creating the
/// directory, and having somewhere sane to land when the environment cannot answer.
///
/// **Nothing here throws.** Every resolver returns `String?` and answers null on any failure.
/// That is the same contract `RunLog.begin` already keeps and for the same reason: a log
/// directory that cannot be created must degrade to "no run log", never to a failed sync. A
/// caller holds `String?` and skips logging, or shows the path it did get.
///
/// **path_provider is the fallback, not the primary.** Reversing that would be a bug on two
/// counts. On Windows `getApplicationSupportDirectory()` answers under FOLDERID_RoamingAppData
/// — `%APPDATA%`, which is copied to a domain file server at logoff and is exactly where
/// `credential_store.dart` forbids an Apple private key from going. And path_provider's desktop
/// implementations are registered by the generated plugin registrant, which only runs in a real
/// app: under `flutter test` the call goes to a method channel nobody answers, so a
/// plugin-first design would make this entire layer untestable AND would silently resolve to
/// different directories in a test than in the shipped app. Asking the environment first gives
/// the same answer in both, and keeps Windows on `%LOCALAPPDATA%`.
abstract final class AppPaths {
  // Memoized successes only. `Directory.create` is a syscall per call and, worse,
  // [FilePermissions.restrictDirectory] is a SUBPROCESS on every platform — the Logs screen
  // asking for its directory once per refresh would otherwise fork icacls/chmod once per
  // refresh. Failures are deliberately NOT cached: a full disk that the user then clears must
  // start working again without a relaunch.
  static String? _applicationSupportCache;
  static String? _runLogCache;

  /// Forget the memoized directories. Tests inject an environment and must not be served the
  /// previous test's answer.
  @visibleForTesting
  static void resetForTesting() {
    _applicationSupportCache = null;
    _runLogCache = null;
  }

  // MARK: layout (pure — no filesystem, so the per-OS rules are testable off their own OS)

  /// abgui's data root: the directory `keys/` sits inside.
  ///
  ///  * macOS — `~/Library/Application Support/abgui`
  ///  * Windows — `%LOCALAPPDATA%\abgui` (local, never roaming — see the class doc)
  ///  * Linux — `$XDG_DATA_HOME/abgui`, defaulting to `~/.local/share/abgui`
  ///
  /// Derived as the PARENT of [CredentialStore.keysDir] rather than written out again, so the
  /// two can never disagree about which of `%LOCALAPPDATA%` / `%APPDATA%` this app uses.
  static String applicationSupportLayout({
    Map<String, String>? environment,
    bool? isWindows,
    bool? isMacOS,
  }) => _parentOf(
    CredentialStore.keysDir(
      environment: environment,
      isWindows: isWindows,
      isMacOS: isMacOS,
    ),
  );

  /// Where run-log transcripts are written and listed.
  ///
  ///  * macOS — `~/Library/Logs/abgui` (the platform convention; Console.app lists it)
  ///  * Windows — `%LOCALAPPDATA%\abgui\logs`
  ///  * Linux — `$XDG_STATE_HOME/abgui/logs`, defaulting to `~/.local/state/abgui/logs`
  ///
  /// The Linux path carries a `logs/` leaf that the macOS one does not, because on macOS the
  /// `Logs` segment is already the platform's own. Whatever it is, it is [RunLog]'s to decide:
  /// this delegates so the viewer reads the directory the writer writes, which is the whole
  /// point of routing both through one file.
  static String runLogLayout({
    Map<String, String>? environment,
    bool? isWindows,
    bool? isMacOS,
  }) => RunLog.defaultDirectory(
    environment: environment,
    isWindows: isWindows,
    isMacOS: isMacOS,
  );

  /// Where a pasted PEM is stored — `<applicationSupport>/keys` under a normal environment.
  ///
  /// Resolve-only, and deliberately NOT `'${applicationSupportLayout()}/keys'`: this must be
  /// the exact directory [CredentialStore.writeKey] will use, or a Settings screen ends up
  /// pointing "Reveal" at a folder the key is not in. Creation and permissions belong to
  /// `writeKey`, which fails loudly if it cannot lock the directory down — the one place in
  /// this app where a filesystem failure MUST NOT degrade quietly.
  static String keysLayout({
    Map<String, String>? environment,
    bool? isWindows,
    bool? isMacOS,
  }) => CredentialStore.keysDir(
    environment: environment,
    isWindows: isWindows,
    isMacOS: isMacOS,
  );

  // MARK: resolution (creates on demand, never throws)

  /// The data root, created if needed. Null if it could not be created.
  ///
  /// [environment] exists for tests, which point the layout at a temp tree; passing it also
  /// bypasses the cache, since an injected environment must not be answered from — or written
  /// into — the process-wide one.
  static Future<String?> applicationSupportDirectory({
    Map<String, String>? environment,
  }) async {
    final cached = _applicationSupportCache;
    if (cached != null && environment == null) return cached;
    final resolved = await _resolve(
      fromEnvironment: applicationSupportLayout(environment: environment),
      fromPlugin: _pluginApplicationSupport,
      restrict: false,
    );
    if (environment == null) _applicationSupportCache = resolved;
    return resolved;
  }

  /// The run-log directory, created if needed. **Null means "no run log"** — the caller writes
  /// nothing and carries on. See the class doc.
  ///
  /// Created owner-only. The permission tightening is a best-effort convenience here, not the
  /// guarantee: `RunLog.begin` asserts it again on every run and refuses to log if it fails.
  /// It is done here as well because the Logs SCREEN can create this directory before anything
  /// has ever been written to it, and a directory abgui created at the process umask is
  /// precisely the hole `RunLog` closes — the listing alone enumerates which tenant operations
  /// ran and when.
  static Future<String?> runLogDirectory({
    Map<String, String>? environment,
  }) async {
    final cached = _runLogCache;
    if (cached != null && environment == null) return cached;
    final resolved = await _resolve(
      fromEnvironment: runLogLayout(environment: environment),
      // No `~/Library/Logs` to be had without a HOME, so the last resort hangs the logs off
      // the data root the plugin does know: wrong-looking beats unwritable.
      fromPlugin: () async {
        final base = await _pluginApplicationSupport();
        return base == null ? null : _join(base, 'logs');
      },
      restrict: true,
    );
    if (environment == null) _runLogCache = resolved;
    return resolved;
  }

  /// Whether [path] is rooted. Hand-rolled because `package:path` is not a declared dependency
  /// of this app and adding one for eight lines is not a trade worth making.
  ///
  /// A RELATIVE answer is the signal that the environment has been stripped — a GUI launch, a
  /// login item, a service — and that whatever we computed is really "the process working
  /// directory", which for a packaged app is somewhere like `C:\Program Files\abgui` or `/`.
  /// Writing tenant transcripts (or, worse, a private key) there is not a degraded outcome, it
  /// is a wrong one, so an unrooted path sends the resolver to path_provider instead.
  static bool isAbsolutePath(String path, {bool? isWindows}) {
    if (path.isEmpty) return false;
    if (isWindows ?? Platform.isWindows) {
      // UNC (`\\server\share`) counts; a bare leading slash does not, because on Windows it is
      // drive-relative and resolves against the CWD's drive.
      if (path.startsWith(r'\\') || path.startsWith('//')) return true;
      if (path.length < 3) return false;
      final drive = path.codeUnitAt(0);
      final isLetter =
          (drive >= 0x41 && drive <= 0x5A) || (drive >= 0x61 && drive <= 0x7A);
      return isLetter && path[1] == ':' && (path[2] == r'\' || path[2] == '/');
    }
    return path.startsWith('/');
  }

  static Future<String?> _resolve({
    required String fromEnvironment,
    required Future<String?> Function() fromPlugin,
    required bool restrict,
  }) async {
    final target = isAbsolutePath(fromEnvironment)
        ? fromEnvironment
        : await fromPlugin();
    if (target == null || target.isEmpty) return null;
    return _ensure(target, restrict: restrict);
  }

  static Future<String?> _ensure(String path, {required bool restrict}) async {
    try {
      await Directory(path).create(recursive: true);
    } catch (_) {
      // Read-only volume, a sandbox denial, or a plain FILE sitting where the directory should
      // be. Nothing here can fix any of them and no caller can either — they get null.
      return null;
    }
    if (restrict) {
      try {
        await FilePermissions.restrictDirectory(path);
      } catch (_) {
        // Best-effort by design: the enforcing copy of this call lives in `RunLog.begin`, which
        // still refuses to write if the directory cannot be locked down. Failing HERE would
        // turn "logs might be readable by another local user" into "the Logs screen is broken",
        // which is a worse trade for the person who just wants to read a transcript.
      }
    }
    return path;
  }

  /// path_provider's answer, or null if the plugin is not there to give one (every unit test,
  /// and any host where the platform implementation failed to register).
  static Future<String?> _pluginApplicationSupport() async {
    try {
      final directory = await getApplicationSupportDirectory();
      return directory.path;
    } catch (_) {
      // MissingPluginException under `flutter test`, MissingPlatformDirectoryException on a
      // host with no such directory. Both mean the same thing to a caller: we do not know.
      return null;
    }
  }

  /// The containing directory, for either separator, without assuming which platform's paths
  /// are being handled — the layout helpers are testable off their own OS, so this sees
  /// backslash paths on a Mac and forward-slash paths on Windows.
  static String _parentOf(String path) {
    var cut = path.lastIndexOf('/');
    final alt = path.lastIndexOf(r'\');
    if (alt > cut) cut = alt;
    return cut <= 0 ? path : path.substring(0, cut);
  }

  static String _join(String base, String child) {
    final separator = base.contains(r'\') && !base.contains('/') ? r'\' : '/';
    final trimmed = base.endsWith(separator)
        ? base.substring(0, base.length - 1)
        : base;
    return '$trimmed$separator$child';
  }
}
