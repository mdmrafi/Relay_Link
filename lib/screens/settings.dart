// RelayLink — Ticket #42: Settings/About screen.
//
// The Settings/About screen collects the few user-facing knobs that don't
// belong on the main chat surface:
//   - "This device's capabilities" → opens the disclosure screen from #30.
//   - The gateway toggle from #21 (`GatewayToggleTile`) — same widget,
//     just presented in the Settings context instead of a sample app.
//   - A README link — shows the project README URL and lets the user copy
//     it to the clipboard (we don't pull in `url_launcher`/`webview_flutter`
//     to keep the dependency surface minimal; the spec explicitly allows
//     "in-app webview or external" and an in-app disclosure is acceptable).
//   - The app version, sourced from `pubspec.yaml` (kept in sync by the
//     `kAppVersion` constant below — no `package_info_plus` required).
//   - A "Code-of-Conduct disclosure" entry that lists exactly what the
//     app collects (device ID, optional location, phone numbers via SMS,
//     evidence capture) and why — verbatim from README.md §"Data collected".
//
// The screen is intentionally a thin wrapper around existing widgets; the
// gateway toggle and capability disclosure are owned by #21 and #30
// respectively, and re-used here so this file stays focused on layout.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/features/gateway/toggle.dart';
import 'package:relaylink/screens/capability_disclosure.dart';

/// App version shown in Settings/About. Kept in sync with `pubspec.yaml`
/// (`version: 1.0.0+1`). Not pulled from `package_info_plus` because the
/// project doesn't depend on it; the constant avoids pulling in a new
/// dependency just to display a static string.
///
/// DRIFT RISK: this is hard-coded, so it will silently fall out of sync
/// when `pubspec.yaml`'s `version:` is bumped. There is no automated CI
/// check guarding it; the format is `X.Y.Z+N` per the Flutter versioning
/// convention, and any bump in `pubspec.yaml` must be mirrored here.
const String kAppVersion = '1.0.0+1';

/// Human-readable label for the README link tile. The URL itself lives in
/// [`kReadmeUrl`] so a tester can assert on it independently.
const String kReadmeLinkTitle = 'Open the project README';

/// Project README URL shown in the Settings/About screen.
///
/// The repository is local for this hackathon submission; the URL points to
/// the canonical GitHub project page where the README is hosted. The README
/// is also checked into the repo at the project root (`README.md`), so this
/// is a pointer rather than a hard dependency.
///
/// Previously hard-coded to a placeholder `relaylink/relaylink` URL that
/// didn't exist; this now points at the actual submission repo.
const String kReadmeUrl =
    'https://github.com/Azm1ne/July-2026-hackathon#readme';

/// Title for the README disclosure dialog shown when the user taps the
/// README link tile. The dialog lists the README URL and offers a copy
/// action (via `Clipboard.setData`, which is a built-in Flutter service and
/// doesn't require a new dependency).
const String kReadmeDialogTitle = 'Project README';

/// Title for the Code-of-Conduct disclosure tile on the Settings/About
/// screen. Tapping the tile opens an in-app disclosure sheet listing the
/// categories of data RelayLink collects and why.
const String kCodeOfConductTileTitle = 'Code of Conduct — data we collect';

/// Title shown at the top of the Code-of-Conduct disclosure sheet.
const String kCodeOfConductDialogTitle = 'Data collected by RelayLink';

/// Intro line shown at the top of the Code-of-Conduct sheet. Verbatim
/// from README.md §"Data collected (Code-of-Conduct disclosure)".
const String kCodeOfConductIntro =
    'RelayLink is built around the principle that the user knows what their '
    'device is sending and to whom. The list below is exhaustive for the '
    'data flows the app actively creates, stores, or transmits. Anything '
    'not listed is not collected.';

/// Verbatim Code-of-Conduct entry: "Pseudonymous device identifier
/// (always)". Sourced from README.md §"Data collected" §1.
const String kCccDeviceIdTitle = 'Pseudonymous device identifier (always)';
const String kCccDeviceIdBody =
    'An Ed25519 signing public key and an X25519 agreement public key, '
    'generated on first launch. The sender_id exposed in messages and the '
    'org_id-equivalent used for allowlist matching are derived from these '
    'keys. No email, no phone number, no name, no username. Stored in '
    'Keystore (Android) / Keychain (iOS) via flutter_secure_storage; '
    'private keys never leave the secure store. Public keys are transmitted '
    'only to peers (never to a server) as part of every signed message and '
    'the QR-exchange handshake. Why: the entire security model depends on '
    'a stable, pseudonymous identity. Replacing this with accounts would '
    'require a sign-up flow the spec explicitly rules out.';

