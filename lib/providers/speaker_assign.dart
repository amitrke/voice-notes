import 'ai_provider.dart';

/// A stretch of a recording in which one voice (numbered by the diarizer) talks.
typedef SpeakerTurn = ({int startMs, int endMs, int speaker});

/// Labels each line with the voice that talks the longest during it.
///
/// Voices get ids "S1", "S2", ... in the order they first appear in [lines],
/// whatever numbers the diarizer used. A line no voice overlaps keeps the
/// previous line's speaker (or none, at the very start).
List<TimedLine> assignSpeakers(List<TimedLine> lines, List<SpeakerTurn> turns) {
  if (turns.isEmpty) return lines;
  final ids = <int, String>{};
  String? previous;
  final out = <TimedLine>[];
  for (final line in lines) {
    final overlap = <int, int>{};
    for (final t in turns) {
      final ms = _min(line.endMs, t.endMs) - _max(line.startMs, t.startMs);
      if (ms > 0) overlap[t.speaker] = (overlap[t.speaker] ?? 0) + ms;
    }
    String? id = previous;
    if (overlap.isNotEmpty) {
      final best = overlap.entries.reduce((a, b) => b.value > a.value ? b : a);
      id = ids.putIfAbsent(best.key, () => 'S${ids.length + 1}');
    }
    previous = id;
    out.add(id == null ? line : line.copyWith(speaker: id));
  }
  return out;
}

int _min(int a, int b) => a < b ? a : b;
int _max(int a, int b) => a > b ? a : b;
