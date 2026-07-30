// RelayLink — Ticket #16 Channel QR encode + scan.
//
// Wire format overview (kept versioned so future ticket revisions can be
// detected and migrated):
//
//   {
//     "v": 1,
//     "id": "<channelId>",          // string, matches ChannelKeyStore key
//     "name": "<human label>",      // optional display name
//     "fp": "<hex-encoded fingerprint>",
//     "k":  "<base64 32-byte AES key>"
//   }
//
// The fingerprint is *not* a secret — it lets the joiner confirm visually
// (or in code) that the bytes they decoded match what the creator is
// displaying. The 32-byte AES key IS the secret — anyone who scans the QR
// can join the channel. Treat the QR like a printed password.
//
// `encodeChannelQR(channelId, key, {name})` returns PNG bytes ready for
// `Image.memory` / `Clipboard` / sharing. `decodeChannelPayload(rawText)`
// parses the string a scanner hands us. We intentionally split "encode
// PNG" from "decode text" so the camera path never has to round-trip
// through PNG re-decoding — `mobile_scanner` hands us the raw string and
// we parse it directly.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Wire-format version. Bump this (and add a migration shim) if the JSON
/// shape changes incompatibly.
const int kChannelInviteVersion = 1;

/// Reason a decoded payload is invalid. Exposed so screens can show
/// targeted messages ("expired invite", "wrong app", "channel id missing").
enum ChannelInviteError {
  notJson,
  wrongVersion,
  missingId,
  missingKey,
  wrongKeyLength,
  badBase64,
}

/// Parsed payload of a channel-invite QR code.
///
/// The 32-byte AES key is the actual channel key that
/// `ChannelKeyStore.addChannel(invite.channelId, invite.keyBytes)` then
/// persists. `fingerprint` is informational — printed under the QR so the
/// joiner can sanity-check what they scanned.
class ChannelInvite {
  /// Wire-format version. Always [kChannelInviteVersion] for now.
  final int version;

  /// Stable channel identifier. Used as the `ChannelKeyStore` key.
  final String channelId;

  /// Optional human-readable label for the channel (creator's choice).
  final String? name;

  /// 32-byte AES-256 key, exactly the bytes the joiner should persist.
  final Uint8List keyBytes;

  /// SHA-256 fingerprint of [keyBytes], hex-encoded.
  ///
  /// Not part of the secret — the joiner can compute this themselves from
  /// [keyBytes] and compare to what's displayed under the QR.
  final String fingerprint;

  const ChannelInvite({
    required this.version,
    required this.channelId,
    required this.keyBytes,
    required this.fingerprint,
    this.name,
  });

  /// Re-emit the invite as the canonical wire JSON string. Used when
  /// sharing via clipboard / deep-link rather than QR.
  String toJsonString() => jsonEncode(_toJson());

  /// Parse a scanned (or copy-pasted) wire-format string into a
  /// [ChannelInvite]. Throws [FormatException] if the payload is malformed.
  ///
  /// We deliberately use [FormatException] (a stdlib type) over a custom
  /// error class so callers can `try { decode } on FormatException catch`
  /// without importing a RelayLink-specific symbol.
  static ChannelInvite fromJsonString(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('Channel invite is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Channel invite must be a JSON object at the top level',
      );
    }

    final v = decoded['v'];
    if (v is! int) {
      throw const FormatException('Channel invite missing version field');
    }
    if (v != kChannelInviteVersion) {
      throw FormatException(
        'Unsupported channel invite version $v '
        '(expected $kChannelInviteVersion)',
      );
    }

