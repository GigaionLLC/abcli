// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// ============================================================================================
//  SECURITY NOTE — READ BEFORE CHANGING ANYTHING IN THIS FILE
//
//  This store writes an Apple Business API EC PRIVATE KEY to disk. Apple hands that key over
//  exactly once; it cannot be re-downloaded, and it authenticates every write abctl makes to
//  the tenant.
//
//  The Swift app guaranteed mode 0600 inside a 0700 directory, set atomically at creation
//  through `FileManager`'s `posixPermissions` attribute. Dart's `File` API has NO chmod and no
//  create-with-mode, so this file reproduces the guarantee by shelling out:
//
//    * macOS / Linux — `chmod 700` on the directory, `chmod 600` on the key. Same guarantee as
//      the Swift app, minus atomicity: the file exists for an instant with the process umask's
//      mode before it is tightened. That window is closed by writing inside the already-0700
//      directory, where no other user can reach the file even while it is briefly 0644.
//
//    * Windows — *** A WEAKER GUARANTEE. THIS IS A KNOWN REGRESSION FROM THE SWIFT APP. ***
//      Windows has no POSIX mode. The key is written under %LOCALAPPDATA% and locked down with
//      `icacls <file> /inheritance:r /grant:r "<user>":F`, over a keys directory that got
//      `/inheritance:r /grant:r "<user>":(OI)(CI)F`. Inherited ACEs are stripped and the
//      current user ends up as the only entry in the DACL of both.
//
//      The inheritable grant on the DIRECTORY is load-bearing, not tidiness: a new file in a
//      directory with no inheritable ACEs does not get an empty DACL, it gets the DEFAULT DACL
//      from the process token — Owner + SYSTEM + Administrators — and `/grant:r` on the file
//      afterwards only replaces the named user's entry, leaving those two behind. Making the
//      directory's grant inheritable is what stops the key from being created with them in the
//      first place. (Verified on Windows 11: without it, a freshly written key lists
//      `BUILTIN\Administrators:(F)` and `NT AUTHORITY\SYSTEM:(F)`.)
//
//      Even so this is NOT equivalent to 0600, and the difference is not academic. A DACL is
//      advisory to anyone holding SeBackupPrivilege or SeTakeOwnershipPrivilege: any local
//      Administrator can take ownership and rewrite it, anything running as SYSTEM can read
//      through it, and backup/AV/EDR agents routinely do exactly that. Nor is the file
//      encrypted at rest. On macOS and Linux root can do the same, but on Windows the set of
//      principals already holding those rights on a managed corporate machine is much larger.
//      Treat a Windows install of abgui as storing the key at "protected from other ordinary
//      users of this PC", not at "protected from the machine". An admin who needs the stronger
//      property should keep the .pem outside this store (see below) on an encrypted volume, or
//      run abgui on macOS/Linux.
//
//  In every case a failure to tighten permissions DELETES the file and throws. A private key
//  sitting on disk with inherited ACLs or a umask-derived mode is worse than no key at all,
//  because nothing downstream would ever surface it.
// ============================================================================================

import 'dart:io';

