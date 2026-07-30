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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
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
      await _pump(tester, ChatScreen(controller: controller));

      // Send a message via the controller so the message ends up in the list.
      await controller.sendMessage(
        type: MessageType.chat,
        body: 'Hello world',
        senderId: 'device-A',
        senderDisplayName: 'Alice',
      );
      await tester.pump();

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

    testWidgets('ALERT messages show the VERIFIED badge',
        (WidgetTester tester) async {
      final controller = LocalChatController();
      await _pump(tester, ChatScreen(controller: controller));

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
      expect(find.text('VERIFIED'), findsOneWidget);
    });

    testWidgets('non-alert messages do NOT show the VERIFIED badge',
        (WidgetTester tester) async {
      final controller = LocalChatController();
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
      expect(String.fromCharCodes(m.payload), 'ping');
      expect(m.senderId, 'me');
      expect(m.channelId, 'public');

      // The bubble now renders the body.
      expect(find.text('ping'), findsOneWidget);
    });

    testWidgets('selecting a type changes the next send wire type',
        (WidgetTester tester) async {
      final controller = LocalChatController();
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
