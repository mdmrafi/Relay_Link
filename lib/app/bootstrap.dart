// RelayLink — Single-shot service-locator / app bootstrap.
//
// The wiring-gap-closure plan's `bootstrapServices` constructs every
// long-lived singleton exactly once at boot and returns a `BootstrapResult`
// bundle the rest of the app pulls from via `ProviderScope.overrides`.
// Without this, `lib/main.dart` only initialised the channel-key store
// and the verified-orgs cache — every transport, every crypto seam,
// and the production `ChatController` were orphans.
//
// The transports registered here are the production implementations;
// their `isAvailable()` returns false until a real radio / Firebase
// binding is wired (per `HANDOFF-2026-07-31.md` §7). With
// `--dart-define=DEV_LOOPBACK=true`, an `EchoTransport` is registered
// last so a single device can exercise the full send → fan-out →
// incoming → decrypt → render path end-to-end without hardware.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:relaylink/channels/keys.dart';
import 'package:relaylink/contacts/repository_contacts_lookup.dart';
import 'package:relaylink/crypto/broadcast.dart';
import 'package:relaylink/crypto/direct_session_store.dart';
import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/mesh/transport.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/screens/remote_chat_controller.dart';
import 'package:relaylink/sms/transport.dart';
import 'package:relaylink/storage/local_db.dart';
import 'package:relaylink/transport/internet.dart';
import 'package:relaylink/transport/transport.dart';

/// Reads the `DEV_LOOPBACK` `--dart-define` flag. When `true`, the
/// bootstrap registers an `EchoTransport` so the full send → fan-out
/// → incoming → decrypt path can be exercised on a single device.
const bool _kDevLoopback = bool.fromEnvironment(
  'DEV_LOOPBACK',
  defaultValue: false,
);

/// Holds every long-lived singleton the app needs at runtime. The
/// `BootstrapResult` is intended to be injected once at boot via
/// `ProviderScope.overrides` and read from the `bootstrapResultProvider`.
class BootstrapResult {
  /// Local SQLite database wrapper.
  final LocalDb db;

  /// Persistent device identity (Ed25519 signing + X25519 DH).
  final DeviceIdentity identity;

  /// Secure-storage-backed cache of per-peer `DirectSession` instances.
  final DirectSessionStore directSessionStore;

  /// Transport fan-out. Holds: `MeshTransport`, `SmsTransport`,
  /// `InternetTransport`, and (when `--dart-define=DEV_LOOPBACK=true`)
  /// an `EchoTransport`.
  final TransportManager transportManager;

  /// Shared `BroadcastCrypto` for BROADCAST encrypt/decrypt.
  final BroadcastCrypto broadcastCrypto;

  /// Production `ContactsLookup` (cache-hydrated from `LocalDb.contacts`).
  final RepositoryContactsLookup contactsLookup;

  /// Mode-aware `MessageDecryptor` that dispatches on `Message.mode`.
  final Future<String?> Function(Message) messageDecryptor;

  /// Production `ChatController` (the seam the chat widget binds to).
  final RemoteChatController remoteChatController;

  /// Channel key store (already initialised by the bootstrap).
  final ChannelKeyStore channelKeyStore;

  /// Was `--dart-define=DEV_LOOPBACK=true` set?
  final bool devLoopbackEnabled;

  const BootstrapResult._({
    required this.db,
    required this.identity,
    required this.directSessionStore,
    required this.transportManager,
    required this.broadcastCrypto,
    required this.contactsLookup,
    required this.messageDecryptor,
    required this.remoteChatController,
    required this.channelKeyStore,
    required this.devLoopbackEnabled,
  });

  /// Release held resources. Called from `main.dart` shutdown hooks or
  /// from test `tearDown` blocks.
  Future<void> dispose() async {
    remoteChatController.dispose();
    await db.close();
    await directSessionStore.close();
  }
}

