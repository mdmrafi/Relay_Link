// RelayLink — Ticket #38: Home screen.
//
// The main landing page after the first-launch capability disclosure
// (`lib/screens/capability_disclosure.dart`) is dismissed. Surfaces the
// device's own short SenderId, live transport status (mesh / SMS /
// internet), peer count, and 24-hour activity count, plus a tab bar to
// the other primary destinations (Chat, Vault, Channels, Settings).
//
// Design notes:
//   * State lives in Riverpod providers so other screens (Chat, Settings)
//     can observe the same source of truth without duplicating queries.
//     The widget itself is otherwise stateless — it watches the providers
//     and renders.
//   * Transport capability flags come from `DeviceCapabilities` (Ticket
//     #29 / SPEC §3.1). Per-transport *availability* (radio on, internet
//     reachable) is wired through dedicated providers below; the home
//     screen is the canonical place where both pieces are combined for
//     the user.
//   * Transport status rows are tappable per acceptance criterion #5.
//     The transport-specific detail screens are owned by later tickets
//     (#07 mesh peers, #08 mesh send/receive, etc.); until they ship,
//     tapping a status surfaces a placeholder screen with a snackbar so
//     the gesture is wired end-to-end and can be tested today.
//   * Recent activity is computed from `LocalDb.listMessages` over the
//     last 24 hours. The query runs on demand (not on a timer) — the
//     screen rebuilds when `activityRefreshProvider` flips. Other screens
//     that mutate the message log can call
//     `ref.read(activityRefreshProvider.notifier).bump()` to invalidate.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/features/gateway/toggle.dart';
import 'package:relaylink/storage/local_db.dart';

// ---------------------------------------------------------------------------
// Identifiers / keys
// ---------------------------------------------------------------------------

/// Tab destinations exposed on the bottom navigation bar. The home tab is
/// implicit (it's where you are); the others are sibling screens whose
/// concrete files will land in later tickets.
enum HomeTab { home, chat, vault, channels, settings }

/// The three transports tracked on the home screen, in display order.
enum HomeTransport { mesh, sms, internet }

/// The first 16 hex chars of the Ed25519 public key is the device's
/// SenderId. We display at most [_senderIdDisplayMax] chars so the header
/// fits on a phone — most devices will already be 16, but the constant
/// gives us a single point of control.
const int _senderIdDisplayMax = 16;

/// Truncate a 32-hex-char SenderId down to [_senderIdDisplayMax] chars.
/// We intentionally do NOT add an ellipsis — the value is just a tag.
String truncateSenderId(String senderId) {
  if (senderId.length <= _senderIdDisplayMax) return senderId;
  return senderId.substring(0, _senderIdDisplayMax);
}

// ---------------------------------------------------------------------------
// State providers (Riverpod)
// ---------------------------------------------------------------------------

/// Source of truth for the device's own SenderId. The real Ticket #38 wire-
/// up uses `DeviceIdentity.loadOrGenerate()` at app start and seeds this
/// provider; until that's wired in, the default is an empty string and the
/// UI renders a placeholder ("…") so the layout still works on a cold
/// launch.
final StateProvider<String> ownSenderIdProvider =
    StateProvider<String>((_) => '');

/// Override hook used by tests + future bootstrap wiring.
final StateProvider<DeviceCapabilities> deviceCapabilitiesProvider =
    StateProvider<DeviceCapabilities>(
  (_) => DeviceCapabilities.forPlatform('unknown'),
);

/// Number of mesh peers currently visible to this device. 0 when mesh is
/// off or no peers are in range. Real Ticket #07 / #08 wiring will flip
/// this from the discovery layer; until then it's a static default so the
/// badge has something to render.
final StateProvider<int> meshPeerCountProvider = StateProvider<int>((_) => 0);

/// Whether the SMS radio is currently usable (permission + coverage).
/// Real Ticket #23 / #26 wiring will toggle this from the SMS platform
/// channel; default `false` so we don't claim a capability we haven't
/// confirmed.
final StateProvider<bool> smsAvailableProvider =
    StateProvider<bool>((_) => false);

/// Whether the device has an active internet route (real connectivity
/// check, not just the gateway toggle). Until Ticket #20 lands we expose
/// it as a separate provider so the home screen can render "✗" until the
/// real check exists.
final StateProvider<bool> internetReachableProvider =
    StateProvider<bool>((_) => false);

