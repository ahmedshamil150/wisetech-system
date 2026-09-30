import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// Every recorded move, newest first.
/// Both admins and viewers can record a movement; only admins can edit data.
class MovementsScreen extends ConsumerStatefulWidget {
  const MovementsScreen({super.key});

  @override
  ConsumerState<MovementsScreen> createState() => _MovementsScreenState();
}

const _filters = ['All', 'Workshop', 'Dealer', 'Customer'];

class _MovementsScreenState extends ConsumerState<MovementsScreen> {
  String _filter = 'All';
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final movements = ref.watch(movementsProvider);
    final labels = ref.watch(itemLabelsProvider);

    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            itemCount: _filters.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final label = _filters[index];
              final selected = _filter == label;
              return ChoiceChip(
                label: Text(label),
                selected: selected,
                onSelected: (_) => setState(() => _filter = label),
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : kMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFFE2E9F0)),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SearchField(
            hint: 'Search by item, location or reference',
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: movements.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
                icon: Icons.error_outline, message: errorMessage(error)),
            data: (rows) {
              final byKind = rows.where((row) {
                final kind = (row['movement_type'] ?? '').toString();
                return _filter == 'All' || kind == _filter;
              }).toList();

              // rows that travelled together (same invoice) stay in one card
              final entries = <List<Map<String, dynamic>>>[];
              final groups = <String, List<Map<String, dynamic>>>{};
              for (final row in byKind) {
                final group = (row['group_ref'] ?? '').toString();
                if (group.isEmpty) {
                  entries.add([row]);
                } else {
                  groups.putIfAbsent(group, () {
                    final members = <Map<String, dynamic>>[];
                    entries.add(members);
                    return members;
                  }).add(row);
                }
              }

              bool matches(Map<String, dynamic> row) {
                if (_query.isEmpty) return true;
                final label = _labelFor(row, labels).toLowerCase();
                final to = (row['to_location'] ?? '').toString().toLowerCase();
                final refNumber =
                    (row['reference'] ?? '').toString().toLowerCase();
                return label.contains(_query) ||
                    to.contains(_query) ||
                    refNumber.contains(_query);
              }

              final visible = entries.where((e) => e.any(matches)).toList();
              if (visible.isEmpty) {
                return const EmptyState(
                    icon: Icons.alt_route_outlined,
                    message: 'No movements recorded yet.');
              }
              for (final members in visible) {
                members.sort(_mainItemFirst);
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: visible.length,
                itemBuilder: (context, index) =>
                    _tile(context, visible[index], labels),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: FilledButton.icon(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (sheetContext) => Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
                child: const _NewMovementForm(),
              ),
            ),
            icon: const Icon(Icons.add),
            label: const Text('New movement'),
          ),
        ),
      ],
    );
  }

  String _labelFor(Map<String, dynamic> row, Map<String, String> labels) {
    final key = _itemKey(row);
    if (key == null) return 'Unknown item';
    return labels['${key.key}:${key.value}'] ?? 'Unknown item';
  }

  Widget _tile(BuildContext context, List<Map<String, dynamic>> rows,
      Map<String, String> labels) {
    final row = rows.first;
    final kind = (row['movement_type'] ?? '').toString();
    final icon = switch (kind) {
      'Workshop' => Icons.build_outlined,
      'Dealer' => Icons.handshake_outlined,
      _ => Icons.person_outline,
    };
    final label = _labelFor(row, labels);
    final actor = row['profiles'];
    final actorName = actor is Map
        ? ((actor['display_name'] ?? actor['username'] ?? '').toString())
        : '';
    final reference = (row['reference'] ?? '').toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: const Color(0xFFEAF3F8),
                child: Icon(icon, color: Theme.of(context).colorScheme.primary),
              ),
              title: Text('$label → ${row['to_location'] ?? ''}',
                  style:
                      const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Text([
                    row['movement_date'] ?? '',
                    kind,
                    if (actorName.isNotEmpty) 'by $actorName',
                    if (reference.isNotEmpty) reference,
                  ].join(' · ')),
                ],
              ),
            ),
            for (final other in rows.skip(1))
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.subdirectory_arrow_right,
                        size: 16, color: kHint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_labelFor(other, labels),
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: 13, color: kMuted)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// `machine:12` style key used by [itemLabelsProvider].
  static MapEntry<String, int>? _itemKey(Map<String, dynamic> row) {
    for (final kind in kItemKinds) {
      final id = row['${kind}_id'];
      if (id is int) return MapEntry(kind, id);
    }
    return null;
  }
}

/// Within one group the machine comes first, then its printer and probes,
/// then the loose parts.
int _mainItemFirst(Map<String, dynamic> a, Map<String, dynamic> b) {
  final byRank = _rankOf(a).compareTo(_rankOf(b));
  if (byRank != 0) return byRank;
  return (a['id'] as int).compareTo(b['id'] as int);
}

int _rankOf(Map<String, dynamic> row) {
  if (row['machine_id'] != null) return 0;
  if (row['printer_id'] != null) return 1;
  if (row['probe_id'] != null) return 2;
  if (row['part_id'] != null) return 3;
  return 4;
}

// ---------------------------------------------------------------------------
// new movement
// ---------------------------------------------------------------------------

class _NewMovementForm extends ConsumerStatefulWidget {
  const _NewMovementForm();

