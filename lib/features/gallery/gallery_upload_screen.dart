import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../common/widgets.dart';
import 'gallery_data.dart';
import 'r2_service.dart';

/// Upload page: pick a batch, generate a group code (1U, 2U…), take photos
/// of machine + printer + any number of probes, upload to Cloudflare R2,
/// save metadata.
class GalleryUploadScreen extends ConsumerStatefulWidget {
  const GalleryUploadScreen({super.key});

  @override
  ConsumerState<GalleryUploadScreen> createState() => _GalleryUploadScreenState();
}

class _GalleryUploadScreenState extends ConsumerState<GalleryUploadScreen> {
  final _picker = ImagePicker();
  String _batchName = '';
  String _groupCode = '';
  bool _generating = false;
  bool _uploading = false;

  XFile? _machineFile;
  Uint8List? _machineBytes;
  XFile? _printerFile;
  Uint8List? _printerBytes;

  final List<XFile?> _probeFiles = [];
  final List<Uint8List?> _probeBytes = [];

  final Map<String, TextEditingController> _serialControllers = {};
  final Map<String, TextEditingController> _modelControllers = {};

  final _kindLabels = {
    'machine': 'Machine',
    'printer': 'Printer',
    'probe': 'Probe',
  };

  SupabaseClient get _db => Supabase.instance.client;
  String _probeKey(int index) => 'probe$index';
  TextEditingController _serialCtrl(String key) =>
      _serialControllers.putIfAbsent(key, () => TextEditingController());
  TextEditingController _modelCtrl(String key) =>
      _modelControllers.putIfAbsent(key, () => TextEditingController());

