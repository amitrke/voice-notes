import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/data/text_scale.dart';
import 'package:voice_notes/ui/text_size.dart';

void main() {
  group('snapTextScale', () {
    test('keeps exact steps', () {
      for (final s in textScaleSteps) {
        expect(snapTextScale(s), s);
      }
    });

    test('snaps in-between and out-of-range values to the nearest step', () {
      expect(snapTextScale(1.1), 1.15);
      expect(snapTextScale(1.02), 1.0);
      expect(snapTextScale(0.1), textScaleSteps.first);
      expect(snapTextScale(9), textScaleSteps.last);
    });

    test('labels as a percentage', () {
      expect(textScaleLabel(1.0), '100%');
      expect(textScaleLabel(1.15), '115%');
      expect(textScaleLabel(2.0), '200%');
    });
  });

  group('SettingsStore text scale', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('defaults to normal size', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore();
      await store.load();
      expect(store.textScale, 1.0);
    });

    test('is saved, snapped, and restored on the next launch', () async {
      SharedPreferences.setMockInitialValues({});
      final first = SettingsStore();
      await first.load();
      await first.setTextScale(1.45); // nearest step is 1.5
      expect(first.textScale, 1.5);

      final second = SettingsStore(); // same underlying preferences
      await second.load();
      expect(second.textScale, 1.5);
    });

    test('a corrupt saved value is repaired on load', () async {
      SharedPreferences.setMockInitialValues({'textScale': 57.0});
      final store = SettingsStore();
      await store.load();
      expect(store.textScale, textScaleSteps.last);
    });
  });

  group('TextSizeControl', () {
    Widget host(double value, ValueChanged<double> onChanged) => MaterialApp(
          home: Scaffold(body: TextSizeControl(value: value, onChanged: onChanged)),
        );

    testWidgets('shows the current percentage', (tester) async {
      await tester.pumpWidget(host(1.3, (_) {}));
      expect(find.textContaining('130%'), findsOneWidget);
    });

    testWidgets('dragging the slider reports a step', (tester) async {
      double? picked;
      await tester.pumpWidget(host(1.0, (v) => picked = v));
      // Drag the thumb to the far right, which is the largest step.
      await tester.drag(find.byType(Slider), const Offset(1000, 0));
      await tester.pump();
      expect(picked, textScaleSteps.last);
    });

    testWidgets('tolerates a value that is not one of the steps', (tester) async {
      await tester.pumpWidget(host(1.12, (_) {}));
      expect(find.textContaining('115%'), findsOneWidget);
    });
  });
}
