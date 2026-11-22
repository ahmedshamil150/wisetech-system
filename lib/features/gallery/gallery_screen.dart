import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/widgets.dart';
import 'gallery_data.dart';
import 'gallery_upload_screen.dart';

/// Gallery page: select a batch, view its image groups 2 per row.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  String _batchName = '';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('Image Gallery'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const GalleryUploadScreen(),
                ),
              ),
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('Upload photos'),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Batch selector ─────────────────────────────────────────────
          Container(
            color: colorScheme.surface,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Consumer(
              builder: (_, ref, __) {
                final batches = ref.watch(galleryBatchesProvider);
                return batches.when(
                  data: (list) => DropdownButtonFormField<String>(
                    value: _batchName.isEmpty ? null : _batchName,
                    items: [
                      for (final b in list)
                        DropdownMenuItem(value: b, child: Text(b)),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        _batchName = v;
                        ref.read(currentGalleryBatchProvider).value = v;
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Select batch',
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.inventory_2_outlined, size: 18),
                    ),
                  ),
                  loading: () => const SizedBox(
                    height: 48,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => TextField(
                    decoration: const InputDecoration(
                      labelText: 'Batch name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _batchName = v.trim()),
                  ),
                );
              },
            ),
          ),

          if (_batchName.isNotEmpty) ...[
            Container(
              color: colorScheme.surfaceContainerLowest,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: colorScheme.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Group codes: 1U, 2U, 3U… — write on the machine with '
                      'a marker, then enter in Inventory.',
                      style: TextStyle(fontSize: 12, color: colorScheme.outline),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],

          // ── Content ────────────────────────────────────────────────────
          if (_batchName.isEmpty)
            Expanded(child: _EmptyBatchHint())
          else
            Expanded(child: _BatchGroupsPane(batchName: _batchName)),

          // ── Link button ────────────────────────────────────────────────
          if (_batchName.isNotEmpty)
            Container(
              color: colorScheme.surface,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                children: [
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: () => _linkGroupToItem(context),
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Link group to inventory item'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _linkGroupToItem(BuildContext context) async {
    final groups = await ref.read(galleryGroupsProvider.future);
    if (!mounted) return;
    if (groups.isEmpty) {
      showSnack(context, 'No groups in this batch yet.', error: true);
      return;
    }

    final group = await showDialog<GalleryGroup>(
      context: context,
      builder: (ctx) => _GroupPickerDialog(groups: groups),
    );
    if (!mounted) return;
    if (group == null) return;

    final kind = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Item kind'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'machine'),
            child: const Text('Machine'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'probe'),
            child: const Text('Probe'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'printer'),
            child: const Text('Printer'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (kind == null) return;

    final items = await ref.read(
      itemsByGroupCodeProvider((kind: kind, groupCode: group.groupCode)).future,
    );
    if (!mounted) return;
    if (items.isEmpty) {
      showSnack(
        context,
        'No ${kind}s carry group code ${group.groupCode} yet. '
        'Enter the code on the item in Inventory first.',
        error: true,
      );
      return;
    }

    final item = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _ItemPickerDialog(kind: kind, items: items),
    );
    if (!mounted) return;
    if (item == null) return;

    await ref.read(
      linkImageGroupProvider((
        kind: kind,
        itemId: item['id'] as int,
        groupCode: group.groupCode,
      )).future,
    );
    if (!mounted) return;

    showSnack(
      context,
      '${group.groupCode} linked to $kind ${item['code']}.',
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyBatchHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.photo_library_outlined,
                size: 40,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Select a batch to view photos',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose a batch from the dropdown above\nto browse its image groups.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: colorScheme.outline, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Grid of groups ────────────────────────────────────────────────────────────

class _BatchGroupsPane extends ConsumerWidget {
  final String batchName;
  const _BatchGroupsPane({required this.batchName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final data = ref.watch(galleryGroupsProvider);
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Error: $e', style: TextStyle(color: colorScheme.error)),
      ),
      data: (groups) {
        if (groups.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.photo_library_outlined,
                    size: 56,
                    color: colorScheme.outline.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No image groups yet',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Tap "Upload photos" to add the first group.',
                    style: TextStyle(fontSize: 13, color: colorScheme.outline),
                  ),
                ],
              ),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(14),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.82,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: groups.length,
          itemBuilder: (ctx, i) => _GroupCard(group: groups[i]),
        );
      },
    );
  }
}

// ── Group card ────────────────────────────────────────────────────────────────

class _GroupCard extends StatelessWidget {
  final GalleryGroup group;
  const _GroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final machine = group.images.where((i) => i.itemType == 'machine').toList();
    final printer = group.images.where((i) => i.itemType == 'printer').toList();
    final probes  = group.images.where((i) => i.itemType == 'probe').toList();

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cover photo
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(14)),
                    child: group.images.isNotEmpty
                        ? Image.network(
                            group.images.first.r2Url,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.broken_image_outlined,
                                  size: 36, color: colorScheme.outline),
                            ),
                          )
                        : Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(Icons.image_outlined,
                                size: 36, color: colorScheme.outline),
                          ),
                  ),
                ),
                // Group code badge
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      group.groupCode,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
                // Photo count
                Positioned(
                  bottom: 6,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${group.images.length} photo${group.images.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
                // Menu
                Positioned(
                  top: 8,
                  right: 8,
                  child: _GroupMenu(group: group),
                ),
              ],
            ),
          ),
          // Details
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.batchName,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.outline),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    if (machine.isNotEmpty)
                      _ImageChip(label: 'Machine',
                          serial: machine.first.itemSerial,
                          color: colorScheme.primary),
                    if (printer.isNotEmpty)
                      _ImageChip(label: 'Printer',
                          serial: printer.first.itemSerial,
                          color: colorScheme.secondary),
                    for (final p in probes)
                      _ImageChip(label: 'Probe',
                          serial: p.itemSerial,
                          color: colorScheme.tertiary),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${group.createdAt.day}/${group.createdAt.month}/${group.createdAt.year}',
                  style: TextStyle(fontSize: 11, color: colorScheme.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Chip ──────────────────────────────────────────────────────────────────────

class _ImageChip extends StatelessWidget {
  final String label;
  final String? serial;
  final Color color;
  const _ImageChip({required this.label, this.serial, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 11),
          ),
          if (serial != null && serial!.isNotEmpty) ...[
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                serial!,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Group picker dialog ──────────────────────────────────────────────────────

class _GroupPickerDialog extends StatelessWidget {
  final List<GalleryGroup> groups;
  const _GroupPickerDialog({required this.groups});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose image group'),
      content: SizedBox(
        width: 300,
        height: 400,
        child: ListView.builder(
          itemCount: groups.length,
          itemBuilder: (ctx, i) => ListTile(
            title: Text(groups[i].groupCode),
            subtitle: Text(
                '${groups[i].batchName} · ${groups[i].images.length} images'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pop(context, groups[i]),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ── Item picker dialog ───────────────────────────────────────────────────────

class _ItemPickerDialog extends StatelessWidget {
  final String kind;
  final List<Map<String, dynamic>> items;
  const _ItemPickerDialog({required this.kind, required this.items});

  @override
  Widget build(BuildContext context) {
    final label = kind == 'machine'
        ? 'Machine'
        : kind == 'probe'
            ? 'Probe'
            : 'Printer';
    return AlertDialog(
      title: Text('Choose $label'),
      content: SizedBox(
        width: 300,
        height: 400,
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (ctx, i) => ListTile(
            title: Text('${items[i]['code'] ?? ''}'),
            subtitle: Text(
                '${items[i]['name'] ?? ''} · ${items[i]['serial_number'] ?? ''}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pop(context, items[i]),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ── Group menu (edit code / delete) ──────────────────────────────────────────

class _GroupMenu extends ConsumerWidget {
  final GalleryGroup group;
  const _GroupMenu({required this.group});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (value) async {
        if (value == 'delete') {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Delete group?'),
              content: Text(
                  'Delete "${group.groupCode}" and all its photos? This cannot be undone.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.red),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (ok == true && context.mounted) {
            ref.read(deleteImageGroupProvider(group.id)).value;
            if (context.mounted) {
              showSnack(context, 'Group deleted');
            }
          }
        } else if (value == 'edit') {
          await _editGroupCode(context, ref);
        }
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(
            leading: Icon(Icons.edit, size: 20),
            title: Text('Edit code'),
            dense: true,
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete, size: 20, color: Colors.red),
            title: Text('Delete group', style: TextStyle(color: Colors.red)),
            dense: true,
          ),
        ),
      ],
    );
  }

  Future<void> _editGroupCode(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: group.groupCode);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit group code'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Group code',
            hintText: 'e.g. 1U',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == group.groupCode) return;
    if (!context.mounted) return;
    try {
      ref.read(updateImageGroupProvider((
        id: group.id,
        groupCode: result,
      ))).value;
      if (context.mounted) {
        showSnack(context, 'Group code updated to $result');
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'Failed to update: $e', error: true);
      }
    }
  }
}
