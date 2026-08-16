// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Both behaviours under test are the ones a bare `Clipboard.setData` call at a call site would
// get wrong: copying nothing wipes what the user had, and a channel failure escapes into the
// framework's error zone from a void `onPressed`.

import 'package:abgui/src/platform/clipboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> calls = <MethodCall>[];
  late bool channelFails;

  setUp(() {
    calls.clear();
    channelFails = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method != 'Clipboard.setData') return null;
          calls.add(call);
          if (channelFails) {
            throw PlatformException(code: 'clipboard-unavailable');
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('a copy reaches the platform', () async {
    expect(await AbClipboard.copy('abctl diff --json'), isTrue);
    expect(calls.single.method, 'Clipboard.setData');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['text'],
      'abctl diff --json',
    );
  });

  test('copying nothing leaves the clipboard alone', () async {
    // The user copied something a minute ago. Pressing Copy on an empty transcript must not be
    // the thing that destroys it — and there is no undo for a clipboard.
    expect(await AbClipboard.copy(''), isFalse);
    expect(calls, isEmpty);
  });

  test('a platform failure is reported, not thrown', () async {
    // No clipboard owner on a headless X session, another app holding the Windows clipboard.
    // This is invoked from a void callback, so an escaping exception has nowhere to go.
    channelFails = true;
    expect(await AbClipboard.copy('text'), isFalse);
  });
}
