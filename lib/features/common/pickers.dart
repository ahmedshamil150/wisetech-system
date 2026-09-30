import 'package:flutter/material.dart';

import '../data/data.dart';
import 'widgets.dart';

/// Relevance score for a search query; lower is better.
/// -1 = no match.
int _scoreMatch(InventoryItem item, String q) {
  final code = item.code.toLowerCase();
  if (code == q) return 0;
  if (code.startsWith(q)) return 1;
  if (code.contains(q)) return 2;
  final name = item.name.toLowerCase();
  if (name == q) return 3;
  if (name.startsWith(q)) return 4;
  if (name.contains(q)) return 5;
  final serial = (item.serial ?? '').toLowerCase();
  if (serial == q) return 6;
  if (serial.startsWith(q)) return 7;
  if (serial.contains(q)) return 8;
  return -1;
}

const _kindRank = {'machine': 0, 'printer': 1, 'probe': 2, 'part': 3};

/// Full-height sheet listing inventory items with a search box.
/// Returns the chosen item, or null when cancelled.
Future<InventoryItem?> showPickItem(
  BuildContext context, {
  required List<InventoryItem> items,
  String? selectedKey,
}) {
  return showModalBottomSheet<InventoryItem>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      var query = '';
      return StatefulBuilder(
        builder: (context, setState) {
          final q = query.trim().toLowerCase();
          List<InventoryItem> matches;
          if (q.isEmpty) {
            matches = items;
          } else {
            final scored = <(int, int, InventoryItem)>[];
            for (var i = 0; i < items.length; i++) {
              final s = _scoreMatch(items[i], q);
              if (s >= 0) scored.add((s, i, items[i]));
            }
            scored.sort((a, b) {
              if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
              final ka = _kindRank[a.$3.kind] ?? 4;
              final kb = _kindRank[b.$3.kind] ?? 4;
              if (ka != kb) return ka.compareTo(kb);
              return a.$2.compareTo(b.$2);
            });
            matches = [for (final t in scored) t.$3];
          }
          final screen = MediaQuery.of(context).size.height;
          final inset = MediaQuery.of(sheetContext).viewInsets.bottom;
          final height = (screen * 0.8 - inset).clamp(screen * 0.45, screen * 0.9);
          return Padding(
            padding: EdgeInsets.only(bottom: inset),
            child: SizedBox(
              height: height,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('Choose an item',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SearchField(
                      hint: 'Search ${items.length} items by code, model or serial',
                      onChanged: (value) => setState(() => query = value),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: matches.isEmpty
                        ? const EmptyState(
                            icon: Icons.search_off,
                            message: 'Nothing matches that search.')
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            itemCount: matches.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = matches[index];
                              final isSelected = item.key == selectedKey;
                              return ListTile(
                                dense: true,
                                leading: Text(item.kindLabel,
                                    style: const TextStyle(
                                        fontSize: 12, color: kHint)),
                                title: Text('${item.code}  ${item.title}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700, fontSize: 14)),
                                subtitle: Text('${item.status} · ${item.location}'),
                                trailing: isSelected
                                    ? Icon(Icons.check,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary)
                                    : null,
                                onTap: () =>
                                    Navigator.pop(sheetContext, item),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
