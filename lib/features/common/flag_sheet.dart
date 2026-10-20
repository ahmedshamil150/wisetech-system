import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../data/data.dart';

/// The colors an admin can pick from when flagging something.
const kFlagColors = <String>[
  '#E53935', // red
  '#FB8C00', // orange
  '#FDD835', // yellow
  '#7CB342', // lime
  '#43A047', // green
  '#00897B', // teal
  '#039BE5', // light blue
  '#1E88E5', // blue
  '#3949AB', // indigo
  '#8E24AA', // purple
  '#D81B60', // pink
  '#6D4C41', // brown
  '#757575', // grey
  '#546E7A', // blue grey
];

/// '#E53935' / 'E53935' → Color; anything unreadable becomes grey.
Color colorFromHex(String hex, {Color fallback = const Color(0xFF757575)}) {
  var value = hex.trim();
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length == 6) value = 'FF$value';
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? fallback : Color(parsed);
}

/// The colored dot a saved flag draws — on item tiles, movement cards
/// and repair jobs. Takes no space when the target is unflagged.
class FlagDot extends ConsumerWidget {
  const FlagDot({super.key, required this.targetKey, this.size = 9});

  final String targetKey;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ref.watch(flagsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final flag = flagIndex(flags)[targetKey];
    if (flag == null) return const SizedBox.shrink();
    final note = '${flag['note'] ?? ''}'.trim();
    return Tooltip(
      message: note.isEmpty ? 'Flagged' : note,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: colorFromHex('${flag['color']}'),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// The swatch grid for choosing a flag color — the flag sheet and the
/// Records flag form both use it. The chosen color goes back through
/// [onChanged]; the parent keeps it.
class FlagColorPicker extends StatefulWidget {
  const FlagColorPicker(
      {super.key, required this.initial, required this.onChanged});

  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<FlagColorPicker> createState() => _FlagColorPickerState();
}

class _FlagColorPickerState extends State<FlagColorPicker> {
  late String _color;

  @override
  void initState() {
    super.initState();
    _color = widget.initial;
  }

  Widget _swatch(String hex) {
    final selected = _color == hex;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        setState(() => _color = hex);
        widget.onChanged(hex);
      },
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: colorFromHex(hex),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : Colors.transparent,
            width: 3,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [for (final hex in kFlagColors) _swatch(hex)],
    );
  }
}

/// Shows a dot when anything inside the box carries a flag — so a box
/// with special cases is visible straight from the list, without
/// opening it.
class BoxFlagDot extends ConsumerWidget {
  const BoxFlagDot({super.key, required this.boxId, this.size = 9});

  final int boxId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(inventoryProvider).maybeWhen(
        data: (rows) => rows, orElse: () => const <InventoryItem>[]);
    final flags = ref.watch(flagsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final index = flagIndex(flags);
    for (final item in items) {
      if (item.kind != 'probe' || item.boxId != boxId) continue;
      final flag = index[flagItemKey(item.kind, item.id)];
      if (flag == null) continue;
      final note = '${flag['note'] ?? ''}'.trim();
      return Tooltip(
        message: note.isEmpty ? 'Flagged' : note,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colorFromHex('${flag['color']}'),
            shape: BoxShape.circle,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Opens the flag sheet for one target — an inventory item, a movement
/// row (or its whole send when the target also carries a group_ref), or
/// a repair job. Pick a color, write what the case is, save; unflag
/// from the same sheet. Admins only (hidden here, enforced by RLS).
Future<void> showFlagSheet(
  BuildContext context,
  WidgetRef ref, {
  required Map<String, dynamic> target,
  required Map<String, dynamic>? current,
}) {
  return showAppSheet<void>(
    context: context,
    title: current == null ? 'Flag' : 'Edit flag',
    heightFraction: 0.6,
    builder: (sheetContext) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _FlagSheet(target: target, current: current),
    ),
  );
}

class _FlagSheet extends ConsumerStatefulWidget {
  const _FlagSheet({required this.target, required this.current});

  final Map<String, dynamic> target;
  final Map<String, dynamic>? current;

  @override
  ConsumerState<_FlagSheet> createState() => _FlagSheetState();
}

class _FlagSheetState extends ConsumerState<_FlagSheet> {
  late String _color;
  final _note = TextEditingController();
  int? _defId; // the saved flag currently picked, if any
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _color = '${widget.current?['color'] ?? kFlagColors.first}';
    if (!kFlagColors.contains(_color)) _color = kFlagColors.first;
    _note.text = '${widget.current?['note'] ?? ''}';
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await setFlag(widget.target, color: _color, note: _note.text.trim());
      ref.invalidate(flagsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Flag saved.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }

  Future<void> _remove() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await clearFlag(widget.target);
      ref.invalidate(flagsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Flag removed.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }

  Widget _savedChip(Map<String, dynamic> def) {
    final scheme = Theme.of(context).colorScheme;
    final id = def['id'] as int;
    final selected = _defId == id;
    return ChoiceChip(
      avatar: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: colorFromHex('${def['color']}'),
          shape: BoxShape.circle,
        ),
      ),
      label: Text('${def['name']}'),
      selected: selected,
      onSelected: (_) => setState(() {
        if (selected) {
          _defId = null;
        } else {
          _defId = id;
          _color = '${def['color']}';
          _note.text = '${def['name']}';
        }
      }),
      selectedColor: scheme.primary,
      labelStyle: TextStyle(
        color: selected ? Colors.white : scheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
      backgroundColor: scheme.surface,
      side: BorderSide(color: scheme.outlineVariant),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final defs = ref.watch(flagDefsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Flag this case',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          if (defs.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Use a saved flag',
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final def in defs) _savedChip(def)],
            ),
            const SizedBox(height: 16),
          ] else
            const SizedBox(height: 4),
          Text('Color',
              style: TextStyle(
                  fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          FlagColorPicker(
            initial: _color,
            onChanged: (color) => setState(() {
              _color = color;
              _defId = null;
            }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 2,
            onChanged: (_) {
              if (_defId != null) setState(() => _defId = null);
            },
            decoration: const InputDecoration(
              labelText: 'Detail (optional)',
              hintText: 'What is the special case?',
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (widget.current != null)
                TextButton.icon(
                  onPressed: _saving ? null : _remove,
                  icon: const Icon(Icons.flag_circle_outlined, size: 18),
                  label: const Text('Remove flag'),
                  style: TextButton.styleFrom(
                      foregroundColor: scheme.error),
                ),
              const Spacer(),
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
        ],
      ),
    );
  }
}
