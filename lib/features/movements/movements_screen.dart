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

  /// The page's round add button: a new movement.
  Widget _newMovementFab(BuildContext context) => AppFab(
        tooltip: 'New movement',
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
      );

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

              // one card per movement: every send to the same party on the
              // same day reads as one delivery, however many sends it took
              final entries = <List<Map<String, dynamic>>>[];
              final byMovement = <String, List<Map<String, dynamic>>>{};
              for (final row in sends) {
                byMovement.putIfAbsent(movementCardKey(row), () {
                  final members = <Map<String, dynamic>>[];
                  entries.add(members);
                  return members;
                }).add(row);
              }

              // one send shows in two places once only part of it came
              // back: the items still out stay on its card under the
              // send's own tab, the returned ones move to 'Returned',
              // where the card says only this item came back — a
              // returned item never sits on the send's card again. A row
              // a later send took with it stays on its own card too, but
              // marked 'Moved on', so it never reads as a live send.
              final visible =
                  <({List<Map<String, dynamic>> rows, int total, int sends, Set<int> movedOn})>[];
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
                  sends: groupSendRows(members).length,
                  movedOn: {for (final row in parts.movedOn) row['id'] as int},
                ));
              }
              if (visible.isEmpty) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: EmptyState(
                          icon: Icons.alt_route_outlined,
                          message: _filter == 'Returned'
                              ? 'No items are back in inventory yet.'
                              : _hasFilters
                                  ? 'No movements match these filters.'
                                  : 'No movements recorded yet.'),
                    ),
                    Positioned(
                        right: 16, bottom: 16, child: _newMovementFab(context)),
                  ],
                );
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
                          '${visible.length} movement${visible.length == 1 ? '' : 's'}'
                          ' · $shown item${shown == 1 ? '' : 's'}',
                          style: TextStyle(
                              fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: AppRefresh(
                            child: ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding:
                                  const EdgeInsets.fromLTRB(16, 8, 16, 84),
                              itemCount: visible.length,
                              itemBuilder: (context, index) {
                                final card = visible[index];
                                return _tile(context, card.rows, labels,
                                    back: _filter == 'Returned',
                                    sendTotal: card.total,
                                    sendCount: card.sends,
                                    movedOn: card.movedOn,
                                    returnedOn: _filter == 'Returned'
                                        ? _returnedDates(card.rows, latest)
                                        : const <int, String>{});
                              },
                            ),
                          ),
                        ),
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: _newMovementFab(context),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
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

    // one card per movement, exactly as in the list
    final entries = <List<Map<String, dynamic>>>[];
    final byMovement = <String, List<Map<String, dynamic>>>{};
    for (final row in allRows) {
      if (row['movement_type'] == 'Return') continue;
      if (!_passes(row, skipDates: true)) continue;
      byMovement.putIfAbsent(movementCardKey(row), () {
        final members = <Map<String, dynamic>>[];
        entries.add(members);
        return members;
      }).add(row);
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
      int? sendCount,
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

    // one card per movement; the sends it was recorded in are its groups
    final sends = groupSendRows(rows);
    for (final send in sends) {
      send.rows.sort(_mainItemFirst);
    }
    // the movement can hold more sends than this tab shows — a send that
    // is wholly back sits under 'Returned' — so the card counts the
    // movement, not just the rows on screen
    final multi = (sendCount ?? sends.length) > 1;
    final party = (row['to_location'] ?? '').toString();
    final partyLabel = multi ? party : '$label → $party';

    // any item of the movement may carry flags, and a send itself too —
    // the card shows the first target that has one
    final flagRows = ref.watch(flagsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final flagBy = flagIndex(flagRows);
    List<Map<String, dynamic>> cardFlags = const [];
    for (final r in rows) {
      cardFlags = flagBy[flagRowKey(r['id'] as int)] ?? const [];
      if (cardFlags.isNotEmpty) break;
    }
    if (cardFlags.isEmpty) {
      for (final send in sends) {
        cardFlags = flagBy[flagSendKey(send.rows.first)] ?? const [];
        if (cardFlags.isNotEmpty) break;
      }
    }

    // the tags one group carries: back/moved on per item, sold/paid per
    // send — a group sold apart from the rest of the movement says so
    List<String> sendTags(List<Map<String, dynamic>> sendRows) {
      final tags = <String>[];
      final backDates = <String>{};
      var moved = false;
      for (final r in sendRows) {
        final date = returnedOn[r['id'] as int];
        if (date != null && date.isNotEmpty) backDates.add(date);
        if (movedOn.contains(r['id'] as int)) moved = true;
      }
      if (backDates.isNotEmpty) tags.add('Back ${backDates.join(', ')}');
      if (moved) tags.add('Moved on');
      Map<String, dynamic>? soldRow;
      for (final r in sendRows) {
        if (movementSold(r)) {
          soldRow = r;
          break;
        }
      }
      if (soldRow != null) {
        final by = movementSoldBy(soldRow);
        tags.add(by.isEmpty ? 'Sold' : 'Sold by $by');
        final amount = soldAmountOf(soldRow);
        if (amount != null) tags.add(_amountText(amount));
      }
      if (isOutboundKind(kind)) {
        tags.add(sendRows.any(movementPaid) ? 'Paid' : 'Unpaid');
      }
      return tags;
    }

    Widget itemLine(Map<String, dynamic> other, {required bool indented}) => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openMovement(rows),
          child: Padding(
            padding: EdgeInsets.only(left: indented ? 28 : 16, right: 16, bottom: 8),
            child: Row(
              children: [
                Icon(Icons.subdirectory_arrow_right,
                    size: 15, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_labelFor(other, labels),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                if (other['is_demo'] == true)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text('Demo',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.outline)),
                  ),
                if (movedOn.contains(other['id'] as int))
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text('Moved on',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.outline)),
                  ),
              ],
            ),
          ),
        );

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
                    child: Text(partyLabel,
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
                      if (multi) '${sendCount ?? sends.length} sends',
                      if (multi) '${sendTotal ?? rows.length} items',
                      kind,
                      if (!multi && movementSold(row))
                        movementSoldBy(row).isEmpty
                            ? 'Sold'
                            : 'Sold by ${movementSoldBy(row)}',
                      if (!multi && isOutboundKind(kind))
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
                        // a partial return says how much of the movement
                        // came back, so one returned item reads as its
                        // own event rather than the whole movement
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
            if (!multi)
              for (final other in sends.single.rows.skip(1))
                itemLine(other, indented: false)
            else
              for (final send in sends) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.subdirectory_arrow_right,
                              size: 16,
                              color: Theme.of(context).colorScheme.outline),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(_labelFor(send.rows.first, labels),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                      Builder(builder: (context) {
                        final tags = sendTags(send.rows);
                        if (tags.isEmpty) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(left: 22, top: 2, bottom: 2),
                          child: Text(tags.join(' · '),
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        );
                      }),
                    ],
                  ),
                ),
                for (final other in send.rows.skip(1))
                  itemLine(other, indented: true),
              ],
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

  /// The whole movement in one sheet: every send it was recorded in as a
  /// group, each with its own sold/return menu. Rows are re-resolved by
  /// send inside the sheet, so an item added there shows up straight away.
  void _openMovement(List<Map<String, dynamic>> rows) {
    final groupRefs = <String>{
      for (final row in rows)
        if ('${row['group_ref'] ?? ''}'.isNotEmpty)
          '${row['group_ref']}'
    };
    showAppSheet<void>(
      context: context,
      title: 'Movement details',
      heightFraction: 0.85,
      builder: (sheetContext) => _MovementDetails(
        state: this,
        cardKey: movementCardKey(rows.first),
        groupRefs: groupRefs,
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

/// A sale amount as it reads on a card — whole numbers without '.0'.
String _amountText(double? amount) {
  if (amount == null) return '';
  return amount == amount.roundToDouble()
      ? amount.toStringAsFixed(0)
      : '$amount';
}

/// One movement, opened from its card: every send to that party on that
/// day. One compact action row on top — back to inventory, Edit, and a
/// ⋮ for the missing name — and each send keeps its own edit, add,
/// flag and delete menu next to its items. The rows are re-read from the
/// provider on every change, so the sheet always shows what the last
/// action did.
class _MovementDetails extends ConsumerWidget {
  const _MovementDetails({
    required this.state,
    required this.cardKey,
    required this.groupRefs,
    required this.rowIds,
  });

  final _MovementsScreenState state;

  /// The movement card this sheet was opened from, as the list grouped it.
  final String cardKey;

  /// The sends the card was built from: rows are re-resolved by them, so
  /// an item added while the sheet is open shows up without reopening.
  final Set<String> groupRefs;

  /// Fallback anchor for legacy rows that travelled without a group.
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
    // every send of this movement, however it was recorded: by the group
    // it travelled in, by the rows the card was opened with, or by the
    // movement key the list itself grouped on
    final rows = [
      for (final row in all)
        if (row['movement_type'] != 'Return' &&
            (rowIds.contains(row['id'] as int) ||
                groupRefs.contains('${row['group_ref'] ?? ''}') ||
                movementCardKey(row) == cardKey))
          row
    ]..sort(_mainItemFirst);
    if (rows.isEmpty) {
      return Center(
        child: Text('This movement was deleted.',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }

    // the latest movement of an item decides where it stands right now
    final latest = latestMovementByItem(all);
    SendRowState stateOf(Map<String, dynamic> row) =>
        sendRowState(row, latest);

    // the movement's sends, each its own group: a send sold apart from
    // the rest of the movement keeps its own sold and paid marks
    final sends = groupSendRows(rows);
    for (final send in sends) {
      send.rows.sort(_mainItemFirst);
    }
    final oneSend = sends.length == 1;

    // what already came back is kept apart from what is still out, and
    // from what a later send took with it: each gets its own section
    // here, and the returned ones leave the movement's card in the list
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
    final party = (first['to_location'] ?? '').toString().trim();
    // one send reads by its main item; a movement of several sends reads
    // by the party they all went to
    final title = oneSend
        ? _sendTitle(rows, labels)
        : party.isEmpty
            ? '$kind movement'
            : party;
    final notes = rows
        .map((row) => '${row['notes'] ?? ''}'.trim())
        .firstWhere((note) => note.isNotEmpty, orElse: () => '');
    final subtitle = [
      first['movement_date'] ?? '',
      kind,
      if (!oneSend) '${sends.length} sends',
      if (!oneSend) '${rows.length} items',
      if (oneSend && rows.any(movementSold))
        movementSoldBy(first).isEmpty
            ? 'Sold'
            : 'Sold by ${movementSoldBy(first)}',
      if (oneSend && outbound) rows.any(movementPaid) ? 'Paid' : 'Unpaid',
      if (rows.any((r) => r['is_demo'] == true)) 'Demo',
      if (actorName.isNotEmpty) 'by $actorName',
      if (reference.isNotEmpty) reference,
    ].join(' · ');

    // one send's own marks — a send sold apart from the rest of the
    // movement says so on its own line
    List<String> sendTags(List<Map<String, dynamic>> sendRows) {
      final sendFirst = sendRows.first;
      final tags = <String>[];
      if (sendRows.any(movementSold)) {
        final by = movementSoldBy(sendFirst);
        tags.add(by.isEmpty ? 'Sold' : 'Sold by $by');
        final amount = soldAmountOf(sendFirst);
        if (amount != null) tags.add(_amountText(amount));
      }
      if (isOutboundKind('${sendFirst['movement_type'] ?? ''}')) {
        tags.add(sendRows.any(movementPaid) ? 'Paid' : 'Unpaid');
      }
      return tags;
    }

    // only the missing party name sits behind the sheet's own ⋮ — every
    // send carries its own edit, add, flag and delete menu
    final topMenu = <PopupMenuEntry<String>>[
      if (canFixParty)
        PopupMenuItem(
            value: 'party',
            child: _menuRow(
                Icons.edit_note, 'Add the ${kind.toLowerCase()} name')),
    ];
    final hasActions =
        (canManage && outRows.isNotEmpty) || isAdmin || topMenu.isNotEmpty;

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

    // one send's card: its own actions in its own ⋮, then its items
    Widget sendCard(String sendKey, List<Map<String, dynamic>> shownRows) {
      final full = sends.firstWhere((s) => s.key == sendKey).rows;
      final sendFirst = full.first;
      final canManageSend =
          isAdmin || full.any((r) => r['actor_id'] == myId);
      final sendFlags =
          flagBy[flagSendKey(sendFirst)] ?? const <Map<String, dynamic>>[];
      final group = (sendFirst['group_ref'] ?? '').toString();
      final tags = sendTags(full);
      final sendMenu = <PopupMenuEntry<String>>[
        if (isAdmin)
          PopupMenuItem(
              value: 'edit',
              child: _menuRow(Icons.edit_outlined, 'Edit this send')),
        if (canManageSend && group.isNotEmpty)
          PopupMenuItem(
              value: 'add',
              child: _menuRow(Icons.add, 'Add item to this send')),
        if (isAdmin)
          PopupMenuItem(
              value: 'flag',
              child: _menuRow(
                  Icons.flag_outlined,
                  sendFlags.isEmpty
                      ? 'Flag this send'
                      : 'Flags (${sendFlags.length})',
                  color: sendFlags.isEmpty
                      ? null
                      : colorFromHex('${sendFlags.first['color']}'))),
        if (canManageSend)
          PopupMenuItem(
              value: 'delete',
              child: _menuRow(Icons.delete_outline, 'Delete this send',
                  color: scheme.error)),
      ];
      return AppCard(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            // a caption per send — how many items it holds and its own
            // marks, with the send's actions in its own ⋮; no item name
            // here, the items below are the content
            if (!oneSend)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 0, 2),
                child: Row(
                  children: [
                    Icon(Icons.subdirectory_arrow_right,
                        size: 15, color: scheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          [
                            '${full.length} item${full.length == 1 ? '' : 's'}',
                            ...tags,
                          ].join(' · '),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant)),
                    ),
                    if (sendMenu.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: 'Send actions',
                        icon: Icon(Icons.more_vert,
                            size: 20, color: scheme.outline),
                        itemBuilder: (menuContext) => sendMenu,
                        onSelected: (value) async {
                          if (value == 'edit') {
                            await showEditSendSheet(context, full);
                          } else if (value == 'add') {
                            await state._addToSend(full);
                          } else if (value == 'flag') {
                            showFlagSheet(context, ref,
                                target: {
                                  'movement_id': sendFirst['id'],
                                  'group_ref': sendGroupValue(sendFirst),
                                });
                          } else if (value == 'delete') {
                            final gone = await state._deleteGroup(full);
                            if (!context.mounted) return;
                            if (gone && oneSend) Navigator.pop(context);
                          }
                        },
                      ),
                  ],
                ),
              ),
            for (final row in shownRows) itemTile(row),
          ],
        ),
      );
    }

    Widget section(String title, List<Map<String, dynamic>> sectionRows) {
      final ids = {for (final row in sectionRows) row['id'] as int};
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          // one card per send, in the order the movement holds them
          for (final send in sends)
            if (send.rows.any((row) => ids.contains(row['id'] as int)))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: sendCard(send.key, [
                  for (final row in send.rows)
                    if (ids.contains(row['id'] as int)) row,
                ]),
              ),
          const SizedBox(height: 4),
        ],
      );
    }

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
        Row(
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(subtitle,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(notes,
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
              if (topMenu.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  icon: const Icon(Icons.more_vert),
                  itemBuilder: (menuContext) => topMenu,
                  onSelected: (value) async {
                    if (value == 'party') {
                      await showAddPartySheet(context, ref, rows);
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
/// detail sheet's Edit button opens it. Given a whole movement it edits
/// every send in it, each send keeping its own marks.
Future<void> showEditSendSheet(
  BuildContext context,
  List<Map<String, dynamic>> rows,
) {
  return showAppSheet<void>(
    context: context,
    title: groupSendRows(rows).length > 1 ? 'Edit movement' : 'Edit send',
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
  // what the sheet opened with — a save only writes the sold fields when
  // one of them actually changed, so a plain notes edit never wipes the
  // amount or seller of another send in the movement
  late final bool _initialPaid;
  late final bool _initialSold;
  late final double? _initialAmount;
  late final String _initialSoldBy;
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
    // a mixed movement opens on a sold send's figures, so the fields read
    // what the sold part of the movement carries
    final soldRow = widget.rows.firstWhere(movementSold,
        orElse: () => first);
    final amount = soldAmountOf(soldRow);
    _initialAmount = amount;
    _initialSoldBy = movementSoldBy(soldRow);
    _amount = TextEditingController(
        text: amount == null
            ? ''
            : amount == amount.roundToDouble()
                ? amount.toStringAsFixed(0)
                : '$amount');
    _soldBy = TextEditingController(text: _initialSoldBy);
    _initialPaid = widget.rows.any(movementPaid);
    _initialSold = widget.rows.any(movementSold);
    _paid = _initialPaid;
    _sold = _initialSold;
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
      // date and notes are the whole movement's — every row takes them,
      // the way the new-movement form writes one date and one note
      await setMovementDate([for (final row in rows) row['id'] as int], date);
      // a movement holds several sends and every send write lands on one
      // group, so paid and sold are applied send by send
      final amount = parseSaleAmount(_amount.text);
      final soldBy = _soldBy.text.trim();
      final soldToggled = _sold != _initialSold;
      final soldDetailsChanged =
          amount != _initialAmount || soldBy != _initialSoldBy;
      for (final send in groupSendRows(rows)) {
        final sendRows = send.rows;
        await setMovementNotes(sendRows, _notes.text.trim());
        if (_paid != _initialPaid) await setSendPaid(sendRows, _paid);
        // the sold mark carries the sale amount and the seller with it.
        // An untouched switch on a mixed movement leaves the unsold sends
        // alone and a plain notes edit never rewrites what a sold send
        // already carries — only a real change reaches them
        if (soldToggled) {
          await setSendSold(sendRows, _sold,
              amount: _sold ? amount : null, soldBy: soldBy);
        } else if (_sold && soldDetailsChanged) {
          await setSendSold(sendRows, true,
              amount: amount, soldBy: soldBy);
        }
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
    final noun =
        groupSendRows(widget.rows).length > 1 ? 'movement' : 'send';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Edit $noun',
                    style:
                        const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
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
                    decoration: InputDecoration(
                        labelText: 'Notes',
                        helperText: 'One note for the whole $noun'),
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

/// One group of a new movement: a machine with its kit, or a few loose
/// items. It is recorded as its own send on the same day for the same
/// party, so it keeps its own sold, amount and paid marks.
class _GroupDraft {
  final List<InventoryItem> items = [];
  bool sold = false;
  bool paid = false;
  final amount = TextEditingController();
  final soldBy = TextEditingController();

  void dispose() {
    amount.dispose();
    soldBy.dispose();
  }
}

class _NewMovementForm extends ConsumerStatefulWidget {
  const _NewMovementForm();

  @override
  ConsumerState<_NewMovementForm> createState() => _NewMovementFormState();
}

class _NewMovementFormState extends ConsumerState<_NewMovementForm> {
  /// What leaves, group by group. The party, date and notes are typed
  /// once; each group becomes its own send, so the card holds one
  /// movement with a group per machine, sold and paid on their own.
  final List<_GroupDraft> _groups = [_GroupDraft()];
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
    for (final group in _groups) {
      group.dispose();
    }
    super.dispose();
  }

  int get _itemCount =>
      _groups.fold(0, (sum, group) => sum + group.items.length);

  /// Picking a machine also brings its probes and printer along, into
  /// the group it was picked for.
  Future<void> _pickGroupItems(
      _GroupDraft group, List<InventoryItem> items) async {
    final chosen = {
      for (final other in _groups)
        for (final item in other.items) item.key
    };
    final offered = [
      for (final item in items)
        if (!chosen.contains(item.key)) item
    ];
    if (offered.isEmpty) {
      showSnack(context, 'Every item is already in this movement.');
      return;
    }
    final picked = await showPickItem(
      context,
      items: offered,
      selectedKey: group.items.isEmpty ? null : group.items.first.key,
    );
    if (picked == null) return;
    setState(() {
      final additions =
          picked.kind == 'machine' ? kitFor(items, picked) : [picked];
      for (final item in additions) {
        if (chosen.add(item.key)) group.items.add(item);
      }
    });
  }

  void _removeGroup(int index) {
    final group = _groups[index];
    setState(() => _groups.removeAt(index));
    // its fields are still mounted for the rest of this frame
    WidgetsBinding.instance.addPostFrameCallback((_) => group.dispose());
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

  /// One group's card in the new-movement form: its items, and the sold
  /// and paid marks this send keeps on its own.
  Widget _groupCard(
    BuildContext context,
    int index,
    List<InventoryItem> items,
    bool isAdmin, {
    required bool soldKind,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final group = _groups[index];
    final multi = _groups.length > 1;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    multi ? 'Group ${index + 1}' : 'Items',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                ),
                if (multi)
                  IconButton(
                    tooltip: 'Remove this group',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _removeGroup(index),
                  ),
              ],
            ),
          ),
          if (group.items.isEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.search),
              title: Text('Choose an item',
                  style: TextStyle(color: scheme.outline)),
              subtitle: const Text(
                  'Pick a machine and its probes and printer come with it'),
              onTap: () => _pickGroupItems(group, items),
            )
          else ...[
            for (final item in group.items)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('${item.code}  ${item.title}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13.5)),
                subtitle: Text('${item.kindLabel} · ${item.status}'),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => group.items.remove(item)),
                ),
              ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.add, size: 20),
              title: Text(
                  multi ? 'Add another item to this group' : 'Add another item',
                  style: const TextStyle(fontSize: 14)),
              onTap: () => _pickGroupItems(group, items),
            ),
          ],
          if (soldKind && isAdmin) ...[
            const SizedBox(height: 6),
            SwitchListTile.adaptive(
              value: group.sold,
              onChanged: (value) => setState(() => group.sold = value),
              dense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              title: const Text('Sold',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              subtitle: const Text(
                  'This group was sold — the sale shows on the Sales screen',
                  style: TextStyle(fontSize: 12)),
            ),
            if (group.sold)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Column(
                  children: [
                    TextField(
                      controller: group.amount,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Sale amount (optional)',
                          hintText: 'Blank is fine',
                          isDense: true),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: group.soldBy,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                          labelText: 'Sold by (optional)',
                          hintText: 'Name of the person who sold it',
                          isDense: true),
                    ),
                  ],
                ),
              ),
          ],
          if (isOutboundKind(_kind))
            SwitchListTile.adaptive(
              value: group.paid,
              onChanged: (value) => setState(() => group.paid = value),
              dense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              title: const Text('Paid',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              subtitle: const Text(
                  'This group is settled — it reads Paid on the card',
                  style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    // empty group cards are left behind — a movement only records what
    // it actually carries
    final groups = [
      for (final group in _groups)
        if (group.items.isNotEmpty) group
    ];
    if (groups.isEmpty) {
      showSnack(context, 'Choose at least one item to send.', error: true);
      return;
    }
    final isAdmin = ref.read(isAdminProvider);
    final soldKind = isSoldKind(_kind);
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

      // every group is one send: its own group_ref, so its items travel
      // together and keep their own sold, amount and paid marks
      var soldGroups = 0;
      var paidGroups = 0;
      for (final group in groups) {
        final groupRef = _newGroupRef();
        for (final item in group.items) {
          await db.rpc('create_movement', params: {
            'p_item_type': item.kind,
            'p_item_id': item.id,
            'p_kind': _kind,
            ...destination,
            if (_date.text.trim().isNotEmpty) 'p_date': _date.text.trim(),
            if (_notes.text.trim().isNotEmpty) 'p_notes': _notes.text.trim(),
            'p_demo': _demo,
            'p_paid': group.paid,
            'p_group_ref': groupRef,
          });
        }
        if (group.paid) paidGroups++;
        // the sold mark is an admin-only write, so it is applied after
        // the send exists. Other members record the send and an admin
        // marks it sold later, the way Sales works everywhere else
        if (soldKind && group.sold && isAdmin) {
          await setSendSold(
            [
              {
                'group_ref': groupRef,
                'movement_type': _kind,
                'is_demo': _demo,
              }
            ],
            true,
            amount: parseSaleAmount(group.amount.text),
            soldBy: group.soldBy.text.trim(),
          );
          soldGroups++;
        }
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
      final pending =
          target.isEmpty && _kind != 'Workshop' && _kind != 'Branch'
              ? ' — add the name later'
              : '';
      final groupText =
          groups.length == 1 ? '' : ' in ${groups.length} groups';
      final paidText = paidGroups == 0
          ? ''
          : paidGroups == groups.length
              ? ' — paid'
              : ' — $paidGroups of ${groups.length} paid';
      final soldText = soldGroups == 0
          ? ''
          : soldGroups == groups.length
              ? ' — sold'
              : ' — $soldGroups of ${groups.length} sold';
      messenger.showSnackBar(SnackBar(
          content: Text(
              '$_itemCount item(s)$groupText sent to $where$added$pending'
              '${_demo ? ' (demo)' : ''}$paidText$soldText.')));
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
    final scheme = Theme.of(context).colorScheme;
    final isAdmin = ref.watch(isAdminProvider);
    final soldKind = isSoldKind(_kind);
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
                  Text('What is going out *',
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(
                      'Party, date and notes are typed once. Add a group for '
                      'each machine — a group is one send, so it keeps its '
                      'own sold and paid marks.',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  for (var i = 0; i < _groups.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _groupCard(context, i, items, isAdmin, soldKind: soldKind),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () =>
                        setState(() => _groups.add(_GroupDraft())),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add another group'),
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
