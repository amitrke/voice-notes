import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes/data/templates.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/providers/voice_match.dart';
import 'package:voice_notes/ui/settings_page.dart';

Note _note(List<TimedLine> lines, {String transcript = ''}) => Note(
      provider: 'gemini',
      createdAt: DateTime(2026, 10, 29),
      transcript: transcript,
      segments: [
        Segment(audioPath: '', lines: lines, status: NoteStatus.done),
      ],
    );

void main() {
  group('recognising your voice', () {
    test('picks the closest voice, if close enough', () {
      const mine = [1.0, 0.0, 0.0];
      expect(
          pickYou({
            'S1': [0.0, 1.0, 0.0],
            'S2': [0.9, 0.1, 0.0],
          }, mine),
          'S2');
      expect(pickYou({'S1': [0.2, 1.0, 0.0]}, mine), isNull);
    });

    test('your lines are relabelled and shown as "You"', () {
      final lines = markAsYou([
        const TimedLine(0, 1000, 'hello', speaker: 'S1'),
        const TimedLine(1000, 2000, 'hi', speaker: 'S2'),
      ], 'S2');
      expect(lines.map((l) => l.speaker), ['S1', youSpeakerId]);
      expect(_note(lines).speakerLabel(youSpeakerId), 'You');
    });
  });

  group('speaking feedback', () {
    test('reads only your lines when speakers are labelled', () {
      final s = speakingSample(_note(const [
        TimedLine(0, 30000, 'um so basically we ship', speaker: youSpeakerId),
        TimedLine(30000, 40000, 'sounds good', speaker: 'S1'),
        TimedLine(40000, 70000, 'you know it is basically done',
            speaker: youSpeakerId),
      ]))!;
      expect(s.mine, 'um so basically we ship you know it is basically done');
      expect(s.ms, 60000);
      expect(s.text, contains('Other: sounds good'));
      final numbers = speakingNumbers(s).body;
      expect(numbers, contains('Pace: 11 words a minute'));
      expect(numbers, contains('You spoke for 1 min'));
      expect(numbers, contains('Filler words: 4 ("basically" 2'));
    });

    test('needs your voice when there are several speakers', () {
      expect(
          speakingSample(_note(const [
            TimedLine(0, 1000, 'a', speaker: 'S1'),
            TimedLine(1000, 2000, 'b', speaker: 'S2'),
          ])),
          isNull);
    });

    test('a note with no speaker labels is all yours', () {
      final s = speakingSample(_note(const [], transcript: 'just me'))!;
      expect(s.mine, 'just me');
    });

    test('fillers count whole words only', () {
      expect(countFillers('Umbrella, um, actually! I mean, kind of. Erm.'), {
        'um': 1,
        'actually': 1,
        'i mean': 1,
        'kind of': 1,
        'erm': 1,
      });
    });
  });

  group('voice sample', () {
    test('needs the pauses of someone reading', () {
      expect(sampleVerdict([0.6, 0.7, 0.1, 0.5, 0.8, 0.2, 0.6, 0.7]), isNull);
      expect(sampleVerdict(List.filled(50, 0.1)), contains('too quiet'));
      expect(sampleVerdict(List.filled(50, 0.9)), contains('background noise'));
      expect(sampleVerdict(const []), isNotNull);
    });
  });
}
