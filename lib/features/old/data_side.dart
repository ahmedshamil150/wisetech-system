import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Set in `main()` before the first frame so the shell opens on the side
/// the user chose last time.
String? initialDataSide;

/// Which dataset the whole app is showing: `'current'` (the post-14-9-2026
/// data) or `'old'` (the imported legacy stock, movements and sales).
/// Persisted so a refresh keeps the choice.
class DataSideNotifier extends Notifier<String> {
  @override
  String build() => initialDataSide ?? 'current';

  Future<void> set(String side) async {
    state = side;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dataSide', side);
  }
}

final dataSideProvider =
    NotifierProvider<DataSideNotifier, String>(DataSideNotifier.new);

bool isOldSide(Ref ref) => ref.watch(dataSideProvider) == 'old';
