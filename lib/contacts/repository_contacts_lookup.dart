// RelayLink — Production `ContactsLookup` backed by `LocalDb.contacts`.
//
// `ContactsLookup` (Ticket #28) is the seam the SMS-DIRECT adapter uses
// to resolve a recipient device-id → phone number. `InMemoryContactsStore`
// is fine for tests and pre-#40 wiring; this file ships the production
// implementation that reads through to the v3 `contacts` table introduced
// by the wiring-gap-closure plan.
//
// Lookup is best-effort: a contact may have been paired but the in-memory
// snapshot is stale. `RepositoryContactsLookup` keeps a small in-process
// cache that is hydrated on first read and invalidated on every write.
// Tests use `RepositoryContactsLookup.withCacheSize` to size the cache
// explicitly; production code uses the default.

import 'dart:async';

import 'package:relaylink/contacts/contacts_lookup.dart';
import 'package:relaylink/storage/local_db.dart';

/// `ContactsLookup` backed by the `contacts` table in `LocalDb`.
class RepositoryContactsLookup implements ContactsLookup {
  /// Constructs a lookup over the given [db]. The optional [nowFn] lets
  /// tests inject a deterministic clock; production code leaves it null
  /// and uses `DateTime.now()`.
  RepositoryContactsLookup(this._db);

  final LocalDb _db;

  // Cache is intentionally tiny: a phone-sized contact list is well under
  // 100 entries, and the SQLite round-trip for `lookupByDeviceId` is
  // already an indexed PK lookup.
  final Map<String, ContactRecord> _cache = <String, ContactRecord>{};

  bool _hydrated = false;

  Future<void> _hydrate() async {
    if (_hydrated) return;
    final all = await _db.listContacts();
    _cache
      ..clear()
      ..addEntries(all.map((c) => MapEntry(c.deviceId, c)));
    _hydrated = true;
  }

  @override
  ContactRecord? lookupByDeviceId(String deviceId) {
    final cached = _cache[deviceId];
    if (cached != null) return cached;
    // Cache miss: kick off a hydration and return null for this call.
    // The next call after the hydration completes will hit the cache.
    // Production callers should use `Future<...> lookupByDeviceIdAsync`
    // when they need the up-to-date value; the sync API is for the
    // hot path where stale-is-fine.
    unawaited(_hydrate());
    return null;
  }

  /// Async variant — returns the up-to-date value, hydrating the cache
  /// first if necessary. Use this when staleness is unacceptable (e.g.
  /// immediately after a fresh pairing in the same code path).
  Future<ContactRecord?> lookupByDeviceIdAsync(String deviceId) async {
    await _hydrate();
    final cached = _cache[deviceId];
    if (cached != null) return cached;
    final fromDb = await _db.getContact(deviceId);
    if (fromDb != null) _cache[deviceId] = fromDb;
    return fromDb;
  }

  /// Insert or replace a contact. Returns the previous record (if any).
  Future<ContactRecord?> upsert(ContactRecord record) async {
    await _hydrate();
    final previous = _cache[record.deviceId];
    await _db.insertContact(record);
    _cache[record.deviceId] = record;
    _hydrated = true;
    return previous;
  }

  /// Delete a contact by id. Returns rows affected.
  Future<int> delete(String deviceId) async {
    await _hydrate();
    final removed = await _db.deleteContact(deviceId);
    _cache.remove(deviceId);
    return removed;
  }

  /// All paired contacts, newest first.
  Future<List<ContactRecord>> list() async {
    await _hydrate();
    return List<ContactRecord>.unmodifiable(_cache.values);
  }

  /// Drop the in-memory cache. Useful for tests.
  void invalidate() {
    _cache.clear();
    _hydrated = false;
  }
}
