import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../movements/movements_screen.dart';

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
          loading: () => <(String, IconData, String)>[
            for (final (label, icon) in _statSlots)
              (label, icon, '…'),
          ],
          error: (_, _) => <(String, IconData, String)>[
            for (final (label, icon) in _statSlots)
              (label, icon, '—'),
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
          data: (items) => items.where((item) => !item.isSold).length,
          orElse: () => 0,
        );

    final movementRows = ref.watch(movementsProvider).maybeWhen(
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
      if (kind != 'Workshop' && kind != 'Dealer' && kind != 'Customer') {
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
        if (missingSends > 0) ...[
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            color: const Color(0xFFFFF6E5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0xFFF2C94C)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Color(0xFFF2B01E), size: 20),
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
                  const Text(
                    'You recorded these without the dealer or customer '
                    'name. Add it whenever you know it.',
                    style: TextStyle(color: Color(0xFF5B6B7B), fontSize: 13),
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
        if (ranking.isNotEmpty) ...[
          const SizedBox(height: 16),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Who sent the most?',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                const Text(
                  'Machines out to the workshop, dealers and customers.',
                  style: TextStyle(color: kMuted, fontSize: 12.5),
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
                                      ? scheme.primary
                                      : kHint)),
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
                                'Workshop ${ranking[i].value['Workshop']}',
                                style: const TextStyle(
                                    color: kMuted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        if (i == 0)
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Icon(Icons.emoji_events_outlined,
                                color: Color(0xFFF2B01E), size: 20),
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
        ],
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
