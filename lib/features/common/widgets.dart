import 'package:flutter/material.dart';

const Color kMuted = Color(0xFF5B6B7B);
const Color kHint = Color(0xFF8A97A3);

class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE2E9F0)),
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: kHint),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kMuted, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.onChanged, this.hint = 'Search'});

  final ValueChanged<String> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      ),
    );
  }
}

Color statusColor(String status) => switch (status) {
      'In Stock' || 'Available' => const Color(0xFF1B7F4B),
      'With Workshop' => const Color(0xFFB26A00),
      'With Dealer' => const Color(0xFF6A3FB2),
      'With Machine' => const Color(0xFF1668A8),
      'Sold' => const Color(0xFFB3261E),
      'Archived' => kHint,
      _ => kMuted,
    };

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: TextStyle(
            color: color, fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? const Color(0xFFB3261E) : null,
    ));
}

/// A date entry in `dd-MM-yyyy` (the format used by the legacy data).
/// The suffix button opens the calendar; text can also be typed in.
class DateField extends StatelessWidget {
  const DateField({super.key, required this.controller, this.label = 'Date'});

  final TextEditingController controller;
  final String label;

  static String format(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.year}';

  Future<void> _pick(BuildContext context) async {
    var initial = DateTime.now();
    final parts = controller.text.split('-');
    if (parts.length == 3) {
      final day = int.tryParse(parts[0]);
      final month = int.tryParse(parts[1]);
      final year = int.tryParse(parts[2]);
      if (day != null && month != null && year != null) {
        initial = DateTime(year, month, day);
      }
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
    );
    if (picked != null) controller.text = format(picked);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'DD-MM-YYYY',
        suffixIcon: IconButton(
          tooltip: 'Pick a date',
          icon: const Icon(Icons.calendar_today_outlined, size: 18),
          onPressed: () => _pick(context),
        ),
      ),
    );
  }
}

/// A label + value line used inside the forms and detail rows.
class KeyValue extends StatelessWidget {
  const KeyValue({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(color: kHint, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style:
                    const TextStyle(fontSize: 13.5, color: Color(0xFF25313D))),
          ),
        ],
      ),
    );
  }
}

/// A text field whose trailing button opens a searchable list of choices.
/// The field still accepts free text, so a value can also be typed in.
class PickyField extends StatelessWidget {
  const PickyField({
    super.key,
    required this.controller,
    required this.hint,
    required this.options,
    required this.pickTitle,
    this.label,
    this.keyboardType,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final String pickTitle;
  final List<String> options;
  final String? label;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(label!,
              style: const TextStyle(fontSize: 13, color: kMuted)),
          const SizedBox(height: 6),
        ],
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: IconButton(
              tooltip: 'Search $pickTitle',
              icon: const Icon(Icons.search, size: 20),
              onPressed: () async {
                final picked = await showPickFromList(
                  context: context,
                  title: pickTitle,
                  options: options,
                  selected: controller.text,
                );
                if (picked != null) {
                  controller.text = picked;
                  onChanged?.call(picked);
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-height sheet with a search box and a list of strings.
/// Returns the chosen value, or null when cancelled.
Future<String?> showPickFromList({
  required BuildContext context,
  required String title,
  required List<String> options,
  String? selected,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      var query = '';
      return StatefulBuilder(
        builder: (context, setState) {
          final matches = query.isEmpty
              ? options
              : options
                  .where((o) => o.toLowerCase().contains(query.toLowerCase()))
                  .toList();
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.75,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(title,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SearchField(
                    hint: 'Search ${options.length} entries',
                    onChanged: (value) => setState(() => query = value),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: matches.isEmpty
                      ? const EmptyState(
                          icon: Icons.search_off,
                          message: 'Nothing matches that search.')
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          itemCount: matches.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final option = matches[index];
                            final isSelected = option == selected;
                            return ListTile(
                              dense: true,
                              title: Text(option),
                              trailing: isSelected
                                  ? Icon(Icons.check,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary)
                                  : null,
                              onTap: () =>
                                  Navigator.pop(sheetContext, option),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

