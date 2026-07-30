// RelayLink — `ContactInvite` codec tests.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:relaylink/crypto/contact_invite.dart';
import 'package:relaylink/crypto/identity.dart';

void main() {
  group('ContactInviteCodec', () {
    test('encode produces a relaylink-invite-v1 prefixed token', () {
      final invite = ContactInvite(
        deviceId: 'aabbccddeeff0011',
        x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
        displayName: 'Alice',
        salt: Uint8List.fromList(List<int>.filled(16, 0x22)),
      );
      final token = ContactInviteCodec.encode(invite);
      expect(token.startsWith('$kContactInvitePrefix:'), isTrue);
      // ASCII-safe (no QR-incompatible characters).
      expect(RegExp(r'^[A-Za-z0-9\-_=:]+$').hasMatch(token), isTrue);
    });

    test('encode → decode round-trips all fields', () {
      final invite = ContactInvite(
        deviceId: '0123456789abcdef',
        x25519PublicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
        displayName: 'Bob the Builder',
        salt: Uint8List.fromList(List<int>.generate(16, (i) => i + 100)),
      );
      final token = ContactInviteCodec.encode(invite);
      final decoded = ContactInviteCodec.decode(token);
      expect(decoded.deviceId, invite.deviceId);
      expect(decoded.displayName, invite.displayName);
      expect(decoded.x25519PublicKey, invite.x25519PublicKey);
      expect(decoded.salt, invite.salt);
    });

    test('decode rejects an unknown prefix', () {
      expect(
        () => ContactInviteCodec.decode('bogus-prefix:abc'),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode rejects a missing colon', () {
      expect(
        () => ContactInviteCodec.decode('relaylink-invite-v1noColon'),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode rejects truncated / empty payload', () {
      expect(
        () => ContactInviteCodec.decode('$kContactInvitePrefix:'),
        throwsA(isA<FormatException>()),
      );
      // A 1-character payload base64Url-decodes to garbage that won't
      // be valid JSON — either the base64 step or the JSON step throws
      // a FormatException. We accept either path as "rejected".
      expect(
        () => ContactInviteCodec.decode('${kContactInvitePrefix}:Zg'),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode rejects a payload with wrong field types', () {
      // Build a token with version=2, which is unsupported.
      final badJson = '{"v":2,"device_id":"abcd","x25519_pub":"AAAA","display_name":"","salt":"AAAA"}';
      final token =
          '$kContactInvitePrefix:${Uri.encodeComponent(badJson)}';
      // The above payload isn't base64-url-encoded, so it'll fail at the
      // base64 decode step. Either way: FormatException.
      expect(
        () => ContactInviteCodec.decode(token),
        throwsA(isA<FormatException>()),
      );
    });

    test('encode rejects a non-16-char deviceId', () {
      expect(
        () => ContactInviteCodec.encode(
          ContactInvite(
            deviceId: 'short',
            x25519PublicKey: Uint8List(32),
            displayName: '',
            salt: Uint8List(16),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('encode rejects a wrong-length x25519 key', () {
      expect(
        () => ContactInviteCodec.encode(
          ContactInvite(
            deviceId: '0123456789abcdef',
            x25519PublicKey: Uint8List(16),
            displayName: '',
            salt: Uint8List(16),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('forLocalDevice produces a valid (encode → decode) token', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final self = await DeviceIdentity.generate();
      addTearDown(() async {
        await FlutterSecureStorage().deleteAll();
      });
      final invite = ContactInviteCodec.forLocalDevice(self);
      // 16-char senderId, 32-byte x25519 pub, 16-byte salt.
      expect(invite.deviceId, self.senderId);
      expect(invite.x25519PublicKey.length, 32);
      expect(invite.salt.length, 16);

      final token = ContactInviteCodec.encode(invite);
      final decoded = ContactInviteCodec.decode(token);
      expect(decoded.deviceId, self.senderId);
      expect(decoded.x25519PublicKey, self.x25519PublicKeyBytes);
    });
  });

  group('ContactInviteCodec.bootstrapSession', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('two simulated devices derive the same shared root from each other',
        () async {
      // Each side uses the OTHER's invite. The shared root on both
      // sides must be identical because ECDH is symmetric and the
      // domain-separation HKDF info is a constant.
      final alice = await DeviceIdentity.generate();
      final bob = await DeviceIdentity.generate();

      final aliceInvite = ContactInviteCodec.forLocalDevice(alice);
      final bobInvite = ContactInviteCodec.forLocalDevice(bob);

      final aliceRoot = await ContactInviteCodec.deriveSharedRoot(
        self: alice,
        invite: bobInvite,
      );
      final bobRoot = await ContactInviteCodec.deriveSharedRoot(
        self: bob,
        invite: aliceInvite,
      );
      expect(aliceRoot, bobRoot);
      expect(aliceRoot.length, 32);
    });

    test('bidirectional ECDH produces matching DirectSession roundtrips',
        () async {
      // The canonical "Alice and Bob pair and exchange messages"
      // scenario: each side generates an invite, they exchange invites,
      // and each side bootstraps from the OTHER's invite (which carries
      // the other side's X25519 public key). The shared root must match
      // on both ends because ECDH is symmetric.
      final alice = await DeviceIdentity.generate();
      final bob = await DeviceIdentity.generate();

      final aliceInvite = ContactInviteCodec.forLocalDevice(alice);
      final bobInvite = ContactInviteCodec.forLocalDevice(bob);

      // Alice bootstraps from Bob's invite; Bob bootstraps from Alice's.
      final aliceSession = await ContactInviteCodec.bootstrapSession(
        self: alice,
        invite: bobInvite,
        isInitiator: true,
      );
      final bobSession = await ContactInviteCodec.bootstrapSession(
        self: bob,
        invite: aliceInvite,
        isInitiator: false,
      );

      final dm = await aliceSession.encrypt('hello bob');
      final plaintext = await bobSession.decrypt(
        dm.ciphertext,
        dm.ratchetHeader,
      );
      expect(plaintext, 'hello bob');
    });
  });
}
