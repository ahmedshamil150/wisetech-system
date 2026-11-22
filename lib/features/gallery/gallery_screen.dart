import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/widgets.dart';
import 'gallery_data.dart';
import 'gallery_upload_screen.dart';

/// Gallery page: select a batch, view its image groups 2 per row.
/// Each group card shows the machine + printer + probe photos with serials
/// and models. Tap a group card to open the full-screen image viewer.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  String _batchName = '';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header bar: title + upload
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Image Gallery',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const GalleryUploadScreen(),
                  ),
                ),
                icon: const Icon(Icons.cloud_upload, size: 18),
                label: const Text('Upload photos'),
              ),
            ],
          ),
        ),
        // Batch selector (from Records only)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Consumer(
            builder: (_, ref, __) {
              final batches = ref.watch(galleryBatchesProvider);
              return batches.when(
                data: (list) => DropdownButtonFormField<String>(
                  value: _batchName.isEmpty ? null : _batchName,
                  items: [
                    for (final b in list)
                      DropdownMenuItem(
                        value: b,
                        child: Text(b),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _batchName = v;
                      ref.read(currentGalleryBatchProvider).value = v;
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Batch',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                loading: () => const SizedBox(
                  height: 56,
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
        if (_batchName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Text(
              'Group code format: 1U, 2U, 3U…  Write the code on the '
              'physical machine with a marker, then enter it in '
              'Inventory → item → Image group code.',
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
          ),

        if (_batchName.isEmpty)
          Expanded(child: _EmptyBatchHint())
        else
          Expanded(child: _BatchGroupsPane(batchName: _batchName)),

        if (_batchName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
    );
  }

  ColorScheme get colorScheme => Theme.of(context).colorScheme;

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

    ref.read(
      linkImageGroupProvider((
        kind: kind,
        itemId: item['id'] as int,
        groupCode: group.groupCode,
      )),
    );
    if (!mounted) return;

    showSnack(
      context,
      '${group.groupCode} linked to $kind ${item['code']}.',
    );
  }
}

// ── Grid of groups ─────────────────────────────────────────────────────────────

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
                      fontWeight: FontWeight.w800,
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

// ── Empty state ──────────────────────────────────────────────────────────────

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
                fontWeight: FontWeight.w800,
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
}

// ── Group card (tap to open full-screen viewer) ────────────────────────────────

class _GroupCard extends StatelessWidget {
  final GalleryGroup group;
  const _GroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final machine = group.images.where((i) => i.itemType == 'machine').toList();
    final printer = group.images.where((i) => i.itemType == 'printer').toList();
    final probes = group.images.where((i) => i.itemType == 'probe').toList();

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _ImageGalleryViewer(group: group),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colorScheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover photo + group code badge
            Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.network(
                      group.images.isNotEmpty
                          ? group.images.first.r2Url
                          : '',
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: 150,
                      errorBuilder: (_, __, ___) => Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(Icons.image_outlined,
                            size: 36, color: colorScheme.outline),
                      ),
                    ),
                  ),
                ),
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
                Positioned(
                  top: 8,
                  right: 8,
                  child: _GroupMenu(group: group),
                ),
              ],
            ),
            const SizedBox(height: 10),
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
                        fontWeight: FontWeight.w800,
                        color: colorScheme.outline),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: [
                      if (machine.isNotEmpty)
                        _ImageChip(
                          label: 'Machine',
                          serial: machine.first.itemSerial,
                          color: colorScheme.primary,
                        ),
                      if (printer.isNotEmpty)
                        _ImageChip(
                          label: 'Printer',
                          serial: printer.first.itemSerial,
                          color: colorScheme.secondary,
                        ),
                      for (final p in probes)
                        _ImageChip(
                          label: 'Probe',
                          serial: p.itemSerial,
                          color: colorScheme.tertiary,
                        ),
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
      ),
    );
  }
}

// ── Chip ───────────────────────────────────────────────────────────────────────

class _ImageChip extends StatelessWidget {
  final String label;
  final String? serial;
  final Color color;
  _ImageChip({required this.label, this.serial, required this.color});

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
            ref.read(deleteImageGroupProvider(group.id));
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

// ── Full-screen image viewer (pinch-to-zoom) ─────────────────────────────────

class _ImageGalleryViewer extends StatelessWidget {
  final GalleryGroup group;
  const _ImageGalleryViewer({required this.group});

  @override
  Widget build(BuildContext context) {
    final images = group.images;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${group.groupCode} — ${images.length} photo${images.length == 1 ? '' : 's'}',
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: PageView.builder(
        itemCount: images.length,
        itemBuilder: (ctx, i) {
          final img = images[i];
          return Center(
            child: InteractiveViewer(
              panEnabled: true,
              scaleEnabled: true,
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.network(
                img.r2Url,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.broken_image, size: 64, color: Colors.grey),
                    const SizedBox(height: 8),
                    Text(img.r2Url,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}