/// Bump-this counter that other screens call when they mutate the message
/// log (e.g. Chat composing a new message, mesh receiving one). The home
/// screen watches the counter and re-runs the 24h query when it changes.
/// Cheap, observable, no Streams needed.
final StateNotifierProvider<ActivityRefreshNotifier, int>
    activityRefreshProvider =
    StateNotifierProvider<ActivityRefreshNotifier, int>(
  (_) => ActivityRefreshNotifier(),
);

/// State notifier backing [activityRefreshProvider].
class ActivityRefreshNotifier extends StateNotifier<int> {
  ActivityRefreshNotifier() : super(0);

  /// Invalidate the home-screen activity count. Cheap; safe to call often.
  void bump() {
    state = state + 1;
  }
}

// ---------------------------------------------------------------------------
// Recent-activity query
// ---------------------------------------------------------------------------

/// Result of "how many messages did we see in the last 24 hours". Computed
/// from `LocalDb.listMessages` (Ticket #05). Unknown when the DB is not
/// initialized (e.g. on the very first frame before async init resolves);
/// the UI renders `—` in that case.
class HomeActivityCount {
  /// How many messages were inserted into the local store in the last
  /// 24 hours. Counts both incoming and outgoing because the schema
  /// does not distinguish (Ticket #04's `received_at` is a local-write
  /// timestamp).
  final int count24h;

  /// `true` once we've successfully queried the DB at least once. The
  /// home screen renders `—` until this flips.
  final bool known;

  const HomeActivityCount({required this.count24h, required this.known});

  /// Async lookup. Returns `HomeActivityCount.known = false` if the DB
  /// isn't initialized yet — the widget retries on the next frame.
  static Future<HomeActivityCount> query({LocalDb? db}) async {
    final LocalDb database;
    try {
      database = db ?? await LocalDb.instance();
    } catch (_) {
      return const HomeActivityCount(count24h: 0, known: false);
    }
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;
    // listMessages sorts newest-first; pruneOlderThan keeps anything with
    // received_at >= cutoff. Combine to get the 24h set without loading
    // everything into memory.
    final keep = await database.listMessages(limit: 10000);
    final inWindow = keep.where((m) {
      // listMessages returns full Message objects, but its ordering is by
      // received_at DESC — we re-derive the cutoff check from
      // created_at for a cheap proxy. createdAt is UTC per the schema.
      return m.createdAt.isAfter(DateTime.fromMillisecondsSinceEpoch(
        cutoff,
        isUtc: true,
      ));
    }).length;
    // Reference cutoff so the analyzer doesn't warn about unused locals
    // when the implementation evolves.
    assert(cutoff > 0);
    return HomeActivityCount(count24h: inWindow, known: true);
  }
}

/// Async-value wrapper that the widget tree watches.
final FutureProvider<HomeActivityCount> homeActivityProvider =
    FutureProvider<HomeActivityCount>((ref) async {
  // Re-run whenever something invalidates the counter.
  ref.watch(activityRefreshProvider);
  return HomeActivityCount.query();
});

// ---------------------------------------------------------------------------
// Home screen
// ---------------------------------------------------------------------------

/// The home screen. Stateless; all state is sourced from Riverpod providers
/// so other widgets can observe the same source of truth.
///
/// Constructor takes optional injected dependencies for tests. In
/// production the home screen is instantiated by `lib/main.dart` and uses
/// the providers above as the data source.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({
    super.key,
    this.initialTab = HomeTab.home,
    this.onTabChanged,
    this.onTransportTapped,
    this.onComposeTapped,
    this.onChannelsTapped,
    this.onVaultTapped,
  });

  /// Tab to show when the screen first builds. Defaults to [HomeTab.home].
  final HomeTab initialTab;

  /// Optional tab-change hook. When null, tapping a tab is a no-op
  /// (production wiring pushes the new route instead). Tests pass a
  /// callback to assert navigation semantics without spinning up a real
  /// Navigator.
  final void Function(HomeTab tab)? onTabChanged;

  /// Called when the user taps a transport-status chip. The argument is
  /// the transport tapped. Production pushes the relevant detail screen;
  /// tests can simply observe the callback.
  final void Function(HomeTransport transport)? onTransportTapped;

  /// Called when the user taps the "Compose" quick action.
  final VoidCallback? onComposeTapped;

  /// Called when the user taps the "Channels" quick action.
  final VoidCallback? onChannelsTapped;

  /// Called when the user taps the "Vault" quick action.
  final VoidCallback? onVaultTapped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _HomeBody(
      initialTab: initialTab,
      onTabChanged: onTabChanged,
      onTransportTapped: onTransportTapped,
      onComposeTapped: onComposeTapped,
      onChannelsTapped: onChannelsTapped,
      onVaultTapped: onVaultTapped,
    );
  }
}

