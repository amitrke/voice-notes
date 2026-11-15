import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Where the share sheet points on iPad, which shows it as a popover and
/// refuses to open without an anchor: the widget [context] belongs to, or
/// with [topRight], the top right corner of it (for a page whose share
/// starts from an app bar menu). Phones ignore it.
Rect? shareOrigin(BuildContext context, {bool topRight = false}) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return null;
  final all = box.localToGlobal(Offset.zero) & box.size;
  if (!topRight) return all;
  final w = math.min(48.0, all.width);
  return Rect.fromLTWH(all.right - w, all.top, w, math.min(48.0, all.height));
}
