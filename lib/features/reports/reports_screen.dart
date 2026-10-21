import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import 'pdf_download.dart';
import 'report_data.dart';
import 'report_pdf.dart';

/// The report types the admin picks from — stock views, movement
/// views and the repair jobs.
const _kStock = ['All stock', 'Machines', 'Probes', 'Boxes'];
const _kMovements = [
  'All movements',
  'Workshop movements',
  'Branch movements',
  'Dealer movements',
  'Customer movements',
  'Box movements',
];
const _kRepairs = ['Repairs'];

String _titleOf(String kind) => switch (kind) {
      'All stock' => 'Stock report — all stock',
      'Machines' => 'Stock report — machines',
      'Probes' => 'Stock report — probes',
      'Boxes' => 'Box report — every box',
      'All movements' => 'Movements report — all movements',
      'Workshop movements' => 'Movements report — workshop',
      'Branch movements' => 'Movements report — branch',
      'Dealer movements' => 'Movements report — dealer',
      'Customer movements' => 'Movements report — customer',
      'Repairs' => 'Repairs report — received in range',
      _ => 'Movements report — box moves',
    };

String _fileOf(String kind) => switch (kind) {
      'All stock' => 'stock-all',
      'Machines' => 'stock-machines',
      'Probes' => 'stock-probes',
      'Boxes' => 'boxes',
      'All movements' => 'movements-all',
      'Workshop movements' => 'movements-workshop',
      'Branch movements' => 'movements-branch',
      'Dealer movements' => 'movements-dealer',
      'Customer movements' => 'movements-customer',
      'Repairs' => 'repairs',
      _ => 'movements-box',
    };

String _movementKindOf(String kind) => switch (kind) {
      'Workshop movements' => 'Workshop',
      'Branch movements' => 'Branch',
      'Dealer movements' => 'Dealer',
      'Customer movements' => 'Customer',
      'Box movements' => 'Box moves',
      _ => 'All',
    };

