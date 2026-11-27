import 'package:flutter/material.dart';

/// Shows a bottom sheet that always leaves a way out: it stays below the
/// status bar and never covers the whole screen, so the dimmed area above it
/// can be tapped, and [SheetHeader] gives it a close button. iPhones have no
/// back button, so a sheet that fills the screen is otherwise a dead end.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) =>
    showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * maxSheetHeight),
      builder: builder,
    );

/// The most of the screen's height a sheet from [showAppSheet] takes.
const maxSheetHeight = 0.85;

/// A sheet's title with a close button beside it.
class SheetHeader extends StatelessWidget {
  final String title;
  final TextStyle? style;
  final EdgeInsetsGeometry padding;
  const SheetHeader(this.title,
      {super.key, this.style, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: style ?? Theme.of(context).textTheme.titleMedium),
            ),
            IconButton(
              key: const ValueKey('sheet_close'),
              icon: const Icon(Icons.close),
              tooltip: 'Close',
              onPressed: () => Navigator.maybePop(context),
            ),
          ],
        ),
      );
}