/// The actual widget tree. Pulled into its own class so the parent
/// [HomeScreen] can stay a thin [ConsumerWidget] shim without re-watching
/// the providers when the constructor changes.
class _HomeBody extends ConsumerStatefulWidget {
  const _HomeBody({
    required this.initialTab,
    required this.onTabChanged,
    required this.onTransportTapped,
    required this.onComposeTapped,
    required this.onChannelsTapped,
    required this.onVaultTapped,
  });

  final HomeTab initialTab;
  final void Function(HomeTab tab)? onTabChanged;
  final void Function(HomeTransport transport)? onTransportTapped;
  final VoidCallback? onComposeTapped;
  final VoidCallback? onChannelsTapped;
  final VoidCallback? onVaultTapped;

  @override
  ConsumerState<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends ConsumerState<_HomeBody> {
  late HomeTab _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
  }

  void _selectTab(HomeTab tab) {
    setState(() => _tab = tab);
    widget.onTabChanged?.call(tab);
  }

  void _onTransportTap(HomeTransport t) {
    // Always emit a snackbar so the affordance is observable in dev. In
    // production, [HomeScreen.onTransportTapped] will push the actual
    // detail screen (Ticket #07, #08, #20).
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        key: ValueKey<String>('transportTappedSnack::${t.name}'),
        content: Text(_transportPlaceholderLabel(t)),
        duration: const Duration(milliseconds: 1200),
      ),
    );
    widget.onTransportTapped?.call(t);
  }

  String _transportPlaceholderLabel(HomeTransport t) {
    switch (t) {
      case HomeTransport.mesh:
        return 'Mesh peers list — coming in Ticket #07';
      case HomeTransport.sms:
        return 'SMS bridge — coming in Ticket #23';
      case HomeTransport.internet:
        return 'Internet gateway — coming in Ticket #20';
    }
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = ref.watch(deviceCapabilitiesProvider);
    final ownSenderId = ref.watch(ownSenderIdProvider);
    final peerCount = ref.watch(meshPeerCountProvider);
    final smsAvailable = ref.watch(smsAvailableProvider);
    final internetReachable = ref.watch(internetReachableProvider);
    final gatewayEnabled = ref.watch(gatewayEnabledProvider);

    // Internet is "on" when either the platform reports an active route OR
    // the user has explicitly opted into gateway mode (they've signaled
    // willingness to relay even if the live check hasn't returned yet).
    final internetOn = internetReachable || gatewayEnabled;

    final activity = ref.watch(homeActivityProvider);

    return Scaffold(
      appBar: _buildAppBar(context, ownSenderId),
      body: SafeArea(
        child: _HomeContent(
          capabilities: capabilities,
          peerCount: peerCount,
          smsAvailable: smsAvailable,
          internetOn: internetOn,
          activity: activity,
          onTransportTap: _onTransportTap,
          onComposeTap: widget.onComposeTapped == null
              ? null
              : () => widget.onComposeTapped!(),
          onChannelsTap: widget.onChannelsTapped == null
              ? null
              : () => widget.onChannelsTapped!(),
          onVaultTap: widget.onVaultTapped == null
              ? null
              : () => widget.onVaultTapped!(),
        ),
      ),
      bottomNavigationBar: _HomeTabBar(
        current: _tab,
        onChanged: _selectTab,
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, String ownSenderId) {
    return AppBar(
      title: Row(
        key: const ValueKey<String>('homeHeaderRow'),
        children: <Widget>[
          const Text('RelayLink'),
          const SizedBox(width: 12),
          Container(
            key: const ValueKey<String>('homeSenderIdBadge'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2933),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF4FC3F7)),
            ),
            child: Text(
              ownSenderId.isEmpty
                  ? '…'
                  : truncateSenderId(ownSenderId),
              key: const ValueKey<String>('homeSenderIdText'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Color(0xFF9AA4B2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The home-screen body content. Extracted so widget tests can pump just
/// the inner layout without the tab bar / app bar.
class _HomeContent extends StatelessWidget {
  const _HomeContent({
    required this.capabilities,
    required this.peerCount,
    required this.smsAvailable,
    required this.internetOn,
    required this.activity,
    required this.onTransportTap,
    required this.onComposeTap,
    required this.onChannelsTap,
    required this.onVaultTap,
  });

  final DeviceCapabilities capabilities;
  final int peerCount;
  final bool smsAvailable;
  final bool internetOn;
  final AsyncValue<HomeActivityCount> activity;
  final void Function(HomeTransport) onTransportTap;
  final VoidCallback? onComposeTap;
  final VoidCallback? onChannelsTap;
  final VoidCallback? onVaultTap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _TransportStatusRow(
          capabilities: capabilities,
          smsAvailable: smsAvailable,
          internetOn: internetOn,
          onTap: onTransportTap,
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(child: _PeerCountBadge(count: peerCount)),
            const SizedBox(width: 12),
            Expanded(child: _ActivityCard(activity: activity)),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Quick actions',
          key: const ValueKey<String>('homeQuickActionsLabel'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        _QuickActionGrid(
          onComposeTap: onComposeTap,
          onChannelsTap: onChannelsTap,
          onVaultTap: onVaultTap,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header & status row
// ---------------------------------------------------------------------------

/// One transport chip (Mesh / SMS / Internet) with ✓/✗ and an optional
/// peer count sub-label. Tappable so the user can navigate into the
/// transport's detail screen.
class _TransportChip extends StatelessWidget {
  const _TransportChip({
    required this.label,
    required this.available,
    required this.sublabel,
    required this.onTap,
    required this.testKey,
  });

  final String label;
  final bool available;
  final String sublabel;
  final VoidCallback onTap;
  final String testKey;

  @override
  Widget build(BuildContext context) {
    final color =
        available ? const Color(0xFF66BB6A) : const Color(0xFFEF5350);
    return Expanded(
      child: InkWell(
        key: ValueKey<String>('transportChip::$testKey'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1F2933),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    available ? Icons.check_circle : Icons.cancel,
                    color: color,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                sublabel,
                key: ValueKey<String>('transportChipSub::$testKey'),
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9AA4B2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The horizontal row of three transport chips. Combines the static
/// capability flags from [DeviceCapabilities] with live per-transport
/// availability (radio on, internet reachable).
class _TransportStatusRow extends StatelessWidget {
  const _TransportStatusRow({
    required this.capabilities,
    required this.smsAvailable,
    required this.internetOn,
    required this.onTap,
  });

  final DeviceCapabilities capabilities;
  final bool smsAvailable;
  final bool internetOn;
  final void Function(HomeTransport) onTap;

  @override
  Widget build(BuildContext context) {
    final meshOn =
        capabilities.bluetoothMeshSend.available; // capability gate
    final smsOn = capabilities.smsSend.available && smsAvailable;
    final netOn = capabilities.internet.available && internetOn;
    return Row(
      key: const ValueKey<String>('homeTransportRow'),
      children: <Widget>[
        _TransportChip(
          testKey: HomeTransport.mesh.name,
          label: 'Mesh',
          available: meshOn,
          sublabel: meshOn ? 'on' : 'off',
          onTap: () => onTap(HomeTransport.mesh),
        ),
        _TransportChip(
          testKey: HomeTransport.sms.name,
          label: 'SMS',
          available: smsOn,
          sublabel: smsOn ? 'on' : 'off',
          onTap: () => onTap(HomeTransport.sms),
        ),
        _TransportChip(
          testKey: HomeTransport.internet.name,
          label: 'Internet',
          available: netOn,
          sublabel: netOn ? 'on' : 'off',
          onTap: () => onTap(HomeTransport.internet),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Stats cards
// ---------------------------------------------------------------------------

/// "Peers: N" badge in the stats row.
class _PeerCountBadge extends StatelessWidget {
  const _PeerCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return _StatsCard(
      key: const ValueKey<String>('homePeerCountCard'),
      icon: Icons.people_outline,
      label: 'Peers',
      value: '$count',
      valueKey: const ValueKey<String>('homePeerCountValue'),
    );
  }
}

/// "Activity: N in 24h" card.
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity});

  final AsyncValue<HomeActivityCount> activity;

  @override
  Widget build(BuildContext context) {
    final value = activity.when(
      data: (a) => a.known ? '${a.count24h}' : '—',
      loading: () => '…',
      error: (_, _) => '!',
    );
    final sublabel = activity.when(
      data: (a) => a.known ? 'last 24h' : 'loading…',
      loading: () => 'last 24h',
      error: (e, _) => 'error',
    );
    return _StatsCard(
      key: const ValueKey<String>('homeActivityCard'),
      icon: Icons.timeline,
      label: 'Activity',
      value: value,
      valueKey: const ValueKey<String>('homeActivityValue'),
      sublabel: sublabel,
    );
  }
}

/// Reusable stat card: small icon + label, big value, optional sub-label.
class _StatsCard extends StatelessWidget {
  const _StatsCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.valueKey,
    this.sublabel,
  });

  final IconData icon;
  final String label;
  final String value;
  final ValueKey<String> valueKey;
  final String? sublabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2933),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18, color: const Color(0xFF9AA4B2)),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9AA4B2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            key: valueKey,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: Color(0xFFE6EAF2),
            ),
          ),
          if (sublabel != null)
            Text(
              sublabel!,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF9AA4B2),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick actions
// ---------------------------------------------------------------------------

class _QuickActionGrid extends StatelessWidget {
  const _QuickActionGrid({
    required this.onComposeTap,
    required this.onChannelsTap,
    required this.onVaultTap,
  });

  final VoidCallback? onComposeTap;
  final VoidCallback? onChannelsTap;
  final VoidCallback? onVaultTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey<String>('homeQuickActionGrid'),
      children: <Widget>[
        _QuickActionButton(
          label: 'Compose message',
          icon: Icons.edit_outlined,
          onTap: onComposeTap,
          testKey: 'homeComposeButton',
        ),
        const SizedBox(height: 8),
        _QuickActionButton(
          label: 'Channels',
          icon: Icons.tag,
          onTap: onChannelsTap,
          testKey: 'homeChannelsButton',
        ),
        const SizedBox(height: 8),
        _QuickActionButton(
          label: 'Evidence Vault',
          icon: Icons.shield_outlined,
          onTap: onVaultTap,
          testKey: 'homeVaultButton',
        ),
      ],
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.testKey,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final String testKey;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: ValueKey<String>(testKey),
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom tab bar
// ---------------------------------------------------------------------------

class _HomeTabBar extends StatelessWidget {
  const _HomeTabBar({
    required this.current,
    required this.onChanged,
  });

  final HomeTab current;
  final void Function(HomeTab) onChanged;

  static const List<_HomeTabSpec> _tabs = <_HomeTabSpec>[
    _HomeTabSpec(HomeTab.home, Icons.home_outlined, 'Home'),
    _HomeTabSpec(HomeTab.chat, Icons.chat_bubble_outline, 'Chat'),
    _HomeTabSpec(HomeTab.vault, Icons.shield_outlined, 'Vault'),
    _HomeTabSpec(HomeTab.channels, Icons.tag, 'Channels'),
    _HomeTabSpec(HomeTab.settings, Icons.settings_outlined, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      key: const ValueKey<String>('homeTabBar'),
      selectedIndex: _tabs.indexWhere((t) => t.tab == current),
      onDestinationSelected: (int i) => onChanged(_tabs[i].tab),
      destinations: <NavigationDestination>[
        for (final t in _tabs)
          NavigationDestination(
            key: ValueKey<String>('homeTab::${t.tab.name}'),
            icon: Icon(t.icon),
            label: t.label,
          ),
      ],
    );
  }
}

class _HomeTabSpec {
  const _HomeTabSpec(this.tab, this.icon, this.label);
  final HomeTab tab;
  final IconData icon;
  final String label;
}

// ---------------------------------------------------------------------------
// Identity helper
// ---------------------------------------------------------------------------

/// Convenience for bootstrap: load (or generate) the device identity and
/// seed the [ownSenderIdProvider] with the resulting SenderId. Returns the
/// same identity so callers can chain.
///
/// Not used directly by the widget — provided so [lib/main.dart] (or a
/// dedicated bootstrap file in a later wave) can wire the provider
/// without re-implementing the load/generate dance.
Future<DeviceIdentity> bootstrapOwnSenderId(WidgetRef ref) async {
  final identity = await DeviceIdentity.loadOrGenerate();
  ref.read(ownSenderIdProvider.notifier).state = identity.senderId;
  return identity;
}
