import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data.dart';
import '../../core/layout.dart';

export '../../core/palette.dart';

class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding, this.onTap});

  final Widget child;
  final EdgeInsets? padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // cardTheme (light + dark) carries the colour, radius and border.
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class SearchField extends StatelessWidget {
  const SearchField(
      {super.key, required this.onChanged, this.hint = 'Search', this.controller});

  final ValueChanged<String> onChanged;
  final String hint;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autocorrect: false,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      ),
    );
  }
}

/// The colour of a status pill; dark mode gets lightened variants so the
/// small bold text keeps its contrast on dark cards.
Color statusColor(String status, [Brightness brightness = Brightness.light]) {
  final Color base = switch (status) {
    'In Stock' || 'Available' => const Color(0xFF1B7F4B),
    'With Workshop' => const Color(0xFF9A5A00),
    'With Branch' => const Color(0xFF6D4C41),
    'With Dealer' => const Color(0xFF6A3FB2),
    'With Customer' => const Color(0xFF0E7C86),
    'With Machine' => const Color(0xFF1668A8),
    'Sold' => const Color(0xFFB3261E),
    'Archived' => const Color(0xFF666F7A),
    _ => const Color(0xFF5B6B7B),
  };
  if (brightness == Brightness.dark) {
    return Color.lerp(base, Colors.white, 0.42)!;
  }
  return base;
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status, Theme.of(context).brightness);
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
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: error
          ? Text(message,
              style: TextStyle(
                  color: scheme.onError,
                  fontSize: 14,
                  fontWeight: FontWeight.w600))
          : Text(message),
      backgroundColor: error ? scheme.error : null,
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
      autocorrect: false,
      keyboardType: TextInputType.datetime,
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
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(color: scheme.outline, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 13.5, color: scheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

/// A text field that suggests matches while you type - everything that
/// starts with what you wrote comes first, the rest follows, so typing "P"
/// shows every option starting with P without pressing anything.
/// The field still accepts free text; the trailing button opens the full
/// searchable list.
class PickyField extends StatefulWidget {
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
  State<PickyField> createState() => _PickyFieldState();
}

class _PickyFieldState extends State<PickyField> {
  final _focus = FocusNode();
  String _query = '';
  bool _showList = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _query = widget.controller.text;
    _focus.addListener(() {
      if (!_focus.hasFocus && mounted) _hideListSoon();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  /// Hiding on focus loss must not race an in-flight tap: on desktop, web
  /// and stylus input the field unfocuses on pointer-DOWN, which would
  /// unmount the suggestions before the tap's pointer-up and the click
  /// would be lost. Defer the hide so the tap can complete first.
  void _hideListSoon() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted && !_focus.hasFocus && _showList) {
        setState(() => _showList = false);
      }
    });
  }

  /// "starts with" matches first (like a search box), then the rest,
  /// each group in alphabetical order.
  List<String> get _matches {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return const <String>[];
    final starts = <String>[];
    final rest = <String>[];
    for (final option in widget.options) {
      final value = option.toLowerCase();
      if (value.startsWith(query)) {
        starts.add(option);
      } else if (value.contains(query)) {
        rest.add(option);
      }
    }
    int byText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    starts.sort(byText);
    rest.sort(byText);
    return [...starts, ...rest];
  }

  void _select(String value) {
    _hideTimer?.cancel();
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged?.call(value);
    setState(() => _showList = false);
  }

  @override
  Widget build(BuildContext context) {
    final matches = _showList ? _matches : const <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
        ],
        TextField(
          controller: widget.controller,
          focusNode: _focus,
          keyboardType: widget.keyboardType,
          autocorrect: false,
          onChanged: (value) {
            widget.onChanged?.call(value);
            setState(() {
              _query = value;
              _showList = true;
            });
          },
          decoration: InputDecoration(
            hintText: widget.hint,
            suffixIcon: IconButton(
              tooltip: 'Browse ${widget.pickTitle}',
              icon: const Icon(Icons.search, size: 20),
              onPressed: () async {
                final picked = await showPickFromList(
                  context: context,
                  title: widget.pickTitle,
                  options: widget.options,
                  selected: widget.controller.text,
                );
                if (picked != null && mounted) {
                  widget.controller.text = picked;
                  widget.onChanged?.call(picked);
                  setState(() => _showList = false);
                }
              },
            ),
          ),
        ),
        if (matches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: AppCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final option in matches)
                        InkWell(
                          onTap: () => _select(option),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(option,
                                      style: const TextStyle(fontSize: 14)),
                                ),
                                Icon(Icons.north_west,
                                    size: 14,
                                    color:
                                        Theme.of(context).colorScheme.outline),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
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
  return showAppSheet<String>(
    context: context,
    title: title,
    heightFraction: 0.75,
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

/// Wrap a page's scrollable: pulling down refetches everything, so you
/// see what another member just changed without restarting the app.
class AppRefresh extends ConsumerWidget {
  const AppRefresh({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () => refreshAll(ref),
      child: child,
    );
  }
}

