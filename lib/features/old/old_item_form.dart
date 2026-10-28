import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import 'old_data.dart';

/// Opens the add/edit form for one old-stock item. [row] is null when
/// adding; pass the existing map when editing.
Future<void> showOldItemForm(
  BuildContext context, {
  required String kind,
  Map<String, dynamic>? row,
}) {
  return showAppSheet<void>(
    context: context,
    title: row == null
        ? 'Add to old stock'
        : 'Edit ${(row[codeColumnFor(kind)] ?? '').toString()}',
    heightFraction: 0.9,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _OldItemForm(kind: kind, row: row),
    ),
  );
}

/// Column that holds the human-readable code for each kind.
String codeColumnFor(String kind) =>
    kind == 'machine' ? 'machine_id' : 'internal_id';

/// Column that holds the display name for each kind.
String nameColumnFor(String kind) =>
    kind == 'machine' || kind == 'probe' ? 'model' : 'name_model';

String tableFor(String kind) => switch (kind) {
      'machine' => 'machines',
      'probe' => 'probes',
      'printer' => 'printers',
      _ => 'parts',
    };

String kindLabel(String kind) => switch (kind) {
      'machine' => 'Machine',
      'probe' => 'Probe',
      'printer' => 'Printer',
      _ => 'Part',
    };

class _OldItemForm extends ConsumerStatefulWidget {
  const _OldItemForm({required this.kind, this.row});

  final String kind;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_OldItemForm> createState() => _OldItemFormState();
}

class _OldItemFormState extends ConsumerState<_OldItemForm> {
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _serial;
  late final TextEditingController _location;
  late final TextEditingController _notes;
  late String _status;
  bool _saving = false;

  bool get _isEdit => widget.row != null;

  @override
  void initState() {
    super.initState();
    final row = widget.row;
    _code = TextEditingController(
        text: row == null ? '' : (row[codeColumnFor(widget.kind)] ?? '').toString());
    _name = TextEditingController(
        text: row == null ? '' : (row[nameColumnFor(widget.kind)] ?? '').toString());
    _serial = TextEditingController(
        text: row == null ? '' : (row['serial_number'] ?? '').toString());
    _location = TextEditingController(
        text: row == null ? '' : (row['current_location'] ?? '').toString());
    _notes = TextEditingController(
        text: row == null ? '' : (row['notes'] ?? '').toString());
    _status = row?['status']?.toString() ?? defaultStatus(widget.kind);
  }

  @override
  void dispose() {
    for (final c in [_code, _name, _serial, _location, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final code = _code.text.trim();
    final name = _name.text.trim();
    if (code.isEmpty) {
      showSnack(context, 'Code is required.', error: true);
      return;
    }
    if (name.isEmpty) {
      showSnack(context, 'Name is required.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final table = tableFor(widget.kind);
    try {
      if (_isEdit) {
        await db.from(table).update({
          nameColumnFor(widget.kind): name,
          'status': _status,
          'serial_number': _serial.text.trim().isEmpty
              ? null
              : _serial.text.trim(),
          'current_location': _location.text.trim(),
          'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        }).eq('id', widget.row!['id']);
      } else {
        await db.from(table).insert({
          codeColumnFor(widget.kind): code,
          nameColumnFor(widget.kind): name,
          'status': _status,
          if (_serial.text.trim().isNotEmpty)
            'serial_number': _serial.text.trim(),
          'current_location': _location.text.trim(),
          if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
          // machines, probes and printers belong to BATCH-OLD; parts are
          // shared and have no batch_id column
          if (widget.kind != 'part') 'batch_id': kOldBatchId,
        });
      }
      _invalidate();
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
          content: Text(_isEdit ? '$code updated.' : '$code added.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  Future<void> _delete() async {
    final code = _code.text.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $code?'),
        content: Text(
            'This removes the $code ${kindLabel(widget.kind).toLowerCase()} '
            'from the old stock. Its movement history rows will be removed '
            'too. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await db
          .from(tableFor(widget.kind))
          .delete()
          .eq('id', widget.row!['id']);
      _invalidate();
      if (!mounted) return;
      Navigator.pop(context);
      messenger
          .showSnackBar(SnackBar(content: Text('$code deleted.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  void _invalidate() {
    ref.invalidate(oldMachinesProvider);
    ref.invalidate(oldProbesProvider);
    ref.invalidate(oldPrintersProvider);
    ref.invalidate(oldStockItemsProvider);
    ref.invalidate(inventoryProvider);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    _isEdit
                        ? 'Edit ${_code.text}'
                        : 'Add ${kindLabel(widget.kind).toLowerCase()}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _code,
                    autocorrect: false,
                    enabled: !_isEdit,
                    decoration: InputDecoration(
                      labelText: 'Code *',
                      hintText: _isEdit
                          ? 'Cannot change an existing code'
                          : 'e.g. 123, OLD-45',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(
                        labelText: '${kindLabel(widget.kind)} name *'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _serial,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'Serial number (optional)'),
                  ),
                  const SizedBox(height: 12),
                  Text('Status',
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    key: ValueKey('old-status-$_status'),
                    initialValue: _status,
                    items: statusOptions(widget.kind)
                        .map((s) =>
                            DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) => setState(
                        () => _status = v ?? defaultStatus(widget.kind)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _location,
                    decoration: const InputDecoration(labelText: 'Location'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 2,
                    decoration:
                        const InputDecoration(labelText: 'Notes (optional)'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (_isEdit)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error),
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              const Spacer(),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_isEdit ? 'Save changes' : 'Add'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