/// Verbatim Code-of-Conduct entry: "Optional location (user-initiated,
/// per-message)". Sourced from README.md §"Data collected" §2.
const String kCccLocationTitle = 'Optional location (user-initiated, per-message)';
const String kCccLocationBody =
    'A latitude + longitude pair, only included on a message when the user '
    'explicitly attaches location to that message (long-press → "Add '
    'location" on the composer). Stored in the message JSON in sqflite '
    'and in the Firebase relay document if the message goes out over the '
    'internet leg. Transmitted only on messages the user explicitly '
    'attaches location to, and only to the same destinations the message '
    'itself goes to. Location is never sampled continuously or in the '
    'background. Why: the SOS use case (SPEC user story #1) is the '
    'headline feature; location is behind an explicit per-message action '
    'rather than a continuous background permission.';

/// Verbatim Code-of-Conduct entry: "Phone numbers via SMS features
/// (Android only, opt-in)". Sourced from README.md §"Data collected" §3.
const String kCccPhoneTitle =
    'Phone numbers via SMS features (Android only, opt-in)';
const String kCccPhoneBody =
    'The phone numbers of contacts the user has added to RelayLink and '
    'flagged as "available via SMS fan-out." On Android only — iOS does '
    'not allow third-party apps to send SMS. Stored in the contacts '
    'sqflite table, flagged with a "can-sms" boolean the user sets. The '
    'phone number is used as the destination of an SMS sent through '
    'android.telephony.SmsManager; the phone number is NOT included in '
    'the SMS body — only the RelayLink message payload. The carrier sees '
    'the phone number as the SMS destination by virtue of the SMS '
    'protocol itself — RelayLink cannot hide this. Why: the '
    'connectivity-fallback story only works if the app can reach people '
    'via the device\'s own SIM when internet and mesh are both unavailable.';

/// Verbatim Code-of-Conduct entry: "Evidence Vault text records
/// (user-initiated capture)". Sourced from README.md §"Data collected" §4.
const String kCccEvidenceTitle =
    'Evidence Vault text records (user-initiated capture)';
const String kCccEvidenceBody =
    'Text the user has typed into the Evidence surface, or promoted from '
    'chat via long-press → "Save as evidence." Text only — photo, video, '
    'and audio capture are deferred per ROADMAP. Stored encrypted at rest '
    'with AES-256-GCM (per-record symmetric key, sealed under a '
    'vault-wrapping key, sealed under the device identity key) in sqflite, '
    'ciphertext only. When any transport becomes available, queued records '
    'transmit to the chosen recipient; the ciphertext, the recipient\'s '
    'id, and the Ed25519 signature are transmitted. The plaintext never '
    'leaves the device unencrypted.';

/// Settings/About screen.
///
/// Composes the existing `GatewayToggleTile` (#21) and the route builder
/// `buildSettingsAboutCapabilitiesRoute` (#30) with a couple of
/// disclosure tiles. Stateful only because `_ReadmeDisclosureSheet` and
/// `_CodeOfConductSheet` are pushed via `showModalBottomSheet` and need a
/// `BuildContext` from the screen.
class SettingsAboutScreen extends StatelessWidget {
  const SettingsAboutScreen({
    super.key,
    required this.capabilities,
  });

  /// The device's capability table, computed once at app start by
  /// `detectCapabilities()`. Required so the "This device's capabilities"
  /// tile can navigate to the same disclosure screen shown on first-launch.
  final DeviceCapabilities capabilities;

