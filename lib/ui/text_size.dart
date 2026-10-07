import 'package:flutter/material.dart';

import '../data/text_scale.dart';

/// A slider with a small "A" at one end and a large "A" at the other, a live
/// preview line and the current percentage. It only reports changes; the caller
/// decides where to keep the value.
class TextSizeControl extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const TextSizeControl({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final index = textScaleSteps.indexOf(snapTextScale(value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('A', style: TextStyle(fontSize: 14)),
            Expanded(
              child: Slider(
                min: 0,
                max: (textScaleSteps.length - 1).toDouble(),
                divisions: textScaleSteps.length - 1,
                value: index.toDouble(),
                label: textScaleLabel(textScaleSteps[index]),
                semanticFormatterCallback: (v) =>
                    'Text size ${textScaleLabel(textScaleSteps[v.round()])}',
                onChanged: (v) => onChanged(textScaleSteps[v.round()]),
              ),
            ),
            const Text('A', style: TextStyle(fontSize: 26)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '${textScaleLabel(textScaleSteps[index])}  ·  The quick brown fox jumps over the lazy dog.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// Shows [TextSizeControl] in a bottom sheet, for a quick change from a note.
Future<void> showTextSizeSheet(
  BuildContext context, {
  required double Function() current,
  required ValueChanged<double> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => StatefulBuilder(
      builder: (context, setSheetState) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Text size', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextSizeControl(
              value: current(),
              onChanged: (v) {
                onChanged(v);
                setSheetState(() {});
              },
            ),
          ],
        ),
      ),
    ),
  );
}
