import '../models/note.dart';

/// True when at least one finished recording has timestamps to export.
bool hasTimedText(Note note) => note.segments
    .any((s) => s.status == NoteStatus.done && s.lines.isNotEmpty);

/// The note as SubRip subtitles. Recordings follow one another, so each one's
/// times are offset by the length of the recordings before it. Recordings
/// without timestamps add no cues but still count towards the offset.
/// With [english], lines use their English text where they have one.
String srtText(Note note, {bool english = false}) {
  final b = StringBuffer();
  var offset = 0;
  var n = 0;
  for (final seg in note.segments) {
    if (seg.status == NoteStatus.done) {
      for (final l in seg.lines) {
        final text =
            (english && l.english.trim().isNotEmpty ? l.english : l.text).trim();
        if (text.isEmpty) continue;
        n++;
        b
          ..writeln(n)
          ..writeln('${srtTime(offset + l.startMs)} --> '
              '${srtTime(offset + l.endMs)}')
          ..writeln(text)
          ..writeln();
      }
    }
    offset += seg.durationMs ?? (seg.lines.isEmpty ? 0 : seg.lines.last.endMs);
  }
  return b.toString();
}

/// 3723004 -> "01:02:03,004"
String srtTime(int ms) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = ms ~/ 3600000;
  final m = ms ~/ 60000 % 60;
  final s = ms ~/ 1000 % 60;
  return '${two(h)}:${two(m)}:${two(s)},${(ms % 1000).toString().padLeft(3, '0')}';
}
