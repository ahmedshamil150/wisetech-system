import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../../core/theme_controller.dart';
import '../auth/auth_controller.dart';
import '../inventory/inventory_screen.dart';
import '../movements/movements_screen.dart';
import '../old/data_side.dart';
import '../old/old_shell.dart';
import '../repairs/repairs_screen.dart';
import '../sales/sales_screen.dart';
import 'dashboard_screen.dart';
import 'navigation_providers.dart';
import 'profile_screen.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The old-data side has its own shell with three simple tabs.
    final side = ref.watch(dataSideProvider);
    if (side == 'old') return const OldShell();
    return const _CurrentShell();
  }
}

class _CurrentShell extends ConsumerStatefulWidget {
  const _CurrentShell();

  @override
  ConsumerState<_CurrentShell> createState() => _CurrentShellState();
}

class _CurrentShellState extends ConsumerState<_CurrentShell> {
  static const _titles = [
    'Dashboard',
    'Inventory',
    'Movements',
    'Sales',
    'Repairs',
  ];

  static const _destinations = [
    (Icons.dashboard_outlined, Icons.dashboard, 'Dashboard'),
    (Icons.inventory_2_outlined, Icons.inventory_2, 'Inventory'),
    (Icons.swap_horiz_outlined, Icons.swap_horiz, 'Movements'),
    (Icons.receipt_long_outlined, Icons.receipt_long, 'Sales'),
    (Icons.build_outlined, Icons.build, 'Repairs'),
  ];

  late final List<Widget> _pages = [
    const DashboardScreen(),
    const InventoryScreen(),
    const MovementsScreen(),
    const SalesScreen(),
    const RepairsScreen(),
  ];

  /// Pages build the first time their tab is opened and stay alive
  /// after that, so start-up does not pay for all five at once.
  final Set<int> _visited = {0};

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellTabProvider);
    _visited.add(index);
    final desktop = isDesktopLayout(context);
    final body = IndexedStack(
      index: index,
      children: [
        for (var i = 0; i < _pages.length; i++)
          if (_visited.contains(i)) _pages[i] else const SizedBox.shrink(),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[index]),
        actions: const [_ProfileMenuButton()],
      ),
      body: desktop
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) =>
                      ref.read(shellTabProvider.notifier).set(i),
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
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: desktop
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) =>
                  ref.read(shellTabProvider.notifier).set(i),
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
    );
  }
}

class _ProfileMenuButton extends ConsumerWidget {
  const _ProfileMenuButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final auth = ref.read(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final name = profile.maybeWhen(
          data: (p) => (p?['display_name'] ?? p?['username'] ?? '') as String,
          orElse: () => '',
        );
    return PopupMenuButton<String>(
      onSelected: (value) {
        if (value == 'profile') {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ProfileScreen()),
          );
        } else if (value == 'theme') {
          ref.read(themeModeProvider.notifier).toggle();
        } else if (value == 'old') {
          ref.read(dataSideProvider.notifier).set('old');
        } else if (value == 'logout') {
          auth.signOut();
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
        const PopupMenuItem(value: 'profile', child: Text('My profile')),
        PopupMenuItem(
          value: 'theme',
          child: Row(
            children: [
              Icon(
                themeMode == ThemeMode.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                size: 20,
              ),
              const SizedBox(width: 10),
              Text(themeMode == ThemeMode.dark ? 'Light mode' : 'Dark mode'),
            ],
          ),
        ),
        const PopupMenuItem(value: 'old', child: Text('Switch to old data')),
        const PopupMenuItem(value: 'logout', child: Text('Log out')),
      ],
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
