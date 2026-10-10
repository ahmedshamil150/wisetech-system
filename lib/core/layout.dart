import 'package:flutter/material.dart';

/// True when the window is wide enough for the desktop layout.
/// Phones and narrow windows keep the existing mobile layout.
bool isDesktopLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 900;

/// Centers content with a max width on desktop so lists and cards
/// don't stretch edge-to-edge on wide screens.
Widget desktopWrap(BuildContext context, Widget child) {
  if (!isDesktopLayout(context)) return child;
  return Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: child,
    ),
  );
}

/// Opens [child] as a bottom sheet on phone or a centered dialog on desktop.
/// [title] is the dialog header; on phone it becomes the sheet title.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  double heightFraction = 0.85,
}) {
  if (isDesktopLayout(context)) {
    return showDialog<T>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
        content: SizedBox(
          width: 560,
          child: builder(dialogContext),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * heightFraction,
      child: builder(sheetContext),
    ),
  );
}