    final id = decoded['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Channel invite missing channel id');
    }
    if (id.contains('\n') || id.contains('\r')) {
      throw const FormatException(
        'Channel invite id must not contain newlines',
      );
    }

    final keyB64 = decoded['k'];
    if (keyB64 is! String || keyB64.isEmpty) {
      throw const FormatException('Channel invite missing key');
    }

    final Uint8List keyBytes;
    try {
      keyBytes = Uint8List.fromList(base64.decode(keyB64));
    } on FormatException catch (e) {
      throw FormatException('Channel invite key is not valid base64: ${e.message}');
    }
    if (keyBytes.length != 32) {
      throw FormatException(
        'Channel invite key must be 32 bytes, got ${keyBytes.length}',
      );
    }

    final nameRaw = decoded['name'];
    final name = (nameRaw is String && nameRaw.isNotEmpty) ? nameRaw : null;

    return ChannelInvite(
      version: v,
      channelId: id,
      keyBytes: keyBytes,
      fingerprint: keyFingerprint(keyBytes),
      name: name,
    );
  }

  /// Build a [ChannelInvite] from the same arguments as
  /// [encodeChannelQR]. Convenience helper so callers don't have to
  /// compute the fingerprint themselves.
  factory ChannelInvite.build({
    required String channelId,
    required List<int> keyBytes,
    String? name,
  }) {
    if (channelId.isEmpty) {
      throw ArgumentError.value(channelId, 'channelId', 'must be non-empty');
    }
    if (keyBytes.length != 32) {
      throw ArgumentError.value(
        keyBytes,
        'keyBytes',
        'AES-256 requires a 32-byte key, got ${keyBytes.length}',
      );
    }
    final bytes = keyBytes is Uint8List
        ? keyBytes
        : Uint8List.fromList(keyBytes);
    return ChannelInvite(
      version: kChannelInviteVersion,
      channelId: channelId,
      keyBytes: bytes,
      fingerprint: keyFingerprint(bytes),
      name: name,
    );
  }

  Map<String, dynamic> _toJson() => <String, dynamic>{
        'v': version,
        'id': channelId,
        if (name != null) 'name': name,
        'fp': fingerprint,
        'k': base64.encode(keyBytes),
      };

  @override
  String toString() =>
      'ChannelInvite(v=$version, id=$channelId, name=$name, '
      'fingerprint=$fingerprint)';
}

/// SHA-256 of [keyBytes], rendered as lowercase hex. Used both for the
/// `fp` field on the wire and for the human-visible fingerprint string
/// the channel creator shows under their QR so the joiner can visually
/// confirm the bytes match.
///
/// This is the same scheme used by SSH/age-style "fingerprint" lines — a
/// truncated, human-typeable hash that uniquely identifies the key
/// without exposing it.
String keyFingerprint(List<int> keyBytes) {
  final digest = sha256.convert(keyBytes);
  return digest.toString();
}

// ---------------------------------------------------------------------------
// Encode: PNG bytes
// ---------------------------------------------------------------------------

/// Default side-length of the rendered QR PNG, in pixels (logical size —
/// the painter maps to device pixels at paint time).
const double kDefaultQrImageSize = 320.0;

