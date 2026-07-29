// RelayLink — Ticket #01 scaffold home screen + #30 capability disclosure gate.
//
// This is a placeholder home screen so the scaffold compiles and runs. Later
// tickets (#38-#42) will replace this with the actual navigation surface.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:relaylink/alerts/allowlist.dart';
import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/channels/keys.dart';
import 'package:relaylink/screens/capability_disclosure.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Ticket #15: ensure the public channel key is registered before any
  // broadcast crypto (#03) runs. Safe to call repeatedly.
  final keyStore = await ChannelKeyStore.instance();
  await keyStore.init();
  // Ticket #36: warm the verified-orgs allowlist cache (read from disk,
  // refresh from Firestore if stale). Fire-and-forget — the app must NOT
  // block on this. Receivers fall back to the bundled
  // `assets/verified_orgs.json` allowlist from #35 if the cache is empty
  // (e.g. on a cold offline launch).
  unawaited(VerifiedOrgsCache().init());
  runApp(const RelayLinkApp());
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

  @override
  void initState() {
    super.initState();
    _checkSeen();
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
    return _DisclosureOverlayHome(
      seen: _seen!,
      capabilities: detectCapabilities(),
    );
  }
}

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
    return const RelayLinkHome();
  }
}

class RelayLinkHome extends StatelessWidget {
  const RelayLinkHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'RelayLink',
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontSize: 56,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Offline mesh messaging · End-to-end encrypted',
                style: TextStyle(
                  color: const Color(0xFF9AA4B2),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
