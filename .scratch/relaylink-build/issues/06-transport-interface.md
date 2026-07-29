# 06 — Transport interface (common abstraction)

**What to build:** `lib/transport/transport.dart` defining a common `Transport` interface that all channels (mesh, SMS, internet, gateway) implement: `Future<void> send(Message msg)`, `Stream<Message> get incoming`, `bool isAvailable()` (true when this device has the radio + connectivity), `String get name`. Plus a `TransportManager` that holds a list of registered transports and exposes `fanOutSend(Message)` (calls `send` on every available transport).

**Blocked by:** #01, #04

**Status:** done

- [x] `Transport` abstract class with the four members above
- [x] `TransportManager.register(Transport)`, `unregister(Transport)`, `fanOutSend(Message)` working
- [x] `fanOutSend` only sends on transports where `isAvailable()` returns true
- [x] `incoming` stream is broadcast (multiple listeners can subscribe)
- [x] A trivial `LoopbackTransport` (sends go directly to `incoming` of the same manager) for testing without radios
- [x] Tests: `LoopbackTransport` round-trips a message, `isAvailable` toggles correctly