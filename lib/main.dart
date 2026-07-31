// RelayLink — Ticket #01 scaffold home screen + #30 capability disclosure
// gate + #38 home screen + wiring-gap-closure bootstrap injection.
//
// `RelayLinkHome` renders the real home screen from `lib/screens/home.dart`
// once the first-launch capability disclosure has been dismissed. The
// older placeholder (Ticket #01) is gone; #38 owns the surface.
//
// The wiring-gap-closure plan (commit history: feat/wired-bootstrap)
// introduces `bootstrapServices` in `lib/app/bootstrap.dart`. This
// `main()` calls it once, then injects the resulting `BootstrapResult`
// into a top-level `ProviderScope` override so the rest of the app can
// `ref.watch(bootstrapResultProvider)` instead of re-initialising
// singletons everywhere.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:relaylink/alerts/allowlist.dart';
import 'package:relaylink/app/bootstrap.dart';
import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/capabilities/observer.dart';
import 'package:relaylink/contacts/contact.dart';
import 'package:relaylink/contacts/contacts_lookup.dart';
import 'package:relaylink/contacts/repository_contacts_lookup.dart';
import 'package:relaylink/crypto/contact_invite.dart';
import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/screens/capability_disclosure.dart';
import 'package:relaylink/screens/chat.dart';
import 'package:relaylink/screens/contacts.dart';
import 'package:relaylink/screens/home.dart';
import 'package:relaylink/screens/remote_chat_controller.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Build every long-lived singleton exactly once at boot. This includes
  // LocalDb, DeviceIdentity, TransportManager (+ mesh/sms/internet
  // transports), DirectSessionStore, BroadcastCrypto, the production
  // ContactsLookup, and the production RemoteChatController.
  final bootstrap = await bootstrapServices();
  // Ticket #36: warm the verified-orgs allowlist cache (read from disk,
  // refresh from Firestore if stale). Fire-and-forget — the app must NOT
  // block on this. Receivers fall back to the bundled
  // `assets/verified_orgs.json` allowlist from #35 if the cache is empty
  // (e.g. on a cold offline launch).
  unawaited(VerifiedOrgsCache().init());
  runApp(
    ProviderScope(
      overrides: [
        bootstrapResultProvider.overrideWithValue(bootstrap),
      ],
      child: const RelayLinkApp(),
    ),
  );
}

class RelayLinkApp extends StatelessWidget {
  const RelayLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RelayLink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4FC3F7),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1116),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            color: Color(0xFFE6EAF2),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      ),
      home: const _FirstLaunchGate(),
    );
  }
}

/// First-launch gate widget. Reads the "seen" flag from SharedPreferences and
/// (1) shows the capability disclosure on top of Home if not seen, or
/// (2) goes straight to Home otherwise. See `lib/screens/capability_disclosure.dart`
/// for the underlying persistence helpers and the iOS-specific verbatim text.
class _FirstLaunchGate extends StatefulWidget {
  const _FirstLaunchGate();

  @override
  State<_FirstLaunchGate> createState() => _FirstLaunchGateState();
}

class _FirstLaunchGateState extends State<_FirstLaunchGate> {
  bool? _seen;

  /// Watches app lifecycle events and re-runs capability detection so the
  /// home screen (#38) auto-refreshes when capabilities change. See
  /// `lib/capabilities/observer.dart`.
  final CapabilityObserver _capabilitiesObserver = CapabilityObserver();

  @override
  void initState() {
    super.initState();
    _checkSeen();
  }

  @override
  void dispose() {
    _capabilitiesObserver.dispose();
    super.dispose();
  }

  Future<void> _checkSeen() async {
    final seen = await hasSeenCapabilityDisclosure();
    if (mounted) setState(() => _seen = seen);
  }

  @override
  Widget build(BuildContext context) {
    if (_seen == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return StreamBuilder<DeviceCapabilities>(
      initialData: _capabilitiesObserver.current,
      stream: _capabilitiesObserver.stream,
      builder: (context, snapshot) {
        final capabilities = snapshot.data ?? _capabilitiesObserver.current;
        return _DisclosureOverlayHome(
          seen: _seen!,
          capabilities: capabilities,
        );
      },
    );
  }
}

// `ProviderScope` is mounted higher up in `main()`.
// `_DisclosureOverlayHome` creates a nested scope with the latest
// device-capability override so downstream consumers such as `HomeScreen`
// remain purely declarative.

/// Renders the home page, and overlays the first-launch disclosure if the
/// user has not yet seen it. Once the overlay is shown, the home page is
/// built first so the disclosure has something to pop back to.
class _DisclosureOverlayHome extends StatefulWidget {
  const _DisclosureOverlayHome({
    required this.seen,
    required this.capabilities,
  });

  final bool seen;
  final DeviceCapabilities capabilities;

  @override
  State<_DisclosureOverlayHome> createState() => _DisclosureOverlayHomeState();
}

class _DisclosureOverlayHomeState extends State<_DisclosureOverlayHome> {
  @override
  void initState() {
    super.initState();
    if (!widget.seen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pushDisclosure());
    }
  }

  Future<void> _pushDisclosure() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CapabilityDisclosurePage(
          capabilities: widget.capabilities,
          mode: CapabilityDisclosureMode.firstLaunch,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Push the freshly-detected capability table into the Riverpod scope
    // *declaratively* via an override, rather than mutating provider state
    // from inside `build()` (which is a Riverpod anti-pattern — the
    // assignment would re-fire on every rebuild). When `widget.capabilities`
    // changes (e.g. after a lifecycle observation tick), the rebuilt
    // ProviderScope re-issues the override and downstream consumers rerun.
    return ProviderScope(
      overrides: [
        deviceCapabilitiesProvider.overrideWith((ref) => widget.capabilities),
      ],
      child: const RelayLinkHome(),
    );
  }
}