/// Build a `BootstrapResult` for the running app. Safe to call from
/// `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
///
/// [dbOverride] is intended for tests: pass an already-open in-memory
/// `LocalDb` (via `LocalDb.withDatabase`) so the test doesn't touch
/// the on-device database file. Production code calls without
/// arguments.
Future<BootstrapResult> bootstrapServices({LocalDb? dbOverride}) async {
  // 1. Identity — looked up or generated on first launch.
  final identity = await DeviceIdentity.loadOrGenerate();

  // 2. Channel key store — ensures the default `public` channel key is
  //    registered before any `BroadcastCrypto` operation.
  final channelKeyStore = await ChannelKeyStore.instance();
  await channelKeyStore.init();

  // 3. Local DB.
  final db = dbOverride ?? await LocalDb.instance();

  // 4. Production ContactsLookup, hydrated from db.contacts.
  final contactsLookup = RepositoryContactsLookup(db);

  // 5. DirectSessionStore (secure-storage-backed).
  final directSessionStore = DirectSessionStore.instance();

  // 6. BroadcastCrypto — defaults come seeded with the `public` channel.
  final broadcastCrypto = BroadcastCrypto();

  // 7. TransportManager + transports.
  final transportManager = TransportManager();
  transportManager.register(MeshTransport());
  transportManager.register(SmsTransport());
  // `InternetTransport` requires a `FirestoreGateway`; the null-object
  // gateway returns "unavailable" so the transport registers but never
  // observes traffic. This is the honest "registered but stubbed"
  // wiring the handoff calls for.
  transportManager.register(InternetTransport(
    gateway: _UnavailableFirestoreGateway(),
    ownSenderId: identity.senderId,
  ));
  if (_kDevLoopback) {
    transportManager.register(EchoTransport(name: 'echo'));
  }

  // 8. Decryptor — dispatches on `message.mode`.
  final Future<String?> Function(Message) messageDecryptor =
      (msg) => _decryptMessage(
            msg,
            broadcastCrypto: broadcastCrypto,
            directSessionStore: directSessionStore,
          );

  // 9. Chat controller.
  final remoteChatController = RemoteChatController(
    db: db,
    transports: transportManager,
    identity: identity,
    broadcastCrypto: broadcastCrypto,
    directSessionStore: directSessionStore,
    decryptor: messageDecryptor,
  );

  return BootstrapResult._(
    db: db,
    identity: identity,
    directSessionStore: directSessionStore,
    transportManager: transportManager,
    broadcastCrypto: broadcastCrypto,
    contactsLookup: contactsLookup,
    messageDecryptor: messageDecryptor,
    remoteChatController: remoteChatController,
    channelKeyStore: channelKeyStore,
    devLoopbackEnabled: _kDevLoopback,
  );
}

Future<String?> _decryptMessage(
  Message msg, {
  required BroadcastCrypto broadcastCrypto,
  required DirectSessionStore directSessionStore,
}) async {
  switch (msg.mode) {
    case MessageMode.broadcast:
      try {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        if (!broadcastCrypto.hasChannelKey(env.channelId)) return null;
        return broadcastCrypto.decryptString(env);
      } catch (_) {
        return null;
      }
    case MessageMode.direct:
      if (msg.senderId.isEmpty) return null;
      final session = await directSessionStore.get(msg.senderId);
      if (session == null) return null;
      final ciphertext = msg.payload;
      try {
        final header = RemoteChatController.decodeRatchetHeader(
          msg.ratchetHeader ?? Uint8List(0),
        );
        return await session.decrypt(ciphertext, header);
      } catch (_) {
        return null;
      }
  }
}

/// Riverpod provider that exposes the `BootstrapResult` to the rest of
/// the app. `main.dart` overrides this with the value from
/// `bootstrapServices()`.
final bootstrapResultProvider = Provider<BootstrapResult>((ref) {
  throw UnimplementedError(
    'bootstrapResultProvider must be overridden at app boot '
    'with a value produced by `bootstrapServices()`.',
  );
});

/// Convenience reader for the `RemoteChatController`. Screens that need
/// the production chat controller read this and `watch` / `read` it.
final remoteChatControllerProvider = Provider<RemoteChatController>((ref) {
  final result = ref.watch(bootstrapResultProvider);
  return result.remoteChatController;
});

/// Convenience reader for the `DeviceIdentity`. Exposed so screens can
/// display the local SenderId without going through the full bootstrap.
final deviceIdentityProvider = Provider<DeviceIdentity>((ref) {
  final result = ref.watch(bootstrapResultProvider);
  return result.identity;
});

/// Convenience reader for the `TransportManager`.
final transportManagerProvider = Provider<TransportManager>((ref) {
  final result = ref.watch(bootstrapResultProvider);
  return result.transportManager;
});

/// Convenience reader for the `LocalDb`.
final localDbProvider = Provider<LocalDb>((ref) {
  final result = ref.watch(bootstrapResultProvider);
  return result.db;
});

/// Convenience reader for the `RepositoryContactsLookup`.
final contactsLookupProvider = Provider<RepositoryContactsLookup>((ref) {
  final result = ref.watch(bootstrapResultProvider);
  return result.contactsLookup;
});

// ---------------------------------------------------------------------------
// Stubs / null-objects
// ---------------------------------------------------------------------------

/// `FirestoreGateway` that always reports itself unavailable. Used by
/// the bootstrap to wire `InternetTransport` into the
/// `TransportManager` without standing up a real Firebase project.
class _UnavailableFirestoreGateway implements FirestoreGateway {
  @override
  Future<void> pushMessage(Message msg) async {
    throw const FirestoreGatewayUnavailable();
  }

  @override
  Future<List<Message>> pullBroadcastSince(
    DateTime since, {
    Set<String> channelIds = const <String>{},
  }) async {
    throw const FirestoreGatewayUnavailable();
  }

  @override
  Future<List<Message>> pullDirectFor(
    String recipientId,
    DateTime since,
  ) async {
    throw const FirestoreGatewayUnavailable();
  }
}
