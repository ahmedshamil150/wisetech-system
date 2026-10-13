import 'package:flutter/material.dart';

import '../common/widgets.dart';

/// A page-based table for the old-data side: 50 rows at a time, a search
/// field on top and simple prev/next paging underneath. Rows are built by
/// [rowBuilder] so each screen decides its own columns.
class OldTable<T> extends StatelessWidget {
  const OldTable({
    super.key,
    required this.rows,
    required this.total,
    required this.page,
    required this.onPageChanged,
    required this.rowBuilder,
    this.emptyMessage = 'Nothing matches this search.',
  });

  final List<Map<String, dynamic>> rows;
  final int total;
  final int page;
  final ValueChanged<int> onPageChanged;
  final Widget Function(Map<String, dynamic> row) rowBuilder;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final start = page * 50 + 1;
    final end = (page + 1) * 50;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: rows.isEmpty
              ? EmptyState(
                  icon: Icons.inbox_outlined, message: emptyMessage)
              : AppRefresh(
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    itemCount: rows.length,
                    itemBuilder: (context, index) =>
                        rowBuilder(rows[index]),
                  ),
                ),
        ),
        if (total > 50)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Previous page',
                  onPressed: page > 0 ? () => onPageChanged(page - 1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '$start–${end > total ? total : end} of $total',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant),
                ),
                IconButton(
                  tooltip: 'Next page',
                  onPressed: end < total
                      ? () => onPageChanged(page + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Amber pill marking a row that came from the old-data import.
Widget oldBadge(BuildContext context) {
  final color = const Color(0xFF9A5A00);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text('Old',
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: color)),
  );
}

/// Search bar shown above every old-data table.
Widget oldSearchField(BuildContext context,
    {required ValueChanged<String> onChanged, required String hint}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: SearchField(hint: hint, onChanged: onChanged),
  );
}