  @override
  ConsumerState<_NewMovementForm> createState() => _NewMovementFormState();
}

class _NewMovementFormState extends ConsumerState<_NewMovementForm> {
  /// Everything that leaves: the machine plus its probes and printer by
  /// default — add or remove items before recording the movement.
  final List<InventoryItem> _selection = [];
  String _kind = 'Workshop';
  final _target = TextEditingController();
  final _date = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _date.text = DateField.format(DateTime.now());
  }

  @override
  void dispose() {
    for (final c in [_target, _date, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Picking a machine also brings its probes and printer along.
  Future<void> _pickAndAdd(List<InventoryItem> available) async {
    final picked = await showPickItem(
      context,
      items: available,
      selectedKey: _selection.isEmpty ? null : _selection.first.key,
    );
    if (picked == null) return;
    setState(() {
      final additions =
          picked.kind == 'machine' ? kitFor(available, picked) : [picked];
      final keys = _selection.map((item) => item.key).toSet();
      for (final item in additions) {
        if (!keys.contains(item.key)) {
          _selection.add(item);
          keys.add(item.key);
        }
      }
    });
  }

  Future<int> _idFor(String table, String name) async {
    final rows = await db
        .from(table)
        .select('id')
        .eq('name', name)
        .order('id')
        .limit(1);
    if (rows.isEmpty) {
      throw Exception('${table == 'dealers' ? 'Dealer' : 'Customer'} '
          '"$name" was not found. Add it first on the Records page.');
    }
    return rows.first['id'] as int;
  }

  Future<void> _save() async {
    if (_selection.isEmpty) {
      showSnack(context, 'Choose what you are sending.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final destination = <String, dynamic>{};
      if (_kind == 'Dealer') {
        destination['p_dealer_id'] = await _idFor('dealers', _target.text.trim());
      } else if (_kind == 'Customer') {
        destination['p_customer_id'] =
            await _idFor('customers', _target.text.trim());
      }

      for (final item in _selection) {
        await db.rpc('create_movement', params: {
          'p_item_type': item.kind,
          'p_item_id': item.id,
          'p_kind': _kind,
          ...destination,
          if (_date.text.trim().isNotEmpty) 'p_date': _date.text.trim(),
          if (_notes.text.trim().isNotEmpty) 'p_notes': _notes.text.trim(),
        });
      }

      ref
        ..invalidate(movementsProvider)
        ..invalidate(inventoryProvider);
      if (!mounted) return;
      Navigator.pop(context);
      final where = _kind == 'Workshop'
          ? 'the workshop'
          : _target.text.trim();
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${_selection.length} item(s) sent to $where.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) =>
              rows.where((i) => i.status != 'Sold' && i.status != 'Archived').toList(),
          orElse: () => const <InventoryItem>[],
        );
    final dealerNames = ref.watch(dealersProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );
    final customerNames = ref.watch(customersProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('New movement',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Items to send *',
                      style: TextStyle(fontSize: 13, color: kMuted)),
                  const SizedBox(height: 6),
                  AppCard(
                    child: Column(
                      children: [
                        if (_selection.isEmpty)
                          ListTile(
                            leading: const Icon(Icons.search),
                            title: const Text('Choose an item',
                                style: TextStyle(color: kHint)),
                            subtitle: const Text(
                                'Pick a machine and its probes and printer '
                                'come with it'),
                            onTap: () => _pickAndAdd(items),
                          )
                        else ...[
                          for (final item in _selection)
                            ListTile(
                              dense: true,
                              title: Text('${item.code}  ${item.title}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13.5)),
                              subtitle:
                                  Text('${item.kindLabel} · ${item.status}'),
                              trailing: IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => setState(
                                    () => _selection.remove(item)),
                              ),
                            ),
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.add, size: 20),
                            title: const Text('Add another item',
                                style: TextStyle(fontSize: 14)),
                            onTap: () => _pickAndAdd(items),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Sent to *',
                      style: TextStyle(fontSize: 13, color: kMuted)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'Workshop',
                          label: Text('Workshop'),
                          icon: Icon(Icons.build_outlined, size: 18)),
                      ButtonSegment(
                          value: 'Dealer',
                          label: Text('Dealer'),
                          icon: Icon(Icons.handshake_outlined, size: 18)),
                      ButtonSegment(
                          value: 'Customer',
                          label: Text('Customer'),
                          icon: Icon(Icons.person_outline, size: 18)),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (value) => setState(() {
                      _kind = value.first;
                      _target.clear();
                    }),
                  ),
                  const SizedBox(height: 16),
                  if (_kind == 'Workshop')
                    const AppCard(
                      padding: EdgeInsets.all(14),
                      child: Text('The company workshop (single location).',
                          style: TextStyle(color: kMuted, fontSize: 13.5)),
                    )
                  else if (_kind == 'Dealer')
                    PickyField(
                      controller: _target,
                      label: 'Dealer *',
                      hint: 'Search dealers',
                      options: dealerNames,
                      pickTitle: 'dealers',
                    )
                  else
                    PickyField(
                      controller: _target,
                      label: 'Customer *',
                      hint: 'Search customers',
                      options: customerNames,
                      pickTitle: 'customers',
                    ),
                  const SizedBox(height: 12),
                  DateField(controller: _date, label: 'Date'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Record movement'),
          ),
        ],
      ),
    );
  }
}
