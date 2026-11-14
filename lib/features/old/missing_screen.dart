import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../reports/pdf_download.dart';
import '../reports/report_pdf.dart';
import 'old_data.dart';
import 'old_item_form.dart';
import 'old_table.dart';

/// The Missing page: every machine the physical audit could not find —
/// flagged Missing — with the date it came in, a chip for the ones that
/// arrived in 2026, and a PDF printout of the whole list.
class MissingScreen extends ConsumerStatefulWidget {
  const MissingScreen({super.key});

  @override
  ConsumerState<MissingScreen> createState() => _MissingScreenState();
}

class _MissingScreenState extends ConsumerState<MissingScreen> {
  String _query = '';
  bool _arrivedOnly = false;
  int _page = 0;
  bool _printing = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        oldSearchField(
          context,
          hint: 'Search missing items',
          onChanged: (value) => setState(() {
            _query = value.trim();
            _page = 0;
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: !_arrivedOnly,
                onSelected: (_) => setState(() {
                  _arrivedOnly = false;
                  _page = 0;
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Arrived 2026'),
                selected: _arrivedOnly,
                onSelected: (_) => setState(() {
                  _arrivedOnly = true;
                  _page = 0;
                }),
              ),
            ],
          ),
        ),
        Expanded(
          child: _MissingList(
            search: _query,
            arrivedOnly: _arrivedOnly,
            page: _page,
            onPage: (p) => setState(() => _page = p),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: FilledButton.icon(
            onPressed: _printing ? null : _print,
            icon: _printing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.print_outlined),
            label: const Text('Print PDF'),
          ),
        ),
      ],
    );
  }

  /// Prints the whole missing list: code, model, serial, where the app
  /// thinks it is, the date it came in and whether it arrived in 2026.
  Future<void> _print() async {
    setState(() => _printing = true);
    try {
      final rows = await ref.read(missingAllProvider.future);
      final flags = await ref.read(flagsProvider.future);
      final profile = await ref.read(profileProvider.future);
      final arrivedIds = {
        for (final flag in flags)
          if ('${flag['note'] ?? ''}'.trim() == 'Arrived 2026' &&
              flag['item_id'] is int)
            '${flag['item_kind']}:${flag['item_id']}',
      };
      final by =
          '${profile?['display_name'] ?? profile?['username'] ?? 'Admin'}';
      var arrived = 0;
      final data = <List<String>>[];
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        final didArrive =
            arrivedIds.contains('${row['kind']}:${row['id']}');
        if (didArrive) arrived++;
        data.add([
          '${i + 1}',
          '${row['code'] ?? row['machine_id'] ?? ''}',
          '${row['name'] ?? row['model'] ?? ''}',
          '${row['serial_number'] ?? ''}',
          'Missing',
          '${row['current_location'] ?? ''}',
          '${row['acquisition_date'] ?? '—'}',
          didArrive ? 'Yes' : '',
        ]);
      }
      final bytes = await buildReportPdf(
        title: 'Missing items',
        subtitle: 'Machines the app holds but the physical stock audit '
            'could not find',
        columns: const [
          '#',
          'Code',
          'Model',
          'Serial',
          'Status',
          'Location',
          'Came in',
          'Arrived 2026',
        ],
        data: data,
        generatedBy: by,
        summary: [
          'Missing: ${rows.length}',
          'Arrived in 2026: $arrived',
        ],
      );
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      await downloadPdf(
        bytes,
        'missing_items_${two(now.day)}${two(now.month)}${now.year}.pdf',
      );
    } catch (error) {
      if (!mounted) return;
      showSnack(context, errorMessage(error), error: true);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }
}

class _MissingList extends ConsumerWidget {
  const _MissingList({
    required this.search,
    required this.arrivedOnly,
    required this.page,
    required this.onPage,
  });

  final String search;
  final bool arrivedOnly;
  final int page;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(
      missingMachinesProvider((
        page: page,
        search: search,
        status: 'All',
        flagFilters: arrivedOnly ? const {'note:Arrived 2026'} : const {},
      )),
    );
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (result) => OldTable(
        rows: result.rows,
        total: result.total,
        page: page,
        onPageChanged: onPage,
        emptyMessage: 'No missing items match this search.',
        rowBuilder: (row) => _MissingTile(row: row),
      ),
    );
  }
}

