// RelayLink — Per-feature capability gating tests (Ticket #10 cut #10).
//
// What we verify:
//   1. Each gate starts at `false` (the safe default — UI hides features
//      rather than overselling them while we wait for real radio checks).
//   2. Calling `notifier.update(true)` flips the gate and emits one
//      `CapabilityEvent` to the timeline with `gate=<this>, available=true`.
//   3. Calling `notifier.update(false, reason: ...)` flips back and emits
//      a second event carrying the reason.
//   4. The timeline's `history` getter accumulates the events so a
//      regression that drops an event fails the test.
//   5. Riverpod's provider exposes the same value the notifier sets —
//      so a `ConsumerWidget` watching the gate would rebuild correctly.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/capabilities/gates.dart';
import 'package:relaylink/capabilities/timeline.dart';

void main() {
  // Reset the timeline between tests so events do not leak.
  setUp(() => CapabilityTimeline.resetForTesting());

  group('timeline', () {
    test('starts empty after reset', () {
      CapabilityTimeline.resetForTesting();
      expect(CapabilityTimeline.instance().history, isEmpty);
    });

    test('add() appends and broadcasts on the events stream', () async {
      final timeline = CapabilityTimeline.instance();
      final received = <CapabilityEvent>[];
      final sub = timeline.events.listen(received.add);

      final ev = CapabilityEvent(
        gate: CapabilityGateKind.mesh,
        available: true,
        reason: '',
        timestamp: DateTime.now().toUtc(),
      );
      timeline.add(ev);

      // Flush microtask queue so the broadcast is delivered.
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.first, equals(ev));
      await sub.cancel();
    });

    test('history is bounded (drops oldest past 256)', () {
      final timeline = CapabilityTimeline.instance();
      for (var i = 0; i < 300; i++) {
        timeline.add(
          CapabilityEvent(
            gate: CapabilityGateKind.mesh,
            available: i.isEven,
            reason: '',
            timestamp: DateTime.now().toUtc().add(Duration(seconds: i)),
          ),
        );
      }
      expect(timeline.length, lessThanOrEqualTo(256));
      expect(timeline.length, equals(256));
    });
  });

  group('CapabilityGate — base behavior', () {
    test('starts at the constructor-supplied initial value', () {
      CapabilityTimeline.resetForTesting();
      final n = MeshAvailableNotifier();
      addTearDown(n.dispose);
      expect(n.state, isFalse);
    });

    test('update(true) flips the gate and emits one event', () async {
      CapabilityTimeline.resetForTesting();
      final n = MeshAvailableNotifier();
      addTearDown(n.dispose);
      n.update(true);
      expect(n.state, isTrue);
      final history = CapabilityTimeline.instance().history;
      expect(history, hasLength(1));
      expect(history.first.gate, CapabilityGateKind.mesh);
      expect(history.first.available, isTrue);
      expect(history.first.reason, isEmpty);
    });

    test('update(false, reason: "...") flips back and emits the reason',
        () async {
      CapabilityTimeline.resetForTesting();
      final n = MeshAvailableNotifier();
      addTearDown(n.dispose);
      n.update(true);
      n.update(false, reason: 'permission denied');
      expect(n.state, isFalse);
      final history = CapabilityTimeline.instance().history;
      expect(history, hasLength(2));
      expect(history[0].available, isTrue);
      expect(history[1].available, isFalse);
      expect(history[1].reason, equals('permission denied'));
    });

    test('no-op: setting the same value with no reason does NOT emit',
        () async {
      CapabilityTimeline.resetForTesting();
      final n = MeshAvailableNotifier();
      addTearDown(n.dispose);
      n.update(false);
      expect(CapabilityTimeline.instance().history, isEmpty);
    });
  });

  group('MeshAvailableNotifier', () {
    test('starts false; flip via provider updates Riverpod listeners',
        () async {
      CapabilityTimeline.resetForTesting();
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(meshAvailableProvider), isFalse);
      container.read(meshAvailableProvider.notifier).update(true);
      expect(container.read(meshAvailableProvider), isTrue);

      // Verify the timeline picked it up too.
      final ev = CapabilityTimeline.instance().history.single;
      expect(ev.gate, CapabilityGateKind.mesh);
      expect(ev.available, isTrue);
    });
  });

  group('SmsAvailableNotifier', () {
    test('setUnavailableIos emits the spec reason verbatim', () async {
      CapabilityTimeline.resetForTesting();
      final n = SmsAvailableNotifier();
      addTearDown(n.dispose);
      n.setUnavailableIos();
      expect(n.state, isFalse);
      final ev = CapabilityTimeline.instance().history.single;
      expect(ev.gate, CapabilityGateKind.sms);
      expect(ev.available, isFalse);
      expect(
        ev.reason,
        equals(
          "Apple doesn't allow apps to send or read SMS automatically",
        ),
      );
    });

    test('can flip true → false → true with reasons at each step', () async {
      CapabilityTimeline.resetForTesting();
      final n = SmsAvailableNotifier();
      addTearDown(n.dispose);
      n.update(true);
      n.update(false, reason: 'cellular radio off');
      n.update(true);
      final history = CapabilityTimeline.instance().history;
      expect(history, hasLength(3));
      expect(history[0].available, isTrue);
      expect(history[1].available, isFalse);
      expect(history[1].reason, equals('cellular radio off'));
      expect(history[2].available, isTrue);
    });
  });

  group('InternetAvailableNotifier', () {
    test('reacts to Wi-Fi on / off transitions', () async {
      CapabilityTimeline.resetForTesting();
      final n = InternetAvailableNotifier();
      addTearDown(n.dispose);

      expect(n.state, isFalse);
      n.update(true);
      n.update(false, reason: 'Wi-Fi disconnected');
      n.update(true);

      final history = CapabilityTimeline.instance().history;
      final avail = history.map((e) => e.available).toList();
      expect(avail, <bool>[true, false, true]);
      expect(history[1].reason, equals('Wi-Fi disconnected'));
    });
  });

  group('VaultAvailableNotifier', () {
    test('starts false; update(true) flips the gate', () async {
      CapabilityTimeline.resetForTesting();
      final n = VaultAvailableNotifier();
      addTearDown(n.dispose);
      n.update(true);
      expect(n.state, isTrue);
      final ev = CapabilityTimeline.instance().history.single;
      expect(ev.gate, CapabilityGateKind.vault);
      expect(ev.available, isTrue);
    });

    test('update(false, reason: secure storage unreachable) emits reason',
        () async {
      CapabilityTimeline.resetForTesting();
      final n = VaultAvailableNotifier();
      addTearDown(n.dispose);
      n.update(false, reason: 'secure storage unreachable');
      final ev = CapabilityTimeline.instance().history.single;
      expect(ev.reason, equals('secure storage unreachable'));
    });
  });

  group('ChannelAvailableNotifier', () {
    test('starts false; update(true) flips the gate', () async {
      CapabilityTimeline.resetForTesting();
      final n = ChannelAvailableNotifier();
      addTearDown(n.dispose);
      n.update(true);
      expect(n.state, isTrue);
      final ev = CapabilityTimeline.instance().history.single;
      expect(ev.gate, CapabilityGateKind.channel);
      expect(ev.available, isTrue);
    });
  });

  group('capabilityEventsProvider', () {
    test('subscribers receive every transition in order', () async {
      CapabilityTimeline.resetForTesting();
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Subscribe directly to the timeline stream — same source the
      // StreamProvider exposes. We avoid `container.read(...future)`
      // because StreamProvider's future never completes.
      final received = <CapabilityEvent>[];
      final sub = CapabilityTimeline.instance().events.listen(received.add);
      addTearDown(sub.cancel);

      // Flip a gate and verify the listener sees the event.
      container.read(meshAvailableProvider.notifier).update(true);
      await Future<void>.delayed(Duration.zero);

      expect(received, isNotEmpty);
      expect(received.last.gate, CapabilityGateKind.mesh);
      expect(received.last.available, isTrue);
    });
  });

  group('independence of gates', () {
    test('flipping mesh does not flip sms or others', () {
      CapabilityTimeline.resetForTesting();
      final mesh = MeshAvailableNotifier();
      final sms = SmsAvailableNotifier();
      final internet = InternetAvailableNotifier();
      final vault = VaultAvailableNotifier();
      final channel = ChannelAvailableNotifier();
      addTearDown(mesh.dispose);
      addTearDown(sms.dispose);
      addTearDown(internet.dispose);
      addTearDown(vault.dispose);
      addTearDown(channel.dispose);

      mesh.update(true);
      expect(mesh.state, isTrue);
      expect(sms.state, isFalse);
      expect(internet.state, isFalse);
      expect(vault.state, isFalse);
      expect(channel.state, isFalse);

      // Timeline should have exactly ONE event so far.
      expect(CapabilityTimeline.instance().history, hasLength(1));
    });
  });
}