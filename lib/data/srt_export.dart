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
        final spoken =
            (english && l.english.trim().isNotEmpty ? l.english : l.text).trim();
        if (spoken.isEmpty) continue;
        final text = l.speaker == null
            ? spoken
            : '${note.speakerLabel(l.speaker!)}: $spoken';
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

/// True when the speakers of at least one line are known.
bool hasSpeakers(Note note) => note.speakerIds.isNotEmpty;

/// The transcript as text with "Name: ..." paragraphs, one per change of
/// speaker. Recordings without speaker labels contribute their plain text.
/// With [english], lines use their English text where they have one.
String speakerTranscript(Note note, {bool english = false}) {
  final parts = <String>[];
  for (final seg in note.segments) {
    if (seg.status != NoteStatus.done) continue;
    if (seg.lines.every((l) => l.speaker == null)) {
      final plain = (english && seg.english.trim().isNotEmpty
              ? seg.english
              : seg.transcript)
          .trim();
      if (plain.isNotEmpty) parts.add(plain);
      continue;
    }
    String? current;
    final buffer = StringBuffer();
    void flush() {
      final t = buffer.toString().trim();
      if (t.isNotEmpty) {
        parts.add(current == null ? t : '${note.speakerLabel(current)}: $t');
      }
      buffer.clear();
    }

    for (final l in seg.lines) {
      final text =
          (english && l.english.trim().isNotEmpty ? l.english : l.text).trim();
      if (text.isEmpty) continue;
      if (l.speaker != current) {
        flush();
        current = l.speaker;
      }
      buffer.write(buffer.isEmpty ? text : ' $text');
    }
    flush();
  }
  return parts.join('\n\n');
}

/// 3723004 -> "01:02:03,004"
String srtTime(int ms) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = ms ~/ 3600000;
  final m = ms ~/ 60000 % 60;
  final s = ms ~/ 1000 % 60;
  return '${two(h)}:${two(m)}:${two(s)},${(ms % 1000).toString().padLeft(3, '0')}';
}