class RelayLinkHome extends ConsumerWidget {
  const RelayLinkHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bootstrap = ref.watch(bootstrapResultProvider);
    final identity = ref.watch(deviceIdentityProvider);
    return HomeScreen(
      onContactsTapped: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const _ProductionContactsScreen(),
          ),
        );
      },
      onComposeTapped: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _ProductionChatScreen(
              bootstrap: bootstrap,
              identity: identity,
            ),
          ),
        );
      },
    );
  }
}

/// Production contacts screen: a `ContactsPage` whose repository is
/// backed by the bootstrap's `LocalDb` (read-through cache). Wires the
/// `onPairViaInvite` callback to the bootstrap's
/// `RemoteChatController` + `RepositoryContactsLookup`.
class _ProductionContactsScreen extends ConsumerWidget {
  const _ProductionContactsScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bootstrap = ref.watch(bootstrapResultProvider);
    final identity = ref.watch(deviceIdentityProvider);
    return ContactsPage(
      repository: _ProductionContactsRepository(
        contactsLookup: bootstrap.contactsLookup,
      ),
      myDeviceIdentityLabel: identity.senderId,
      onPairViaInvite: (token) async {
        // Decode the invite, bootstrap a DirectSession, upsert the
        // resulting ContactRecord, and report back what was paired.
        // Any decode / crypto failure surfaces as a thrown exception
        // which the dialog catches and shows as an error snackbar.
        final invite = ContactInviteCodec.decode(token);
        final session = await RemoteChatController.pairWithInviteStatic(
          identity: identity,
          invite: invite,
          isInitiator: true,
        );
        await bootstrap.directSessionStore.put(invite.deviceId, session);
        final record = ContactRecord(
          deviceId: invite.deviceId,
          displayName: invite.displayName,
          x25519PublicKey: invite.x25519PublicKey,
          phoneNumber: null,
        );
        await bootstrap.contactsLookup.upsert(record);
        return PairInviteResult(
          displayName: invite.displayName,
          deviceId: invite.deviceId,
          x25519PublicKey: invite.x25519PublicKey,
        );
      },
    );
  }
}

/// `ContactsRepository` that bridges the bootstrap's
/// `RepositoryContactsLookup` into the simple `Contact` model the
/// ContactsPage expects (Ticket #40). The widget's persistence surface
/// uses `Contact` (id, displayName, publicKey, phoneNumber); the
/// production model uses `ContactRecord` (deviceId, x25519PublicKey).
/// We map between the two.
class _ProductionContactsRepository implements ContactsRepository {
  _ProductionContactsRepository({
    required this.contactsLookup,
  });

  final RepositoryContactsLookup contactsLookup;

  Contact _toContact(ContactRecord r) {
    return Contact(
      id: r.deviceId,
      displayName: r.displayName,
      publicKey: r.x25519PublicKey == null
          ? ''
          : r.x25519PublicKey!
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
      phoneNumber: r.phoneNumber,
    );
  }

  ContactRecord _toRecord(Contact c) {
    final pk = c.publicKey.isEmpty
        ? null
        : Uint8List.fromList(<int>[
            for (var i = 0; i < c.publicKey.length; i += 2)
              int.parse(c.publicKey.substring(i, i + 2), radix: 16),
          ]);
    return ContactRecord(
      deviceId: c.id,
      displayName: c.displayName,
      x25519PublicKey: pk,
      phoneNumber: c.phoneNumber,
    );
  }

  @override
  Future<List<Contact>> list() async {
    final records = await contactsLookup.list();
    return records.map(_toContact).toList(growable: false);
  }

  @override
  Future<void> save(Contact contact) async {
    await contactsLookup.upsert(_toRecord(contact));
  }

  @override
  Future<Contact?> updateDetails({
    required String id,
    String? displayName,
    String? phoneNumber,
  }) async {
    final existing = await contactsLookup.lookupByDeviceIdAsync(id);
    if (existing == null) return null;
    final updated = ContactRecord(
      deviceId: existing.deviceId,
      displayName: displayName ?? existing.displayName,
      x25519PublicKey: existing.x25519PublicKey,
      phoneNumber: phoneNumber ?? existing.phoneNumber,
    );
    await contactsLookup.upsert(updated);
    return _toContact(updated);
  }

  @override
  Future<bool> remove(String id) async {
    final n = await contactsLookup.delete(id);
    return n > 0;
  }
}

/// Production broadcast chat screen. Wires the shared [RemoteChatController]
/// and local [DeviceIdentity] into the [ChatScreen] widget so messages are
/// encrypted, fanned-out over all registered transports, and stored in the
/// local DB.
class _ProductionChatScreen extends StatelessWidget {
  const _ProductionChatScreen({
    required this.bootstrap,
    required this.identity,
  });

  final BootstrapResult bootstrap;
  final DeviceIdentity identity;

  @override
  Widget build(BuildContext context) {
    return ChatScreen(
      controller: bootstrap.remoteChatController,
      senderId: identity.senderId,
      senderDisplayName: 'Me',
      channelId: 'public',
      channelName: 'Public channel',
    );
  }
}
