import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes/ui/format.dart';

void main() {
  group('dayLabel', () {
    final now = DateTime(2026, 10, 8, 9, 30);

    test('names today and yesterday', () {
      expect(dayLabel(DateTime(2026, 10, 8, 0, 5), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 10, 7, 23, 59), now: now), 'Yesterday');
    });

    test('uses the weekday within the last week', () {
      expect(dayLabel(DateTime(2026, 10, 3, 12), now: now), 'Saturday');
    });

    test('uses a date after that, with the year only when it differs', () {
      expect(dayLabel(DateTime(2026, 9, 1, 12), now: now), 'Tue, 1 Sep');
      expect(dayLabel(DateTime(2025, 12, 31, 12), now: now), '31 Dec 2025');
    });
  });

  test('isEnglish recognises codes and names', () {
    expect(isEnglish('en-IN'), isTrue);
    expect(isEnglish('english'), isTrue);
    expect(isEnglish('hi-IN'), isFalse);
    expect(isEnglish(null), isFalse);
  });
}
