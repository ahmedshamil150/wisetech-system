import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../inventory/inventory_screen.dart';

/// Every recorded move, newest first.
/// Both admins and viewers can record a movement; only admins can edit data.
class MovementsScreen extends ConsumerStatefulWidget {
  const MovementsScreen({super.key});

  @override
  ConsumerState<MovementsScreen> createState() => _MovementsScreenState();
}

const _filters = ['All', 'Workshop', 'Branch', 'Dealer', 'Customer', 'Returned'];

class _MovementsScreenState extends ConsumerState<MovementsScreen> {
  String _filter = 'All';
  String _query = '';
  String _party = 'All'; // customer or dealer name, or 'All'
  String _actor = 'All'; // who sent it, or 'All'
  String _kind = 'All'; // Machine / Probe / Printer / Part, or 'All'
  DateTime? _date;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _hasFilters =>
      _party != 'All' ||
      _actor != 'All' ||
      _kind != 'All' ||
      _date != null ||
      _query.isNotEmpty;

  void _clearFilters() {
    _search.clear();
    setState(() {
      _party = 'All';
      _actor = 'All';
      _kind = 'All';
      _date = null;
      _query = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final movements = ref.watch(movementsProvider);
    final labels = ref.watch(itemLabelsProvider);
    final rows = movements.maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final counts = _groupCounts(rows, labels);

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
                label: Text('$label (${counts[label] ?? 0})'),
                selected: selected,
                onSelected: (_) => setState(() {
                  _filter = label;
                  _party = 'All';
                }),
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                backgroundColor: context.colors.isDark
                    ? context.colors.quietFill
                    : Theme.of(context).colorScheme.surface,
                side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
              );
            },
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            children: [
              if (_filter == 'Customer' || _filter == 'Dealer')
                _menuChip(
                  icon: Icons.person_outline,
                  label: _party == 'All'
                      ? (_filter == 'Customer' ? 'Any customer' : 'Any dealer')
                      : _party,
                  active: _party != 'All',
                  entries: [
                    _menuOption('All',
                        _filter == 'Customer' ? 'Any customer' : 'Any dealer',
                        selected: _party == 'All'),
                    for (final name in _partyOptions(rows))
                      _menuOption(name, name, selected: _party == name),
                  ],
                  onSelected: (value) => setState(() => _party = value),
                ),
              _menuChip(
                icon: Icons.supervisor_account_outlined,
                label: _actor == 'All' ? 'Anyone' : _actor,
                active: _actor != 'All',
                entries: [
                  _menuOption('All', 'Anyone', selected: _actor == 'All'),
                  for (final name in _actorOptions(rows))
                    _menuOption(name, name, selected: _actor == name),
                ],
                onSelected: (value) => setState(() => _actor = value),
              ),
              _menuChip(
                icon: Icons.category_outlined,
                label: _kind == 'All' ? 'Any item' : _kind,
                active: _kind != 'All',
                entries: [
                  _menuOption('All', 'Any item', selected: _kind == 'All'),
                  for (final kind in _kindOptions(rows))
                    _menuOption(kind, '${kind}s', selected: _kind == kind),
                ],
                onSelected: (value) => setState(() => _kind = value),
              ),
              _dateChip(rows),
              if (_hasFilters)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _clearFilters,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: context.colors.errorContainer,
                        borderRadius: BorderRadius.circular(20),
                        border:
                            Border.all(color: context.colors.errorBorder),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.close,
                              size: 14, color: Theme.of(context).colorScheme.error),
                          SizedBox(width: 4),
                          Text('Reset',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.error)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: SearchField(
            controller: _search,
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
            data: (allRows) {
              // the latest movement of an item decides whether it is
              // already back in stock
              final latest = <String, Map<String, dynamic>>{};
              for (final row in allRows) {
                final key = _itemKey(row);
                if (key == null) continue;
                final mapKey = '${key.key}:${key.value}';
                final seen = latest[mapKey];
                if (seen == null || (row['id'] as int) > (seen['id'] as int)) {
                  latest[mapKey] = row;
                }
              }
              bool isBack(Map<String, dynamic> row) {
                final key = _itemKey(row);
                if (key == null) return false;
                final last = latest['${key.key}:${key.value}'];
                return last != null && last['movement_type'] == 'Return';
              }

              // Return rows are history, not cards — they show in the
              // item details instead
              final sends = allRows
                  .where((row) => row['movement_type'] != 'Return')
                  .toList();
              final filtered = sends.where((row) => _passes(row)).toList();

              // rows that travelled together (same invoice) stay in one card
              final entries = <List<Map<String, dynamic>>>[];
              final groups = <String, List<Map<String, dynamic>>>{};
              for (final row in filtered) {
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

              // a send sits in 'Returned' once every item of it is back —
              // everywhere else only sends that are still out are shown
              final visible = <List<Map<String, dynamic>>>[];
              for (final members in entries) {
                final back = members.every(isBack);
                if (back != (_filter == 'Returned')) continue;
                if (!back &&
                    _filter != 'All' &&
                    members.first['movement_type'] != _filter) {
                  continue;
                }
                if (_query.isNotEmpty &&
                    !members.any((row) => _searchMatches(row, labels))) {
                  continue;
                }
                visible.add(members);
              }
              if (visible.isEmpty) {
                return EmptyState(
                    icon: Icons.alt_route_outlined,
                    message: _filter == 'Returned'
                        ? 'No sends are back in inventory yet.'
                        : _hasFilters
                            ? 'No movements match these filters.'
                            : 'No movements recorded yet.');
              }
              for (final members in visible) {
                members.sort(_mainItemFirst);
              }
              final shown =
                  visible.fold<int>(0, (sum, members) => sum + members.length);
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                          '$shown movement${shown == 1 ? '' : 's'}',
                          style: TextStyle(
                              fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                  ),
                  Expanded(
                    child: AppRefresh(
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final members = visible[index];
                          return _tile(context, members, labels,
                              back: members.every(isBack));
                        },
                      ),
                    ),
                  ),
                ],
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

  // -----------------------------------------------------------------------
  // filters
  // -----------------------------------------------------------------------

  /// How many send cards every tab would show with the other filters
  /// (party, actor, item kind, date, search) kept as they are.
  Map<String, int> _groupCounts(
      List<Map<String, dynamic>> allRows, Map<String, String> labels) {
    final latest = <String, Map<String, dynamic>>{};
    for (final row in allRows) {
      final key = _itemKey(row);
      if (key == null) continue;
      final mapKey = '${key.key}:${key.value}';
      final seen = latest[mapKey];
      if (seen == null || (row['id'] as int) > (seen['id'] as int)) {
        latest[mapKey] = row;
      }
    }
    bool isBack(Map<String, dynamic> row) {
      final key = _itemKey(row);
      if (key == null) return false;
      final last = latest['${key.key}:${key.value}'];
      return last != null && last['movement_type'] == 'Return';
    }

    // rows that travelled together stay in one card, as in the list
    final entries = <List<Map<String, dynamic>>>[];
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final row in allRows) {
      if (row['movement_type'] == 'Return') continue;
      if (!_passes(row)) continue;
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

    final counts = <String, int>{for (final f in _filters) f: 0};
    for (final members in entries) {
      final back = members.every(isBack);
      for (final filter in _filters) {
        if (back != (filter == 'Returned')) continue;
        if (!back &&
            filter != 'All' &&
            members.first['movement_type'] != filter) {
          continue;
        }
        if (_query.isNotEmpty &&
            !members.any((row) => _searchMatches(row, labels))) {
          continue;
        }
        counts[filter] = counts[filter]! + 1;
      }
    }
    return counts;
  }

  bool _passes(Map<String, dynamic> row) {
    if (_party != 'All' &&
        (row['to_location'] ?? '').toString() != _party) {
      return false;
    }
    if (_actor != 'All' && _actorOf(row) != _actor) return false;
    if (_kind != 'All' && _kindOf(row) != _kind) return false;
    if (_date != null &&
        (row['movement_date'] ?? '').toString() != DateField.format(_date!)) {
      return false;
    }
    return true;
  }

  bool _searchMatches(Map<String, dynamic> row, Map<String, String> labels) {
    if (_query.isEmpty) return true;
    final label = _labelFor(row, labels).toLowerCase();
    final to = (row['to_location'] ?? '').toString().toLowerCase();
    final refNumber = (row['reference'] ?? '').toString().toLowerCase();
    return label.contains(_query) ||
        to.contains(_query) ||
        refNumber.contains(_query);
  }

  String _actorOf(Map<String, dynamic> row) {
    final actor = row['profiles'];
    return actor is Map
        ? ((actor['display_name'] ?? actor['username'] ?? '').toString())
        : '';
  }

  String _kindOf(Map<String, dynamic> row) => switch (_rankOf(row)) {
        0 => 'Machine',
        1 => 'Printer',
        2 => 'Probe',
        3 => 'Part',
        _ => 'Other',
      };

  List<String> _partyOptions(List<Map<String, dynamic>> rows) {
    final names = <String>{};
    for (final row in rows) {
      if ((row['movement_type'] ?? '').toString() != _filter) continue;
      final name = (row['to_location'] ?? '').toString();
      if (name.isNotEmpty) names.add(name);
    }
    return names.toList()..sort(_byText);
  }

  List<String> _actorOptions(List<Map<String, dynamic>> rows) {
    final names = <String>{};
    for (final row in rows) {
      final name = _actorOf(row);
      if (name.isNotEmpty) names.add(name);
    }
    return names.toList()..sort(_byText);
  }

  List<String> _kindOptions(List<Map<String, dynamic>> rows) {
    final present = rows.map(_kindOf).toSet();
    return [
      for (final kind in ['Machine', 'Printer', 'Probe', 'Part', 'Other'])
        if (present.contains(kind)) kind,
    ];
  }

  List<String> _dateOptions(List<Map<String, dynamic>> rows) {
    final dates = <String, DateTime>{};
    for (final row in rows) {
      final text = (row['movement_date'] ?? '').toString();
      final parsed = _parseDateText(text);
      if (parsed != null) dates[text] = parsed;
    }
    final list = dates.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final entry in list.take(12)) entry.key];
  }

  Widget _menuChip({
    required IconData icon,
    required String label,
    required bool active,
    required List<PopupMenuEntry<String>> entries,
    required ValueChanged<String> onSelected,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    final color = active ? primary : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PopupMenuButton<String>(
        onSelected: onSelected,
        itemBuilder: (context) => entries,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: active ? primary.withValues(alpha: 0.10) : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: active ? primary : Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: color)),
              ),
              Icon(Icons.arrow_drop_down, size: 16, color: color),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuOption(String value, String text,
      {bool selected = false}) {
    final primary = Theme.of(context).colorScheme.primary;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          if (selected) ...[
            Icon(Icons.check, size: 16, color: primary),
            const SizedBox(width: 8),
          ] else
            const SizedBox(width: 24),
          Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _dateChip(List<Map<String, dynamic>> rows) {
    final active = _date != null;
    return _menuChip(
      icon: Icons.calendar_today_outlined,
      label: active ? DateField.format(_date!) : 'Any date',
      active: active,
      entries: [
        _menuOption('__any', 'Any date', selected: !active),
        _menuOption('__pick', 'Pick a date…'),
        for (final text in _dateOptions(rows))
          _menuOption(text, text,
              selected: active && text == DateField.format(_date!)),
      ],
      onSelected: (value) {
        if (value == '__any') {
          setState(() => _date = null);
        } else if (value == '__pick') {
          _pickDate();
        } else {
          setState(() => _date = _parseDateText(value));
        }
      },
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime.now(),
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }

  static DateTime? _parseDateText(String text) {
    final parts = text.split('-');
    if (parts.length != 3) return null;
    final day = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final year = int.tryParse(parts[2]);
    if (day == null || month == null || year == null) return null;
    return DateTime(year, month, day);
  }

  String _labelFor(Map<String, dynamic> row, Map<String, String> labels) {
    final key = _itemKey(row);
    if (key == null) return 'Unknown item';
    return labels['${key.key}:${key.value}'] ?? 'Unknown item';
  }

  Widget _tile(BuildContext context, List<Map<String, dynamic>> rows,
      Map<String, String> labels,
      {required bool back}) {
    final row = rows.first;
    final kind = (row['movement_type'] ?? '').toString();
    final icon = switch (kind) {
      'Workshop' => Icons.build_outlined,
      'Branch' => Icons.storefront_outlined,
      'Dealer' => Icons.handshake_outlined,
      _ => Icons.person_outline,
    };
    final label = _labelFor(row, labels);
    final actor = row['profiles'];
    final actorName = actor is Map
        ? ((actor['display_name'] ?? actor['username'] ?? '').toString())
        : '';
    final reference = (row['reference'] ?? '').toString();
    final isDemo = row['is_demo'] == true;

    // dealer/customer sends recorded without their name can get it later
    final myId = ref.read(authControllerProvider).currentUser?.id;
    final isAdmin = ref.read(isAdminProvider);
    final missing = rows.where(movementPartyMissing).toList();
    final canFixParty = missing.isNotEmpty &&
        (isAdmin || missing.any((r) => r['actor_id'] == myId));
    final canManage = isAdmin || rows.any((r) => r['actor_id'] == myId);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: Column(
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: context.colors.tintBlue,
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
                    if (isDemo) 'Demo',
                    if (actorName.isNotEmpty) 'by $actorName',
                    if (reference.isNotEmpty) reference,
                  ].join(' · ')),
                ],
              ),
              trailing: Icon(Icons.chevron_right, size: 20, color: Theme.of(context).colorScheme.outline),
              onTap: () => _openItem(rows.first),
            ),
            if (canFixParty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => showAddPartySheet(context, ref, rows),
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: Text(
                        'Add the ${kind.toLowerCase()} name'),
                  ),
                ),
              ),
            if (back)
              Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 15, color: context.colors.success),
                    SizedBox(width: 6),
                    Text('Back in inventory',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: context.colors.success)),
                  ],
                ),
              ),
            if (canManage)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Row(
                  children: [
                    if (!back)
                      TextButton.icon(
                        onPressed: rows.length > 1
                            ? () => _showReturnSheet(rows)
                            : () => _returnGroup(rows),
                        icon: const Icon(Icons.login_outlined, size: 18),
                        label: const Text('Back to inventory'),
                      ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _deleteGroup(rows),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                      style: TextButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error),
                    ),
                  ],
                ),
              ),
            for (final other in rows.skip(1))
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openItem(other),
                child: Padding(
                  padding:
                      const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                  child: Row(
                    children: [
                      Icon(Icons.subdirectory_arrow_right,
                          size: 16, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_labelFor(other, labels),
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ),
                      if (other['is_demo'] == true)
                        Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Text('Demo',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.outline)),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Opens the same details sheet the inventory list uses — tappable from
  /// every movement, in every tab.
  void _openItem(Map<String, dynamic> row) {
    final key = _itemKey(row);
    if (key == null) return;
    final items = ref.read(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
        );
    for (final item in items) {
      if (item.key == '${key.key}:${key.value}') {
        showItemDetails(context, ref, item);
        return;
      }
    }
    showSnack(context, 'This item is no longer in the inventory.',
        error: true);
  }

  /// Puts every item of this send back into stock. An item that moved on
  /// to a later send is left alone — only its own last movement decides.
  Future<void> _returnGroup(List<Map<String, dynamic>> rows) async {
    final allMovements = ref.read(movementsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final items = ref.read(inventoryProvider).maybeWhen(
        data: (value) => value, orElse: () => const <InventoryItem>[]);
    final groupIds = {for (final row in rows) row['id'] as int};

    final latest = <String, int>{}; // item key -> latest movement id
    for (final row in allMovements) {
      final key = _itemKey(row);
      if (key == null) continue;
      final mapKey = '${key.key}:${key.value}';
      final id = row['id'] as int;
      final seen = latest[mapKey];
      if (seen == null || id > seen) latest[mapKey] = id;
    }

    var count = 0;
    String? failure;
    try {
      for (final row in rows) {
        final key = _itemKey(row);
        if (key == null) continue;
        final mapKey = '${key.key}:${key.value}';
        if (!groupIds.contains(latest[mapKey])) continue;
        InventoryItem? item;
        for (final candidate in items) {
          if (candidate.key == mapKey) {
            item = candidate;
            break;
          }
        }
        if (item == null) continue;
        await returnToInventory(item);
        count++;
      }
    } catch (error) {
      failure = errorMessage(error);
    } finally {
      ref.invalidate(movementsProvider);
      ref.invalidate(inventoryProvider);
    }
    if (!mounted) return;
    showSnack(
        context,
        failure ??
            (count == 0
                ? 'Nothing to return — these items moved on.'
                : '$count item${count == 1 ? '' : 's'} back in inventory.'),
        error: failure != null);
  }

  /// Opens the tick-list sheet for a multi-item send: the sender picks
  /// which of the items actually came back; the rest stay out.
  void _showReturnSheet(List<Map<String, dynamic>> rows) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: _ReturnFromSendSheet(rows: rows),
      ),
    );
  }

  /// Erases this send completely: the movement history is gone, the
  /// items simply live in the inventory again, and a customer/dealer
  /// added with this send is deleted too when nothing else uses it.
  Future<void> _deleteGroup(List<Map<String, dynamic>> rows) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this send?'),
        content: const Text(
            'The movement is erased from the history and the items stay '
            'in the inventory. A customer or dealer added with this send '
            'is deleted too when nothing else uses it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await deleteMovement(rows.first['id'] as int);
      ref.invalidate(movementsProvider);
      ref.invalidate(inventoryProvider);
      ref.invalidate(customersProvider);
      ref.invalidate(dealersProvider);
      ref.invalidate(recentPartiesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Send deleted.')));
    } catch (error) {
      messenger
          .showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
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

int _byText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

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

/// Where a send's member stands right now: still out with this send,
/// already back, or moved on to a later movement.
enum _SendRowState { out, back, movedOn }

/// Partial (or full) return from a send — a customer sends one or two
/// machines back while the others stay with them. Everything still out
/// is ticked by default; untick what is not coming, set the date and
/// notes, and only the ticked items go back to stock.
class _ReturnFromSendSheet extends ConsumerStatefulWidget {
  const _ReturnFromSendSheet({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  ConsumerState<_ReturnFromSendSheet> createState() =>
      _ReturnFromSendSheetState();
}

class _ReturnFromSendSheetState extends ConsumerState<_ReturnFromSendSheet> {
  final _date = TextEditingController();
  final _notes = TextEditingController();
  final _selected = <int>{}; // movement-row ids ticked to come back
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _date.text = DateField.format(DateTime.now());
    // everything still out with this send starts ticked, so a plain
    // "everything is back" case is one tap like it always was
    for (final row in widget.rows) {
      if (_stateOf(row) == _SendRowState.out) {
        _selected.add(row['id'] as int);
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_date, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, Map<String, dynamic>> _latestByItem() {
    final movements = ref.read(movementsProvider).maybeWhen(
          data: (value) => value,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final latest = <String, Map<String, dynamic>>{};
    for (final row in movements) {
      final key = _MovementsScreenState._itemKey(row);
      if (key == null) continue;
      final mapKey = '${key.key}:${key.value}';
      final id = row['id'] as int;
      final seen = latest[mapKey];
      if (seen == null || id > (seen['id'] as int)) latest[mapKey] = row;
    }
    return latest;
  }

  _SendRowState _stateOf(Map<String, dynamic> row) {
    final key = _MovementsScreenState._itemKey(row);
    if (key == null) return _SendRowState.movedOn;
    final last = _latestByItem()['${key.key}:${key.value}'];
    if (last == null) return _SendRowState.out;
    if (last['movement_type'] == 'Return') return _SendRowState.back;
    if (last['id'] == row['id']) return _SendRowState.out;
    return _SendRowState.movedOn;
  }

  Future<void> _returnSelected(
      Map<String, InventoryItem> itemsByKey) async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    var count = 0;
    String? failure;
    try {
      for (final row in widget.rows) {
        if (!_selected.contains(row['id'] as int)) continue;
        final key = _MovementsScreenState._itemKey(row);
        if (key == null) continue;
        final item = itemsByKey['${key.key}:${key.value}'];
        if (item == null) continue;
        await returnToInventory(item,
            date: _date.text.trim(), notes: _notes.text.trim());
        count++;
      }
    } catch (error) {
      failure = errorMessage(error);
    } finally {
      ref.invalidate(movementsProvider);
      ref.invalidate(inventoryProvider);
    }
    if (!mounted) return;
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(
        content: Text(failure ??
            '$count item${count == 1 ? '' : 's'} back in inventory.')));
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(inventoryProvider).maybeWhen(
          data: (value) => value,
          orElse: () => const <InventoryItem>[],
        );
    final itemsByKey = {for (final item in items) item.key: item};
    final labels = ref.watch(itemLabelsProvider);

    String labelOf(Map<String, dynamic> row) {
      final key = _MovementsScreenState._itemKey(row);
      if (key == null) return 'Unknown item';
      return labels['${key.key}:${key.value}'] ?? 'Unknown item';
    }

    final outRows =
        widget.rows.where((r) => _stateOf(r) == _SendRowState.out).toList();
    final backRows =
        widget.rows.where((r) => _stateOf(r) == _SendRowState.back).toList();
    final movedRows = widget.rows
        .where((r) => _stateOf(r) == _SendRowState.movedOn)
        .toList();

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Back to inventory',
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
            Text(
                'Tick the items that came back — the rest of the send stays '
                'out with them.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 8),
            for (final row in outRows)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _selected.contains(row['id'] as int),
                onChanged: _saving
                    ? null
                    : (_) => setState(() {
                          final id = row['id'] as int;
                          if (!_selected.remove(id)) _selected.add(id);
                        }),
                title: Text(labelOf(row),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            for (final row in backRows)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading:
                    Icon(Icons.check_circle, size: 20, color: context.colors.success),
                title: Text(labelOf(row),
                    style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                subtitle: Text('Already back in inventory',
                    style: TextStyle(fontSize: 12, color: context.colors.success)),
              ),
            for (final row in movedRows)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.swap_horiz, size: 20, color: Theme.of(context).colorScheme.outline),
                title: Text(labelOf(row),
                    style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                subtitle: Text('Moved on with a later movement',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
              ),
            const SizedBox(height: 8),
            DateField(controller: _date, label: 'Date they came back'),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: (_saving || _selected.isEmpty)
                  ? null
                  : () => _returnSelected(itemsByKey),
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('Return ${_selected.length} item'
                      '${_selected.length == 1 ? '' : 's'}'),
            ),
          ],
        ),
      ),
    );
  }
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
  bool _demo = false;
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

  /// Finds the party by name or adds it — any member may add a
  /// customer/dealer (see 0011_party_add_and_audit.sql). Returns the id
  /// and whether this call created the record.
  Future<(int id, bool created)> _findOrCreate(
      String table, String name) async {
    final rows = await db
        .from(table)
        .select('id')
        .eq('name', name)
        .order('id')
        .limit(1);
    if (rows.isNotEmpty) return (rows.first['id'] as int, false);
    final inserted =
        await db.from(table).insert({'name': name}).select('id').single();
    return (inserted['id'] as int, true);
  }

  /// One selectable tile in the 2x2 "Sent to" grid.
  Widget _kindTile(BuildContext context, String value, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _kind == value;
    return Material(
      color: selected
          ? scheme.primary
          : context.colors.quietFill,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() {
          _kind = value;
          _target.clear();
          _demo = false;
        }),
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 18,
                  color: selected ? scheme.onPrimary : scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(value,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: selected ? scheme.onPrimary : scheme.onSurface)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_selection.isEmpty) {
      showSnack(context, 'Choose what you are sending.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // the name is optional: an unnamed send lands on 'Dealer' /
      // 'Customer' and the name can be added later. A name typed here
      // that is not in the records yet is added to them on save —
      // any member may add a customer/dealer (see 0011 migration).
      final target = _target.text.trim();
      final destination = <String, dynamic>{};
      var newParty = false;
      if (_kind == 'Dealer' && target.isNotEmpty) {
        final (id, created) = await _findOrCreate('dealers', target);
        destination['p_dealer_id'] = id;
        newParty = created;
      } else if (_kind == 'Customer' && target.isNotEmpty) {
        final (id, created) = await _findOrCreate('customers', target);
        destination['p_customer_id'] = id;
        newParty = created;
      }

      // one group for the whole send: one card in the list, one name
      // to add later
      final groupRef = _newGroupRef();

      for (final item in _selection) {
        await db.rpc('create_movement', params: {
          'p_item_type': item.kind,
          'p_item_id': item.id,
          'p_kind': _kind,
          ...destination,
          if (_date.text.trim().isNotEmpty) 'p_date': _date.text.trim(),
          if (_notes.text.trim().isNotEmpty) 'p_notes': _notes.text.trim(),
          'p_demo': _demo,
          'p_group_ref': groupRef,
        });
      }

      ref
        ..invalidate(movementsProvider)
        ..invalidate(inventoryProvider);
      if (newParty) {
        ref
          ..invalidate(_kind == 'Dealer' ? dealersProvider : customersProvider)
          ..invalidate(recentPartiesProvider);
      }
      if (!mounted) return;
      Navigator.pop(context);
      final where = _kind == 'Workshop'
          ? 'the workshop'
          : _kind == 'Branch'
              ? 'the Lahore branch'
              : target.isEmpty
                  ? (_kind == 'Dealer' ? 'a dealer' : 'a customer')
                  : target;
      final added = newParty ? ' — $target added to the records' : '';
      final pending = target.isEmpty &&
              _kind != 'Workshop' &&
              _kind != 'Branch'
          ? ' — add the name later'
          : '';
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${_selection.length} item(s) sent to $where$added$pending'
              '${_demo ? ' (demo)' : ''}.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  /// One group per save loop, so every item of this send travels together.
  String _newGroupRef() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final salt = Random.secure().nextInt(0xFFFFFF).toRadixString(16);
    return '$time$salt';
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
                  Text('Items to send *',
                      style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  AppCard(
                    child: Column(
                      children: [
                        if (_selection.isEmpty)
                          ListTile(
                            leading: const Icon(Icons.search),
                            title: Text('Choose an item',
                                style: TextStyle(color: Theme.of(context).colorScheme.outline)),
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
                  Text('Sent to *',
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  // Two per row — four side by side is too tight on a phone.
                  Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                              child: _kindTile(context, 'Workshop',
                                  Icons.build_outlined)),
                          const SizedBox(width: 10),
                          Expanded(
                              child: _kindTile(
                                  context, 'Branch', Icons.storefront_outlined)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                              child: _kindTile(
                                  context, 'Dealer', Icons.handshake_outlined)),
                          const SizedBox(width: 10),
                          Expanded(
                              child: _kindTile(
                                  context, 'Customer', Icons.person_outline)),
                        ],
                      ),
                    ],
                  ),
                  if (_kind == 'Dealer' || _kind == 'Customer') ...[
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: _demo
                            ? Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.07)
                            : context.colors.quietFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: _demo
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outlineVariant),
                      ),
                      child: SwitchListTile.adaptive(
                        value: _demo,
                        onChanged: (value) =>
                            setState(() => _demo = value),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 2),
                        title: const Text('Send as demo',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        subtitle: Text(
                            'Stays company stock — record a return when '
                            'it comes back',
                            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_kind == 'Workshop')
                    AppCard(
                      padding: EdgeInsets.all(14),
                      child: Text('The company workshop (single location).',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13.5)),
                    )
                  else if (_kind == 'Branch')
                    AppCard(
                      padding: EdgeInsets.all(14),
                      child: Text(
                          'The Lahore branch — the company\'s own location. '
                          'Items sent there show as With Branch.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13.5)),
                    )
                  else if (_kind == 'Dealer')
                    PickyField(
                      controller: _target,
                      label: 'Dealer',
                      hint:
                          'Optional — search, or type a name to add it',
                      options: dealerNames,
                      pickTitle: 'dealers',
                    )
                  else
                    PickyField(
                      controller: _target,
                      label: 'Customer',
                      hint:
                          'Optional — search, or type a name to add it',
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

/// Fills in the dealer/customer name of sends that were recorded without
/// one (0010_optional_movement_party.sql). One tap names a whole send —
/// every row that shares its group. Used by the movement cards and by
/// the dashboard's "add now" alert.
Future<void> showAddPartySheet(
  BuildContext context,
  WidgetRef ref,
  List<Map<String, dynamic>> rows,
) async {
  final myId = ref.read(authControllerProvider).currentUser?.id;
  final isAdmin = ref.read(isAdminProvider);
  final labels = ref.read(itemLabelsProvider);
  final pending = rows
      .where((row) =>
          movementPartyMissing(row) && (isAdmin || row['actor_id'] == myId))
      .toList();
  if (pending.isEmpty) return;

  // one entry per send: rows sharing a group are named in a single tap
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final row in pending) {
    final group = (row['group_ref'] ?? '').toString();
    groups
        .putIfAbsent(group.isEmpty ? row['id'].toString() : group, () => [])
        .add(row);
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        return Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Add the missing name',
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
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'These sends went out without a dealer or customer '
                    'name — pick it now and the items follow.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      for (final entry in groups.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: AppCard(
                            padding: const EdgeInsets.all(4),
                            child: ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                radius: 18,
                                backgroundColor: context.colors.warningContainer,
                                child: Icon(Icons.person_add_alt_outlined,
                                    size: 20, color: kAmber),
                              ),
                              title: Text(
                                _sendTitle(entry.value, labels),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 14),
                              ),
                              subtitle: Text([
                                '${entry.value.length} item(s)',
                                entry.value.first['movement_date'] ?? '',
                                entry.value.first['movement_type'] ?? '',
                              ].join(' · ')),
                              trailing: Icon(Icons.chevron_right,
                                  size: 20, color: Theme.of(context).colorScheme.outline),
                              onTap: () async {
                                final groupRows = entry.value;
                                final isDealer = groupRows
                                        .first['movement_type'] ==
                                    'Dealer';
                                final table =
                                    isDealer ? 'dealers' : 'customers';
                                final options = await db
                                    .from(table)
                                    .select('id, name')
                                    .order('name');
                                if (!sheetContext.mounted) return;
                                const addNew = 'Add a new name…';
                                final picked = await showPickFromList(
                                  context: sheetContext,
                                  title: isDealer
                                      ? 'Choose dealer'
                                      : 'Choose customer',
                                  options: [
                                    addNew,
                                    for (final r in options)
                                      r['name'].toString(),
                                  ],
                                );
                                if (picked == null || !sheetContext.mounted) {
                                  return;
                                }
                                int id;
                                if (picked == addNew) {
                                  // the name is not in the records yet —
                                  // add it here (any member may)
                                  final typed = await _askForNewName(
                                      sheetContext,
                                      isDealer ? 'dealer' : 'customer');
                                  if (typed == null ||
                                      !sheetContext.mounted) {
                                    return;
                                  }
                                  try {
                                    final found = await db
                                        .from(table)
                                        .select('id')
                                        .eq('name', typed)
                                        .order('id')
                                        .limit(1);
                                    if (found.isNotEmpty) {
                                      id = found.first['id'] as int;
                                    } else {
                                      final inserted = await db
                                          .from(table)
                                          .insert({'name': typed})
                                          .select('id')
                                          .single();
                                      id = inserted['id'] as int;
                                      ref
                                        ..invalidate(isDealer
                                            ? dealersProvider
                                            : customersProvider)
                                        ..invalidate(recentPartiesProvider);
                                    }
                                  } catch (error) {
                                    if (sheetContext.mounted) {
                                      showSnack(sheetContext,
                                          errorMessage(error),
                                          error: true);
                                    }
                                    return;
                                  }
                                } else {
                                  id = options.firstWhere(
                                      (r) => r['name'] == picked)['id'] as int;
                                }
                                String? failure;
                                for (final row in groupRows) {
                                  try {
                                    await setMovementParty(
                                      row['id'] as int,
                                      dealerId: isDealer ? id : null,
                                      customerId: isDealer ? null : id,
                                    );
                                  } catch (error) {
                                    failure ??= errorMessage(error);
                                  }
                                }
                                ref
                                  ..invalidate(movementsProvider)
                                  ..invalidate(inventoryProvider);
                                if (!sheetContext.mounted) return;
                                if (failure != null) {
                                  showSnack(sheetContext, failure,
                                      error: true);
                                }
                                setSheetState(() {
                                  for (final row in groupRows) {
                                    pending.remove(row);
                                  }
                                  groups.remove(entry.key);
                                });
                                if (pending.isEmpty) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Small dialog for naming a send when the name is not in the records yet.
Future<String?> _askForNewName(BuildContext context, String kind) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('New $kind name'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(hintText: 'Type the name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    ),
  );
  controller.dispose();
  return (name == null || name.isEmpty) ? null : name;
}

/// `<main item> → <destination>` for one send entry.
String _sendTitle(List<Map<String, dynamic>> rows, Map<String, String> labels) {
  for (final row in rows) {
    final key = _MovementsScreenState._itemKey(row);
    final label = key == null
        ? null
        : labels['${key.key}:${key.value}'];
    if (label != null) {
      return '$label → ${row['to_location'] ?? ''}';
    }
  }
  return 'Sent to ${rows.first['to_location'] ?? ''}';
}
