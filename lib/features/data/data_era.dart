import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which stock view is open: `before` = the old data as it was on 13-09-2026,
/// `after` = the current stock. Admins pick this once after first login and
/// can switch it any time from the profile menu. Viewers are locked to
/// `after`. The choice is remembered in shared_preferences.
enum DataEra {
  before,
  after;

  bool get isBefore => this == DataEra.before;

  String get label => switch (this) {
        DataEra.before => 'Before 14-9-2026',
        DataEra.after => 'After 14-9-2026',
      };
}

/// The era picked before the first frame, or null if no choice has been
/// made yet (admins see the choice screen then).
DataEra? initialDataEra;

DataEra parseDataEra(String? raw) =>
    raw == 'before' ? DataEra.before : DataEra.after;

/// True when a choice has been stored; used by AuthGate before the first frame.
DataEra? storedDataEra(String? raw) =>
    raw == null ? null : parseDataEra(raw);

class DataEraNotifier extends Notifier<DataEra> {
  @override
  DataEra build() => initialDataEra ?? DataEra.after;

  void set(DataEra era) {
    state = era;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString('dataEra', era.name));
  }
}

final dataEraProvider =
    NotifierProvider<DataEraNotifier, DataEra>(DataEraNotifier.new);

/// True once an admin has made a choice; false means show the choice screen.
final eraChoiceMadeProvider = Provider<bool>(
  (ref) => initialDataEra != null,
);
