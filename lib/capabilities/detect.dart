// Capability detection for RelayLink (Ticket #29 / Spec §3.1).
//
// On first launch the app tells the user what *this* device can and can't
// do, in plain language, with reasons. This file is the single source of
// truth for that table — the UI just renders what `detectCapabilities()`
// returns.
//
// The 9 features are taken directly from §3.1 of SPEC.md (Capability
// disclosure). The platform branching is the only logic here: Android gets
// the full feature set; iOS gets the mesh subset plus internet (gateway
// route) and the locally-implementable features (ALERT verification,
// Evidence Vault). SMS is unavailable on iOS because Apple does not allow
// apps to send or read SMS automatically.

import 'dart:io' show Platform;

/// A single feature's availability on the current device.
///
/// `reason` is empty when [available] is `true` and non-empty when it is
/// `false`. UI surfaces should display the reason verbatim — it's written
/// to be plain-language and helpful.
class FeatureCapability {
  final bool available;
  final String reason;
  const FeatureCapability({required this.available, this.reason = ''});
}

/// The 9 feature flags from §3.1, plus the platform tag that produced them.
///
/// Constructed once at app start via [detectCapabilities] and passed around
/// as an immutable value object.
class DeviceCapabilities {
  final FeatureCapability bluetoothMeshSend;
  final FeatureCapability bluetoothMeshDiscover;
  final FeatureCapability multiHopRelay;
  final FeatureCapability smsSend;
  final FeatureCapability smsReceive;
  final FeatureCapability internet;
  final FeatureCapability alertVerification;
  final FeatureCapability vaultCapture;
  final FeatureCapability vaultSendOnConnect;

  /// 'android' | 'ios' | 'unknown'.
  final String platform;

  const DeviceCapabilities({
    required this.bluetoothMeshSend,
    required this.bluetoothMeshDiscover,
    required this.multiHopRelay,
    required this.smsSend,
    required this.smsReceive,
    required this.internet,
    required this.alertVerification,
    required this.vaultCapture,
    required this.vaultSendOnConnect,
    required this.platform,
  });

  /// Build the table for a specific platform string ('android' | 'ios').
  ///
  /// Exposed publicly so tests (and the Settings/About UI) can construct the
  /// canonical object without mocking `Platform`.
  factory DeviceCapabilities.forPlatform(String platform) {
    switch (platform) {
      case 'android':
        return const DeviceCapabilities(
          platform: 'android',
          bluetoothMeshSend: FeatureCapability(available: true),
          bluetoothMeshDiscover: FeatureCapability(available: true),
          multiHopRelay: FeatureCapability(available: true),
          smsSend: FeatureCapability(available: true),
          smsReceive: FeatureCapability(available: true),
          internet: FeatureCapability(available: true),
          alertVerification: FeatureCapability(available: true),
          vaultCapture: FeatureCapability(available: true),
          vaultSendOnConnect: FeatureCapability(available: true),
        );
      case 'ios':
        return const DeviceCapabilities(
          platform: 'ios',
          bluetoothMeshSend: FeatureCapability(available: true),
          bluetoothMeshDiscover: FeatureCapability(available: true),
          multiHopRelay: FeatureCapability(available: true),
          smsSend: FeatureCapability(
            available: false,
            reason: _iosSmsReason,
          ),
          smsReceive: FeatureCapability(
            available: false,
            reason: _iosSmsReason,
          ),
          internet: FeatureCapability(available: true),
          alertVerification: FeatureCapability(available: true),
          vaultCapture: FeatureCapability(available: true),
          vaultSendOnConnect: FeatureCapability(available: true),
        );
      default:
        // Defensive default: an "unknown" platform returns every feature
        // as unavailable with a generic reason — the UI can show this
        // rather than crashing. This is reached on desktop builds (Linux,
        // macOS, Windows) which Platform reports as something other than
        // android or ios.
        return const DeviceCapabilities(
          platform: 'unknown',
          bluetoothMeshSend: FeatureCapability(
            available: false,
            reason:
                'Not a supported platform. Bluetooth mesh requires Android or iOS.',
          ),
          bluetoothMeshDiscover: FeatureCapability(
            available: false,
            reason:
                'Not a supported platform. Bluetooth mesh requires Android or iOS.',
          ),
          multiHopRelay: FeatureCapability(
            available: false,
            reason:
                'Not a supported platform. Multi-hop relay requires Android or iOS.',
          ),
          smsSend: FeatureCapability(
            available: false,
            reason: _iosSmsReason,
          ),
          smsReceive: FeatureCapability(
            available: false,
            reason: _iosSmsReason,
          ),
          internet: FeatureCapability(
            available: false,
            reason:
                'Desktop platform: real-device radio checks are not available.',
          ),
          alertVerification: FeatureCapability(
            available: true,
            reason: '',
          ),
          vaultCapture: FeatureCapability(available: true),
          vaultSendOnConnect: FeatureCapability(available: true),
        );
    }
  }