/// Where abgui persists a pasted private key.
///
/// abctl reads the EC key from a file PATH (see `internal/config`), so a PEM the user pastes
/// into Settings is written to a user-only file under the platform's per-user application
/// data directory and the context stores that path. Key material is never passed on argv,
/// logged, or written to contexts.yaml. Users who prefer to keep the key elsewhere can instead
/// point a context at an existing .pem on disk — this store is only for the paste path.
abstract final class CredentialStore {
  /// The keys directory for this platform. Created on demand by [writeKey].
  ///
  ///  * macOS — `~/Library/Application Support/abgui/keys`, as in the Swift app.
  ///  * Windows — `%LOCALAPPDATA%\abgui\keys`. LOCAL, never `%APPDATA%`: roaming profiles are
  ///    copied to a domain file server at logoff, and pushing an Apple private key onto a
  ///    network share is precisely the thing this store exists to avoid.
  ///  * Linux — `$XDG_DATA_HOME/abgui/keys`, defaulting to `~/.local/share/abgui/keys`.
  ///
  /// [environment] is injectable so the layout can be tested off its native platform.
  static String keysDir({
    Map<String, String>? environment,
    bool? isWindows,
    bool? isMacOS,
  }) {
    final env = environment ?? Platform.environment;
    final windows = isWindows ?? Platform.isWindows;
    final mac = isMacOS ?? Platform.isMacOS;

    if (windows) {
      final base = _firstNonEmpty([
        env['LOCALAPPDATA'],
        _joinAll([env['USERPROFILE'], 'AppData', 'Local'], r'\'),
      ]);
      return _joinAll([base, 'abgui', 'keys'], r'\');
    }
    final home = _firstNonEmpty([env['HOME'], '.']);
    if (mac) {
      return _joinAll([
        home,
        'Library',
        'Application Support',
        'abgui',
        'keys',
      ], '/');
    }
    final dataHome = _firstNonEmpty([
      env['XDG_DATA_HOME'],
      _joinAll([home, '.local', 'share'], '/'),
    ]);
    return _joinAll([dataHome, 'abgui', 'keys'], '/');
  }

  /// Persist [pem] for [context], returning the absolute path abctl should read. Overwrites
  /// any prior key for the same context (re-saving credentials is idempotent).
  ///
  /// The write is staged through a temporary file in the SAME directory and renamed into
  /// place, so an interrupted save cannot replace a working key with a truncated one — the
  /// property Swift got from `write(to:atomically:)`. Permissions are tightened on the
  /// temporary file BEFORE the rename, because mode and DACL both travel with a rename: the
  /// key is therefore never reachable at its final name in a loose state.
  ///
  /// Throws [CredentialStoreException] if anything at all goes wrong, including — especially —
  /// a failure to lock the file down.
  ///
  /// Async because tightening permissions costs a subprocess on every platform (Dart's `File`
  /// has no chmod), and a credential save is a user action that can perfectly well be awaited.
  static Future<String> writeKey({
    required String pem,
    required String context,
    String? directory,
  }) async {
    final dir = directory ?? keysDir();
    try {
      await Directory(dir).create(recursive: true);
    } on FileSystemException catch (error) {
      throw CredentialStoreException(
        'could not create the key directory at $dir: ${error.message}',
      );
    }
    await FilePermissions.restrictDirectory(dir);

    final target = _joinAll([dir, '${safeName(context)}.pem'], _separator());
    final staging = File('$target.tmp');
    try {
      await staging.writeAsString(pem, flush: true);
    } on FileSystemException catch (error) {
      await _deleteQuietly(staging);
      throw CredentialStoreException(
        'could not write the private key to $dir: ${error.message}',
      );
    }

    try {
      await FilePermissions.restrictFile(staging.path);
    } catch (_) {
      // The whole point of this class. If the key cannot be locked down it does not get to
      // exist: leaving a readable private key behind while reporting an error is the failure
      // mode that turns a bad afternoon into a disclosed credential.
      await _deleteQuietly(staging);
      rethrow;
    }

    try {
      // Windows `rename` refuses to clobber. The window between the delete and the rename can
      // only lose the OLD key, never leak the new one, and the caller is re-saving anyway.
      final existing = File(target);
      if (existing.existsSync()) await existing.delete();
      await staging.rename(target);
    } on FileSystemException catch (error) {
      await _deleteQuietly(staging);
      throw CredentialStoreException(
        'could not install the private key at $target: ${error.message}',
      );
    }
    return target;
  }

  /// A filesystem-safe filename component from a user-chosen context name.
  ///
  /// Beyond the Swift version's character filter this also defuses the Windows RESERVED DEVICE
  /// NAMES. `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9` are reserved *before* the
  /// extension, so a context innocently named `aux` would produce `aux.pem` — a path Windows
  /// resolves to a device, not a file, failing the save with an error message that explains
  /// nothing. The name is only ever used as a filename, so prefixing is harmless.
  static String safeName(String s) {
    final buffer = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(
        _allowed.hasMatch(ch) || ch == '-' || ch == '_' || ch == '.' ? ch : '_',
      );
    }
    final cleaned = buffer.isEmpty ? 'default' : buffer.toString();
    final stem = cleaned.split('.').first.toUpperCase();
    return _windowsReserved.contains(stem) ? '_$cleaned' : cleaned;
  }

  static final RegExp _allowed = RegExp(r'^[\p{L}\p{N}]$', unicode: true);

  static const Set<String> _windowsReserved = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Nothing useful to do, and the caller is already being told the save failed.
    }
  }

  static String _separator() => Platform.isWindows ? r'\' : '/';

  static String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) return value;
    }
    return '.';
  }

  static String _joinAll(List<String?> parts, String sep) {
    final kept = <String>[];
    for (final part in parts) {
      if (part == null || part.isEmpty) return '';
      kept.add(part.endsWith(sep) ? part.substring(0, part.length - 1) : part);
    }
    return kept.join(sep);
  }
}