/// One missing item: code, name, the Missing tag, where the app thinks
/// it is and the date it came in. Tapping opens the edit form; the
/// check button records that the item was found and moves it to its
/// dedicated place (workshop, dealer, customer or branch).
class _MissingTile extends ConsumerWidget {
  const _MissingTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code =
        '${row['code'] ?? row['machine_id'] ?? ''}';
    final name = '${row['name'] ?? row['model'] ?? ''}';
    final serial = (row['serial_number'] ?? '').toString();
    final location = (row['current_location'] ?? '').toString();
    final cameIn = (row['acquisition_date'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        onTap: () => showOldItemForm(
          context,
          kind: '${row['kind'] ?? 'machine'}',
          row: row,
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            child: Icon(
              Icons.help_outline,
              color: Theme.of(context).colorScheme.onErrorContainer,
              size: 20,
            ),
          ),
          title: Text(
            code.isEmpty ? (serial.isEmpty ? name : serial) : code,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty && code.isNotEmpty) Text(name),
              const SizedBox(height: 4),
              Row(
                children: [
                  const StatusChip(status: 'Missing'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      [
                        if (serial.isNotEmpty) serial,
                        location,
                        if (cameIn.isNotEmpty) 'Came in $cameIn',
                      ].join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'I found this item',
                icon: Icon(
                  Icons.task_alt,
                  color: Theme.of(context).colorScheme.primary,
                ),
                onPressed: () => _openFoundSheet(context, ref),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFoundSheet(BuildContext context, WidgetRef ref) async {
    final moved = await showAppSheet<bool>(
      context: context,
      title: 'I found this item',
      heightFraction: 0.7,
      builder: (_) => _FoundSheet(row: row),
    );
    if (moved != true) return;
    ref
      ..invalidate(flagsProvider)
      ..invalidate(inventoryProvider)
      ..invalidate(allMovementsProvider)
      ..invalidate(workshopItemsProvider)
      ..invalidate(missingItemsProvider);
    if (context.mounted) {
      showSnack(
        context,
        '${row['code'] ?? row['machine_id'] ?? 'Item'} moved — it is off '
        'the Missing list.',
      );
    }
  }
}

/// The sheet behind the check button: pick where the found item goes —
/// Workshop, Branch, Dealer or Customer — name the party when needed,
/// and one button records the send and clears the Missing flag.
class _FoundSheet extends ConsumerStatefulWidget {
  const _FoundSheet({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_FoundSheet> createState() => _FoundSheetState();
}

class _FoundSheetState extends ConsumerState<_FoundSheet> {
  String _kind = 'Workshop';
  final _target = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final kind = '${widget.row['kind'] ?? 'machine'}';
    final id = widget.row['id'] as int;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final destination = <String, dynamic>{};
      final target = _target.text.trim();
      if (_kind == 'Dealer' && target.isNotEmpty) {
        final (partyId, _) = await findOrCreateParty('dealers', target);
        destination['p_dealer_id'] = partyId;
      } else if (_kind == 'Customer' && target.isNotEmpty) {
        final (partyId, _) = await findOrCreateParty('customers', target);
        destination['p_customer_id'] = partyId;
      }
      await db.rpc(
        'create_movement',
        params: {
          'p_item_type': kind,
          'p_item_id': id,
          'p_kind': _kind,
          ...destination,
          'p_notes': 'Found — taken off the missing list',
        },
      );
      // the status changed with the send, so the Missing flag goes too
      await syncMissingFlag(kind, id, _kind);
      if (!mounted) return;
      Navigator.pop(context, true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _kind == 'Workshop'
                ? 'Sent to the workshop.'
                : 'Sent to ${_kind.toLowerCase()}'
                    '${target.isEmpty ? '' : ' · $target'}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text(errorMessage(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dealerNames = ref
        .watch(dealersProvider)
        .maybeWhen(
          data: (rows) => rows.map((r) => '${r['name']}').toList(),
          orElse: () => const <String>[],
        );
    final customerNames = ref
        .watch(customersProvider)
        .maybeWhen(
          data: (rows) => rows.map((r) => '${r['name']}').toList(),
          orElse: () => const <String>[],
        );
    final code = '${widget.row['code'] ?? widget.row['machine_id'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            code.isEmpty ? '${widget.row['name'] ?? ''}' : code,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Where does it actually sit?',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SendKindGrid(
            selected: _kind,
            onSelected: (value) {
              if (value == _kind) return;
              setState(() {
                _kind = value;
                _target.clear();
              });
            },
          ),
          if (_kind == 'Dealer' || _kind == 'Customer') ...[
            const SizedBox(height: 12),
            PickyField(
              controller: _target,
              label: _kind == 'Dealer' ? 'Dealer' : 'Customer',
              hint: 'Optional — type a new name to add it',
              options: _kind == 'Dealer' ? dealerNames : customerNames,
              pickTitle: _kind == 'Dealer' ? 'dealers' : 'customers',
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.task_alt),
            label: Text(
              _kind == 'Workshop'
                  ? 'Put it in the workshop'
                  : 'Send it to ${_kind.toLowerCase()}',
            ),
          ),
        ],
      ),
    );
  }
}
