// RelayLink — Ticket #40: Contacts screen widget tests.
//
// Covers the user-visible behavior of `lib/screens/contacts.dart` without
// touching the camera or sqflite. Tests use an in-memory repository so the
// widget tree is fully deterministic.
//
// What's covered:
//   1. Empty state renders the "No contacts yet" placeholder.
//   2. The list shows display name + derived short id for each row.
//   3. Phone icon is shown only when `hasPhone` is true.
//   4. Tap → opens a QR dialog containing a QrImageView.
//   5. Long-press → opens the actions bottom sheet.
//   6. Edit dialog updates the row in the repository.
//   7. Copy key writes to the clipboard (no camera needed).
//   8. Remove flow asks for confirmation and then drops the row.
//   9. "Show my QR" dialog renders a QrImageView with the local label.
//  10. Add-contact button invokes the optional callback.
//  11. `deriveContactShortId` is stable and predictable.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/contacts/contact.dart';
import 'package:relaylink/screens/contacts.dart';

void main() {
  /// Build a deterministic seeded repo for each test.
  List<Contact> seed() => <Contact>[
        const Contact(
          id: 'abcdef0123456789abcdef0123456789',
          displayName: 'Alice',
          publicKey: 'abcdef0123456789abcdef0123456789',
          phoneNumber: '+15555550101',
        ),
        const Contact(
          id: 'fedcba9876543210fedcba9876543210',
          displayName: 'Bob',
          publicKey: 'fedcba9876543210fedcba9876543210',
          phoneNumber: null,
        ),
      ];

  /// Pump the contacts page with the supplied repository. Optional
  /// [onAddContactPressed] is wired to the "Add contact" button.
  Future<void> pumpPage(
    WidgetTester tester, {
    required ContactsRepository repo,
    String myDeviceIdentityLabel = '0123456789abcdef',
    VoidCallback? onAddContactPressed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          repository: repo,
          myDeviceIdentityLabel: myDeviceIdentityLabel,
          onAddContactPressed: onAddContactPressed,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('deriveContactShortId', () {
    test('returns empty string for empty input', () {
      expect(deriveContactShortId(''), '');
    });

    test('returns the full string when shorter than 8', () {
      expect(deriveContactShortId('abcd'), 'abcd');
    });

    test('takes the first 8 hex chars of a long id', () {
      expect(
        deriveContactShortId('abcdef0123456789abcdef0123456789'),
        'abcdef01',
      );
    });

    test('strips non-hex characters before slicing', () {
      expect(deriveContactShortId('aa-bb-cc-dd-ee-ff-00-11'), 'aabbccdd');
    });
  });

  group('InMemoryContactsRepository', () {
    test('list returns the seeded contacts', () async {
      final repo = InMemoryContactsRepository(seed());
      final result = await repo.list();
      expect(result, hasLength(2));
      expect(result.first.displayName, 'Alice');
    });

    test('updateDetails changes display name and phone', () async {
      final repo = InMemoryContactsRepository(seed());
      final updated = await repo.updateDetails(
        id: 'abcdef0123456789abcdef0123456789',
        displayName: 'Alice 2',
        phoneNumber: '+15555550999',
      );
      expect(updated, isNotNull);
      expect(updated!.displayName, 'Alice 2');
      expect(updated.phoneNumber, '+15555550999');
      final listed = await repo.list();
      final alice = listed.firstWhere((c) => c.id == updated.id);
      expect(alice.displayName, 'Alice 2');
      expect(alice.phoneNumber, '+15555550999');
    });

    test('updateDetails on unknown id returns null', () async {
      final repo = InMemoryContactsRepository(seed());
      final result = await repo.updateDetails(
        id: 'unknown',
        displayName: 'x',
      );
      expect(result, isNull);
    });

    test('remove returns true for a present id and false for a missing one',
        () async {
      final repo = InMemoryContactsRepository(seed());
      expect(await repo.remove('abcdef0123456789abcdef0123456789'), isTrue);
      expect((await repo.list()), hasLength(1));
      expect(await repo.remove('nope'), isFalse);
    });
  });

  group('ContactsPage — empty state', () {
    testWidgets('renders the empty placeholder and add button',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(<Contact>[]);
      var addedTaps = 0;
      await pumpPage(
        tester,
        repo: repo,
        onAddContactPressed: () => addedTaps++,
      );

      expect(find.text('No contacts yet'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('contactsEmptySubtitle')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('contactsEmptyAddButton')),
          findsOneWidget);

      await tester.tap(find.byKey(
          const ValueKey<String>('contactsEmptyAddButton')));
      await tester.pumpAndSettle();
      expect(addedTaps, 1);
    });

    testWidgets('does not render the list when empty',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(<Contact>[]);
      await pumpPage(tester, repo: repo);
      expect(find.byKey(const ValueKey<String>('contactsList')),
          findsNothing);
    });
  });

  group('ContactsPage — list rendering', () {
    testWidgets('renders one row per contact with derived short id',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(tester, repo: repo);

      expect(find.byKey(const ValueKey<String>('contactsList')),
          findsOneWidget);

      // Alice row: id starts with 'abcdef01'.
      expect(
        find.byKey(const ValueKey<String>(
            'contactRow::abcdef0123456789abcdef0123456789')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>(
            'contactRowTitle::abcdef0123456789abcdef0123456789')),
        findsOneWidget,
      );
      expect(find.text('Alice'), findsOneWidget);
      // Subtitle text includes the short id "abcdef01…".
      expect(find.textContaining('abcdef01'), findsWidgets);

      // Bob row: id starts with 'fedcba98'.
      expect(
        find.byKey(const ValueKey<String>(
            'contactRow::fedcba9876543210fedcba9876543210')),
        findsOneWidget,
      );
      expect(find.text('Bob'), findsOneWidget);
    });

    testWidgets('shows the phone icon only on contacts with a phone number',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(tester, repo: repo);

      // Exactly one phone icon (Alice).
      expect(
        find.byKey(const ValueKey<String>('contactRowPhoneIcon')),
        findsOneWidget,
      );
      // Bob has no phone, so no second phone icon.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>(
              'contactRow::fedcba9876543210fedcba9876543210')),
          matching: find.byKey(const ValueKey<String>('contactRowPhoneIcon')),
        ),
        findsNothing,
      );
    });
  });

  group('ContactsPage — tap (QR dialog)', () {
    testWidgets('tap opens a dialog containing a QrImageView',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(tester, repo: repo);

      await tester.tap(find.byKey(const ValueKey<String>(
          'contactRow::abcdef0123456789abcdef0123456789')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('contactQrDialog')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('contactQrImage')),
          findsOneWidget);
      // Short id rendered under the QR.
      expect(
        find.byKey(const ValueKey<String>('contactQrShortId')),
        findsOneWidget,
      );

      // Close.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('contactQrDialog')),
          findsNothing);
    });
  });

  group('ContactsPage — long press (actions sheet)', () {
    testWidgets('long-press opens the actions sheet',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(tester, repo: repo);

      await tester.longPress(find.byKey(const ValueKey<String>(
          'contactRow::abcdef0123456789abcdef0123456789')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('contactsActionEdit')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('contactsActionCopyKey')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('contactsActionRemove')),
          findsOneWidget);
    });
  });

  group('ContactsPage — edit flow', () {
    testWidgets('edit dialog updates the contact via the repository',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(tester, repo: repo);

      await tester.longPress(find.byKey(const ValueKey<String>(
          'contactRow::fedcba9876543210fedcba9876543210')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(
          const ValueKey<String>('contactsActionEdit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('contactsEditDialog')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('contactsEditNameField')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('contactsEditPhoneField')),
          findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('contactsEditNameField')),
        'Bobby',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('contactsEditPhoneField')),
        '+15555550999',
      );
      await tester.tap(find.byKey(
          const ValueKey<String>('contactsEditSaveButton')));
      await tester.pumpAndSettle();

      // The repo was updated.
      final updated = await repo.list();
      final bob = updated.firstWhere(
        (c) => c.id == 'fedcba9876543210fedcba9876543210',
      );
      expect(bob.displayName, 'Bobby');
      expect(bob.phoneNumber, '+15555550999');

      // The list re-renders with the new title.
      expect(find.text('Bobby'), findsOneWidget);
    });
  });

  group('ContactsPage — copy public key', () {
    testWidgets('tapping copy public key writes the contact pubkey to the '
        'clipboard and surfaces a confirmation snackbar',
        (WidgetTester tester) async {
      // Verify both halves of the copy-key flow:
      //   1. The platform clipboard receives the contact's public key.
      //   2. The "Public key copied" snackbar is shown to the user.
      //
      // `Clipboard.setData` sends over `SystemChannels.platform`, an
      // OptionalMethodChannel that uses `JSONMethodCodec` (NOT the
      // default `StandardMethodCodec`). The mock channel must match
      // the codec exactly or it throws "Message corrupted" while
      // decoding the request bytes.
      String? lastClipboardText;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const platformChannel =
          MethodChannel('flutter/platform', JSONMethodCodec());
      messenger.setMockMethodCallHandler(
        platformChannel,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments;
            if (args is Map && args['text'] is String) {
              lastClipboardText = args['text'] as String;
            }
          }
          // Return null for every other call (SystemSound,
          // HapticFeedback, SystemChrome, etc.) so they all stay
          // no-ops in the test.
          return null;
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(platformChannel, null);
      });

      final repo = InMemoryContactsRepository(seed());
      await pumpPage(tester, repo: repo);

      await tester.longPress(find.byKey(const ValueKey<String>(
          'contactRow::abcdef0123456789abcdef0123456789')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(
          const ValueKey<String>('contactsActionCopyKey')));
      // Pump a couple of frames so the bottom-sheet pop + async
      // Clipboard.setData reply + snackbar reveal all complete.
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // The bottom sheet is gone.
      expect(find.byKey(const ValueKey<String>('contactsActionCopyKey')),
          findsNothing);
      // The platform clipboard received the contact's public key.
      expect(
        lastClipboardText,
        'abcdef0123456789abcdef0123456789',
        reason: 'Clipboard.setData must carry the contact public key',
      );
      // The confirmation snackbar is visible.
      expect(find.text('Public key copied'), findsOneWidget);
    });
  });

  group('ContactsPage — remove flow', () {
    testWidgets('remove asks for confirmation and then drops the row',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(tester, repo: repo);

      await tester.longPress(find.byKey(const ValueKey<String>(
          'contactRow::fedcba9876543210fedcba9876543210')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(
          const ValueKey<String>('contactsActionRemove')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('contactsRemoveConfirmDialog')),
          findsOneWidget);

      // Cancel first — should NOT remove.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await repo.list()), hasLength(2));

      // Re-open and confirm.
      await tester.longPress(find.byKey(const ValueKey<String>(
          'contactRow::fedcba9876543210fedcba9876543210')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const ValueKey<String>('contactsActionRemove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const ValueKey<String>('contactsRemoveConfirmButton')));
      await tester.pumpAndSettle();

      expect((await repo.list()), hasLength(1));
      // The removed row no longer renders.
      expect(
        find.byKey(const ValueKey<String>(
            'contactRow::fedcba9876543210fedcba9876543210')),
        findsNothing,
      );
    });
  });

  group('ContactsPage — Show my QR', () {
    testWidgets('dialog renders a QrImageView and the device label',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(
        tester,
        repo: repo,
        myDeviceIdentityLabel: '0123456789abcdef',
      );

      await tester.tap(find.byKey(
          const ValueKey<String>('contactsMyQrButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('myQrDialog')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('myQrImage')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('myQrLabel')),
          findsOneWidget);
      expect(find.text('0123456789abcdef'), findsOneWidget);
    });

    testWidgets('dialog falls back to a placeholder when no identity is set',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(
        tester,
        repo: repo,
        myDeviceIdentityLabel: '',
      );
      await tester.tap(find.byKey(
          const ValueKey<String>('contactsMyQrButton')));
      await tester.pumpAndSettle();
      expect(find.text('(no identity)'), findsOneWidget);
    });
  });

  group('ContactsPage — Add contact button', () {
    testWidgets('app-bar add button invokes the callback',
        (WidgetTester tester) async {
      final repo = InMemoryContactsRepository(seed());
      var taps = 0;
      await pumpPage(
        tester,
        repo: repo,
        onAddContactPressed: () => taps++,
      );

      await tester.tap(find.byKey(
          const ValueKey<String>('contactsAddButton')));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('app-bar add button is tappable even without a callback '
        '(no camera dependency)', (WidgetTester tester) async {
      // The button itself must always be present — even when no scanner
      // is wired (e.g. tests, headless demo builds). Tapping it should
      // be a no-op, not throw.
      final repo = InMemoryContactsRepository(seed());
      await pumpPage(tester, repo: repo);
      await tester.tap(find.byKey(
          const ValueKey<String>('contactsAddButton')));
      await tester.pumpAndSettle();
      // Still on the contacts page.
      expect(find.byKey(const ValueKey<String>('contactsList')),
          findsOneWidget);
    });
  });
}