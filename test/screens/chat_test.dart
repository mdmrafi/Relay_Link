// RelayLink — Ticket #39: Chat screen widget tests.
//
// These tests cover the user-visible behavior of the chat screen:
//   1. Empty state renders when the controller has no messages.
//   2. Message bubbles render the sender / body / timestamp / type label.
//   3. ALERT messages render the VERIFIED badge from #37.
//   4. The compose bar shows the type selector + text field + send button.
//   5. Tapping the send button calls the controller and renders the body.
//   6. The type selector changes the wire type used by the next send.
//   7. Different origins render different origin icons.
//   8. BROADCAST messages are encrypted with BroadcastCrypto on the way out;
//      the chat widget renders decrypted plaintext via the injected
//      MessageDecryptor. Without a decryptor, ciphertext stays opaque.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/alerts/allowlist.dart';
import 'package:relaylink/crypto/broadcast.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/screens/chat.dart';

/// Pump [child] inside a minimal MaterialApp so AppBar / Theme.of() work.
Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: child,
    ),
  );
  await tester.pump();
}

/// Pump until the chat widget's async decrypt future has resolved and the
/// bubble has rebuilt with plaintext. Used by the crypto tests where the
/// plaintext is only available after a microtask tick.
Future<void> _pumpUntilDecrypted(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  setUp(() {
    // VerifiedOrgsCache.init() reads/writes SharedPreferences; mock with
    // an empty store so cache.init() never hits a platform channel.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('ChatScreen — empty state', () {
    testWidgets('renders the empty state when no messages exist',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

      expect(find.byKey(const ValueKey<String>('chatEmptyState')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('chatMessageList')),
          findsNothing);
      expect(find.text('No messages yet'), findsOneWidget);
    });

    testWidgets('header reports zero messages', (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

      expect(find.byKey(const ValueKey<String>('chatHeaderCount')),
          findsOneWidget);
      expect(find.text('0 messages'), findsOneWidget);
    });
  });

  group('ChatScreen — message bubbles', () {
    testWidgets('renders sender, body, timestamp, and type label',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      // In-memory controller has no real decryptor; inject a fake that
      // recovers plaintext from the BroadcastEnvelope JSON the controller
      // encoded into the payload.
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      await _pump(tester, ChatScreen(controller: controller));

      // Send a message via the controller so the message ends up in the list.
      await controller.sendMessage(
        type: MessageType.chat,
        body: 'Hello world',
        senderId: 'device-A',
        senderDisplayName: 'Alice',
      );
      await tester.pump();
      // Let the async decrypt future settle so the bubble shows plaintext.
      await _pumpUntilDecrypted(tester);

      expect(find.byKey(const ValueKey<String>('chatEmptyState')),
          findsNothing);
      expect(find.byKey(const ValueKey<String>('chatMessageList')),
          findsOneWidget);

      final id = controller.messages.last.id;
      expect(find.byKey(ValueKey<String>('chatBubble::$id')), findsOneWidget);
      expect(find.byKey(ValueKey<String>('chatBubbleSender::$id')),
          findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.byKey(ValueKey<String>('chatBubbleBody::$id')),
          findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.byKey(ValueKey<String>('chatBubbleTimestamp::$id')),
          findsOneWidget);
      expect(find.byKey(ValueKey<String>('chatBubbleTypeLabel::$id')),
          findsOneWidget);
      expect(find.text('CHAT'), findsOneWidget);
    });

    testWidgets(
        'ALERT messages render the receiver-side VerifiedBadge — '
        'verified when senderId is on the allowlist',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      // In-memory controller needs a decryptor so the alert body renders.
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      // Allowlist is loaded; senderId 'org-1' is on it.
      final cache = VerifiedOrgsCache.withFetcher(
        () async => <String>['org-1'],
      );
      // Cache starts empty; init() loads from the fetcher.
      await cache.init();

      await _pump(
        tester,
        ChatScreen(controller: controller, verifiedCache: cache),
      );

      await controller.sendMessage(
        type: MessageType.alert,
        body: 'Flood warning',
        senderId: 'org-1',
        senderDisplayName: 'Rescue Co.',
      );
      await tester.pump();

      final id = controller.messages.last.id;
      expect(find.byKey(ValueKey<String>('chatBubbleAlertBadge::$id')),
          findsOneWidget);
      // Verified branch: green "Verified: <name>".
      expect(find.text('Verified: Rescue Co.'), findsOneWidget);
    });

    testWidgets(
        'ALERT messages render "Signed by" when senderId is NOT on the '
        'allowlist (receiver-side trust, never claims verification)',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      // Allowlist exists but does NOT contain the sender.
      final cache = VerifiedOrgsCache.withFetcher(
        () async => const <String>['some-other-org'],
      );
      await cache.init();

      await _pump(
        tester,
        ChatScreen(controller: controller, verifiedCache: cache),
      );

      await controller.sendMessage(
        type: MessageType.alert,
        body: 'Watch out',
        senderId: 'unknown-peer',
        senderDisplayName: 'Unknown Sender',
      );
      await tester.pump();

      final id = controller.messages.last.id;
      expect(find.byKey(ValueKey<String>('chatBubbleAlertBadge::$id')),
          findsOneWidget);
      // Receiver-side: never claim verification for unknown pubkeys.
      expect(find.text('Signed by: Unknown Sender'), findsOneWidget);
      expect(find.textContaining('Verified:'), findsNothing);
    });

    testWidgets(
        'ALERT messages without an injected cache default to "Signed by"',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      // No verifiedCache injected — must NOT claim verification.
      await _pump(tester, ChatScreen(controller: controller));

      await controller.sendMessage(
        type: MessageType.alert,
        body: 'Heads up',
        senderId: 'org-1',
        senderDisplayName: 'Rescue Co.',
      );
      await tester.pump();

      final id = controller.messages.last.id;
      expect(find.byKey(ValueKey<String>('chatBubbleAlertBadge::$id')),
          findsOneWidget);
      expect(find.text('Signed by: Rescue Co.'), findsOneWidget);
      expect(find.textContaining('Verified:'), findsNothing);
    });

    testWidgets('non-alert messages do NOT show the VERIFIED badge',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      await _pump(tester, ChatScreen(controller: controller));

      await controller.sendMessage(
        type: MessageType.chat,
        body: 'regular',
        senderId: 'me',
        senderDisplayName: 'Me',
      );
      await tester.pump();

      final id = controller.messages.last.id;
      expect(find.byKey(ValueKey<String>('chatBubbleAlertBadge::$id')),
          findsNothing);
    });

    testWidgets('falls back to senderId when display name is empty',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      await _pump(tester, ChatScreen(controller: controller));

      await controller.sendMessage(
        type: MessageType.chat,
        body: 'no name',
        senderId: 'anon-42',
        senderDisplayName: '',
      );
      await tester.pump();

      expect(find.text('anon-42'), findsOneWidget);
    });
  });

  group('ChatScreen — end-to-end crypto', () {
    testWidgets(
        'BROADCAST messages encrypt the body on the way out and the widget '
        'renders the decrypted plaintext via the injected decryptor',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      await _pump(tester, ChatScreen(controller: controller));

      await controller.sendMessage(
        type: MessageType.chat,
        body: 'secret',
        senderId: 'me',
        senderDisplayName: 'Me',
      );
      await tester.pump();
      await _pumpUntilDecrypted(tester);

      final m = controller.messages.single;
      // The on-the-wire payload is the BroadcastEnvelope JSON, NOT the
      // raw UTF-8 of the body. This is the crypto-not-wired-finding fix.
      expect(String.fromCharCodes(m.payload), isNot(equals('secret')));
      final env = BroadcastEnvelope.fromJsonBytes(m.payload);
      expect(env.channelId, 'public');
      expect(env.ciphertext, isNot(equals(utf8.encode('secret'))));
      final recovered = await crypto.decryptString(env);
      expect(recovered, 'secret');

      // The widget renders the plaintext via the decryptor.
      expect(find.text('secret'), findsOneWidget);
    });

    testWidgets(
        'without a MessageDecryptor, BROADCAST messages render as their '
        'opaque envelope (treated as text, not silently rendered as garbage)',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      // No decryptor injected.
      await _pump(tester, ChatScreen(controller: controller));

      await controller.sendMessage(
        type: MessageType.chat,
        body: 'hello',
        senderId: 'me',
        senderDisplayName: 'Me',
      );
      await tester.pump();

      // Plaintext "hello" is NOT rendered (the payload is ciphertext).
      expect(find.text('hello'), findsNothing);
      // The envelope is short enough to fit in the bubble — make sure the
      // body widget exists so the user can see something is there.
      final id = controller.messages.last.id;
      expect(find.byKey(ValueKey<String>('chatBubbleBody::$id')),
          findsOneWidget);
    });
  });

  group('ChatScreen — compose bar', () {
    testWidgets('renders the type selector, text field, and send button',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

      expect(find.byKey(const ValueKey<String>('chatComposerField')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('chatComposerSendButton')),
          findsOneWidget);

      // All five user-facing types are listed as chips.
      for (final t in ChatComposerType.values) {
        expect(find.byKey(ValueKey<String>('chatTypeChip::${t.name}')),
            findsOneWidget);
      }
    });

    testWidgets('tapping the send button delivers a message with default type',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      await _pump(tester, ChatScreen(controller: controller));

      await tester.enterText(
        find.byKey(const ValueKey<String>('chatComposerField')),
        'ping',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('chatComposerSendButton')),
      );
      // Let the async sendMessage future resolve.
      await tester.pump();
      await tester.pump();

      expect(controller.messages, hasLength(1));
      final m = controller.messages.single;
      expect(m.type, MessageType.chat);
      // The on-the-wire payload is the BroadcastEnvelope JSON; the body
      // round-trips through BroadcastCrypto + the injected decryptor.
      expect(String.fromCharCodes(m.payload), isNot(equals('ping')));
      final env = BroadcastEnvelope.fromJsonBytes(m.payload);
      expect(await crypto.decryptString(env), 'ping');
      expect(m.senderId, 'me');
      expect(m.channelId, 'public');

      // The bubble renders the plaintext via the decryptor.
      expect(find.text('ping'), findsOneWidget);
    });

    testWidgets('selecting a type changes the next send wire type',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      final crypto = BroadcastCrypto();
      controller.messageDecryptor = (msg) async {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        return crypto.decryptString(env);
      };
      await _pump(tester, ChatScreen(controller: controller));

      await tester.tap(
        find.byKey(const ValueKey<String>('chatTypeChip::sos')),
      );
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey<String>('chatComposerField')),
        'help',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('chatComposerSendButton')),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.messages.single.type, MessageType.sos);
    });

    testWidgets('empty composer does not send', (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

      await tester.tap(
        find.byKey(const ValueKey<String>('chatComposerSendButton')),
      );
      await tester.pump();

      expect(controller.messages, isEmpty);
    });

    testWidgets('whitespace-only composer does not send',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

      await tester.enterText(
        find.byKey(const ValueKey<String>('chatComposerField')),
        '   ',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('chatComposerSendButton')),
      );
      await tester.pump();

      expect(controller.messages, isEmpty);
    });

    testWidgets('header message count updates after sending',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

      expect(find.text('0 messages'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('chatComposerField')),
        'one',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('chatComposerSendButton')),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('1 message'), findsOneWidget);
    });

    testWidgets('composer TextField exposes a labelText for screen readers',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('chatComposerField')),
      );
      expect(field.decoration?.labelText, 'Message');
    });
  });

  group('ChatScreen — origin icons', () {
    testWidgets('each bubble has an origin icon widget',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

      await controller.sendMessage(
        type: MessageType.chat,
        body: 'one',
        senderId: 'A',
        senderDisplayName: 'A',
      );
      await controller.sendMessage(
        type: MessageType.chat,
        body: 'two',
        senderId: 'B',
        senderDisplayName: 'B',
      );
      await tester.pump();

      // Every bubble exposes an origin icon (the local controller only
      // emits MESH origin, but the wiring is the same for SMS / INTERNET).
      for (final id in controller.messages.map((m) => m.id)) {
        final iconFinder = find.byKey(
          ValueKey<String>('chatBubbleOriginIcon::$id'),
        );
        expect(iconFinder, findsOneWidget);
        final icon = tester.widget<Icon>(iconFinder);
        expect(icon.size, 14);
      }
    });
  });
}
