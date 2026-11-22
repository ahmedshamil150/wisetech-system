import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
              child: const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }

  // Gallery is independent — no linking to inventory items.
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
