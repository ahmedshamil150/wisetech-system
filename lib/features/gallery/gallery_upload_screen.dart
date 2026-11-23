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

  // Single optional slots
  XFile? _machineFile;
  Uint8List? _machineBytes;
  XFile? _printerFile;
  Uint8List? _printerBytes;

  // Dynamic probe slots
  final List<XFile?> _probeFiles = [];
  final List<Uint8List?> _probeBytes = [];

  // Controllers keyed by slot id
  final Map<String, TextEditingController> _serialControllers = {};
  final Map<String, TextEditingController> _modelControllers = {};

  SupabaseClient get _db => Supabase.instance.client;

  String _probeKey(int index) => 'probe$index';
  final _kindLabels = {
    'machine': 'Machine',
    'printer': 'Printer',
    'probe': 'Probe',
  };

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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Upload batch pictures',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Photos go to Cloudflare R2. Group code is written on the '
                'physical machine with a marker, then entered in Inventory.',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),
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
                        if (v == null) return;
                        setState(() {
                          _batchName = v;
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
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _uploading || _batchName.isEmpty
                          ? null
                          : _generateGroupCode,
                      icon: _generating
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome, size: 18),
                      label: Text(_groupCode.isEmpty
                          ? 'Generate group code'
                          : 'Group: $_groupCode'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _uploading || _groupCode.isEmpty ? null : _uploadAll,
                    icon: const Icon(Icons.cloud_upload, size: 18),
                    label: const Text('Upload to R2'),
                  ),
                ],
              ),
            ],
          ),
        ),

        if (_groupCode.isNotEmpty)
          Expanded(
            child: _imagePickerPane(),
          )
        else
          const Expanded(
            child: Center(
              child: Text('Select a batch and generate a group code first.'),
            ),
          ),

        if (_groupCode.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _uploading ? null : _uploadAll,
                icon: _uploading
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload, size: 20),
                label: Text(_uploading ? 'Uploading…' : 'Upload all photos to R2'),
              ),
            ),
          ),
      ],
    );
  }

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const Spacer(),
            if (hasImage) const Icon(Icons.check_circle, color: Colors.green, size: 18),
            if (kind == 'probe')
              IconButton(
                icon: const Icon(Icons.remove_circle, color: Colors.red, size: 20),
                onPressed: () => _removeProbe(idx),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
          ],
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => _pickImage(kind, idx),
          child: Container(
            width: double.infinity,
            height: 120,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border.all(
                color: hasImage
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline,
                width: hasImage ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: hasImage
                ? Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          bytes!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: 120,
                        ),
                      ),
                      Positioned(
                        right: 4,
                        top: 4,
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
                            color: Colors.black.withValues(alpha: 0.5),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_a_photo,
                        color: Theme.of(context).colorScheme.outline,
                        size: 32,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Tap to add $label photo',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _serialCtrl(key),
                decoration: InputDecoration(
                  labelText: 'Serial number',
                  hintText: kind == 'machine' ? 'e.g. L4593871' : null,
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                      hint: kind == 'machine' ? 'e.g. NEMIO 35' : '',
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
    );
  }

  Widget _imagePickerPane() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'Photos',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: (MediaQuery.of(context).size.width - 60) / 2 - 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _imageSlot('machine'),
                  const SizedBox(height: 12),
                  _imageSlot('printer'),
                ],
              ),
            ),
            for (final i in Iterable<int>.generate(_probeFiles.length))
              SizedBox(
                width: (MediaQuery.of(context).size.width - 60) / 2 - 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _imageSlot('probe', probeIndex: i),
                  ],
                ),
              ),
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
        const SizedBox(height: 16),
        Text(
          'Group code: $_groupCode  ·  Write this on the machine with a marker.',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  static String _basename(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.last;
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
      // Ensure the group exists (idempotent: reuse if already created)
      final existing = await _db
          .from('image_groups')
          .select('id')
          .eq('group_code', _groupCode)
          .eq('batch_name', _batchName)
          .limit(1);
      int groupId;
      if (existing.isNotEmpty) {
        groupId = existing.first['id'] as int;
      } else {
        final inserted = await _db.from('image_groups').insert({
          'group_code': _groupCode,
          'batch_name': _batchName,
          'created_at': DateTime.now().toIso8601String(),
        }).select('id');
        groupId = inserted.first['id'] as int;
      }

      // Upload each image
      for (final kind in toUpload) {
        final isProbe = kind.startsWith('probe');
        final probeIndex = isProbe ? int.parse(kind.replaceAll('probe', '')) : -1;

        final bytes = isProbe
            ? _probeBytes[probeIndex]!
            : (kind == 'machine' ? _machineBytes! : _printerBytes!);
        final file = isProbe
            ? _probeFiles[probeIndex]
            : (kind == 'machine' ? _machineFile : _printerFile);
        final originalName = _basename(file!.path);
        final safeName =
            originalName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        final itemType = kind == 'machine'
            ? 'machine'
            : kind == 'printer'
                ? 'printer'
                : 'probe';
        final r2Key = 'batches/$_batchName/$_groupCode/$itemType/$safeName';

        final r2Url = await R2Service.uploadBytes(
          key: r2Key,
          bytes: bytes,
          contentType: 'image/jpeg',
        );

        final ctrlKey = isProbe ? _probeKey(probeIndex) : itemType;
        final serial = _serialControllers[ctrlKey]?.text.trim();
        final model = _modelControllers[ctrlKey]?.text.trim();

        await _db.from('item_images').insert({
          'group_id': groupId,
          'item_type': itemType,
          'item_serial': (serial == null || serial.isEmpty) ? null : serial,
          'item_model': (model == null || model.isEmpty) ? null : model,
          'r2_key': r2Key,
          'r2_url': r2Url,
          'uploaded_at': DateTime.now().toIso8601String(),
        });
      }

      if (!mounted) return;
      showSnack(context, '${toUpload.length} photo(s) uploaded to R2 and saved.');
      // Clear selections
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
