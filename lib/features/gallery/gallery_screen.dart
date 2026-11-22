import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/widgets.dart';
import 'gallery_data.dart';

/// Gallery page: batch name at top, image groups arranged 2 per row.
/// Each group card shows the machine + printer + probe photos with their
/// serials and models.
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
        // Batch selector bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Image Gallery',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () => _newBatch(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New batch'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Batch name',
                  hintText: 'e.g. BATCH-3',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _batchName = v.trim()),
                onSubmitted: (_) => _setBatch(),
              ),
              if (_batchName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Group code format: 1U, 2U, 3U…  Write the code on the '
                    'physical machine with a marker, then enter it in '
                    'Inventory → item → Image group code.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),

        if (_batchName.isNotEmpty)
          Expanded(
            child: _BatchGroupsPane(batchName: _batchName),
          )
        else
          const Expanded(
            child: Center(
              child: Text('Enter a batch name above to view its image groups.'),
            ),
          ),

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

  void _setBatch() {
    if (_batchName.isNotEmpty) {
      ref.read(currentGalleryBatchProvider).value = _batchName;
      setState(() {});
    }
  }

  Future<void> _newBatch(BuildContext context) async {
    final controller = TextEditingController(text: _batchName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New batch'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Batch name',
            hintText: 'e.g. BATCH-4',
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
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      setState(() => _batchName = result);
      ref.read(currentGalleryBatchProvider).value = result;
    }
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
      itemsByGroupCodeProvider((
        kind: kind,
        groupCode: group.groupCode,
      )).future,
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

/// Shows all groups for one batch, 2 per row.
class _BatchGroupsPane extends ConsumerWidget {
  final String batchName;
  const _BatchGroupsPane({required this.batchName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(galleryGroupsProvider);
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (groups) {
        if (groups.isEmpty) {
          return const Center(
            child: Text('No image groups yet. Add one from the upload page.'),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.85,
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

/// One group card: group code badge + machine/printer/probe images.
class _GroupCard extends ConsumerWidget {
  final GalleryGroup group;
  const _GroupCard({required this.group});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machine = group.images.where((i) => i.itemType == 'machine').toList();
    final printer = group.images.where((i) => i.itemType == 'printer').toList();
    final probes = group.images.where((i) => i.itemType == 'probe').toList();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: group code
          Stack(
            children: [
              Positioned.fill(
                child: Image.network(
                  group.images.isNotEmpty ? group.images.first.r2Url : '',
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: 150,
                  errorBuilder: (_, _, _) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image, size: 40),
                  ),
                ),
              ),
              Container(
                color: Colors.black.withValues(alpha: 0.45),
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        group.groupCode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${group.images.length} photo${group.images.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Details
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Batch: ${group.batchName}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                if (machine.isNotEmpty)
                  _ImageChip(
                    label: 'Machine',
                    serial: machine.first.itemSerial,
                    model: machine.first.itemModel,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                if (printer.isNotEmpty)
                  _ImageChip(
                    label: 'Printer',
                    serial: printer.first.itemSerial,
                    model: printer.first.itemModel,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                if (probes.isNotEmpty)
                  ...probes.map((p) => _ImageChip(
                        label: 'Probe',
                        serial: p.itemSerial,
                        model: p.itemModel,
                        color: Theme.of(context).colorScheme.tertiary,
                      )),
                const SizedBox(height: 4),
                Text(
                  '${group.createdAt.day}/${group.createdAt.month}/${group.createdAt.year}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageChip extends StatelessWidget {
  final String label;
  final String? serial;
  final String? model;
  final Color color;
  const _ImageChip({
    required this.label,
    this.serial,
    this.model,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
          if (serial != null && serial!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              serial!,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
          if (model != null && model!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                model!,
                style: const TextStyle(fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Picks one group from a list.
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
              '${groups[i].batchName} · ${groups[i].images.length} images',
            ),
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

/// Picks one item that already carries a group code.
class _ItemPickerDialog extends StatelessWidget {
  final String kind;
  final List<Map<String, dynamic>> items;
  const _ItemPickerDialog({required this.kind, required this.items});

  @override
  Widget build(BuildContext context) {
    final label = kind == 'machine' ? 'Machine' : kind == 'probe' ? 'Probe' : 'Printer';
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
              '${items[i]['name'] ?? ''} · ${items[i]['serial_number'] ?? ''}',
            ),
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