/// The one place that knows how to make a path unreadable to other users on each platform.
///
/// It is shared with the run log, which carries tenant identifiers and therefore gets the same
/// treatment for the same reason — see `run_log.dart`. Keeping both callers on one
/// implementation means the Windows story above is told once and cannot drift.
abstract final class FilePermissions {
  /// Owner-only, and owner-only for whatever is created inside it: POSIX `0700`, Windows
  /// `icacls /inheritance:r /grant:r <user>:(OI)(CI)F`. See the header for why the
  /// inheritance flags on the directory are what keep SYSTEM and Administrators off the files.
  static Future<void> restrictDirectory(String path) =>
      _restrict(path, posixMode: '700', inheritable: true);

  /// Owner-only read/write: POSIX `0600`, Windows `icacls /inheritance:r /grant:r <user>:F`.
  static Future<void> restrictFile(String path) =>
      _restrict(path, posixMode: '600', inheritable: false);

  static Future<void> _restrict(
    String path, {
    required String posixMode,
    required bool inheritable,
  }) {
    if (Platform.isWindows) return _icacls(path, inheritable: inheritable);
    return _chmod(path, posixMode);
  }

  static Future<void> _chmod(String path, String mode) async {
    // Absolute path first: a GUI-launched process can inherit an all-but-empty PATH, and this
    // must not be the thing that fails a credential save. Fall back to a PATH lookup for the
    // exotic layouts (NixOS, a container) where /bin/chmod does not exist.
    final chmod = File('/bin/chmod').existsSync() ? '/bin/chmod' : 'chmod';
    final ProcessResult result;
    try {
      result = await Process.run(chmod, [mode, path]);
    } on ProcessException catch (error) {
      throw CredentialStoreException(
        'could not run chmod to set permissions $mode on $path: ${error.message}',
      );
    }
    if (result.exitCode != 0) {
      throw CredentialStoreException(
        'could not set permissions $mode on $path: ${_text(result.stderr)}',
      );
    }
  }

  static Future<void> _icacls(String path, {required bool inheritable}) async {
    // `/inheritance:r` strips the ACEs inherited from the parent directory (which, under a
    // default profile, include entries this file must not keep). `/grant:r <user>:…` then
    // REPLACES rather than adds, so re-saving a key does not accumulate ACEs. `(OI)(CI)` on a
    // directory makes the grant apply to the files created inside it, which is the only way to
    // stop Windows handing them the token's default DACL instead.
    final user = _windowsPrincipal();
    final rights = inheritable ? '(OI)(CI)F' : 'F';
    final ProcessResult result;
    try {
      result = await Process.run('icacls', [
        path,
        '/inheritance:r',
        '/grant:r',
        '$user:$rights',
      ]);
    } on ProcessException catch (error) {
      throw CredentialStoreException(
        'could not run icacls to restrict $path: ${error.message}',
      );
    }
    if (result.exitCode != 0) {
      throw CredentialStoreException(
        'could not restrict $path to $user: ${_text(result.stdout)} ${_text(result.stderr)}',
      );
    }
  }

  /// `DOMAIN\user` when the environment names a domain, else the bare username. The qualified
  /// form is unambiguous on a machine where a local account and a domain account share a name,
  /// which is exactly the machine where getting this wrong would be least visible.
  static String _windowsPrincipal() {
    final env = Platform.environment;
    final user = env['USERNAME'];
    if (user == null || user.isEmpty) {
      throw const CredentialStoreException(
        'cannot determine the current Windows user (USERNAME is not set), so the private '
        'key cannot be restricted to you; refusing to write it.',
      );
    }
    final domain = env['USERDOMAIN'];
    return domain == null || domain.isEmpty ? user : '$domain\\$user';
  }

  static String _text(Object? streamOutput) =>
      streamOutput == null ? '' : streamOutput.toString().trim();
}

/// Anything that stopped a credential from being stored safely. Separate from `AbctlError`:
/// nothing here ran abctl, and a caller that maps this onto a CLI failure would be inventing
/// a tenant problem out of a local filesystem one.
class CredentialStoreException implements Exception {
  const CredentialStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}