/// Admin-only PDF reports: pick a view and a date range, download a
/// table of everything that sits inside it. Reached from My profile.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  String _kind = 'All stock';
  final _from = TextEditingController();
  final _to = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Widget _chip(String value) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _kind == value;
    return ChoiceChip(
      label: Text(value),
      selected: selected,
      onSelected: (_) => setState(() => _kind = value),
      selectedColor: scheme.primary,
      labelStyle: TextStyle(
        color: selected ? Colors.white : scheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
      backgroundColor: context.colors.isDark
          ? context.colors.quietFill
          : scheme.surface,
      side: BorderSide(color: scheme.outlineVariant),
    );
  }

  Future<void> _download() async {
    final needsDates = _kind != 'Boxes';
    DateTime? from;
    DateTime? to;
    if (needsDates) {
      from = reportDate(_from.text);
      to = reportDate(_to.text);
      if (from == null || to == null) {
        showSnack(context, 'Pick both the from and to date.', error: true);
        return;
      }
      if (from.isAfter(to)) {
        showSnack(context, 'The from date is after the to date.',
            error: true);
        return;
      }
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final profile = ref
        .read(profileProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
    final by = '${profile?['display_name'] ?? profile?['username'] ?? 'Admin'}';
    try {
      final inventory = ref.read(inventoryProvider).maybeWhen(
          data: (value) => value, orElse: () => const <InventoryItem>[]);
      final movementRows = ref.read(allMovementsProvider).maybeWhen(
          data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
      final boxRows = ref.read(probeBoxesProvider).maybeWhen(
          data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
      final vendors = {
        for (final v in ref.read(vendorsProvider).maybeWhen(
            data: (value) => value, orElse: () => const <Map<String, dynamic>>[]))
          if (v['id'] != null) v['id'] as int: '${v['name'] ?? ''}',
      };
      final boxes = {
        for (final box in boxRows)
          if (box['id'] != null) box['id'] as int: '${box['name'] ?? ''}',
      };
      final labels = ref.read(itemLabelsProvider);

      final Uint8List bytes;
      final String filename;
      final String subtitle;
      if (_kind == 'Boxes') {
        final data = [
          for (final box in boxRows) boxReportRow(box, items: inventory),
        ];
        subtitle = 'Every box, with the probes inside it right now';
        bytes = await buildReportPdf(
          title: _titleOf(_kind),
          subtitle: subtitle,
          columns: kBoxColumns,
          data: data,
          generatedBy: by,
        );
        filename = '${_fileOf(_kind)}.pdf';
      } else if (_kMovements.contains(_kind)) {
        final filtered = filterMovementRows(movementRows,
            kind: _movementKindOf(_kind), from: from!, to: to!);
        final data = [
          for (final row in filtered) movementReportRow(row, labels: labels),
        ];
        subtitle = 'From ${_from.text} to ${_to.text}';
        bytes = await buildReportPdf(
          title: _titleOf(_kind),
          subtitle: subtitle,
          columns: kMovementColumns,
          data: data,
          generatedBy: by,
        );
        filename =
            '${_fileOf(_kind)}_${_from.text}_${_to.text}.pdf';
      } else if (_kRepairs.contains(_kind)) {
        final repairRows = ref.read(repairsProvider).maybeWhen(
            data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
        final filtered =
            filterRepairRows(repairRows, from: from!, to: to!);
        final data = [
          for (final row in filtered) repairReportRow(row),
        ];
        subtitle =
            'From ${_from.text} to ${_to.text} · by the date the job came in';
        bytes = await buildReportPdf(
          title: _titleOf(_kind),
          subtitle: subtitle,
          columns: kRepairColumns,
          data: data,
          generatedBy: by,
        );
        filename =
            '${_fileOf(_kind)}_${_from.text}_${_to.text}.pdf';
      } else {
        final items = filterStockItems(inventory,
            kind: _kind, from: from!, to: to!);
        final single = _kind != 'All stock';
        final data = [
          for (final item in items)
            stockReportRow(item,
                single: single,
                vendors: vendors,
                boxes: boxes,
                labels: labels),
        ];
        subtitle =
            'From ${_from.text} to ${_to.text} · by the date it was bought';
        bytes = await buildReportPdf(
          title: _titleOf(_kind),
          subtitle: subtitle,
          columns: single ? kStockColumnsSingle : kStockColumnsAll,
          data: data,
          generatedBy: by,
        );
        filename =
            '${_fileOf(_kind)}_${_from.text}_${_to.text}.pdf';
      }
      downloadPdf(bytes, filename);
      messenger
          .showSnackBar(SnackBar(content: Text('Downloaded $filename')));
    } catch (error) {
      messenger.showSnackBar(
          SnackBar(content: Text('Could not build the report: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isAdmin = ref.watch(isAdminProvider);
    final inventory = ref.watch(inventoryProvider);
    final movements = ref.watch(allMovementsProvider);
    final boxes = ref.watch(probeBoxesProvider);
    final vendors = ref.watch(vendorsProvider);
    final repairs = ref.watch(repairsProvider);
    final stillLoading = [
      inventory,
      movements,
      boxes,
      vendors,
      repairs,
    ].any((state) => state.isLoading);
    final needsDates = _kind != 'Boxes';

    if (!isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reports')),
        body: const Center(child: Text('Reports are for administrators.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Stock',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final kind in _kStock) _chip(kind)],
          ),
          const SizedBox(height: 16),
          Text('Movements',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final kind in _kMovements) _chip(kind)],
          ),
          const SizedBox(height: 16),
          Text('Repairs',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final kind in _kRepairs) _chip(kind)],
          ),
          const SizedBox(height: 20),
          if (needsDates)
            Row(
              children: [
                Expanded(
                  child: DateField(controller: _from, label: 'From'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DateField(controller: _to, label: 'To'),
                ),
              ],
            )
          else
            Text(
              'Every box is listed with the probes inside it right now — '
              'dates do not apply.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          const SizedBox(height: 8),
          Text(
            _kind == 'Boxes'
                ? 'One table: box name, probe type, how many probes sit '
                    'inside, their serials and notes.'
                : _kStock.contains(_kind)
                    ? 'Current stock whose bought date falls inside the '
                        'range — sold items are left out.'
                    : _kRepairs.contains(_kind)
                        ? 'Repair jobs whose received date falls inside the '
                            'range — status, return details and costs as '
                            'they stand today.'
                        : _kind == 'Box movements'
                            ? 'Only the box and unbox moves dated inside the '
                                'range — they are kept out of the '
                                'all-movements report.'
                            : 'Every send, return and branch move dated '
                                'inside the range — box moves have their own '
                                'report.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy || stillLoading ? null : _download,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: Text(_busy ? 'Building…' : 'Download PDF'),
          ),
        ],
      ),
    );
  }
}