  @override
  void dispose() {
    for (final c in _serialControllers.values) c.dispose();
    for (final c in _modelControllers.values) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──────────────────────────────────────────────────
            Container(
              color: colorScheme.surface,
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Upload batch pictures',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Photos go to Cloudflare R2',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_groupCode.isNotEmpty)
                    FilledButton.icon(
                      onPressed: _uploading ? null : _uploadAll,
                      icon: _uploading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.cloud_upload, size: 18),
                      label: Text(_uploading ? 'Uploading…' : 'Upload to R2'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),

            // ── Scrollable body ──────────────────────────────────────────
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // ── Step 1: Batch + Group code card ──────────────────
                  _StepCard(
                    stepNumber: 1,
                    title: 'Select batch & generate code',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Consumer(
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
                                  setState(() {
                                    _batchName = v!;
                                    _groupCode = '';
                                  });
                                },
                                decoration: const InputDecoration(
                                  labelText: 'Batch',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                              loading: () => const SizedBox(
                                height: 48,
                                child: Center(
                                    child: CircularProgressIndicator()),
                              ),
                              error: (e, _) => TextField(
                                decoration: const InputDecoration(
                                  labelText: 'Batch name',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                onChanged: (v) =>
                                    setState(() => _batchName = v.trim()),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed:
                                    _uploading || _batchName.isEmpty
                                        ? null
                                        : _generateGroupCode,
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14),
                                ),
                                icon: _generating
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : const Icon(Icons.auto_awesome, size: 18),
                                label: Text(
                                  _groupCode.isEmpty
                                      ? 'Generate group code'
                                      : 'Regenerate code',
                                ),
                              ),
                            ),
                            if (_groupCode.isNotEmpty) ...[
                              const SizedBox(width: 12),
                              _GroupCodeBadge(code: _groupCode),
                            ],
                          ],
                        ),
                        if (_groupCode.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer
                                  .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.edit_outlined,
                                  size: 16,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Write "$_groupCode" on the physical '
                                    'machine with a marker.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Step 2: Photos (only shown after code is generated) ──
                  if (_groupCode.isEmpty)
                    _EmptyPhotosHint()
                  else ...[
                    _StepCard(
                      stepNumber: 2,
                      title: 'Add photos',
                      child: Column(
                        children: [
                          _imageSlot('machine'),
                          const SizedBox(height: 16),
                          _imageSlot('printer'),
                          for (final i in Iterable<int>.generate(
                              _probeFiles.length)) ...[
                            const SizedBox(height: 16),
                            _imageSlot('probe', probeIndex: i),
                          ],
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _uploading ? null : _addProbe,
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Add probe'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Upload button at bottom ──────────────────────────
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _uploading ? null : _uploadAll,
                        icon: _uploading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.cloud_upload, size: 20),
                        label: Text(
                          _uploading
                              ? 'Uploading…'
                              : 'Upload all photos to R2',
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Future<void> _generateGroupCode() async {
    if (_batchName.isEmpty) {
      showSnack(context, 'Select a batch first.', error: true);
      return;
    }
    ref.read(currentGalleryBatchProvider).value = _batchName;
    setState(() => _generating = true);
    try {
      final code = await ref.read(createImageGroupProvider(null).future);
      if (!mounted) return;
      setState(() => _groupCode = code);
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'Failed to generate group code: $e', error: true);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _pickImage(String kind, int probeIndex) async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      if (kind == 'machine') {
        _machineFile = picked;
        _machineBytes = bytes;
      } else if (kind == 'printer') {
        _printerFile = picked;
        _printerBytes = bytes;
      } else {
        _probeFiles[probeIndex] = picked;
        _probeBytes[probeIndex] = bytes;
      }
    });
  }

  void _addProbe() {
    setState(() {
      _probeFiles.add(null);
      _probeBytes.add(null);
    });
  }

  void _removeProbe(int index) {
    setState(() {
      _probeFiles.removeAt(index);
      _probeBytes.removeAt(index);
      final key = _probeKey(index);
      _serialControllers.remove(key)?.dispose();
      _modelControllers.remove(key)?.dispose();
    });
  }

  Widget _imageSlot(String kind, {int? probeIndex}) {
    final isProbe = kind == 'probe';
    final idx = probeIndex ?? 0;
    final key = isProbe ? _probeKey(idx) : kind;
    final bytes = isProbe
        ? _probeBytes[idx]
        : (kind == 'machine' ? _machineBytes : _printerBytes);
    final hasImage = bytes != null;
    final label = isProbe ? 'Probe ${idx + 1}' : _kindLabels[kind]!;
    final isOptional = kind != 'probe';
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        border: Border.all(
          color: hasImage
              ? colorScheme.primary.withValues(alpha: 0.5)
              : colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Slot header
          Row(
            children: [
              Icon(
                kind == 'machine'
                    ? Icons.monitor_heart_outlined
                    : kind == 'printer'
                        ? Icons.print_outlined
                        : Icons.cable_outlined,
                size: 16,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14),
              ),
              const SizedBox(width: 6),
              if (isOptional)
                Text(
                  'optional',
                  style: TextStyle(
                      fontSize: 11, color: colorScheme.outline),
                ),
              const Spacer(),
              if (hasImage)
                Icon(Icons.check_circle, color: Colors.green, size: 18),
              if (isProbe)
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _removeProbe(idx),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close,
                        color: colorScheme.error, size: 18),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Photo picker
          GestureDetector(
            onTap: () => _pickImage(kind, idx),
            child: Container(
              width: double.infinity,
              height: 110,
              decoration: BoxDecoration(
                color: hasImage
                    ? Colors.transparent
                    : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: hasImage
                    ? null
                    : Border.all(
                        color: colorScheme.outline.withValues(alpha: 0.5),
                        style: BorderStyle.solid,
                      ),
              ),
              child: hasImage
                  ? Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: 110,
                          ),
                        ),
                        Positioned(
                          right: 6,
                          top: 6,
                          child: GestureDetector(
                            onTap: () => setState(() {
                              if (kind == 'machine') {
                                _machineFile = null;
                                _machineBytes = null;
                              } else if (kind == 'printer') {
                                _printerFile = null;
                                _printerBytes = null;
                              } else {
                                _probeFiles[idx] = null;
                                _probeBytes[idx] = null;
                              }
                            }),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              padding: const EdgeInsets.all(4),
                              child: const Icon(Icons.close,
                                  color: Colors.white, size: 16),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onTap: () => _pickImage(kind, idx),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: const BorderRadius.only(
                                  bottomLeft: Radius.circular(8),
                                  bottomRight: Radius.circular(8),
                                ),
                              ),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 6),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.refresh,
                                      color: Colors.white, size: 14),
                                  SizedBox(width: 4),
                                  Text(
                                    'Replace photo',
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo_outlined,
                            color: colorScheme.outline, size: 28),
                        const SizedBox(height: 6),
                        Text(
                          'Tap to add photo',
                          style: TextStyle(
                              fontSize: 12, color: colorScheme.outline),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 10),

          // Serial + Model fields
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _serialCtrl(key),
                  decoration: InputDecoration(
                    labelText: 'Serial no.',
                    hintText: kind == 'machine' ? 'e.g. L4593871' : null,
                    isDense: true,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Consumer(
                  builder: (_, ref, __) {
                    final models = ref.watch(galleryProductModelsProvider);
                    return models.when(
                      data: (list) => PickyField(
                        controller: _modelCtrl(key),
                        label: 'Model',
                        hint:
                            kind == 'machine' ? 'e.g. NEMIO 35' : '',
                        options: list,
                        pickTitle: 'products',
                      ),
                      loading: () => TextField(
                        controller: _modelCtrl(key),
                        decoration: const InputDecoration(
                          labelText: 'Model',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      error: (e, _) => TextField(
                        controller: _modelCtrl(key),
                        decoration: const InputDecoration(
                          labelText: 'Model',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _basename(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  Future<void> _uploadAll() async {
    final toUpload = <String>[];
    if (_machineBytes != null) toUpload.add('machine');
    if (_printerBytes != null) toUpload.add('printer');
    for (final i in Iterable<int>.generate(_probeFiles.length)) {
      if (_probeBytes[i] != null) toUpload.add('probe$i');
    }
    if (toUpload.isEmpty) {
      showSnack(context, 'Select at least one photo.', error: true);
      return;
    }

    setState(() => _uploading = true);
    try {
      await _db.from('image_groups').insert({
        'group_code': _groupCode,
        'batch_name': _batchName,
        'created_at': DateTime.now().toIso8601String(),
      });

      final groupRow = await _db
          .from('image_groups')
          .select('id')
          .eq('group_code', _groupCode)
          .limit(1);
      final groupId = groupRow.first['id'] as int;

      for (final key in toUpload) {
        final isProbe = key.startsWith('probe');
        final probeIndex =
            isProbe ? int.parse(key.replaceAll('probe', '')) : -1;

        final bytes = isProbe
            ? _probeBytes[probeIndex]!
            : (key == 'machine' ? _machineBytes! : _printerBytes!);
        final file = isProbe
            ? _probeFiles[probeIndex]
            : (key == 'machine' ? _machineFile : _printerFile);
        final originalName = _basename(file!.path);
        final safeName =
            originalName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final itemType = key == 'machine'
            ? 'machine'
            : key == 'printer'
                ? 'printer'
                : 'probe';
        final r2Key =
            'batches/$_batchName/$_groupCode/$itemType/$safeName';

        final r2Url = await R2Service.uploadBytes(
          key: r2Key,
          bytes: bytes,
          contentType: 'image/jpeg',
        );

        final serial = _serialControllers[key]?.text.trim();
        final model = _modelControllers[key]?.text.trim();

        await _db.from('item_images').insert({
          'group_id': groupId,
          'item_type': itemType,
          'item_serial':
              (serial == null || serial.isEmpty) ? null : serial,
          'item_model': (model == null || model.isEmpty) ? null : model,
          'r2_key': r2Key,
          'r2_url': r2Url,
          'uploaded_at': DateTime.now().toIso8601String(),
        });
      }

      if (!mounted) return;
      showSnack(
          context, '${toUpload.length} photo(s) uploaded and saved.');
      setState(() {
        _machineFile = null;
        _machineBytes = null;
        _printerFile = null;
        _printerBytes = null;
        _probeFiles.clear();
        _probeBytes.clear();
        for (final c in _serialControllers.values) c.clear();
        for (final c in _modelControllers.values) c.clear();
      });
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'Upload failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }
}

// ── Supporting widgets ───────────────────────────────────────────────────────

/// A numbered step card with a title and arbitrary child content.
class _StepCard extends StatelessWidget {
  final int stepNumber;
  final String title;
  final Widget child;

  const _StepCard({
    required this.stepNumber,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$stepNumber',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// Pill-style badge showing the generated group code.
class _GroupCodeBadge extends StatelessWidget {
  final String code;
  const _GroupCodeBadge({required this.code});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.label_outline,
              size: 16, color: colorScheme.onPrimaryContainer),
          const SizedBox(width: 6),
          Text(
            code,
            style: TextStyle(
              color: colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w900,
              fontSize: 16,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder shown before a group code is generated.
class _EmptyPhotosHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(
        children: [
          Icon(
            Icons.photo_camera_outlined,
            size: 52,
            color: colorScheme.outline.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 16),
          Text(
            'Select a batch and generate\na group code to add photos',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The code (e.g. 1U) is written on the physical machine\nwith a marker, then entered in Inventory.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
