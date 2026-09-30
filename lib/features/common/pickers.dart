import 'package:flutter/material.dart';

import '../data/data.dart';
import 'widgets.dart';

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
          final matches = q.isEmpty
              ? items
              : items
                  .where((item) =>
                      item.code.toLowerCase().contains(q) ||
                      item.name.toLowerCase().contains(q) ||
                      (item.serial ?? '').toLowerCase().contains(q))
                  .toList();
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.8,
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
                                      color:
                                          Theme.of(context).colorScheme.primary)
                                  : null,
                              onTap: () => Navigator.pop(sheetContext, item),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
