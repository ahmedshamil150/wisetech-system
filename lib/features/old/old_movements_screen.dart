import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/widgets.dart';
import '../data/data.dart';
import 'old_data.dart';
import 'old_table.dart';

/// The imported Legacy movements — the history that came in with the old
/// stock. Read-only for everyone; admins can erase a bad import row.
class OldMovementsScreen extends ConsumerStatefulWidget {
  const OldMovementsScreen({super.key});

  @override
  ConsumerState<OldMovementsScreen> createState() => _OldMovementsScreenState();
}

class _OldMovementsScreenState extends ConsumerState<OldMovementsScreen> {
  String _query = '';
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(
        oldMovementsProvider((page: _page, search: _query)));
    return Column(
      children: [
        oldSearchField(context,
            hint: 'Search old movements',
            onChanged: (value) => setState(() {
                  _query = value.trim();
                  _page = 0;
                })),
        Expanded(
          child: data.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
                icon: Icons.error_outline, message: errorMessage(error)),
            data: (result) => OldTable(
              rows: result.rows,
              total: result.total,
              page: _page,
              onPageChanged: (p) => setState(() => _page = p),
              emptyMessage: 'No old movements match this search.',
              rowBuilder: _movementTile,
            ),
          ),
        ),
      ],
    );
  }

  Widget _movementTile(Map<String, dynamic> row) {
    final date = (row['movement_date'] ?? '').toString();
    final from = (row['from_location'] ?? '').toString();
    final to = (row['to_location'] ?? '').toString();
    final notes = (row['notes'] ?? '').toString();
    final item = (row['machines'] ??
        row['probes'] ??
        row['printers'] ??
        row['parts']) as Map?;
    final label = (item?['machine_id'] ??
            item?['internal_id'] ??
            item?['model'] ??
            item?['name_model'] ??
            '')
        .toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: const Icon(Icons.history,
                color: Colors.white, size: 20),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                    label.isEmpty
                        ? '${from.isEmpty ? '?' : from} → ${to.isEmpty ? '?' : to}'
                        : label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
              oldBadge(context),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (date.isNotEmpty)
                Text(date,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              if (from.isNotEmpty || to.isNotEmpty)
                Text('${from.isEmpty ? '?' : from} → ${to.isEmpty ? '?' : to}',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              if (notes.isNotEmpty)
                Text(notes,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}
