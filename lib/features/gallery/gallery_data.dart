import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One image row returned from item_images.
class GalleryImage {
  final int id;
  final int groupId;
  final String itemType;      // 'machine' | 'printer' | 'probe'
  final String? itemSerial;
  final String? itemModel;
  final String r2Key;
  final String r2Url;
  final DateTime uploadedAt;

  GalleryImage({
    required this.id,
    required this.groupId,
    required this.itemType,
    this.itemSerial,
    this.itemModel,
    required this.r2Key,
    required this.r2Url,
    required this.uploadedAt,
  });

  factory GalleryImage.fromMap(Map<String, dynamic> m) => GalleryImage(
        id: m['id'] as int,
        groupId: m['group_id'] as int,
        itemType: m['item_type'] as String,
        itemSerial: m['item_serial'] as String?,
        itemModel: m['item_model'] as String?,
        r2Key: m['r2_key'] as String,
        r2Url: m['r2_url'] as String,
        uploadedAt: DateTime.parse(m['uploaded_at'] as String),
      );
}

/// One image group with its images attached.
class GalleryGroup {
  final int id;
  final String groupCode;     // e.g. '1U'
  final int? batchId;
  final String batchName;
  final DateTime createdAt;
  List<GalleryImage> images;

  GalleryGroup({
    required this.id,
    required this.groupCode,
    this.batchId,
    required this.batchName,
    required this.createdAt,
    this.images = const [],
  });

  factory GalleryGroup.fromMap(Map<String, dynamic> m) => GalleryGroup(
        id: m['id'] as int,
        groupCode: m['group_code'] as String,
        batchId: m['batch_id'] as int?,
        batchName: m['batch_name'] as String? ?? '',
        createdAt: DateTime.parse(m['created_at'] as String),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'group_code': groupCode,
        'batch_id': batchId,
        'batch_name': batchName,
        'created_at': createdAt.toIso8601String(),
      };
}

/// Providers for the image gallery feature.

SupabaseClient get _db => Supabase.instance.client;

/// Next sequential group code (1U, 2U, ...) for a given batch.
final nextGroupCodeProvider = FutureProvider<String>((ref) async {
  final batchName = ref.watch(currentGalleryBatchProvider).value;
  final existing = await _db
      .from('image_groups')
      .select('group_code')
      .eq('batch_name', batchName)
      .order('id', ascending: false)
      .limit(1);
  String last = '0U';
  if (existing.isNotEmpty) {
    last = existing.first['group_code'] as String? ?? '0U';
  }
  final num = int.tryParse(last.replaceAll(RegExp(r'\D'), '')) ?? 0;
  return '${num + 1}U';
});

/// Which batch the gallery is currently viewing/editing.
class _BatchHolder {
  String value = '';
}

final currentGalleryBatchProvider = Provider<_BatchHolder>((ref) {
  return _BatchHolder();
});

/// All groups for the current batch, newest first.
final galleryGroupsProvider =
    FutureProvider<List<GalleryGroup>>((ref) async {
  final batchName = ref.watch(currentGalleryBatchProvider).value;
  if (batchName.isEmpty) return const [];

  final rows = await _db
      .from('image_groups')
      .select('*')
      .eq('batch_name', batchName)
      .order('created_at', ascending: false);

  final groups = <GalleryGroup>[];
  for (final row in rows) {
    final group = GalleryGroup.fromMap(row);
    final imgs = await _db
        .from('item_images')
        .select('*')
        .eq('group_id', group.id)
        .order('uploaded_at');
    group.images =
        imgs.map((m) => GalleryImage.fromMap(m)).toList();
    groups.add(group);
  }
  return groups;
});

/// Create a new image group and return its group_code.
final createImageGroupProvider =
    FutureProvider.family<String, void>((ref, _) async {
  final batchName = ref.watch(currentGalleryBatchProvider).value;
  if (batchName.isEmpty) {
    throw Exception('Select a batch first.');
  }

  final code = await ref.watch(nextGroupCodeProvider.future);

  await _db.from('image_groups').insert({
    'group_code': code,
    'batch_name': batchName,
    'created_at': DateTime.now().toIso8601String(),
  });

  return code;
});

/// Add one image to a group and return its public URL.
final addImageToGroupProvider =
    FutureProvider.family<String, ({
      int groupId,
      String itemType,
      String? itemSerial,
      String? itemModel,
      String r2Key,
      String r2Url,
    })>((ref, args) async {
  await _db.from('item_images').insert({
    'group_id': args.groupId,
    'item_type': args.itemType,
    'item_serial': args.itemSerial,
    'item_model': args.itemModel,
    'r2_key': args.r2Key,
    'r2_url': args.r2Url,
    'uploaded_at': DateTime.now().toIso8601String(),
  });
  return args.r2Url;
});

/// Link an image_group_code to a machine, probe, or printer.
/// Does not touch any existing data — only sets the nullable column.
final linkImageGroupProvider =
    FutureProvider.family<void, ({
      String kind,       // 'machine' | 'probe' | 'printer'
      int itemId,
      String groupCode,
    })>((ref, args) async {
  final table = args.kind == 'machine' ? 'machines' : args.kind == 'probe' ? 'probes' : 'printers';
  await _db
      .from(table)
      .update({'image_group_code': args.groupCode})
      .eq('id', args.itemId);
});

/// Look up items that already carry a given group code.
final itemsByGroupCodeProvider =
    FutureProvider.family<List<Map<String, dynamic>>, ({
      String kind,
      String groupCode,
    })>((ref, args) async {
  final table = args.kind == 'machine' ? 'machines' : args.kind == 'probe' ? 'probes' : 'printers';
  final codeCol = args.kind == 'machine' ? 'machine_id' : 'internal_id';
  final nameCol = args.kind == 'machine' || args.kind == 'probe' ? 'model' : 'name_model';
  final rows = await _db
      .from(table)
      .select('id, $codeCol as code, $nameCol as name, serial_number, status, current_location')
      .eq('image_group_code', args.groupCode);
  return rows.cast<Map<String, dynamic>>();
});
