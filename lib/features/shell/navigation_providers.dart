import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which tab the shell is showing. The dashboard sets it to jump straight
/// to another page when one of its cards is tapped.
class ShellTabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void set(int index) => state = index;
}

final shellTabProvider =
    NotifierProvider<ShellTabNotifier, int>(ShellTabNotifier.new);
