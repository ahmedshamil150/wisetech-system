import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../common/flag_sheet.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// One item drawn exactly the way the Inventory list draws it: code on
/// top, name below, the status chip, the badges and flag dot under that,
/// and the location (plus date) on the right.
///
/// The Inventory page and the Workshop / Missing / Basement views all use
/// this tile, so the same item looks the same wherever it is opened.
class InventoryItemTile extends StatelessWidget {
  const InventoryItemTile({
    super.key,
    required this.item,
    this.indented = false,
    this.onTap,
    this.trailing,
  });

  final InventoryItem item;
  final bool indented;

  /// Opens the shared details sheet. Pass the page's own handler so the
  /// tile does not drag the whole Inventory screen into every view.
  final VoidCallback? onTap;

  /// Replaces the chevron when a page needs its own quick action.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final phone = isPhoneLayout(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 8, left: indented ? 32 : 0),
      child: AppCard(
        child: ListTile(
          onTap: onTap,
          leading: CircleAvatar(
            backgroundColor: context.colors.tintBlue,
            child: Icon(
              inventoryKindIcon(item.kind),
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          title: Text(
            item.code.isNotEmpty ? item.code : (item.serial ?? item.title),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: phone ? 13.5 : 14,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: TextStyle(fontSize: phone ? 12 : 13)),
              const SizedBox(height: 4),
              Row(
                children: [
                  StatusChip(status: item.displayStatus),
                  if (item.kind == 'probe') ...[
                    const SizedBox(width: 6),
                    _probeBadge(context, item),
                  ],
                  if (item.kind == 'part' && _partIsMoved(item)) ...[
                    const SizedBox(width: 6),
                    _movedBadge(context),
                  ],
                  if (item.needsReview) ...[
                    const SizedBox(width: 6),
                    _reviewDot(context, item),
                  ],
                  const SizedBox(width: 6),
                  FlagDot(targetKey: flagItemKey(item.kind, item.id)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${item.location}${item.date == null ? '' : ' · ${item.date}'}',
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

IconData inventoryKindIcon(String kind) => switch (kind) {
  'machine' => Icons.monitor_outlined,
  'probe' => Icons.cable_outlined,
  'printer' => Icons.print_outlined,
  _ => Icons.settings_outlined,
};

Widget _probeBadge(BuildContext context, InventoryItem item) {
  // The badge says where the probe physically is, and only that. The
  // status chip carries outbound statuses, so a free probe never shows
  // "With Customer" next to "In stock".
  final (label, color) = item.displayStatus == 'With Machine'
      ? ('With machine', Theme.of(context).colorScheme.primary)
      : item.boxId != null
      ? ('In box', context.colors.tintBlue)
      : (item.displayStatus == 'In Stock'
            ? ('In stock', context.colors.success)
            : ('', context.colors.success));
  if (label.isEmpty) return const SizedBox.shrink();
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

/// A part is moved once it left the company — sold or sitting with a
/// dealer/customer. Those stay in the list so history stays reachable.
bool _partIsMoved(InventoryItem item) =>
    item.status != 'Available' && item.status != 'In Stock';

/// Small red pill marking a part that has left the company.
Widget _movedBadge(BuildContext context) {
  final color = Theme.of(context).colorScheme.error;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      'Moved',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

/// Small dot marking an item flagged for review: red when the serial
/// could not be found in the old stock, green for every other flag (e.g.
/// a boxed probe whose serial also turns up in the old sales records).
Widget _reviewDot(BuildContext context, InventoryItem item) {
  final isSerial = item.reviewKind == 'serial';
  final color = isSerial
      ? Theme.of(context).colorScheme.error
      : context.colors.success;
  return Tooltip(
    message: isSerial
        ? 'Serial not found in the old stock — verify by hand'
        : 'Needs review — check against the old sales records',
    child: Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}
