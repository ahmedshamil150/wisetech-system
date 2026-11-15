import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/flag_sheet.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../inventory/inventory_screen.dart' show showItemDetails;
import 'old_item_form.dart';

/// The icon that stands for each kind of item, the same one the Inventory
/// page and the Branch list use.
IconData oldKindIcon(String kind) => switch (kind) {
  'machine' => Icons.monitor_outlined,
  'probe' => Icons.cable_outlined,
  'printer' => Icons.print_outlined,
  _ => Icons.settings_outlined,
};

/// One old-data row drawn exactly like the Inventory list: code on top,
/// name · serial below, the status chip and flag dot under that, and the
/// location (plus "with M-…" for a kit member) on the right. Tapping it
/// opens the same details sheet the Inventory page uses.
///
/// [indented] tucks a probe, printer or part under its machine; [trailing]
/// replaces the chevron when a page needs its own action menu.
class OldItemTile extends ConsumerWidget {
  const OldItemTile({
    super.key,
    required this.row,
    this.indented = false,
    this.withCode,
    this.trailing,
  });

  final Map<String, dynamic> row;
  final bool indented;

  /// The machine a kit member travels with — shown as "with M-08126".
  final String? withCode;

  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = '${row['kind'] ?? 'machine'}';
    final id = row['id'] as int;
    final code = '${row[codeColumnFor(kind)] ?? ''}';
    final name = '${row[nameColumnFor(kind)] ?? ''}';
    final serial = '${row['serial_number'] ?? ''}';
    final phone = isPhoneLayout(context);
    final detail = [
      '${row['current_location'] ?? ''}',
      if ((withCode ?? '').isNotEmpty) 'with $withCode',
    ].where((value) => value.isNotEmpty).join(' · ');
    return Padding(
      padding: EdgeInsets.only(bottom: 8, left: indented ? 32 : 0),
      child: AppCard(
        child: ListTile(
          onTap: () => showItemDetails(context, ref, itemFromRow(row)),
          leading: CircleAvatar(
            backgroundColor: context.colors.tintBlue,
            child: Icon(
              oldKindIcon(kind),
              size: indented ? 18 : 22,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          title: Text(
            code.isEmpty ? name : code,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: phone ? 13.5 : 14,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                serial.isEmpty ? name : '$name · $serial',
                style: TextStyle(fontSize: phone ? 12 : 13),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  StatusChip(status: '${row['status'] ?? ''}'),
                  const SizedBox(width: 6),
                  FlagDot(targetKey: flagItemKey(kind, id)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      detail,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: phone ? 11.5 : 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          trailing: trailing ?? const Icon(Icons.chevron_right, size: 20),
        ),
      ),
    );
  }
}