/// Encode [channelId] + [key] as a wire-format string and render it as a
/// QR code, returning the PNG bytes.
///
/// The returned [Uint8List] is suitable for `Image.memory(...)`, sharing
/// via `Share`/`Clipboard`, or persisting to disk.
///
/// [name] is optional display metadata embedded in the payload — both
/// creator and joiner can surface it to make the channel identifiable.
Future<Uint8List> encodeChannelQR(
  String channelId,
  List<int> key, {
  String? name,
  double size = kDefaultQrImageSize,
}) async {
  final invite = ChannelInvite.build(
    channelId: channelId,
    keyBytes: key,
    name: name,
  );
  final payload = invite.toJsonString();
  final qrCode = QrCode.fromData(
    data: payload,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final painter = QrPainter.withQr(
    qr: qrCode,
    gapless: true,
    eyeStyle: const QrEyeStyle(
      eyeShape: QrEyeShape.square,
      color: Color(0xFF000000),
    ),
    dataModuleStyle: const QrDataModuleStyle(
      dataModuleShape: QrDataModuleShape.square,
      color: Color(0xFF000000),
    ),
  );
  // `toImageData` returns a `Future<ByteData?>` — null only on framework
  // error (e.g. disposed binding in tests). We surface that as an
  // explicit error rather than a silent null.
  final imageData = await painter.toImageData(size, format: ui.ImageByteFormat.png);
  if (imageData == null) {
    throw StateError('Failed to render QR PNG (painter returned null)');
  }
  return imageData.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Decode: scanned / pasted text → ChannelInvite
// ---------------------------------------------------------------------------

/// Parse the raw text a QR scanner hands us into a [ChannelInvite].
///
/// Throws [FormatException] with a human-readable reason on failure —
/// callers (typically a "Scan to join" screen) should catch and surface
/// it as a user-facing error.
///
/// The scanner does NOT need to be `mobile_scanner` — any source that
/// yields the raw QR string works (clipboard paste, deep link, file
/// drag-and-drop, etc.).
ChannelInvite decodeChannelPayload(String rawText) =>
    ChannelInvite.fromJsonString(rawText);

// ===========================================================================
// UI widgets — kept inside `channels/qr.dart` because #16 does not add a
// dedicated screen file (per ticket scope). A future ticket can promote
// these to `lib/screens/channels/qr_show.dart` / `qr_scan.dart` once the
// app navigation surface is finalized (#41).
// ===========================================================================

/// Pluggable builder for the camera controller — used by
/// [ChannelScannerWidget] so widget tests can inject a stub without
/// requiring real camera hardware.
typedef CameraControllerBuilder = Future<MobileScannerController>
    Function();

/// Builder that hands back a stock [MobileScannerController] bound to
/// QR codes only. The default production builder.
Future<MobileScannerController> _defaultCameraControllerBuilder() async {
  return MobileScannerController(
    detectionSpeed: DetectionSpeed.unrestricted,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
  );
}

/// In-app widget that displays a freshly-generated channel invite as a
/// scannable QR plus the channel id, name, and key fingerprint.
///
/// The joiner reads the fingerprint off their own screen after scanning
/// and visually compares it to the bytes they decoded. Equal
/// fingerprints ⇒ same bytes ⇒ same key ⇒ trust the channel.
///
/// Sized to fit comfortably on a phone screen (~280 px). Callers can
/// wrap / size freely.
class ChannelInviteQrView extends StatefulWidget {
  const ChannelInviteQrView({
    super.key,
    required this.channelId,
    required this.channelKey,
    this.name,
    this.size = kDefaultQrImageSize,
    this.showFingerprint = true,
  });

  final String channelId;
  final List<int> channelKey;
  final String? name;
  final double size;
  final bool showFingerprint;

  @override
  State<ChannelInviteQrView> createState() => _ChannelInviteQrViewState();
}

class _ChannelInviteQrViewState extends State<ChannelInviteQrView> {
  late Future<Uint8List> _pngFuture;

  @override
  void initState() {
    super.initState();
    _pngFuture = encodeChannelQR(
      widget.channelId,
      widget.channelKey,
      name: widget.name,
      size: widget.size,
    );
  }

  @override
  void didUpdateWidget(covariant ChannelInviteQrView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-encode if any input changes (id/key/name/size) — the QR is a
    // pure function of these, no caching layer needed.
    if (oldWidget.channelId != widget.channelId ||
        oldWidget.channelKey != widget.channelKey ||
        oldWidget.name != widget.name ||
        oldWidget.size != widget.size) {
      _pngFuture = encodeChannelQR(
        widget.channelId,
        widget.channelKey,
        name: widget.name,
        size: widget.size,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fingerprint = keyFingerprint(widget.channelKey);
    final formattedFp = _formatFingerprint(fingerprint);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (widget.name != null && widget.name!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              widget.name!,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
        FutureBuilder<Uint8List>(
          future: _pngFuture,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return SizedBox(
                width: widget.size,
                height: widget.size,
                child: const Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError || snap.data == null) {
              return SizedBox(
                width: widget.size,
                height: widget.size,
                child: const Center(child: Icon(Icons.error_outline)),
              );
            }
            return Image.memory(
              Uint8List.fromList(snap.data!),
              width: widget.size,
              height: widget.size,
              gaplessPlayback: true,
              filterQuality: FilterQuality.none,
            );
          },
        ),
        const SizedBox(height: 12),
        SelectableText(
          'Channel: ${widget.channelId}',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        if (widget.showFingerprint) ...<Widget>[
          const SizedBox(height: 4),
          SelectableText(
            'Fingerprint:\n$formattedFp',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  /// Format a SHA-256 hex digest as `aaaa aaaa aaaa ...` (groups of 4).
  ///
  /// Pure presentation; identical bytes produce identical strings so the
  /// joiner can easily compare. We do this in Dart rather than at the
  /// `keyFingerprint` layer so the canonical form is always lowercase
  /// hex (machine-comparable), while the human display has whitespace.
  String _formatFingerprint(String hex) {
    if (hex.length != 64) return hex;
    final buf = StringBuffer();
    for (var i = 0; i < hex.length; i += 4) {
      if (i > 0) buf.write(' ');
      buf.write(hex.substring(i, i + 4));
    }
    return buf.toString();
  }
}

/// Scanner that watches the camera stream and calls [onChannelInvite]
/// exactly once per successful decode. Renders an error placeholder
/// when camera permission is denied or the platform has no camera.
///
/// The camera controller is built lazily on first build via
/// [cameraControllerBuilder] so tests can inject a fake that
/// pre-populates one or more detections without touching real hardware
/// — see `test/channels/qr_test.dart`.
///
/// We accept the raw [rawValue] from the scanner rather than trying to
/// re-encode/re-decode the PNG. `mobile_scanner` already does the
/// heavy lifting on its native side; this widget is just glue.
class ChannelScannerWidget extends StatefulWidget {
  const ChannelScannerWidget({
    super.key,
    required this.onChannelInvite,
    this.cameraControllerBuilder = _defaultCameraControllerBuilder,
    this.permissionDeniedMessage = const Text(
      'Camera permission required to scan a channel invite. '
      'Please enable camera access in Settings.',
    ),
  });

  /// Invoked on a successful decode. Decode failures are silently
  /// dropped (the scanner fires continuously on whatever it sees, so we
  /// only surface confirmed invites).
  final void Function(ChannelInvite invite) onChannelInvite;

  /// Builder for the underlying [MobileScannerController]. Override in
  /// tests to swap in a controller pre-populated with detections.
  final CameraControllerBuilder cameraControllerBuilder;

  /// Message rendered when the OS denies camera access.
  final Widget permissionDeniedMessage;

  @override
  State<ChannelScannerWidget> createState() => ChannelScannerWidgetState();
}

class ChannelScannerWidgetState extends State<ChannelScannerWidget> {
  MobileScannerController? _controller;
  bool _permissionDenied = false;
  Object? _error;
  bool _hasFired = false;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _initFuture = _initialize();
  }

  Future<void> _initialize() async {
    try {
      final c = await widget.cameraControllerBuilder();
      _controller = c;
    } on MobileScannerException catch (e) {
      if (e.errorCode == MobileScannerErrorCode.permissionDenied) {
        setState(() => _permissionDenied = true);
        return;
      }
      setState(() => _error = e);
      return;
    } catch (e) {
      setState(() => _error = e);
      return;
    }
    // Note: we deliberately do NOT call `_controller.start()` here.
    // The embedded `MobileScanner` widget (mounted below) handles
    // attaching the controller to the native preview surface; calling
    // it twice confuses the platform channel and triggers the
    // `_isAttachedCompleter` timeout in headless tests.
    //
    // iOS info.plist + Android CAMERA permission are required for the
    // platform side; permission state is surfaced via a dedicated
    // permission-prompt flow (#30+) rather than this widget.
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Headless-injection hook for widget tests. Feeds a "scanned" string
  /// through the same decode path the live scanner would, without
  /// spinning up the camera.
  void testHandleDetection(String rawValue) {
    _handleDetection(rawValue);
  }

  void _handleDetection(String rawValue) {
    if (_hasFired) return;
    try {
      final invite = decodeChannelPayload(rawValue);
      _hasFired = true;
      widget.onChannelInvite(invite);
    } on FormatException {
      // Garbage payload — ignore. The next frame will produce another
      // detection; only the *first* valid invite stops the camera.
    }
  }

  void _onBarcode(BarcodeCapture capture) {
    if (_hasFired) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null || raw.isEmpty) continue;
      _handleDetection(raw);
      if (_hasFired) break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snap) {
        if (_permissionDenied) {
          return _PermissionDeniedView(message: widget.permissionDeniedMessage);
        }
        if (_error != null) {
          return _ErrorView(error: _error!);
        }
        if (snap.connectionState != ConnectionState.done ||
            _controller == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Stack(
          children: <Widget>[
            MobileScanner(
              controller: _controller!,
              onDetect: _onBarcode,
              errorBuilder: (context, error) {
                return _ErrorView(error: error);
              },
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: _ScanInstructions(),
            ),
          ],
        );
      },
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView({required this.message});
  final Widget message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.no_photography, size: 48),
            const SizedBox(height: 12),
            DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
              child: message,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(
              'Camera error: $error',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanInstructions extends StatelessWidget {
  const _ScanInstructions();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'Point the camera at a RelayLink channel QR',
          style: TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
