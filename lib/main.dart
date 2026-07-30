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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:relaylink/alerts/allowlist.dart';
import 'package:relaylink/app/bootstrap.dart';
import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/capabilities/observer.dart';
import 'package:relaylink/screens/capability_disclosure.dart';
import 'package:relaylink/screens/home.dart';

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

class RelayLinkHome extends StatelessWidget {
  const RelayLinkHome({super.key});

  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
  }
}