  /// Every capability is available. Useful as a quick assertion when the
  /// caller cares only about the full-feature case.
  bool get allAvailable => <FeatureCapability>[
        bluetoothMeshSend,
        bluetoothMeshDiscover,
        multiHopRelay,
        smsSend,
        smsReceive,
        internet,
        alertVerification,
        vaultCapture,
        vaultSendOnConnect,
      ].every((c) => c.available);

  /// A human-readable, multi-line summary suitable for the first-launch
  /// capability card and the Settings/About panel.
  String toDisclosureString() {
    final lines = <String>[
      'Platform: $platform',
      '',
      ..._rows.map((row) {
        final cap = row.$2(this);
        final mark = cap.available ? '✓' : '✗';
        final suffix = cap.available ? '' : ' — ${cap.reason}';
        return '$mark ${row.$1}$suffix';
      }),
    ];
    return lines.join('\n');
  }

  /// Disclosure order + human-friendly label for each of the 9 §3.1
  /// features. Kept as a `static final` (not `const`) because we read
  /// the capability off a `DeviceCapabilities` instance at format time.
  static final List<(String, FeatureCapability Function(DeviceCapabilities))>
      _rows = [
    ('Bluetooth mesh send/receive', (c) => c.bluetoothMeshSend),
    ('Bluetooth mesh discovery', (c) => c.bluetoothMeshDiscover),
    ('Multi-hop store-and-forward relay', (c) => c.multiHopRelay),
    ('SMS send', (c) => c.smsSend),
    ('SMS receive', (c) => c.smsReceive),
    ('Internet (cloud relay)', (c) => c.internet),
    ('ALERT verification (signature check)', (c) => c.alertVerification),
    ('Evidence Vault (capture)', (c) => c.vaultCapture),
    ('Evidence Vault (send-on-connect)', (c) => c.vaultSendOnConnect),
  ];
}

/// The single source of truth for the iOS SMS-unavailable message.
///
/// Citing SPEC.md §3.1 (Capability disclosure) and STRESS-TEST.md §4.
/// Phrasing follows the spec: "Apple doesn't allow apps to send or read
/// SMS automatically."
const String _iosSmsReason =
    "Apple doesn't allow apps to send or read SMS automatically";

/// Detect the current device's capabilities. Call once at app start and
/// stash the result — the table is constant for the lifetime of the
/// process (there are no runtime toggles yet; permissions-based features
/// could become dynamic later but for v1 they are platform-fixed).
DeviceCapabilities detectCapabilities() {
  if (Platform.isAndroid) {
    return DeviceCapabilities.forPlatform('android');
  }
  if (Platform.isIOS) {
    return DeviceCapabilities.forPlatform('ios');
  }
  // Desktop (linux/macOS/windows) or anything else: fall back to the
  // "unknown" platform row so the UI can still render the table rather
  // than crashing.
  return DeviceCapabilities.forPlatform('unknown');
}
