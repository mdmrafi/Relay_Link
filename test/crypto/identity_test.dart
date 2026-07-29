// RelayLink — Ticket #02 device identity unit tests.
//
// We exercise the full lifecycle:
//   1. Generate a fresh identity and check its surface area.
//   2. Persist via save(), reload via load(), assert round-trip stability.
//   3. Sign/verify round-trip.
//   4. ECDH symmetry (A.ecdh(B) == B.ecdh(A)).
//   5. SenderId is deterministic, 16 lowercase hex chars.
//   6. Subsequent load() does NOT regenerate (sender id stays the same).
//
// flutter_secure_storage is mocked via FlutterSecureStorage.setMockInitialValues,
// which is the package's documented test hook.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/crypto/identity.dart';

/// Test-only hex encoder. Mirrors the one in identity.dart (private there).
String _hexLower(List<int> bytes) {
  const chars = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(chars[(b >> 4) & 0x0F]);
    sb.write(chars[b & 0x0F]);
  }
  return sb.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('DeviceIdentity.generate()', () {
    test('produces a non-empty identity with a 16-hex SenderId', () async {
      final id = await DeviceIdentity.generate();
      final sid = id.senderId;
      expect(sid.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(sid), isTrue);
    });

    test('produces 32-byte ed25519 and x25519 public keys', () async {
      final id = await DeviceIdentity.generate();
      expect(id.ed25519PublicKeyBytes.length, 32);
      expect(id.x25519PublicKeyBytes.length, 32);
    });

    test('SenderId is derived from the Ed25519 public key (deterministic)',
        () async {
      final id = await DeviceIdentity.generate();
      final hexStr = _hexLower(id.ed25519PublicKeyBytes);
      expect(id.senderId, hexStr.substring(0, 16));
      expect(id.senderId.toLowerCase(), id.senderId); // lowercase
    });

    test('two fresh identities have distinct SenderIds', () async {
      final a = await DeviceIdentity.generate();
      final b = await DeviceIdentity.generate();
      expect(a.senderId, isNot(b.senderId));
    });
  });

  group('sign / verify', () {
    test('round-trip succeeds with the matching public key', () async {
      final id = await DeviceIdentity.generate();
      final message = utf8.encode('hello RelayLink');
      final sig = await id.sign(message);
      expect(sig.length, 64);

      final ok = await DeviceIdentity.verify(
        message,
        signature: sig,
        publicKey: id.ed25519PublicKeyBytes,
      );
      expect(ok, isTrue);
    });

    test('verify fails when the message is tampered', () async {
      final id = await DeviceIdentity.generate();
      final sig = await id.sign(utf8.encode('original'));
      final ok = await DeviceIdentity.verify(
        utf8.encode('tampered'),
        signature: sig,
        publicKey: id.ed25519PublicKeyBytes,
      );
      expect(ok, isFalse);
    });

    test('verify fails when the signature is from a different identity',
        () async {
      final a = await DeviceIdentity.generate();
      final b = await DeviceIdentity.generate();
      final message = utf8.encode('hello');
      final sig = await a.sign(message);
      // Try to verify A's signature against B's public key — should fail.
      final ok = await DeviceIdentity.verify(
        message,
        signature: sig,
        publicKey: b.ed25519PublicKeyBytes,
      );
      expect(ok, isFalse);
    });

    test('verify returns false (does not throw) on a malformed signature',
        () async {
      final id = await DeviceIdentity.generate();
      final bad = Uint8List(64); // all zero
      final ok = await DeviceIdentity.verify(
        utf8.encode('anything'),
        signature: bad,
        publicKey: id.ed25519PublicKeyBytes,
      );
      expect(ok, isFalse);
    });
  });

  group('ECDH symmetry', () {
    test('A.ecdh(B) == B.ecdh(A) and both are 32 bytes', () async {
      final a = await DeviceIdentity.generate();
      final b = await DeviceIdentity.generate();
      final ab = await a.ecdh(b.x25519PublicKeyBytes);
      final ba = await b.ecdh(a.x25519PublicKeyBytes);
      expect(ab.length, 32);
      expect(ba.length, 32);
      expect(ab, equals(ba));
    });

    test('a third peer derives a different shared secret', () async {
      final a = await DeviceIdentity.generate();
      final b = await DeviceIdentity.generate();
      final c = await DeviceIdentity.generate();
      final ab = await a.ecdh(b.x25519PublicKeyBytes);
      final ac = await a.ecdh(c.x25519PublicKeyBytes);
      expect(ab, isNot(equals(ac)));
    });
  });

  group('persistence (save / load / loadOrGenerate)', () {
    test('save() then load() round-trips the identity', () async {
      final original = await DeviceIdentity.generate();
      final originalSid = original.senderId;
      await original.save();

      final loaded = await DeviceIdentity.load();
      expect(loaded.senderId, originalSid);
      expect(loaded.ed25519PublicKeyBytes, equals(original.ed25519PublicKeyBytes));
      expect(loaded.x25519PublicKeyBytes, equals(original.x25519PublicKeyBytes));

      // Sanity: the loaded identity can still sign with the same key.
      final sig = await loaded.sign(utf8.encode('after-load'));
      final ok = await DeviceIdentity.verify(
        utf8.encode('after-load'),
        signature: sig,
        publicKey: original.ed25519PublicKeyBytes,
      );
      expect(ok, isTrue);
    });

    test('loadOrGenerate creates on first launch', () async {
      final id = await DeviceIdentity.loadOrGenerate();
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(id.senderId), isTrue);
    });

    test('loadOrGenerate does NOT regenerate on subsequent launches',
        () async {
      final first = await DeviceIdentity.loadOrGenerate();
      final second = await DeviceIdentity.loadOrGenerate();
      final third = await DeviceIdentity.loadOrGenerate();
      expect(first.senderId, second.senderId);
      expect(second.senderId, third.senderId);
      expect(first.ed25519PublicKeyBytes, equals(third.ed25519PublicKeyBytes));
    });

    test('load() throws when no identity is stored', () async {
      expect(
        () => DeviceIdentity.load(),
        throwsA(isA<StateError>()),
      );
    });

    test('on-device bytes are base64-encoded strings in storage', () async {
      final id = await DeviceIdentity.generate();
      await id.save();
      const storage = FlutterSecureStorage();
      final edPriv = await storage.read(key: DeviceIdentityKeys.ed25519Private);
      final xPriv = await storage.read(key: DeviceIdentityKeys.x25519Private);
      expect(edPriv, isNotNull);
      expect(xPriv, isNotNull);
      // base64 decode of a 32-byte blob is 44 chars with padding.
      final decoded = base64Decode(edPriv!);
      expect(decoded.length, 32);
      final decodedX = base64Decode(xPriv!);
      expect(decodedX.length, 32);
    });
  });
}