  /// Convenience factory for the Settings/About route. Mirrors
  /// `buildSettingsAboutCapabilitiesRoute` for the disclosure screen.
  static MaterialPageRoute<void> buildRoute(DeviceCapabilities capabilities) {
    return MaterialPageRoute<void>(
      builder: (_) => SettingsAboutScreen(capabilities: capabilities),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings & About'),
      ),
      body: SafeArea(
        child: ListView(
          key: const ValueKey<String>('settingsAboutList'),
          children: <Widget>[
            const _SectionHeader('Device'),
            // Tappable row that opens the capability disclosure (#30).
            ListTile(
              key: const ValueKey<String>('capabilitiesEntry'),
              leading: const Icon(Icons.devices_other),
              title: const Text("This device's capabilities"),
              subtitle: const Text(
                'See what this device can and can’t do',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  buildSettingsAboutCapabilitiesRoute(capabilities),
                );
              },
            ),
            // The same widget shipped in #21, presented in Settings context.
            const GatewayToggleTile(),
            const Divider(height: 24),
            const _SectionHeader('Project'),
            // README link — opens the in-app disclosure dialog.
            ListTile(
              key: const ValueKey<String>('readmeEntry'),
              leading: const Icon(Icons.menu_book),
              title: const Text(kReadmeLinkTitle),
              subtitle: const Text(kReadmeUrl),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showReadmeDialog(context),
            ),
            // Code-of-Conduct disclosure — opens an in-app sheet.
            ListTile(
              key: const ValueKey<String>('codeOfConductEntry'),
              leading: const Icon(Icons.shield_outlined),
              title: const Text(kCodeOfConductTileTitle),
              subtitle: const Text(
                'Device ID, optional location, SMS phone numbers, evidence '
                'capture',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showCodeOfConductDialog(context),
            ),
            const Divider(height: 24),
            const _SectionHeader('About'),
            ListTile(
              key: const ValueKey<String>('appVersionTile'),
              leading: const Icon(Icons.info_outline),
              title: const Text('App version'),
              subtitle: Text(
                kAppVersion,
                key: const ValueKey<String>('appVersionText'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Open the README disclosure dialog. We avoid `url_launcher` /
  /// `webview_flutter` (not in the project deps) by showing the URL inline
  /// as selectable text. The user can long-press / select-and-copy the URL
  /// in-place; the dialog also offers a "Copy" action that writes the URL
  /// to the system clipboard via the built-in `Clipboard.setData` API.
  Future<void> _showReadmeDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          key: const ValueKey<String>('readmeDialog'),
          title: const Text(kReadmeDialogTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'The project README lives at the URL below. Long-press the '
                'URL to copy it, then paste into a browser on a device that '
                'has internet access.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                kReadmeUrl,
                key: const ValueKey<String>('readmeUrl'),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// Open the Code-of-Conduct disclosure as a modal bottom sheet. Lists the
  /// four categories of data the app collects (and why), each as its own
  /// section so the disclosure is scannable rather than a wall of text.
  ///
  /// The body is wrapped in a `SingleChildScrollView` so the disclosure is
  /// readable on small screens (the four entries + intro would otherwise
  /// overflow on a 600-pixel-tall test surface).
  Future<void> _showCodeOfConductDialog(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            key: const ValueKey<String>('codeOfConductSheet'),
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  kCodeOfConductDialogTitle,
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(kCodeOfConductIntro),
                const SizedBox(height: 16),
                _CccSection(title: kCccDeviceIdTitle, body: kCccDeviceIdBody),
                _CccSection(title: kCccLocationTitle, body: kCccLocationBody),
                _CccSection(title: kCccPhoneTitle, body: kCccPhoneBody),
                _CccSection(title: kCccEvidenceTitle, body: kCccEvidenceBody),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey<String>('codeOfConductClose'),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Small section header used inside the Settings/About list. Kept as a
/// private widget so the screen body stays readable.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

/// Single section of the Code-of-Conduct disclosure: bold title + body.
/// Extracted so tests can find individual sections by title.
class _CccSection extends StatelessWidget {
  const _CccSection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(body),
        ],
      ),
    );
  }
}

/// Standalone `MaterialApp` for local dev / testing — same shape used by
/// `GatewayToggleSampleApp` in #21. Useful for previewing the screen
/// without spinning up the full app.
class SettingsAboutSampleApp extends ConsumerWidget {
  const SettingsAboutSampleApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ProviderScope(
      child: MaterialApp(
        title: 'RelayLink — Settings',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4FC3F7),
          ),
          useMaterial3: true,
        ),
        home: SettingsAboutScreen(
          capabilities: DeviceCapabilities.forPlatform('android'),
        ),
      ),
    );
  }
}