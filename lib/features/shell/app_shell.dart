import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../../core/theme_controller.dart';
import '../auth/auth_controller.dart';
import '../data/data_era.dart';
import '../inventory/inventory_screen.dart';
import '../movements/movements_screen.dart';
import '../records/records_screen.dart';
import '../repairs/repairs_screen.dart';
import 'dashboard_screen.dart';
import 'navigation_providers.dart';
import 'profile_screen.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _titles = [
    'Dashboard',
    'Inventory',
    'Movements',
    'Records',
    'Repairs',
  ];

  static const _destinations = [
    (Icons.dashboard_outlined, Icons.dashboard, 'Dashboard'),
    (Icons.inventory_2_outlined, Icons.inventory_2, 'Inventory'),
    (Icons.swap_horiz_outlined, Icons.swap_horiz, 'Movements'),
    (Icons.folder_outlined, Icons.folder, 'Records'),
    (Icons.build_outlined, Icons.build, 'Repairs'),
  ];

  late final List<Widget> _pages = [
    const DashboardScreen(),
    const InventoryScreen(),
    const MovementsScreen(),
    const RecordsScreen(),
    const RepairsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellTabProvider);
    final desktop = isDesktopLayout(context);
    final body = IndexedStack(index: index, children: _pages);
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
    final isAdmin = ref.watch(isAdminProvider);
    final era = ref.watch(dataEraProvider);
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
        } else if (value == 'era') {
          ref.read(dataEraProvider.notifier).set(
                era == DataEra.before ? DataEra.after : DataEra.before,
              );
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
        if (isAdmin)
          PopupMenuItem(
            value: 'era',
            child: Row(
              children: [
                Icon(
                  era == DataEra.before
                      ? Icons.inventory_2_outlined
                      : Icons.archive_outlined,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Text(era == DataEra.before
                    ? 'Switch to current stock'
                    : 'Switch to old stock'),
              ],
            ),
          ),
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
