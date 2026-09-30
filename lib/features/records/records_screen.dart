import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// Reference data: products, brands, customers, dealers and batches.
/// Admins can add records here; viewers can only read them.
class RecordsScreen extends ConsumerStatefulWidget {
  const RecordsScreen({super.key});

  @override
  ConsumerState<RecordsScreen> createState() => _RecordsScreenState();
}

const _sections = ['product', 'brand', 'customer', 'dealer', 'batch'];
const _addLabels = [
  'Add product',
  'Add brand',
  'Add customer',
  'Add dealer',
  'New batch',
];

class _RecordsScreenState extends ConsumerState<RecordsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 5, vsync: this);
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tab.addListener(_sync);
  }

  void _sync() => setState(() {});

  @override
  void dispose() {
    _tab.removeListener(_sync);
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    return Column(
      children: [
        Material(
          color: Colors.white,
          child: TabBar(
            controller: _tab,
            isScrollable: true,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700),
            tabs: const [
              Tab(text: 'Products'),
              Tab(text: 'Brands'),
              Tab(text: 'Customers'),
              Tab(text: 'Dealers'),
              Tab(text: 'Batches'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SearchField(
            hint: 'Search records',
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _ProductsPane(query: _query),
              _BrandsPane(query: _query),
              _PeoplePane(table: 'customers', query: _query),
              _PeoplePane(table: 'dealers', query: _query),
              _BatchesPane(query: _query),
            ],
          ),
        ),
        if (isAdmin)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(
              onPressed: () => showRecordForm(context, _sections[_tab.index]),
              icon: const Icon(Icons.add),
              label: Text(_addLabels[_tab.index]),
            ),
          ),
      ],
    );
  }
}

Future<void> showRecordForm(BuildContext context, String kind) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: kind == 'batch'
          ? const _BatchForm()
          : _RecordForm(kind: kind),
    ),
  );
}

// ---------------------------------------------------------------------------
// list panes
// ---------------------------------------------------------------------------

class _ProductsPane extends ConsumerWidget {
  const _ProductsPane({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(productsProvider);
    return products.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (rows) {
        final filtered = rows.where((row) {
          if (query.isEmpty) return true;
          final name = (row['name_model'] ?? '').toString().toLowerCase();
          final brand =
              ((row['brands'] as Map?)?['name'] ?? '').toString().toLowerCase();
          return name.contains(query) || brand.contains(query);
        }).toList();
        if (filtered.isEmpty) {
          return const EmptyState(
              icon: Icons.inventory_2_outlined, message: 'No products found.');
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) => _productTile(context, filtered[index]),
        );
      },
    );
  }

  Widget _productTile(BuildContext context, Map<String, dynamic> row) {
    final category = (row['category'] ?? 'Other').toString();
    final brand = ((row['brands'] as Map?)?['name'] ?? '').toString();
    final probeType = (row['probe_type'] ?? '').toString();
    final icon = switch (category) {
      'Machine' => Icons.monitor_outlined,
      'Probe' => Icons.cable_outlined,
      'Printer' => Icons.print_outlined,
      'Part' => Icons.settings_outlined,
      _ => Icons.category_outlined,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: const Color(0xFFEAF3F8),
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
          title: Text((row['name_model'] ?? '').toString(),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text([
            category,
            if (brand.isNotEmpty) brand,
            if (probeType.isNotEmpty) probeType,
          ].join(' · ')),
        ),
      ),
    );
  }
}

