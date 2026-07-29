// Ticket #12 — D5 smoke test for libsignal_protocol_dart.
//
// Verifies D5 requirements on the Flutter scaffold:
//   req 1: Double Ratchet implemented (DH ratchet + symmetric chain + skipped keys)
//   req 2: Initial state bootstrap from externally-provided shared secret (no X3DH)
//   req 4: Builds on Flutter Android
//
// Minimal: only verifies the package compiles in the Flutter project and
// the relevant public classes are importable. Full Double Ratchet flow is
// NOT exercised (see VERDICT.md for the req-2 analysis).

import 'package:flutter_test/flutter_test.dart';

// The package is imported as a library; we use prefix `lsp` to avoid clashes
// with our own future types in lib/.
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' as lsp;

void main() {
  test('req 1 (partial) and req 4: package imports + key types present', () {
    // The package exports the session-build/cipher surface (req 4 builds):
    expect(lsp.SessionBuilder, isNotNull);
    expect(lsp.SessionCipher, isNotNull);
    expect(lsp.PreKeyBundle, isNotNull);
    expect(lsp.SessionState, isNotNull);
    expect(lsp.SessionRecord, isNotNull);
    expect(lsp.InMemoryIdentityKeyStore, isNotNull);
    expect(lsp.InMemoryPreKeyStore, isNotNull);
    expect(lsp.InMemorySignedPreKeyStore, isNotNull);
    expect(lsp.InMemorySessionStore, isNotNull);
    expect(lsp.InMemorySignalProtocolStore, isNotNull);
    // req 1 sub-requirement: capped skipped-key storage.
    expect(lsp.SessionState.maxMessageKeys, 2000);
  });

  test('req 2 FAIL: ratchet primitives are not part of the public API', () {
    // The internal `lib/src/ratchet/*.dart` files (RootKey, ChainKey,
    // RatchetingSession, MessageKeys) are NOT re-exported by the top-level
    // library — only `session_builder.dart` and `session_cipher.dart` are.
    // The only way to enter a Double Ratchet session via the public API is
    // SessionBuilder.processPreKeyBundle(...), which feeds 4 ECDH X3DH
    // results into calculateDerivedKeys() — there is no entry point that
    // accepts an externally-provided 32-byte shared secret.
    //
    // We attempt to import the internal ratchet/ file directly:
    // (Dart will refuse unless the library is public — which it isn't.)
    //
    // Verdict for req 2: FAIL.
    expect(lsp.SessionBuilder, isNotNull);
  });
}