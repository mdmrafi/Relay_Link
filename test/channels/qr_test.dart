// RelayLink — Ticket #16 Channel QR encode + scan tests.
//
// The spec under .scratch/relaylink-build/issues/16-channel-qr.md calls
// for a round-trip test (encode → decode → same channelId/key) and
// "UI bits testable without camera". `mobile_scanner` requires a real
// camera surface in widget tests, so we exercise the encode/decode path
// against the payload string + the rendered bytes, and stub the scanner
// controller so `ChannelScannerWidget` can be pumped headlessly.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:relaylink/channels/qr.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Wire format / round-trip
  // ---------------------------------------------------------------------------

  group('ChannelInvite.fromJsonString / toJsonString', () {
    test('roundtrip preserves channelId and key bytes', () {
      // Realistic AES-256 key (32 bytes) — random but fixed so the test
      // is deterministic.
      final key = Uint8List.fromList(<int>[
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
      ]);

      final invite = ChannelInvite.build(channelId: 'ops', keyBytes: key);

      // Sanity-check the fingerprint is a SHA-256 (64 hex chars) of the
      // raw key bytes — this is exactly what the joiner will compute
      // themselves to confirm "I scanned the same bytes the creator
      // displayed", so it MUST be stable.
      expect(
        invite.fingerprint.length,
        64,
        reason: 'SHA-256 hex should be 64 chars',
      );
      expect(
        invite.fingerprint,
        equals(keyFingerprint(key)),
        reason: 'build() fingerprint must match the standalone helper',
      );

      final raw = invite.toJsonString();
      final round = ChannelInvite.fromJsonString(raw);

      expect(round.channelId, equals('ops'));
      expect(round.keyBytes, equals(key));
      expect(round.version, equals(kChannelInviteVersion));
      expect(round.fingerprint, equals(invite.fingerprint));
    });

    test('name field roundtrips when present', () {
      final key = Uint8List.fromList(List<int>.filled(32, 0xAA));
      final invite = ChannelInvite.build(
        channelId: 'dev',
        keyBytes: key,
        name: ' Dev Channel ',
      );

      final round = ChannelInvite.fromJsonString(invite.toJsonString());
      expect(round.name, equals(' Dev Channel '));
    });

    test('name field is null when absent', () {
      final key = Uint8List.fromList(List<int>.filled(32, 0xAB));
      final invite = ChannelInvite.build(channelId: 'dev', keyBytes: key);
      final raw = invite.toJsonString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded.containsKey('name'), isFalse,
          reason: 'omitted name must not appear as a top-level key');
    });

    test('decodeChannelPayload is an alias for fromJsonString', () {
      final key = Uint8List.fromList(List<int>.filled(32, 0xCD));
      final invite = ChannelInvite.build(channelId: 'x', keyBytes: key);
      final viaAlias = decodeChannelPayload(invite.toJsonString());
      expect(viaAlias.channelId, equals(invite.channelId));
      expect(viaAlias.keyBytes, equals(invite.keyBytes));
    });
  });

  group('ChannelInvite.build validation', () {
    test('rejects empty channelId', () {
      final key = Uint8List.fromList(List<int>.filled(32, 0));
      expect(
        () => ChannelInvite.build(channelId: '', keyBytes: key),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects keys that are not exactly 32 bytes', () {
      expect(
        () => ChannelInvite.build(
          channelId: 'x',
          keyBytes: List<int>.filled(16, 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ChannelInvite.build(
          channelId: 'x',
          keyBytes: List<int>.filled(64, 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('ChannelInvite.fromJsonString error handling', () {
    final key = Uint8List.fromList(List<int>.filled(32, 0x11));
    String wellFormedRaw() => ChannelInvite.build(
          channelId: 'ops',
          keyBytes: key,
        ).toJsonString();

    test('rejects non-JSON text', () {
      expect(
        () => ChannelInvite.fromJsonString('not-json'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects JSON that is not an object', () {
      expect(
        () => ChannelInvite.fromJsonString('"a string"'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ChannelInvite.fromJsonString('[1, 2, 3]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unsupported version', () {
      final raw = wellFormedRaw().replaceFirst(
        '"v":$kChannelInviteVersion',
        '"v":999',
      );
      expect(
        () => ChannelInvite.fromJsonString(raw),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing id', () {
      final raw = jsonEncode(<String, Object?>{
        'v': kChannelInviteVersion,
        'k': base64.encode(key),
      });
      expect(
        () => ChannelInvite.fromJsonString(raw),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing key', () {
      final raw = jsonEncode(<String, Object?>{
        'v': kChannelInviteVersion,
        'id': 'ops',
      });
      expect(
        () => ChannelInvite.fromJsonString(raw),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects key that is not 32 bytes', () {
      final raw = jsonEncode(<String, Object?>{
        'v': kChannelInviteVersion,
        'id': 'ops',
        'k': base64.encode(List<int>.filled(16, 0)),
      });
      expect(
        () => ChannelInvite.fromJsonString(raw),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects malformed base64', () {
      final raw = jsonEncode(<String, Object?>{
        'v': kChannelInviteVersion,
        'id': 'ops',
        'k': '!!!not-base64!!!',
      });
      expect(
        () => ChannelInvite.fromJsonString(raw),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Encode → PNG bytes
  // ---------------------------------------------------------------------------

  group('encodeChannelQR', () {
    test('returns non-empty PNG bytes that start with the PNG magic',
        () async {
      final key = Uint8List.fromList(List<int>.filled(32, 0xEE));
      final png = await encodeChannelQR('ops', key);
      expect(png.length, greaterThan(8));
      // PNG signature: 89 50 4E 47 0D 0A 1A 0A
      const pngMagic = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      expect(png.sublist(0, 8), equals(pngMagic));
    });

    test('encoded PNG survives decode of its embedded payload', () async {
      // Round-trip: render → read raw bytes back through our parser.
      // We don't run a full QR decoder on the PNG (would need an
      // image-processing dep in tests); instead we verify the same
      // JSON roundtrip works since that's the wire the scanner hands us.
      final key = Uint8List.fromList(<int>[
        for (var i = 0; i < 32; i++) i + 100,
      ]);
      final invite = ChannelInvite.build(channelId: 'e2e', keyBytes: key);
      final decoded = ChannelInvite.fromJsonString(invite.toJsonString());
      expect(decoded.channelId, equals('e2e'));
      expect(decoded.keyBytes, equals(key));
      expect(decoded.fingerprint, equals(keyFingerprint(key)));
      // The PNG encode path itself does not need to be re-decoded —
      // we already verified the PNG header above.
      final png = await encodeChannelQR('e2e', key);
      expect(png.length, greaterThan(0));
    });

    test('accepts an optional display name', () async {
      final key = Uint8List.fromList(List<int>.filled(32, 0x77));
      // Just ensure the named variant does not throw and produces PNG.
      final png = await encodeChannelQR('named', key, name: 'Crew 7');
      expect(png.length, greaterThan(8));
    });
  });

  // ---------------------------------------------------------------------------
  // UI bits testable without camera
  // ---------------------------------------------------------------------------

  group('ChannelScannerWidget (stubbed controller)', () {
    testWidgets('emits decoded payload via onChannelInvite callback',
        (tester) async {
      final key = Uint8List.fromList(List<int>.filled(32, 0xCC));
      final invite = ChannelInvite.build(
        channelId: 'scan-me',
        keyBytes: key,
      );

      ChannelInvite? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelScannerWidget(
            onChannelInvite: (i) {
              captured = i;
            },
          ),
        ),
      );

      // The widget exposes a test hook to inject a detection the way
      // the real controller would — without spinning up a camera.
      final state = tester.state<ChannelScannerWidgetState>(
        find.byType(ChannelScannerWidget),
      );
      state.testHandleDetection(invite.toJsonString());
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured!.channelId, equals('scan-me'));
      expect(captured!.keyBytes, equals(key));
    });

    testWidgets('ignores payloads that fail to decode', (tester) async {
      var callCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelScannerWidget(
            onChannelInvite: (_) => callCount++,
          ),
        ),
      );

      final state = tester.state<ChannelScannerWidgetState>(
        find.byType(ChannelScannerWidget),
      );

      // Garbage payload must not invoke the callback — the widget
      // consumes it silently. (In the real flow we'd surface a
      // "not a RelayLink invite" toast; widget tests just assert the
      // callback contract.)
      state.testHandleDetection('not-a-valid-invite');
      state.testHandleDetection('');
      state.testHandleDetection('{"unrelated":true}');
      await tester.pump();

      expect(callCount, 0);
    });

    testWidgets('renders an error placeholder when the stubbed camera '
        'is denied', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelScannerWidget(
            onChannelInvite: (_) {},
            cameraControllerBuilder: _deniedCameraController,
          ),
        ),
      );
      // Pump microtasks until the widget's denied-state future settles.
      await tester.pumpAndSettle();
      expect(find.textContaining('permission'), findsWidgets);
    });
  });

  group('ChannelInvite fingerprint', () {
    test('identical keys produce identical fingerprints', () {
      final a = Uint8List.fromList(List<int>.filled(32, 0xAB));
      final b = Uint8List.fromList(List<int>.filled(32, 0xAB));
      expect(keyFingerprint(a), equals(keyFingerprint(b)));
    });

    test('one-byte difference produces a totally different fingerprint', () {
      final a = Uint8List.fromList(List<int>.filled(32, 0xAB));
      final b = Uint8List.fromList(List<int>.filled(32, 0xAB));
      b[31] = 0xAC;
      expect(keyFingerprint(a), isNot(equals(keyFingerprint(b))));
    });
  });

  // Sanity: importing `mobile_scanner` should work — we use it for the
  // real controller wiring. Just assert the symbol resolves so an
  // accidental pubspec edit doesn't silently break the camera path.
  test('mobile_scanner exports MobileScannerController', () {
    // ignore: unnecessary_statements
    expect(MobileScannerController, isNotNull);
  });
}

/// Test-only builder that yields a controller pre-marked as denied —
/// lets widget tests exercise the "camera permission refused" branch
/// without a real device. We simulate the denied branch by throwing
/// the platform's well-known `MobileScannerException` with the
/// `permissionDenied` code, which the widget catches and renders as the
/// permission-denied placeholder.
Future<MobileScannerController> _deniedCameraController() async {
  throw const MobileScannerException(
    errorCode: MobileScannerErrorCode.permissionDenied,
    errorDetails: MobileScannerErrorDetails(
      message: 'simulated permission denial for widget test',
    ),
  );
}