class _BrandsPane extends ConsumerWidget {
  const _BrandsPane({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brands = ref.watch(brandsProvider);
    return brands.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (rows) {
        final filtered = rows
            .where((row) =>
                query.isEmpty ||
                (row['name'] ?? '').toString().toLowerCase().contains(query))
            .toList();
        if (filtered.isEmpty) {
          return const EmptyState(
              icon: Icons.branding_watermark_outlined,
              message: 'No brands found.');
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final row = filtered[index];
            final note = (row['notes'] ?? '').toString();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFEAF3F8),
                    child: Icon(Icons.branding_watermark_outlined),
                  ),
                  title: Text((row['name'] ?? '').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: note.isEmpty ? null : Text(note),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PeoplePane extends ConsumerWidget {
  const _PeoplePane({required this.table, required this.query});

  final String table; // customers | dealers
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = table == 'customers' ? customersProvider : dealersProvider;
    final rows = ref.watch(provider);
    return rows.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (records) {
        final filtered = records.where((row) {
          if (query.isEmpty) return true;
          final name = (row['name'] ?? '').toString().toLowerCase();
          final city = (row['city'] ?? '').toString().toLowerCase();
          final phone = (row['phone'] ?? '').toString().toLowerCase();
          return name.contains(query) ||
              city.contains(query) ||
              phone.contains(query);
        }).toList();
        if (filtered.isEmpty) {
          return EmptyState(
            icon: table == 'customers'
                ? Icons.people_outline
                : Icons.handshake_outlined,
            message: 'No $table found.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final row = filtered[index];
            final parts = [
              if ((row['phone'] ?? '').toString().isNotEmpty)
                row['phone'].toString(),
              if ((row['city'] ?? '').toString().isNotEmpty)
                row['city'].toString(),
              if ((row['address'] ?? '').toString().isNotEmpty)
                row['address'].toString(),
            ];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFEAF3F8),
                    child: Icon(
                      table == 'customers'
                          ? Icons.person_outline
                          : Icons.handshake_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  title: Text((row['name'] ?? '').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle:
                      parts.isEmpty ? null : Text(parts.join(' · ')),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// batches
// ---------------------------------------------------------------------------

class _BatchesPane extends ConsumerWidget {
  const _BatchesPane({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batches = ref.watch(batchesProvider);
    final current = ref.watch(currentBatchProvider);

    return batches.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (rows) {
        final currentId = current.maybeWhen(
          data: (row) => row?['id'],
          orElse: () => null,
        );
        final filtered = rows.where((row) {
          if (query.isEmpty) return true;
          final letter = (row['letter'] ?? '').toString().toLowerCase();
          final code = (row['code'] ?? '').toString().toLowerCase();
          final vendor = ((row['vendors'] as Map?)?['name'] ?? '')
              .toString()
              .toLowerCase();
          final date = (row['arrival_date'] ?? '').toString().toLowerCase();
          return letter.contains(query) ||
              code.contains(query) ||
              vendor.contains(query) ||
              date.contains(query);
        }).toList();
        if (filtered.isEmpty) {
          return const EmptyState(
              icon: Icons.inventory_outlined,
              message: 'No batches yet. Create one so you can enter stock.');
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final row = filtered[index];
            final letter = (row['letter'] ?? '?').toString();
            final vendor = ((row['vendors'] as Map?)?['name'] ?? '')
                .toString();
            final isCurrent = row['id'] == currentId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFEAF3F8),
                    child: Text(letter,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w800)),
                  ),
                  title: Text('Batch $letter',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text([
                    row['arrival_date'] ?? '',
                    if (vendor.isNotEmpty) vendor,
                    (row['code'] ?? '').toString(),
                  ].join(' · ')),
                  trailing: isCurrent
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('New stock',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700)),
                        )
                      : null,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _BatchForm extends ConsumerStatefulWidget {
  const _BatchForm();

  @override
  ConsumerState<_BatchForm> createState() => _BatchFormState();
}

class _BatchFormState extends ConsumerState<_BatchForm> {
  final _letter = TextEditingController();
  final _vendor = TextEditingController();
  final _date = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;
  bool _loadingLetter = true;

  @override
  void initState() {
    super.initState();
    _date.text = DateField.format(DateTime.now());
    _loadLetter();
  }

  @override
  void dispose() {
    for (final c in [_letter, _vendor, _date, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadLetter() async {
    try {
      final letter = await suggestedBatchLetter();
      if (mounted) _letter.text = letter;
    } catch (_) {
      if (mounted) _letter.text = 'U';
    } finally {
      if (mounted) setState(() => _loadingLetter = false);
    }
  }

  Future<void> _save() async {
    final letter = _letter.text.trim().toUpperCase();
    if (letter.length != 1 || !RegExp(r'^[A-Z]$').hasMatch(letter)) {
      showSnack(context, 'The batch letter must be a single letter (U).',
          error: true);
      return;
    }
    if (_vendor.text.trim().isEmpty) {
      showSnack(context, 'Vendor is required.', error: true);
      return;
    }
    if (_date.text.trim().isEmpty) {
      showSnack(context, 'Arrival date is required.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final vendorId = await resolveReferenceId(
          table: 'vendors', name: _vendor.text.trim());
      final row = await db
          .from('batches')
          .insert({
            'code': 'BATCH-$letter',
            'letter': letter,
            'arrival_date': _date.text.trim(),
            'vendor_id': vendorId,
            if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
          })
          .select('id')
          .single();
      await setCurrentBatch(row['id'] as int);
      ref
        ..invalidate(batchesProvider)
        ..invalidate(currentBatchProvider)
        ..invalidate(vendorsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
          content: Text(
              'Batch $letter created — new stock goes into it.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vendorNames = ref.watch(vendorsProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('New batch',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _letter,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 1,
                    decoration: InputDecoration(
                      labelText: 'Batch letter',
                      hintText: 'U',
                      counterText: '',
                      suffixIcon: _loadingLetter
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  PickyField(
                    controller: _vendor,
                    label: 'Vendor *',
                    hint: 'Search vendors',
                    options: vendorNames,
                    pickTitle: 'vendors',
                  ),
                  const SizedBox(height: 12),
                  DateField(controller: _date, label: 'Arrival date *'),
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
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create batch'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// add form
// ---------------------------------------------------------------------------

class _RecordForm extends ConsumerStatefulWidget {
  const _RecordForm({required this.kind});

  final String kind; // product | brand | customer | dealer

  @override
  ConsumerState<_RecordForm> createState() => _RecordFormState();
}

class _RecordFormState extends ConsumerState<_RecordForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  final _address = TextEditingController();
  final _brand = TextEditingController();
  final _probeType = TextEditingController();
  String _category = 'Machine';
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _city, _address, _brand, _probeType]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _title => switch (widget.kind) {
        'product' => 'Add product',
        'brand' => 'Add brand',
        'customer' => 'Add customer',
        _ => 'Add dealer',
      };

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showSnack(context, 'Name is required.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (widget.kind) {
        case 'brand':
          await db.from('brands').insert({'name': name});
          ref.invalidate(brandsProvider);
        case 'product':
          int? brandId;
          if (_brand.text.trim().isNotEmpty) {
            brandId = await resolveReferenceId(
                table: 'brands', name: _brand.text.trim());
          }
          final payload = <String, dynamic>{
            'name_model': name,
            'category': _category,
          };
          if (brandId != null) payload['brand_id'] = brandId;
          if (_category == 'Probe' && _probeType.text.trim().isNotEmpty) {
            payload['probe_type'] = _probeType.text.trim();
          }
          await db.from('catalog_products').insert(payload);
          ref
            ..invalidate(productsProvider)
            ..invalidate(brandsProvider);
        case 'customer':
          await db.from('customers').insert({
            'name': name,
            'phone': _phone.text.trim(),
            'city': _city.text.trim(),
            'address': _address.text.trim(),
            'customer_type': 'Customer',
          });
          ref.invalidate(customersProvider);
        default:
          await db.from('dealers').insert({
            'name': name,
            'phone': _phone.text.trim(),
            'city': _city.text.trim(),
            'address': _address.text.trim(),
          });
          ref.invalidate(dealersProvider);
      }
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text('$name added.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brandNames = ref.watch(brandsProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_title,
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
                  if (widget.kind == 'product') ...[
                    PickyField(
                      controller: _name,
                      label: 'Product name *',
                      hint: 'e.g. LOGIQ P6',
                      options: ref.watch(productsProvider).maybeWhen(
                            data: (rows) => rows
                                .map((r) => r['name_model'].toString())
                                .toList(),
                            orElse: () => const <String>[],
                          ),
                      pickTitle: 'products',
                    ),
                    const SizedBox(height: 12),
                    const Text('Category',
                        style: TextStyle(fontSize: 13, color: kMuted)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      key: ValueKey('category-$_category'),
                      initialValue: _category,
                      items: const [
                        'Machine',
                        'Probe',
                        'Printer',
                        'Accessory',
                        'Part',
                        'Other',
                      ]
                          .map((c) =>
                              DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _category = v ?? 'Machine'),
                    ),
                    const SizedBox(height: 12),
                    PickyField(
                      controller: _brand,
                      label: 'Brand',
                      hint: 'Start typing or search',
                      options: brandNames,
                      pickTitle: 'brands',
                    ),
                    if (_category == 'Probe') ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _probeType,
                        decoration: const InputDecoration(
                          labelText: 'Probe type',
                          hintText: 'Convex, Linear, Phased Array…',
                        ),
                      ),
                    ],
                  ] else if (widget.kind == 'brand') ...[
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                          labelText: 'Brand name *'),
                    ),
                  ] else ...[
                    TextField(
                      controller: _name,
                      decoration:
                          InputDecoration(labelText: '${_title.split(' ').last} name *'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration:
                          const InputDecoration(labelText: 'Phone'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _city,
                      decoration: const InputDecoration(labelText: 'City'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _address,
                      decoration:
                          const InputDecoration(labelText: 'Address'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text('Save'),
          ),
        ],
      ),
    );
  }
}
