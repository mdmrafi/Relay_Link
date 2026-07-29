// RelayLink — Ticket #18 Firestore project stub.
//
// Initializes Firebase Core, Cloud Firestore, and Firebase Storage at app
// startup. Must be safe to call from `main()` BEFORE `runApp()`, and must
// never crash the app on devices that have no Firebase configuration
// (offline-first design — see SPEC.md §9 "Capability disclosure" and STRESS-
// TEST.md rationale: the mesh layer is the non-negotiable baseline; internet
// is an additive channel that activates when available).
//
// The placeholder `lib/firebase_options.dart` checked in for this repository
// does NOT contain a real Firebase project. `Firebase.initializeApp()` will
// throw on a real device when the API keys/project id are placeholders, so
// we catch any init failure and fall back to a no-op "local-only" mode. Later
// tickets (#20 internet messaging, #22 gateway relay, #31 vault, #35/#36
// allowlist) all consult `isInitialized` before touching Firestore so the
// app remains fully usable in offline-only scenarios.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

/// Whether Firebase was successfully initialized at app startup.
///
/// `false` means the app is in **local-only mode**: all features that don't
/// require a backend continue to work (Bluetooth mesh, secure storage, vault
/// capture at rest, ALERT verification against the locally cached allowlist).
/// Features that DO require Firestore/Storage (internet relay push, gateway
/// pull, vault deliver-on-connect, allowlist refresh) silently no-op until a
/// real `firebase_options.dart` is provisioned.
class FirebaseBackend {
  FirebaseBackend._();

  static bool _initialized = false;

  /// True if Firebase Core, Firestore, and Storage are all wired up.
  static bool get isInitialized => _initialized;

  /// True when the app is running without a backend (offline-only / local).
  static bool get isLocalOnlyMode => !_initialized;

  /// Initialize Firebase. Safe to call when offline or when the configuration
  /// file is the demo placeholder.
  ///
  /// Returns `true` if init succeeded, `false` if the app is now in local-only
  /// mode. Callers don't need to branch on the return value — features that
  /// depend on Firebase check [isInitialized] — but the return is useful for
  /// the "first-launch capability disclosure" screen (Ticket #30) to surface
  /// a plain "Firebase unavailable, running offline" line to the user.
  static Future<bool> init() async {
    if (_initialized) return true;
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );

      // Persist offline cache so the app can read previously-fetched relay
      // messages (and pending outbound messages) when the device has no
      // connectivity. Persistence is required for the offline-first design in
      // SPEC.md §5/§9; default Web-style in-memory caching would break the
      // contract.
      try {
        FirebaseFirestore.instance.settings =
            const Settings(persistenceEnabled: true);
      } catch (e) {
        // Settings assignment can fail on some platforms (e.g. web) where the
        // SDK manages persistence internally. Don't treat that as fatal.
        debugPrint('Firestore settings (persistence) not applied: $e');
      }

      // Touch storage so it's eagerly constructed and so any platform-side
      // setup errors surface here rather than at first upload.
      FirebaseStorage.instance;

      _initialized = true;
      debugPrint('Firebase initialized.');
      return true;
    } catch (e, st) {
      // Demo placeholder config (or no network at all on first launch) lands
      // here. We log but do NOT rethrow — the app must keep running.
      debugPrint(
        'Firebase init failed: $e\n'
        'Running in local-only mode. See README → "Firebase setup".',
      );
      debugPrintStack(stackTrace: st);
      _initialized = false;
      return false;
    }
  }

  /// Access the default Firestore instance. Throws if [isInitialized] is
  /// `false`. Callers MUST check [isInitialized] first; this method exists as
  /// a belt-and-braces guard so a stack trace points at the offending caller
  /// rather than at an opaque SDK null-check.
  static FirebaseFirestore get firestore {
    if (!_initialized) {
      throw StateError(
        'FirebaseBackend.firestore called before init succeeded. '
        'Guard with FirebaseBackend.isInitialized.',
      );
    }
    return FirebaseFirestore.instance;
  }

  /// Access the default Firebase Storage instance. Same guard contract as
  /// [firestore].
  static FirebaseStorage get storage {
    if (!_initialized) {
      throw StateError(
        'FirebaseBackend.storage called before init succeeded. '
        'Guard with FirebaseBackend.isInitialized.',
      );
    }
    return FirebaseStorage.instance;
  }

  /// Collection names. Centralized here so rename-safety is one edit, and so
  /// ticket #20/#22/#31/#35/#36 don't need to memorize the schema doc.
  static const String relayCollection = 'relay';
  static const String relayDirectCollection = 'relay_direct';
  static const String verifiedOrgsCollection = 'verified_orgs';
  static const String evidenceCollection = 'evidence';

  /// Build the path to a broadcast (BROADCAST mode) message subcollection.
  static String relayMessagesPath(String channelId) =>
      '$relayCollection/$channelId/messages';

  /// Build the path to a direct (DIRECT mode) message subcollection.
  static String relayDirectMessagesPath(String recipientId) =>
      '$relayDirectCollection/$recipientId/messages';

  /// Build the path to a per-recipient evidence-records subcollection.
  static String evidenceRecordsPath(String recipientId) =>
      '$evidenceCollection/$recipientId/records';
}

/// Convenience top-level wrapper around [FirebaseBackend.init] for `main()`.
///
/// Example:
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await initFirebase();
///   runApp(const RelayLinkApp());
/// }
/// ```
Future<bool> initFirebase() => FirebaseBackend.init();
