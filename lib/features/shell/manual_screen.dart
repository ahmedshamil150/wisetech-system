import 'package:flutter/material.dart';

import '../common/widgets.dart';

/// The whole app in short sections: what each page does and how the
/// flows fit together. Open from My profile for every role.
class ManualScreen extends StatelessWidget {
  const ManualScreen({super.key});

  static const _sections =
      <({IconData icon, String title, List<String> lines})>[
    (
      icon: Icons.login_outlined,
      title: 'Signing in',
      lines: [
        'Use the username given to you and its password.',
        'Admins can add and edit everything. Viewers can record movements.',
        'Ask an admin to reset a forgotten password.',
      ],
    ),
    (
      icon: Icons.dashboard_outlined,
      title: 'Dashboard',
      lines: [
        'Pick a period and a batch at the top; every number follows them.',
        'Sales, sent out, returned and repairs count what happened in the period.',
        'Right now counts the stock as it stands today.',
        'Tap a card to open the list behind it.',
        'A card without a name can be named from the warning box.',
      ],
    ),
    (
      icon: Icons.inventory_2_outlined,
      title: 'Inventory',
      lines: [
        'Machines, probes, printers and parts, with search and filters.',
        'Add stock into a batch; the serial becomes a system number when left blank.',
        'A probe or printer can be linked to a machine on the way in.',
        'Stock check: pick the kind, paste the IDs you see one per line, then read the missing and unknown lists.',
        'Open an item for its details, edit, flags, history, return to inventory and delete.',
        'Boxes keep loose probes together. Box moves stay out of the stock list.',
      ],
    ),
    (
      icon: Icons.swap_horiz_outlined,
      title: 'Movements',
      lines: [
        'One card is one party on one day. Each group inside it is one send.',
        'Record movement: pick the items, then the party, date and notes. A machine brings its probes and printer along.',
        'Add another group for each extra send in the same movement.',
        'Sold marks the equipment as sold and records the amount and seller. Paid marks a settled send.',
        'Both are labels for your books; the item status does not change.',
        'Send menu: edit, add item, add group, back to inventory, sold/paid, delete.',
        'Back to inventory takes a whole send or single items. Items that moved on later stay out.',
        'Deleting one movement returns that item; deleting a send erases its rows.',
      ],
    ),
    (
      icon: Icons.receipt_long_outlined,
      title: 'Sales',
      lines: [
        'Every sale, imported and recorded since, in one list.',
        'Filter by date, buyer, item or invoice.',
        'A send marked Sold shows here with its items, amount and seller.',
        'Not sold anymore clears the sold mark and amount; the movement stays.',
        'Imported sales may have no recorded amount.',
      ],
    ),
    (
      icon: Icons.build_outlined,
      title: 'Repairs',
      lines: [
        'New repair: who sent it, the received date, the items and the problem.',
        'Items come from our stock or are typed in from outside.',
        'Status follows the job: received, in repair, returned.',
        'Sending it back records the return date, who collected it and notes.',
        'Money: estimated cost, final cost, money received and who received it.',
      ],
    ),
    (
      icon: Icons.folder_outlined,
      title: 'Records',
      lines: [
        'Admins keep products, brands, vendors, people, batches, boxes and flags here.',
        'A batch sets the vendor and date for the stock entered into it.',
        'Deleting a customer or dealer also removes the sends recorded only for them.',
        'Saved flags can be applied to items, movements and repairs.',
      ],
    ),
    (
      icon: Icons.picture_as_pdf_outlined,
      title: 'Reports',
      lines: [
        'Admins download PDF reports for stock, movements, sales, repairs and boxes.',
        'Choose the report and its dates, then Download PDF.',
        'Each report carries a summary and totals above the table.',
      ],
    ),
    (
      icon: Icons.history_outlined,
      title: 'Old data',
      lines: [
        'The imported system lives on its own side: old stock and old movements.',
        'Switch to it from the menu, and back from the old menu.',
        'Old sales show in the one Sales list on the current side.',
        'Admins can add and correct old rows; the import stays as it came in otherwise.',
      ],
    ),
    (
      icon: Icons.person_outline,
      title: 'My profile',
      lines: [
        'Shows your name, role and the date you joined.',
        'Admins find Records and Reports here.',
        'The menu in the top-right holds the theme switch, the old data and log out.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Manual')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          for (final section in _sections) ...[
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(section.icon, size: 20, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(section.title,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final line in section.lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ',
                              style: TextStyle(color: scheme.outline)),
                          Expanded(
                            child: Text(line,
                                style: const TextStyle(
                                    fontSize: 13.5, height: 1.35)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
