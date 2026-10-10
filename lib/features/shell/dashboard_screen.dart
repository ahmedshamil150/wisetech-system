import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../inventory/inventory_screen.dart';
import '../movements/movements_screen.dart';
import 'navigation_providers.dart';

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
    final myId = ref.read(authControllerProvider).currentUser?.id;

    final inRepair = ref.watch(openRepairsCountProvider);
    final stats = ref.watch(inventoryProvider).when(
          loading: () => <(String, IconData, String, String)>[
            for (final (label, icon, target) in _statSlots)
              (label, icon, '…', target),
          ],
          error: (_, _) => <(String, IconData, String, String)>[
            for (final (label, icon, target) in _statSlots)
              (label, icon, '—', target),
          ],
          data: (items) {
            int count(Iterable<InventoryItem> rows) => rows.length;
            final inStock = items.where((i) =>
                i.status == 'In Stock' || i.status == 'Available');
            final workshop = items.where((i) => i.status == 'With Workshop');
            final branch = items.where((i) => i.status == 'With Branch');
            final dealer = items.where((i) => i.status == 'With Dealer');
            final customer =
                items.where((i) => i.status == 'With Customer');
            return <(String, IconData, String, String)>[
              ('In stock', Icons.inventory_2_outlined, '${count(inStock)}',
                  'In Stock'),
              ('With workshop', Icons.build_outlined, '${count(workshop)}',
                  'With Workshop'),
              ('With branch', Icons.storefront_outlined, '${count(branch)}',
                  'With Branch'),
              ('With dealer', Icons.handshake_outlined, '${count(dealer)}',
                  'With Dealer'),
              ('With customer', Icons.person_outline, '${count(customer)}',
                  'With Customer'),
              ('In repair', Icons.handyman_outlined, '$inRepair', 'repairs'),
            ];
          },
        );

    final total = ref.watch(inventoryProvider).maybeWhen(
          data: (items) => items.where((item) => !item.isSold).length,
          orElse: () => 0,
        );

    final movementRows = ref.watch(movementsProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );

    final isAdmin = ref.watch(isAdminProvider);
    final newPeople = ref.watch(recentPartiesProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );

    // sends recorded without a dealer/customer name — mine only
    final missingMine = movementRows
        .where((row) =>
            movementPartyMissing(row) && row['actor_id'] == myId)
        .toList();
    final missingSends = missingMine
        .map((row) =>
            ((row['group_ref'] ?? '').toString().isNotEmpty
                    ? row['group_ref']
                    : row['id'])
                .toString())
        .toSet()
        .length;

    // who sent the most machines out
    final byPerson = <String, Map<String, dynamic>>{};
    for (final row in movementRows) {
      if (row['machine_id'] == null) continue;
      final kind = row['movement_type'];
      if (kind != 'Workshop' &&
          kind != 'Branch' &&
          kind != 'Dealer' &&
          kind != 'Customer') {
        continue;
      }
      final actorId = (row['actor_id'] ?? '').toString();
      if (actorId.isEmpty) continue;
      final actor = row['profiles'];
      final person = actor is Map
          ? ((actor['display_name'] ?? actor['username'] ?? '').toString())
          : '';
      if (person.isEmpty) continue;
      final entry = byPerson.putIfAbsent(actorId, () => {
            'name': person,
            'Workshop': 0,
            'Branch': 0,
            'Dealer': 0,
            'Customer': 0,
            'total': 0,
          });
      entry[kind] = (entry[kind] as int) + 1;
      entry['total'] = (entry['total'] as int) + 1;
    }
    final ranking = byPerson.entries.toList()
      ..sort((a, b) =>
          (b.value['total'] as int).compareTo(a.value['total'] as int));

    final desktop = isDesktopLayout(context);

    return AppRefresh(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(desktop ? 24 : 16),
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
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        GridView.count(
          crossAxisCount: desktop ? 4 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.4,
          children: [
            for (final (label, icon, value, target) in stats)
              AppCard(
                onTap: () => openStat(ref, target),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 22, color: scheme.primary),
                      const SizedBox(height: 8),
                      Text(label,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text(value,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (missingSends > 0) ...[
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            color: context.colors.warningContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: context.colors.warningBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: kAmber, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$missingSends send${missingSends == 1 ? '' : 's'} '
                          'without a name',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'You recorded these without the dealer or customer '
                    'name. Add it whenever you know it.',
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonal(
                    onPressed: () =>
                        showAddPartySheet(context, ref, missingMine),
                    child: const Text('Add now'),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (isAdmin && newPeople.isNotEmpty) ...[
          const SizedBox(height: 16),
          AppCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Recently added',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  Text(
                    'Customers and dealers anyone just added.',
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12.5),
                  ),
                  const SizedBox(height: 6),
                  for (var i = 0; i < newPeople.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.person_add_alt_outlined,
                              size: 20, color: kAmber),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${newPeople[i]['name']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13.5)),
                                Text(
                                  '${newPeople[i]['by']} added a '
                                  '${newPeople[i]['kind']} · '
                                  '${_shopDate(newPeople[i]['at'])}',
                                  style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (ranking.isNotEmpty) ...[
          const SizedBox(height: 16),
          AppCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Who sent the most?',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(
                    'Machines out to the workshop, dealers and customers.',
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12.5),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < ranking.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text('#${i + 1}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                color: i == 0
                                    ? context.colors.brandText
                                    : scheme.outline)),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${ranking[i].value['name']}'
                                  '${ranking[i].key == myId ? ' (you)' : ''}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13.5),
                                ),
                                Text(
                                  'Dealer ${ranking[i].value['Dealer']} · '
                                  'Customer ${ranking[i].value['Customer']} · '
                                  'Workshop ${ranking[i].value['Workshop']}'
                                  ' · Branch ${ranking[i].value['Branch']}',
                                  style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          if (i == 0)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Icon(Icons.emoji_events_outlined,
                                  color: kAmber, size: 20),
                            ),
                          Text('${ranking[i].value['total']}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 16)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: context.colors.tintBlue,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Send an item to the workshop or a dealer on the Movements '
              'page, or record a sale — the numbers above update right away.',
                                style: TextStyle(color: context.colors.brandText),
            ),
          ),
        ),
      ],
    ));
  }
}
const _statSlots = [
  ('In stock', Icons.inventory_2_outlined, 'In Stock'),
  ('With workshop', Icons.build_outlined, 'With Workshop'),
  ('With branch', Icons.storefront_outlined, 'With Branch'),
  ('With dealer', Icons.handshake_outlined, 'With Dealer'),
  ('With customer', Icons.person_outline, 'With Customer'),
  ('In repair', Icons.handyman_outlined, 'repairs'),
];

/// A stat card was tapped — open the page it counts, pre-filtered.
void openStat(WidgetRef ref, String target) {
  if (target == 'repairs') {
    ref.read(shellTabProvider.notifier).set(4);
    return;
  }
  ref.read(inventoryStatusFilterProvider.notifier).set(target);
  ref.read(shellTabProvider.notifier).set(1);
}

/// `2026-09-28T…` → `28-09-2026` (the shop's date format).
String _shopDate(Object? iso) {
  final parsed = DateTime.tryParse((iso ?? '').toString());
  return parsed == null ? '' : DateField.format(parsed);
}
