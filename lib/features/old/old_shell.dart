import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../auth/auth_controller.dart';
import '../workshop/workshop_screen.dart';
import 'data_side.dart';
import 'missing_screen.dart';
import 'old_movements_screen.dart';
import 'old_stock_screen.dart';

/// The shell shown when the app is on the sold-and-missing side: the
/// sold items, the missing items and the imported legacy movements.
/// The profile menu switches back to the current side. Sales live in
/// the one Sales screen on the current side — old sales show there too.
class OldShell extends ConsumerStatefulWidget {
  const OldShell({super.key});

  @override
  ConsumerState<OldShell> createState() => _OldShellState();
}

class _OldShellState extends ConsumerState<OldShell> {
  static const _titles = [
    'Sold items',
    'Missing items',
    'Workshop',
    'Old movements',
  ];
  static const _destinations = [
    (Icons.sell_outlined, Icons.sell, 'Sold'),
    (Icons.help_outline, Icons.help, 'Missing'),
    (Icons.handyman_outlined, Icons.handyman, 'Workshop'),
    (Icons.history_outlined, Icons.history, 'Movements'),
  ];

  late final List<Widget> _pages = const [
    OldStockScreen(),
    MissingScreen(),
    WorkshopScreen(),
    OldMovementsScreen(),
  ];

  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktopLayout(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: const [_SwitchSideButton()],
      ),
      body: desktop
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  labelType: NavigationRailLabelType.all,
                  minWidth: 160,
                  destinations: [
                    for (final (icon, activeIcon, label) in _destinations)
                      NavigationRailDestination(
                        icon: Icon(icon),
                        selectedIcon: Icon(activeIcon),
                        label: Text(label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: _pages[_index]),
              ],
            )
          : Column(
              children: [
                Expanded(child: _pages[_index]),
                NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                  destinations: [
                    for (final (icon, activeIcon, label) in _destinations)
                      NavigationDestination(
                        icon: Icon(icon),
                        selectedIcon: Icon(activeIcon),
                        label: label,
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// Menu button that flips the app back to the current-data side.
class _SwitchSideButton extends ConsumerWidget {
  const _SwitchSideButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final name = profile.maybeWhen(
          data: (p) => (p?['display_name'] ?? p?['username'] ?? '') as String,
          orElse: () => '',
        );
    return PopupMenuButton<String>(
      onSelected: (value) {
        if (value == 'current') {
          ref.read(dataSideProvider.notifier).set('current');
        } else if (value == 'logout') {
          ref.read(authControllerProvider).signOut();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Text(
            name.isEmpty ? 'Team member' : name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const PopupMenuItem(
            value: 'current', child: Text('Switch to current data')),
        const PopupMenuItem(value: 'logout', child: Text('Log out')),
      ],
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: CircleAvatar(
          backgroundColor: const Color(0xFF9A5A00),
          child: Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
