import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../data/data.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final name = profile.maybeWhen(
          data: (p) => (p?['display_name'] ?? p?['username'] ?? '') as String,
          orElse: () => '',
        );
    final scheme = Theme.of(context).colorScheme;

    final inRepair = ref.watch(openRepairsCountProvider);
    final stats = ref.watch(inventoryProvider).when(
          loading: () => <(String, IconData, String)>[
            for (final (label, icon) in _statSlots)
              (label, icon, '…'),
          ],
          error: (_, _) => <(String, IconData, String)>[
            for (final (label, icon) in _statSlots) (label, icon, '—'),
          ],
          data: (items) {
            int count(Iterable<InventoryItem> rows) => rows.length;
            final inStock = items.where((i) =>
                i.status == 'In Stock' || i.status == 'Available');
            final workshop = items.where((i) => i.status == 'With Workshop');
            final dealer = items.where((i) => i.status == 'With Dealer');
            return <(String, IconData, String)>[
              ('In stock', Icons.inventory_2_outlined, '${count(inStock)}'),
              ('With workshop', Icons.build_outlined, '${count(workshop)}'),
              ('With dealer', Icons.handshake_outlined, '${count(dealer)}'),
              ('In repair', Icons.handyman_outlined, '$inRepair'),
            ];
          },
        );

    final total = ref.watch(inventoryProvider).maybeWhen(
          data: (items) => items.length,
          orElse: () => 0,
        );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          name.isEmpty ? 'Welcome' : 'Welcome, $name',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          total == 0
              ? 'Here is your activity with the team inventory.'
              : 'Here is your activity with the team inventory · $total items.',
          style: const TextStyle(color: Color(0xFF5B6B7B)),
        ),
        const SizedBox(height: 20),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: [
            for (final (label, icon, value) in stats)
              Card(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: Color(0xFFE2E9F0)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: scheme.primary),
                      const SizedBox(height: 10),
                      Text(label,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF5B6B7B))),
                      const SizedBox(height: 2),
                      Text(value,
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: const Color(0xFFEAF3F8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Send an item to the workshop or a dealer on the Movements '
              'page, or record a sale — the numbers above update right away.',
              style: TextStyle(color: Color(0xFF1668A8)),
            ),
          ),
        ),
      ],
    );
  }
}

const _statSlots = [
  ('In stock', Icons.inventory_2_outlined),
  ('With workshop', Icons.build_outlined),
  ('With dealer', Icons.handshake_outlined),
  ('In repair', Icons.handyman_outlined),
];
