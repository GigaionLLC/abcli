// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The store holds an Apple private key that cannot be re-downloaded, so the permission step is
// tested against the real filesystem on whichever platform this runs — asserting the POSIX mode
// on macOS/Linux and the actual DACL on Windows. The Windows assertion is deliberately about
// what was REMOVED: an inherited ACE granting some group Modify is the failure this guards.

import 'dart:io';

import 'package:abgui/src/abctl/credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

const String _pem =
    '-----BEGIN EC PRIVATE KEY-----\nnot-a-real-key\n-----END EC PRIVATE KEY-----\n';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('abgui_keys'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // The OS owns its temp.
    }
  });

  group('filenames', () {
    test('a context name becomes a filesystem-safe component', () {
      expect(CredentialStore.safeName('prod'), 'prod');
      expect(CredentialStore.safeName('Acme Corp / EU'), 'Acme_Corp___EU');
      expect(CredentialStore.safeName('../../etc/passwd'), '.._.._etc_passwd');
      expect(CredentialStore.safeName(''), 'default');
    });

    test('Windows reserved device names are defused', () {
      // `aux.pem` resolves to a DEVICE on Windows, not a file, and the save fails with an
      // error that explains nothing. The name is only ever a filename, so a prefix is free.
      expect(CredentialStore.safeName('aux'), '_aux');
      expect(CredentialStore.safeName('COM1'), '_COM1');
      expect(CredentialStore.safeName('console'), 'console');
    });
  });

  group('layout', () {
    test('the key never lands in a roaming profile on Windows', () {
      // %APPDATA% is copied to a domain file server at logoff. A private key must not be.
      final path = CredentialStore.keysDir(
        environment: const {
          'LOCALAPPDATA': r'C:\Users\ada\AppData\Local',
          'APPDATA': r'C:\Users\ada\AppData\Roaming',
        },
        isWindows: true,
        isMacOS: false,
      );
      expect(path, r'C:\Users\ada\AppData\Local\abgui\keys');
      expect(path.contains('Roaming'), isFalse);
    });

    test('macOS and Linux follow their own conventions', () {
      expect(
        CredentialStore.keysDir(
          environment: const {'HOME': '/Users/ada'},
          isWindows: false,
          isMacOS: true,
        ),
        '/Users/ada/Library/Application Support/abgui/keys',
      );
      expect(
        CredentialStore.keysDir(
          environment: const {'HOME': '/home/ada'},
          isWindows: false,
          isMacOS: false,
        ),
        '/home/ada/.local/share/abgui/keys',
      );
    });
  });

  group('writing', () {
    test('the PEM round-trips and no staging file is left behind', () async {
      final path = await CredentialStore.writeKey(
        pem: _pem,
        context: 'prod',
        directory: dir.path,
      );

      expect(path.endsWith('prod.pem'), isTrue);
      expect(File(path).readAsStringSync(), _pem);
      expect(
        File('$path.tmp').existsSync(),
        isFalse,
        reason: 'the staged copy must not survive the rename',
      );
    });

    test(
      're-saving the same context overwrites rather than accumulating',
      () async {
        await CredentialStore.writeKey(
          pem: _pem,
          context: 'prod',
          directory: dir.path,
        );
        final second = await CredentialStore.writeKey(
          pem: 'second',
          context: 'prod',
          directory: dir.path,
        );

        expect(File(second).readAsStringSync(), 'second');
        expect(dir.listSync().whereType<File>().length, 1);
      },
    );

    test('the key is readable only by this user', () async {
      final path = await CredentialStore.writeKey(
        pem: _pem,
        context: 'prod',
        directory: dir.path,
      );

      if (Platform.isWindows) {
        // Weaker than 0600 by construction (see the header of credential_store.dart), but the
        // DACL itself must come out clean. Two distinct regressions are covered:
        //   * an inherited ACE surviving — a profile or temp directory routinely grants some
        //     group Modify, and letting a private key inherit that is the whole failure;
        //   * SYSTEM/Administrators arriving from the process token's DEFAULT DACL, which is
        //     what happens if the keys directory's grant ever loses its (OI)(CI) flags.
        final acl = Process.runSync('icacls', [path]).stdout.toString();
        expect(
          acl.contains('(I)'),
          isFalse,
          reason: 'inherited ACEs must be stripped from a private key:\n$acl',
        );
        expect(
          acl.contains(r'BUILTIN\'),
          isFalse,
          reason: 'only the current user belongs on the key\'s DACL:\n$acl',
        );
        expect(
          acl.contains(Platform.environment['USERNAME'] ?? '<unset>'),
          isTrue,
          reason: acl,
        );
      } else {
        expect(
          File(path).statSync().mode & 0x1FF,
          0x180, // 0o600
          reason: 'the key is not owner-only',
        );
      }
    });
  });
}
