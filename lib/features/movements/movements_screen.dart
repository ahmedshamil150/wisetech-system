import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/flag_sheet.dart';
import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../inventory/inventory_screen.dart';
import '../../core/layout.dart';

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
  // Everything the Filters sheet decides, display form ('' / 'All' = off).
  String _party = 'All'; // customer or dealer name, or 'All'
  String _actor = 'All'; // who sent it, or 'All'
  String _kind = 'All'; // Machine / Probe / Printer / Part, or 'All'
  String _dateFrom = '';
  String _dateTo = '';
  String _demo = 'All'; // 'All' / 'Exclude demo' / 'Demo only'
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Filters the sheet holds — the search box has its own count.
  int get _activeFilterCount {
    var n = 0;
    if (_filter != 'All') n++;
    if (_party != 'All') n++;
    if (_actor != 'All') n++;
    if (_kind != 'All') n++;
    if (_dateFrom.isNotEmpty) n++;
    if (_dateTo.isNotEmpty) n++;
    if (_demo != 'All') n++;
    return n;
  }

  bool get _hasFilters =>
      _party != 'All' ||
      _actor != 'All' ||
      _kind != 'All' ||
      _dateFrom.isNotEmpty ||
      _dateTo.isNotEmpty ||
      _demo != 'All' ||
      _query.isNotEmpty;

  void _clearFilters() {
    _search.clear();
    setState(() {
      _party = 'All';
      _actor = 'All';
      _kind = 'All';
      _dateFrom = '';
      _dateTo = '';
      _demo = 'All';
      _query = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final movements = ref.watch(movementsProvider);
    final labels = ref.watch(itemLabelsProvider);
    final rows = movements.maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    // counts decide Returned vs out from the latest movement of each
    // item, so they need the full history behind the filtered list
    final fullHistory = ref.watch(allMovementsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final counts = _groupCounts(rows, fullHistory, labels);

    return Column(
      children: [
        // the kind chips and their counts show at every width — the
        // row scrolls sideways on a phone
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: SearchField(
                  controller: _search,
                  hint: 'Search by item, location or reference',
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
              ),
              const SizedBox(width: 6),
              if (isPhoneLayout(context))
                IconButton(
                  tooltip: 'Filters',
                  onPressed: _openFilters,
                  icon: Badge(
                    isLabelVisible: _activeFilterCount > 0,
                    label: Text('$_activeFilterCount'),
                    child: const Icon(Icons.filter_list, size: 22),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: _openFilters,
                  icon: Badge(
                    isLabelVisible: _activeFilterCount > 0,
                    label: Text('$_activeFilterCount'),
                    child: const Icon(Icons.filter_list, size: 20),
                  ),
                  label: const Text('Filters'),
                ),
              if (_hasFilters)
                IconButton(
                  tooltip: 'Clear filters',
                  icon: Icon(Icons.close,
                      size: 20, color: Theme.of(context).colorScheme.error),
                  onPressed: _clearFilters,
                ),
            ],
          ),
        ),
        Expanded(
          child: movements.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
                icon: Icons.error_outline, message: errorMessage(error)),
            data: (allRows) {
              // the latest movement of an item decides whether it is
              // already back in stock — computed from the full history,
              // not the display rows
              final fullHistory = ref
                  .watch(allMovementsProvider)
                  .maybeWhen(
                      data: (value) => value,
                      orElse: () => const <Map<String, dynamic>>[]);
              final latest = latestMovementByItem(fullHistory);

              // Return rows are history, not cards — they show in the
              // item details instead. The date range is applied per card
              // below: a send by the day it went out, a returned item by
              // the day it came back.
              final sends = allRows
                  .where((row) => row['movement_type'] != 'Return')
                  .where((row) => _passes(row, skipDates: true))
                  .toList();

              // rows that travelled together (same invoice) stay in one card
              final entries = <List<Map<String, dynamic>>>[];
              final groups = <String, List<Map<String, dynamic>>>{};
              for (final row in sends) {
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

              // one send shows in two places once only part of it came
              // back: the items still out stay on its card under the
              // send's own tab, the returned ones move to 'Returned',
              // where the card says only this item came back — a
              // returned item never sits on the send's card again. A row
              // a later send took with it stays on its own card too, but
              // marked 'Moved on', so it never reads as a live send.
              final visible =
                  <({List<Map<String, dynamic>> rows, int total, Set<int> movedOn})>[];
              for (final members in entries) {
                final parts = partitionSendRows(members, latest);
                final shown = _filter == 'Returned'
                    ? <Map<String, dynamic>>[
                        for (final row in parts.back)
                          if (_passesDate(_returnDateOf(row, latest))) row,
                      ]
                    : <Map<String, dynamic>>[
                        for (final row in [...parts.out, ...parts.movedOn])
                          if (_passesDate('${row['movement_date'] ?? ''}'))
                            row,
                      ];
                if (shown.isEmpty) continue;
                if (_filter != 'All' &&
                    _filter != 'Returned' &&
                    shown.first['movement_type'] != _filter) {
                  continue;
                }
                if (_query.isNotEmpty &&
                    !shown.any((row) => _searchMatches(row, labels))) {
                  continue;
                }
                visible.add((
                  rows: shown,
                  total: members.length,
                  movedOn: {for (final row in parts.movedOn) row['id'] as int},
                ));
              }
              if (visible.isEmpty) {
                return EmptyState(
                    icon: Icons.alt_route_outlined,
                    message: _filter == 'Returned'
                        ? 'No items are back in inventory yet.'
                        : _hasFilters
                            ? 'No movements match these filters.'
                            : 'No movements recorded yet.');
              }
              for (final card in visible) {
                card.rows.sort(_mainItemFirst);
              }
              final shown =
                  visible.fold<int>(0, (sum, card) => sum + card.rows.length);
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
                          final card = visible[index];
                          return _tile(context, card.rows, labels,
                              back: _filter == 'Returned',
                              sendTotal: card.total,
                              movedOn: card.movedOn,
                              returnedOn: _filter == 'Returned'
                                  ? _returnedDates(card.rows, latest)
                                  : const <int, String>{});
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
            onPressed: () => showAppSheet<void>(
              context: context,
              title: 'New movement',
              heightFraction: 0.85,
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
  /// [fullHistory] is every current movement so the
  /// latest-movement check behind "Returned" is correct.
  Map<String, int> _groupCounts(List<Map<String, dynamic>> allRows,
      List<Map<String, dynamic>> fullHistory, Map<String, String> labels) {
    final latest = latestMovementByItem(fullHistory);

    // rows that travelled together stay in one card, as in the list
    final entries = <List<Map<String, dynamic>>>[];
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final row in allRows) {
      if (row['movement_type'] == 'Return') continue;
      if (!_passes(row, skipDates: true)) continue;
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

    // each tab counts the part of a send it would actually show: what
    // is still out, or — under 'Returned' — what already came back
    final counts = <String, int>{for (final f in _filters) f: 0};
    for (final members in entries) {
      final parts = partitionSendRows(members, latest);
      for (final filter in _filters) {
        final shown = filter == 'Returned'
            ? <Map<String, dynamic>>[
                for (final row in parts.back)
                  if (_passesDate(_returnDateOf(row, latest))) row,
              ]
            : <Map<String, dynamic>>[
                for (final row in [...parts.out, ...parts.movedOn])
                  if (_passesDate('${row['movement_date'] ?? ''}')) row,
              ];
        if (shown.isEmpty) continue;
        if (filter != 'All' &&
            filter != 'Returned' &&
            shown.first['movement_type'] != filter) {
          continue;
        }
        if (_query.isNotEmpty &&
            !shown.any((row) => _searchMatches(row, labels))) {
          continue;
        }
        counts[filter] = counts[filter]! + 1;
      }
    }
    return counts;
  }

  /// The day each of these rows came back — its own Return row's date,
  /// as the latest movement of the item.
  Map<int, String> _returnedDates(List<Map<String, dynamic>> rows,
      Map<String, Map<String, dynamic>> latest) {
    final dates = <int, String>{};
    for (final row in rows) {
      final key = movementItemKey(row);
      final last = key == null ? null : latest['${key.key}:${key.value}'];
      if (last == null || last['movement_type'] != 'Return') continue;
      final date = (last['movement_date'] ?? '').toString();
      if (date.isNotEmpty) dates[row['id'] as int] = date;
    }
    return dates;
  }

  /// The date a row is judged by in the range filter. A send is judged
  /// by the day it went out; a returned item under 'Returned' is judged
  /// by the day it came back — an October return of a September send
  /// still belongs to October.
  String? _returnDateOf(
      Map<String, dynamic> row, Map<String, Map<String, dynamic>> latest) {
    final key = movementItemKey(row);
    final last = key == null ? null : latest['${key.key}:${key.value}'];
    if (last == null || last['movement_type'] != 'Return') return null;
    return (last['movement_date'] ?? '').toString();
  }

  bool _passesDate(String? raw) {
    if (_dateFrom.isEmpty && _dateTo.isEmpty) return true;
    // a row with no readable date cannot sit inside a range
    final date = _parseDateText(raw ?? '');
    if (date == null) return false;
    final from = _parseDateText(_dateFrom);
    if (from != null && date.isBefore(from)) return false;
    final to = _parseDateText(_dateTo);
    if (to != null && date.isAfter(to)) return false;
    return true;
  }

  bool _passes(Map<String, dynamic> row, {bool skipDates = false}) {
    if (_party != 'All' &&
        (row['to_location'] ?? '').toString() != _party) {
      return false;
    }
    if (_actor != 'All' && _actorOf(row) != _actor) return false;
    if (_kind != 'All' && _kindOf(row) != _kind) return false;
    if (_demo == 'Demo only' && row['is_demo'] != true) return false;
    if (_demo == 'Exclude demo' && row['is_demo'] == true) return false;
    if (!skipDates &&
        !_passesDate((row['movement_date'] ?? '').toString())) {
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

  /// Opens the Filters sheet — everything the old second chip row held,
  /// plus the date range and demo rows. The sheet only narrows the list
  /// already in memory; nothing is fetched or written.
  Future<void> _openFilters() async {
    final rows = ref.read(movementsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final fullHistory = ref.read(allMovementsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final labels = ref.read(itemLabelsProvider);
    final counts = _groupCounts(rows, fullHistory, labels);
    final showParty = _filter == 'Customer' || _filter == 'Dealer';
    // a choice from an earlier visit must still be selectable, even when
    // the rows behind it have changed
    final partyOptions = showParty ? _partyOptions(rows) : <String>[];
    if (_party != 'All' && !partyOptions.contains(_party)) {
      partyOptions.add(_party);
    }
    final actorOptions = _actorOptions(rows);
    if (_actor != 'All' && !actorOptions.contains(_actor)) {
      actorOptions.add(_actor);
    }
    final kindOptions = _kindOptions(rows);
    if (_kind != 'All' && !kindOptions.contains(_kind)) {
      kindOptions.add(_kind);
    }
    final result = await showAppSheet<_MovementFilterValues>(
      context: context,
      title: 'Filters',
      heightFraction: 0.85,
      builder: (sheetContext) => _MovementFilterSheet(
        show: _filter,
        showCounts: counts,
        showParty: showParty,
        partyLabel:
            _filter == 'Customer' ? 'Any customer' : 'Any dealer',
        party: _party,
        partyOptions: partyOptions,
        actor: _actor,
        actorOptions: actorOptions,
        kind: _kind,
        kindOptions: kindOptions,
        dateFrom: _dateFrom,
        dateTo: _dateTo,
        demo: _demo,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _filter = result.show;
      _party = result.party;
      _actor = result.actor;
      _kind = result.kind;
      _dateFrom = result.dateFrom;
      _dateTo = result.dateTo;
      _demo = result.demo;
    });
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
    final key = movementItemKey(row);
    if (key == null) return 'Unknown item';
    return labels['${key.key}:${key.value}'] ?? 'Unknown item';
  }

  Widget _tile(BuildContext context, List<Map<String, dynamic>> rows,
      Map<String, String> labels,
      {required bool back,
      int? sendTotal,
      Set<int> movedOn = const {},
      Map<int, String> returnedOn = const {}}) {
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
    final phone = isPhoneLayout(context);

    // any item of the send may carry flags, and the send itself too —
    // the card shows the first target that has one
    final flagRows = ref.watch(flagsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final flagBy = flagIndex(flagRows);
    List<Map<String, dynamic>> cardFlags = const [];
    for (final r in rows) {
      cardFlags = flagBy[flagRowKey(r['id'] as int)] ?? const [];
      if (cardFlags.isNotEmpty) break;
    }
    if (cardFlags.isEmpty) cardFlags = flagBy[flagSendKey(row)] ?? const [];

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
              title: Row(
                children: [
                  if (cardFlags.isNotEmpty) ...[
                    Tooltip(
                      message: flagLabel(cardFlags),
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: colorFromHex('${cardFlags.first['color']}'),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text('$label → ${row['to_location'] ?? ''}',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: phone ? 13 : 14)),
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Text(
                    [
                      row['movement_date'] ?? '',
                      if (returnedOn.containsKey(row['id'] as int))
                        'Back ${returnedOn[row['id'] as int]}',
                      if (movedOn.contains(row['id'] as int)) 'Moved on',
                      kind,
                      if (movementSold(row))
                        movementSoldBy(row).isEmpty
                            ? 'Sold'
                            : 'Sold by ${movementSoldBy(row)}',
                      if (isOutboundKind(kind))
                        movementPaid(row) ? 'Paid' : 'Unpaid',
                      if (isDemo) 'Demo',
                      if (actorName.isNotEmpty) 'by $actorName',
                      if (reference.isNotEmpty) reference,
                    ].join(' · '),
                    style: TextStyle(fontSize: phone ? 11.5 : 12),
                  ),
                ],
              ),
              trailing: Icon(Icons.chevron_right, size: 20, color: Theme.of(context).colorScheme.outline),
              onTap: () => _openMovement(rows),
            ),
            if (back)
              Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 15, color: context.colors.success),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        // a partial return says how much of the send
                        // came back, so one returned item reads as its
                        // own event rather than the whole send
                        sendTotal == null
                            ? 'Back in inventory'
                            : returnedBannerText(rows.length, sendTotal),
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: context.colors.success),
                      ),
                    ),
                  ],
                ),
              ),
            for (final other in rows.skip(1))
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openMovement(rows),
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
                      if (movedOn.contains(other['id'] as int))
                        Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Text('Moved on',
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
    final key = movementItemKey(row);
    if (key == null) return;
    final items = ref.read(allItemsProvider).maybeWhen(
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

  /// The whole send in one sheet: one compact action row on top (return,
  /// edit, ⋮ menu) and every item below with its own ⋮. The card itself
  /// only ever opens this. Rows are re-resolved by group inside the
  /// sheet, so an item added there shows up straight away.
  void _openMovement(List<Map<String, dynamic>> rows) {
    final group = (rows.first['group_ref'] ?? '').toString();
    showAppSheet<void>(
      context: context,
      title: 'Movement details',
      heightFraction: 0.85,
      builder: (sheetContext) => _MovementDetails(
        state: this,
        groupRef: group,
        rowIds: {for (final row in rows) row['id'] as int},
      ),
    );
  }

  /// Erases one row of a send — the rest of the group stays and the item
  /// takes its status from the history that is left (0014).
  Future<void> _deleteRow(Map<String, dynamic> row) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this movement?'),
        content: const Text(
            'The item returns to inventory. The other movements of this '
            'send are not touched.'),
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
      await deleteMovementRow(row['id'] as int);
      ref.invalidate(allMovementsProvider);
      ref.invalidate(inventoryProvider);
      ref.invalidate(oldStockItemsProvider);
      messenger
          .showSnackBar(const SnackBar(content: Text('Movement deleted.')));
    } catch (error) {
      messenger
          .showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }

  /// Puts every item of this send back into stock. An item that moved on
  /// to a later send is left alone — only its own last movement decides.
  Future<void> _returnGroup(List<Map<String, dynamic>> rows) async {
    final allMovements = ref.read(allMovementsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final items = ref.read(allItemsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <InventoryItem>[]);
    final groupIds = {for (final row in rows) row['id'] as int};

    final latest = <String, int>{}; // item key -> latest movement id
    for (final row in allMovements) {
      final key = movementItemKey(row);
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
        final key = movementItemKey(row);
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
      ref.invalidate(allMovementsProvider);
      ref.invalidate(inventoryProvider);
      ref.invalidate(oldStockItemsProvider);
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

  /// Adds an item to an open send: the new row joins the same group —
  /// same card, same date, same name, same paid flag — through the
  /// app's own create_movement, so it reads exactly like the rows the
  /// send was recorded with. A machine brings its probes and printer
  /// along, as in the new-movement form, minus what the send already
  /// holds.
  Future<void> _addToSend(List<Map<String, dynamic>> rows) async {
    final messenger = ScaffoldMessenger.of(context);
    final first = rows.first;
    final kind = (first['movement_type'] ?? '').toString();
    final group = (first['group_ref'] ?? '').toString();
    if (group.isEmpty) {
      showSnack(context, 'This send travelled without a group — its rows '
          'cannot be added to.', error: true);
      return;
    }
    final inSend = <String>{};
    for (final row in rows) {
      final key = movementItemKey(row);
      if (key != null) inSend.add('${key.key}:${key.value}');
    }
    final available = ref.read(allItemsProvider).maybeWhen(
          data: (items) => items
              .where((i) =>
                  i.status != 'Sold' &&
                  i.status != 'Archived' &&
                  !inSend.contains(i.key))
              .toList(),
          orElse: () => const <InventoryItem>[],
        );
    if (available.isEmpty) {
      showSnack(context, 'Every item is already in this send.');
      return;
    }
    final picked = await showPickItem(context, items: available);
    if (picked == null) return;
    final additions =
        picked.kind == 'machine' ? kitFor(available, picked) : [picked];
    try {
      for (final item in additions) {
        await db.rpc('create_movement', params: {
          'p_item_type': item.kind,
          'p_item_id': item.id,
          'p_kind': kind,
          if (first['dealer_id'] != null) 'p_dealer_id': first['dealer_id'],
          if (first['customer_id'] != null)
            'p_customer_id': first['customer_id'],
          if (first['workshop_id'] != null)
            'p_workshop_id': first['workshop_id'],
          if ('${first['movement_date'] ?? ''}'.isNotEmpty)
            'p_date': '${first['movement_date']}',
          if ('${first['notes'] ?? ''}'.isNotEmpty)
            'p_notes': '${first['notes']}',
          'p_demo': first['is_demo'] == true,
          'p_group_ref': group,
          'p_paid': movementPaid(first),
        });
      }
      ref.invalidate(allMovementsProvider);
      ref.invalidate(inventoryProvider);
      ref.invalidate(oldStockItemsProvider);
      if (!mounted) return;
      showSnack(
          context,
          '${additions.length} item${additions.length == 1 ? '' : 's'} '
          'added to this send.');
    } catch (error) {
      if (!mounted) return;
      messenger
          .showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }

  /// Opens the tick-list sheet for a multi-item send: the sender picks
  /// which of the items actually came back; the rest stay out.
  void _showReturnSheet(List<Map<String, dynamic>> rows) {
    showAppSheet<void>(
      context: context,
      title: 'Return from send',
      heightFraction: 0.8,
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
  /// Returns whether the send was actually deleted.
  Future<bool> _deleteGroup(List<Map<String, dynamic>> rows) async {
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
    if (confirmed != true) return false;
    try {
      await deleteMovement(rows.first['id'] as int);
      ref.invalidate(allMovementsProvider);
      ref.invalidate(inventoryProvider);
      ref.invalidate(oldStockItemsProvider);
      ref.invalidate(customersProvider);
      ref.invalidate(dealersProvider);
      ref.invalidate(recentPartiesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Send deleted.')));
      return true;
    } catch (error) {
      messenger
          .showSnackBar(SnackBar(content: Text(errorMessage(error))));
      return false;
    }
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

/// One line of a PopupMenuButton: icon + label.
Widget _menuRow(IconData icon, String label, {Color? color}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label),
      ],
    );

/// One send, opened from its card. One compact action row on top —
/// back to inventory, Edit, and a ⋮ menu with everything else (add an
/// item, flag, name, delete) — so the items below are never crowded.
/// The rows are re-read from the provider on every change, so the
/// sheet always shows what the last action did.
class _MovementDetails extends ConsumerWidget {
  const _MovementDetails(
      {required this.state, required this.groupRef, required this.rowIds});

  final _MovementsScreenState state;

  /// The send this sheet stands for: rows are re-resolved by group, so
  /// an item added while the sheet is open shows up without reopening.
  final String groupRef;

  /// Fallback for legacy rows that travelled without a group.
  final Set<int> rowIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final labels = ref.watch(itemLabelsProvider);
    final isAdmin = ref.watch(isAdminProvider);
    final myId = ref.read(authControllerProvider).currentUser?.id;
    final all = ref.watch(allMovementsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final flagRows = ref.watch(flagsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final flagBy = flagIndex(flagRows);
    // re-read by group so an item added while the sheet is open shows
    // up without reopening it; legacy rows without a group fall back to
    // the ids the card was opened with
    final rows = [
      for (final row in all)
        if (row['movement_type'] != 'Return' &&
            (groupRef.isNotEmpty
                ? (row['group_ref'] ?? '') == groupRef
                : rowIds.contains(row['id'] as int)))
          row
    ]..sort(_mainItemFirst);
    if (rows.isEmpty) {
      return Center(
        child: Text('This send was deleted.',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }

    // the latest movement of an item decides where it stands right now
    final latest = latestMovementByItem(all);
    SendRowState stateOf(Map<String, dynamic> row) =>
        sendRowState(row, latest);

    // what already came back is kept apart from what is still out, and
    // from what a later send took with it: each gets its own section
    // here, and the returned ones leave the send's card in the list
    final parts = partitionSendRows(rows, latest);
    final outRows = parts.out;
    final backRows = parts.back;
    final movedRows = parts.movedOn;
    final mixed = [outRows, movedRows, backRows]
            .where((groupRows) => groupRows.isNotEmpty)
            .length >
        1;

    String labelOf(Map<String, dynamic> row) {
      final key = movementItemKey(row);
      if (key == null) return 'Unknown item';
      return labels['${key.key}:${key.value}'] ?? 'Unknown item';
    }

    final back = outRows.isEmpty && movedRows.isEmpty; // all of it is back
    final canManage = isAdmin || rows.any((r) => r['actor_id'] == myId);
    final missing = rows.where(movementPartyMissing).toList();
    final canFixParty = missing.isNotEmpty &&
        (isAdmin || missing.any((r) => r['actor_id'] == myId));
    final first = rows.first;
    final kind = (first['movement_type'] ?? '').toString();
    final outbound = isOutboundKind(kind);
    final sold = rows.any(movementSold);
    final soldBy = movementSoldBy(first);
    final paid = rows.any(movementPaid);
    final group = (first['group_ref'] ?? '').toString();
    final icon = switch (kind) {
      'Workshop' => Icons.build_outlined,
      'Branch' => Icons.storefront_outlined,
      'Dealer' => Icons.handshake_outlined,
      _ => Icons.person_outline,
    };
    final actor = first['profiles'];
    final actorName = actor is Map
        ? ((actor['display_name'] ?? actor['username'] ?? '').toString())
        : '';
    final reference = (first['reference'] ?? '').toString();
    final sendFlags = flagBy[flagSendKey(first)] ?? const [];
    final sendTarget = {
      'movement_id': first['id'],
      'group_ref': sendGroupValue(first),
    };

    // everything except the primary action sits behind one ⋮ menu
    final menu = <PopupMenuEntry<String>>[];
    if (canManage && group.isNotEmpty) {
      menu.add(PopupMenuItem(
          value: 'add',
          child: _menuRow(Icons.add, 'Add item to this send')));
    }
    if (isAdmin) {
      menu.add(PopupMenuItem(
          value: 'flag',
          child: _menuRow(
              Icons.flag_outlined,
              sendFlags.isEmpty
                  ? 'Flag this send'
                  : 'Flags (${sendFlags.length})',
              color: sendFlags.isEmpty
                  ? null
                  : colorFromHex('${sendFlags.first['color']}'))));
    }
    if (canFixParty) {
      menu.add(PopupMenuItem(
          value: 'party',
          child:
              _menuRow(Icons.edit_note, 'Add the ${kind.toLowerCase()} name')));
    }
    if (canManage) {
      menu.add(PopupMenuItem(
          value: 'delete',
          child: _menuRow(Icons.delete_outline, 'Delete this send',
              color: scheme.error)));
    }
    final hasActions =
        (canManage && outRows.isNotEmpty) || isAdmin || menu.isNotEmpty;

    Widget itemTile(Map<String, dynamic> row) {
      final rowState = stateOf(row);
      final canReturn = canManage && rowState == SendRowState.out;
      final canDelete = isAdmin || row['actor_id'] == myId;
      final hasRowActions = isAdmin || canReturn || canDelete;
      final rowFlags = flagBy[flagRowKey(row['id'] as int)] ?? const [];
      final dotFlags = rowFlags.isNotEmpty
          ? rowFlags
          : flagBy[flagSendKey(row)] ?? const [];
      // the day it came back, read off its own Return row
      var returnedOn = '';
      if (rowState == SendRowState.back) {
        final key = movementItemKey(row);
        final last = key == null ? null : latest['${key.key}:${key.value}'];
        if (last != null && last['movement_type'] == 'Return') {
          returnedOn = (last['movement_date'] ?? '').toString();
        }
      }
      final meta = [
        row['movement_date'] ?? '',
        if (rowState == SendRowState.back)
          returnedOn.isEmpty ? 'Back in inventory' : 'Back in inventory $returnedOn',
        if (rowState == SendRowState.movedOn) 'Moved on',
        if (row['is_demo'] == true) 'Demo',
      ].join(' · ');
      return ListTile(
        dense: true,
        leading: Icon(icon, size: 20, color: scheme.primary),
        title: Row(
          children: [
            if (dotFlags.isNotEmpty) ...[
              Tooltip(
                message: flagLabel(dotFlags),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: colorFromHex('${dotFlags.first['color']}'),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(labelOf(row),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13.5)),
            ),
          ],
        ),
        subtitle: Text(meta,
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant)),
        // one ⋮ instead of a row of buttons — flag, back to inventory
        // and delete live in the menu; the item itself opens on tap
        trailing: hasRowActions
            ? PopupMenuButton<String>(
                tooltip: 'Item actions',
                icon: Icon(Icons.more_vert, size: 20, color: scheme.outline),
                itemBuilder: (menuContext) => [
                  if (isAdmin)
                    PopupMenuItem(
                      value: 'flag',
                      child: _menuRow(
                          Icons.flag_outlined,
                          rowFlags.isEmpty
                              ? 'Flag this item'
                              : 'Flags (${rowFlags.length})',
                          color: rowFlags.isEmpty
                              ? null
                              : colorFromHex('${rowFlags.first['color']}')),
                    ),
                  if (canReturn)
                    PopupMenuItem(
                      value: 'return',
                      child: _menuRow(Icons.login_outlined, 'Back to inventory',
                          color: scheme.primary),
                    ),
                  if (canDelete)
                    PopupMenuItem(
                      value: 'delete',
                      child: _menuRow(
                          Icons.delete_outline, 'Delete this movement',
                          color: scheme.error),
                    ),
                ],
                onSelected: (value) {
                  if (value == 'flag') {
                    showFlagSheet(context, ref,
                        target: {'movement_id': row['id']});
                  } else if (value == 'return') {
                    state._returnGroup([row]);
                  } else if (value == 'delete') {
                    state._deleteRow(row);
                  }
                },
              )
            : Icon(Icons.chevron_right, size: 18, color: scheme.outline),
        onTap: () => state._openItem(row),
      );
    }

    Widget section(String title, List<Map<String, dynamic>> sectionRows) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            AppCard(
              padding: const EdgeInsets.all(4),
              child: Column(
                children: [for (final row in sectionRows) itemTile(row)],
              ),
            ),
            const SizedBox(height: 12),
          ],
        );

    // a send with every fate in it reads as three lists, not one
    final sections = <(String, List<Map<String, dynamic>>)>[];
    if (mixed) {
      if (outRows.isNotEmpty) {
        sections.add(('Still out (${outRows.length})', outRows));
      }
      if (movedRows.isNotEmpty) {
        sections.add(
            ('Moved on with a later send (${movedRows.length})', movedRows));
      }
      if (backRows.isNotEmpty) {
        sections.add(('Returned (${backRows.length})', backRows));
      }
    } else {
      sections.add((
        back ? 'Returned items (${rows.length})' : 'Items (${rows.length})',
        rows,
      ));
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(_sendTitle(rows, labels),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
            [
              first['movement_date'] ?? '',
              kind,
              if (sold) soldBy.isEmpty ? 'Sold' : 'Sold by $soldBy',
              if (outbound) paid ? 'Paid' : 'Unpaid',
              if (first['is_demo'] == true) 'Demo',
              if (actorName.isNotEmpty) 'by $actorName',
              if (reference.isNotEmpty) reference,
            ].join(' · '),
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        if ('${first['notes'] ?? ''}'.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('${first['notes']}',
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ],
        if (back) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.check_circle_outline,
                  size: 15, color: context.colors.success),
              const SizedBox(width: 6),
              Text('Back in inventory',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: context.colors.success)),
            ],
          ),
        ],
        const SizedBox(height: 12),
        // one primary action, one Edit, everything else behind ⋮ —
        // the old row of seven buttons crowded the items below
        if (hasActions) ...[
          Row(
            children: [
              if (canManage && outRows.isNotEmpty) ...[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: outRows.length > 1
                        ? () => state._showReturnSheet(outRows)
                        : () => state._returnGroup(outRows),
                    icon: const Icon(Icons.login_outlined, size: 18),
                    label: const Text('Back to inventory'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (isAdmin)
                TextButton.icon(
                  onPressed: () => showEditSendSheet(context, rows),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
              if (menu.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  icon: const Icon(Icons.more_vert),
                  itemBuilder: (menuContext) => menu,
                  onSelected: (value) async {
                    if (value == 'add') {
                      await state._addToSend(rows);
                    } else if (value == 'flag') {
                      showFlagSheet(context, ref, target: sendTarget);
                    } else if (value == 'party') {
                      await showAddPartySheet(context, ref, rows);
                    } else if (value == 'delete') {
                      final gone = await state._deleteGroup(rows);
                      if (gone && context.mounted) Navigator.pop(context);
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        // each fate gets its own list: a single returned item leaves
        // this list and shows under 'Returned'
        for (final (title, sectionRows) in sections)
          section(title, sectionRows),
      ],
    );
  }
}

/// Everything about a send that can be corrected after it was recorded,
/// in one sheet: the date, the notes, and — each with a line saying
/// exactly what it means — the Paid and Sold marks. Admins only; the
/// detail sheet's Edit button opens it.
Future<void> showEditSendSheet(
  BuildContext context,
  List<Map<String, dynamic>> rows,
) {
  return showAppSheet<void>(
    context: context,
    title: 'Edit send',
    heightFraction: 0.8,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _EditSendSheet(rows: rows),
    ),
  );
}

class _EditSendSheet extends ConsumerStatefulWidget {
  const _EditSendSheet({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  ConsumerState<_EditSendSheet> createState() => _EditSendSheetState();
}

class _EditSendSheetState extends ConsumerState<_EditSendSheet> {
  late final TextEditingController _date;
  late final TextEditingController _notes;
  late final TextEditingController _amount;
  late final TextEditingController _soldBy;
  late bool _paid;
  late bool _sold;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final first = widget.rows.first;
    var date = (first['movement_date'] ?? '').toString();
    // a few legacy rows are stored as yyyy-MM-dd — show them the app way
    final iso = DateTime.tryParse(date);
    if (iso != null) date = DateField.format(iso);
    _date = TextEditingController(text: date);
    _notes = TextEditingController(text: (first['notes'] ?? '').toString());
    final amount = soldAmountOf(first);
    _amount = TextEditingController(
        text: amount == null
            ? ''
            : amount == amount.roundToDouble()
                ? amount.toStringAsFixed(0)
                : '$amount');
    _soldBy = TextEditingController(text: movementSoldBy(first));
    _paid = widget.rows.any(movementPaid);
    _sold = widget.rows.any(movementSold);
  }

  @override
  void dispose() {
    for (final c in [_date, _notes, _amount, _soldBy]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final date = _date.text.trim();
    final parts = date.split('-');
    final usable = parts.length == 3 &&
        int.tryParse(parts[0]) != null &&
        int.tryParse(parts[1]) != null &&
        int.tryParse(parts[2]) != null;
    if (!usable) {
      showSnack(context, 'Type the date as DD-MM-YYYY.', error: true);
      return;
    }
    final rows = widget.rows;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      // date and notes are the whole send's — every row takes them, the
      // way the new-movement form writes one date and one note
      await setMovementDate([for (final row in rows) row['id'] as int], date);
      await setMovementNotes(rows, _notes.text.trim());
      if (_paid != rows.any(movementPaid)) await setSendPaid(rows, _paid);
      // the sold mark carries the sale amount and the seller with it —
      // typed or blank, whatever changed goes to every row of the send
      final wasSold = rows.any(movementSold);
      final amount = parseSaleAmount(_amount.text);
      final soldBy = _soldBy.text.trim();
      if (_sold != wasSold ||
          (_sold &&
              (amount != soldAmountOf(rows.first) ||
                  soldBy != movementSoldBy(rows.first)))) {
        await setSendSold(rows, _sold,
            amount: _sold ? amount : null, soldBy: soldBy);
      }
      ref.invalidate(allMovementsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Send updated.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = '${widget.rows.first['movement_type'] ?? ''}';
    final outbound = isOutboundKind(kind);
    final soldKind = isSoldKind(kind);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Edit send',
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
                  DateField(controller: _date, label: 'Date'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Notes',
                        helperText: 'One note for the whole send'),
                  ),
                  if (outbound) ...[
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: _paid
                            ? context.colors.success.withValues(alpha: 0.07)
                            : context.colors.quietFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: _paid
                                ? context.colors.success
                                : scheme.outlineVariant),
                      ),
                      child: SwitchListTile.adaptive(
                        value: _paid,
                        onChanged: (value) => setState(() => _paid = value),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 2),
                        title: const Text('Paid',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        subtitle: Text(
                            'The customer or dealer has settled this send, so '
                            'the card reads Paid instead of Unpaid. A record '
                            'for your books — stock does not change.',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                    ),
                  ],
                  if (soldKind) ...[
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: _sold
                            ? scheme.primary.withValues(alpha: 0.07)
                            : context.colors.quietFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color:
                                _sold ? scheme.primary : scheme.outlineVariant),
                      ),
                      child: SwitchListTile.adaptive(
                        value: _sold,
                        onChanged: (value) => setState(() => _sold = value),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 2),
                        title: const Text('Sold',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        subtitle: Text(
                            'The equipment was sold to them, not just sent '
                            'out — the history then reads "Sold to X" and '
                            'the sale shows on the Sales screen. A label '
                            'only; item statuses do not change.',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                    ),
                  ],
                  if (soldKind && _sold) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _amount,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Sale amount (optional)',
                          hintText: 'Blank is fine'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _soldBy,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                          labelText: 'Sold by (optional)',
                          hintText: 'Name of the person who sold it'),
                    ),
                  ],
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
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

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
    final latest = _latestByItem();
    for (final row in widget.rows) {
      if (sendRowState(row, latest) == SendRowState.out) {
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

  /// The newest movement of every item, as the list reads it.
  Map<String, Map<String, dynamic>> _latestByItem() => latestMovementByItem(
      ref.read(allMovementsProvider).maybeWhen(
            data: (value) => value,
            orElse: () => const <Map<String, dynamic>>[],
          ));

  Future<void> _returnSelected(
      Map<String, InventoryItem> itemsByKey) async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    var count = 0;
    String? failure;
    try {
      for (final row in widget.rows) {
        if (!_selected.contains(row['id'] as int)) continue;
        final key = movementItemKey(row);
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
      ref.invalidate(allMovementsProvider);
      ref.invalidate(inventoryProvider);
      ref.invalidate(oldStockItemsProvider);
    }
    if (!mounted) return;
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(
        content: Text(failure ??
            '$count item${count == 1 ? '' : 's'} back in inventory.')));
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(allItemsProvider).maybeWhen(
          data: (value) => value,
          orElse: () => const <InventoryItem>[],
        );
    final itemsByKey = {for (final item in items) item.key: item};
    final labels = ref.watch(itemLabelsProvider);

    String labelOf(Map<String, dynamic> row) {
      final key = movementItemKey(row);
      if (key == null) return 'Unknown item';
      return labels['${key.key}:${key.value}'] ?? 'Unknown item';
    }

    final latest = _latestByItem();
    SendRowState stateOf(Map<String, dynamic> row) =>
        sendRowState(row, latest);
    final outRows =
        widget.rows.where((r) => stateOf(r) == SendRowState.out).toList();
    final backRows =
        widget.rows.where((r) => stateOf(r) == SendRowState.back).toList();
    final movedRows = widget.rows
        .where((r) => stateOf(r) == SendRowState.movedOn)
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
  bool _paid = false;
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
          'p_paid': _paid,
          'p_group_ref': groupRef,
        });
      }

      ref
        ..invalidate(allMovementsProvider)
        ..invalidate(inventoryProvider)
        ..invalidate(oldStockItemsProvider);
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
              '${_demo ? ' (demo)' : ''}'
              '${_paid ? ' — paid' : ''}.')));
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
    final items = ref.watch(allItemsProvider).maybeWhen(
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
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: _paid
                          ? context.colors.success.withValues(alpha: 0.07)
                          : context.colors.quietFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: _paid
                              ? context.colors.success
                              : Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: SwitchListTile.adaptive(
                      value: _paid,
                      onChanged: (value) => setState(() => _paid = value),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      title: const Text('Mark as paid',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      subtitle: Text(
                          'The whole send is settled — it shows as Paid '
                          'on the card',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ),
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

  await showAppSheet<void>(
    context: context,
    title: 'Add the name',
    heightFraction: 0.6,
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
                                  ..invalidate(allMovementsProvider)
                                  ..invalidate(inventoryProvider)
                                  ..invalidate(oldStockItemsProvider);
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
    final key = movementItemKey(row);
    final label = key == null
        ? null
        : labels['${key.key}:${key.value}'];
    if (label != null) {
      return '$label → ${row['to_location'] ?? ''}';
    }
  }
  return 'Sent to ${rows.first['to_location'] ?? ''}';
}


// ---------------------------------------------------------------------------
// filters sheet
// ---------------------------------------------------------------------------

/// What the Filters sheet hands back � display form, '' / 'All' meaning
/// "off".
typedef _MovementFilterValues = ({
  String show,
  String party,
  String actor,
  String kind,
  String dateFrom,
  String dateTo,
  String demo,
});

/// Every movement filter in one sheet: which sends to show, who they
/// went to, who sent them, the item kind, the date range and whether
/// demo rows are wanted.
class _MovementFilterSheet extends StatefulWidget {
  const _MovementFilterSheet({
    required this.show,
    required this.showCounts,
    required this.showParty,
    required this.partyLabel,
    required this.party,
    required this.partyOptions,
    required this.actor,
    required this.actorOptions,
    required this.kind,
    required this.kindOptions,
    required this.dateFrom,
    required this.dateTo,
    required this.demo,
  });

  /// Only customer and dealer sends have a "sent to" name to pick.
  final String show;
  final Map<String, int> showCounts;
  final bool showParty;
  final String partyLabel;
  final String party;
  final List<String> partyOptions;
  final String actor;
  final List<String> actorOptions;
  final String kind;
  final List<String> kindOptions;
  final String dateFrom;
  final String dateTo;
  final String demo;

  @override
  State<_MovementFilterSheet> createState() => _MovementFilterSheetState();
}

class _MovementFilterSheetState extends State<_MovementFilterSheet> {
  late final TextEditingController _from;
  late final TextEditingController _to;
  late String _show;
  late String _party;
  late String _actor;
  late String _kind;
  late String _demo;

  static const _demoOptions = ['All', 'Exclude demo', 'Demo only'];

  @override
  void initState() {
    super.initState();
    _from = TextEditingController(text: widget.dateFrom);
    _to = TextEditingController(text: widget.dateTo);
    _show = widget.show;
    _party = widget.party;
    _actor = widget.actor;
    _kind = widget.kind;
    _demo = widget.demo;
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _apply() {
    Navigator.pop(context, (
      show: _show,
      party: widget.showParty ? _party : widget.party,
      actor: _actor,
      kind: _kind,
      dateFrom: _from.text.trim(),
      dateTo: _to.text.trim(),
      demo: _demo,
    ));
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // the sheet does not lift for the keyboard — pad it so the Apply row
    // stays above it while a field is being typed in
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + keyboard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Filters',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // on phone the send-kind chips live here instead of a
                  // row above the list
                  if (isPhoneLayout(context)) ...[
                    _label('Show'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in _filters)
                          ChoiceChip(
                            label: Text(
                                '$option (${widget.showCounts[option] ?? 0})'),
                            selected: _show == option,
                            onSelected: (_) => setState(() {
                              _show = option;
                              _party = 'All';
                            }),
                            selectedColor: scheme.primary,
                            labelStyle: TextStyle(
                              color: _show == option
                                  ? Colors.white
                                  : scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                            backgroundColor: context.colors.isDark
                                ? context.colors.quietFill
                                : scheme.surface,
                            side:
                                BorderSide(color: scheme.outlineVariant),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (widget.showParty) ...[
                    _label('Sent to'),
                    DropdownButtonFormField<String>(
                      key: ValueKey('filter-party-$_party'),
                      initialValue: _party,
                      items: [
                        DropdownMenuItem(
                            value: 'All', child: Text(widget.partyLabel)),
                        for (final name in widget.partyOptions)
                          DropdownMenuItem(value: name, child: Text(name)),
                      ],
                      onChanged: (v) => setState(() => _party = v ?? 'All'),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _label('Sent by'),
                  DropdownButtonFormField<String>(
                    key: ValueKey('filter-actor-$_actor'),
                    initialValue: _actor,
                    items: [
                      const DropdownMenuItem(
                          value: 'All', child: Text('Anyone')),
                      for (final name in widget.actorOptions)
                        DropdownMenuItem(value: name, child: Text(name)),
                    ],
                    onChanged: (v) => setState(() => _actor = v ?? 'All'),
                  ),
                  const SizedBox(height: 16),
                  _label('Item'),
                  DropdownButtonFormField<String>(
                    key: ValueKey('filter-kind-$_kind'),
                    initialValue: _kind,
                    items: [
                      const DropdownMenuItem(
                          value: 'All', child: Text('Any item')),
                      for (final kind in widget.kindOptions)
                        DropdownMenuItem(
                            value: kind, child: Text('${kind}s')),
                    ],
                    onChanged: (v) => setState(() => _kind = v ?? 'All'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child:
                            DateField(controller: _from, label: 'Date from'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DateField(controller: _to, label: 'Date to'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _label('Demo'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in _demoOptions)
                        ChoiceChip(
                          label: Text(option),
                          selected: _demo == option,
                          onSelected: (_) => setState(() => _demo = option),
                          selectedColor: scheme.primary,
                          labelStyle: TextStyle(
                            color: _demo == option
                                ? Colors.white
                                : scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                          backgroundColor: context.colors.isDark
                              ? context.colors.quietFill
                              : scheme.surface,
                          side: BorderSide(color: scheme.outlineVariant),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, (
                  show: 'All',
                  party: 'All',
                  actor: 'All',
                  kind: 'All',
                  dateFrom: '',
                  dateTo: '',
                  demo: 'All',
                )),
                child: const Text('Clear all'),
              ),
              const Spacer(),
              FilledButton(onPressed: _apply, child: const Text('Apply')),
            ],
          ),
        ],
      ),
    );
  }
}
