// RelayLink — capability re-detection on lifecycle changes.
//
// Ticket cutrev-capab-reobserve: re-run `detectCapabilities()` whenever the
// app foregrounds, resumes from background, or the framework fires
// `didChangeAppLifecycleState`. This lets the home screen (#38) auto-
// refresh its capability disclosure when hardware state changes (e.g. the
// user grants a new permission after toggling a setting while the app was
// in the background).
//
// The observer is a `WidgetsBindingObserver` so the framework delivers
// lifecycle events through the normal `WidgetsBinding` plumbing (see
// `WidgetsBinding.handleAppLifecycleStateChanged`). It exposes a broadcast
// `Stream<DeviceCapabilities>` for consumers that want to react to changes;
// the most recently detected value is always available synchronously via
// [current].

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:relaylink/capabilities/detect.dart';

/// Watches app lifecycle events and re-runs capability detection on every
/// foreground / resume / `didChangeAppLifecycleState` tick.
///
/// Subscribers receive capabilities via [stream] for every detection that
/// happens after they subscribe. The latest value is also available
/// synchronously via [current] — new subscribers should read it for the
/// initial state.
class CapabilityObserver with WidgetsBindingObserver {
  CapabilityObserver({DeviceCapabilities Function()? detector})
      : _detector = detector ?? detectCapabilities {
    _current = _detector();
    WidgetsBinding.instance.addObserver(this);
  }

  final DeviceCapabilities Function() _detector;
  final StreamController<DeviceCapabilities> _controller =
      StreamController<DeviceCapabilities>.broadcast();
  late DeviceCapabilities _current;

  /// Latest detected capabilities.
  DeviceCapabilities get current => _current;

  /// Broadcast stream of capability changes. New subscribers receive
  /// every detection that happens after they subscribe; for the value
  /// at subscription time, read [current].
  Stream<DeviceCapabilities> get stream => _controller.stream;

  /// Re-runs detection and emits the result to all subscribers.
  void _redetect() {
    _current = _detector();
    if (!_controller.isClosed) {
      _controller.add(_current);
    }
  }

  /// `WidgetsBindingObserver` hook. Re-runs detection on every state the
  /// framework reports, per the ticket's explicit requirement that
  /// re-detection fire on `didChangeAppLifecycleState`.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _redetect();
  }

  /// Unregisters from `WidgetsBinding` and closes the stream. Safe to
  /// call multiple times.
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}