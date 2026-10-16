import '../models/note.dart';
import '../providers/ai_provider.dart';

/// Replaces one piece of text with another, the same way everywhere it is
/// applied: plain text (not a pattern), optionally matching case.
class TextReplacer {
  final String find;
  final String replacement;
  final bool matchCase;
  late final RegExp _pattern =
      RegExp(RegExp.escape(find), caseSensitive: matchCase, unicode: true);

  TextReplacer(this.find, this.replacement, {this.matchCase = false});

  bool get isEmpty => find.isEmpty;

  int count(String text) => isEmpty ? 0 : _pattern.allMatches(text).length;

  String apply(String text) =>
      isEmpty ? text : text.replaceAll(_pattern, replacement);
}

/// How many times [r]'s text appears in what a user sees of [n]: its title,
/// summary, transcript and English text.
int countInNote(Note n, TextReplacer r) =>
    r.count(n.title) +
    r.count(n.summary) +
    r.count(n.transcript) +
    r.count(n.english);

/// [n] with [r] applied to its title, summary, clinical note and every
/// recording's text. [changed] holds the recordings whose text changed, which
/// the caller must save. Returns null when nothing matched.
///
/// A summary that was up to date stays up to date: it was edited along with
/// the transcript. One that was already out of date stays flagged.
({Note note, List<Segment> changed})? replaceInNote(Note n, TextReplacer r) {
  if (countInNote(n, r) == 0 && !_clinicalMatches(n.clinical, r)) return null;
  final changed = <Segment>[];
  final segments = <Segment>[];
  for (final s in n.segments) {
    final next = s.copyWith(
      transcript: r.apply(s.transcript),
      english: r.apply(s.english),
      lines: [
        for (final l in s.lines)
          TimedLine(l.startMs, l.endMs, r.apply(l.text),
              english: r.apply(l.english), speaker: l.speaker),
      ],
    );
    final differs = next.transcript != s.transcript ||
        next.english != s.english ||
        next.lines.indexed.any((e) =>
            e.$2.text != s.lines[e.$1].text ||
            e.$2.english != s.lines[e.$1].english);
    segments.add(differs ? next : s);
    if (differs) changed.add(next);
  }
  final c = n.clinical;
  final edited = n
      .copyWith(
        title: r.apply(n.title),
        summary: r.apply(n.summary),
        clinical: c == null
            ? null
            : ClinicalReport(
                interpretation: r.apply(c.interpretation),
                noteEnglish: r.apply(c.noteEnglish),
                noteNative: r.apply(c.noteNative),
                verify: [for (final v in c.verify) r.apply(v)],
              ),
      )
      .withSegments(segments);
  final wasCurrent = n.hasEnrichment && !n.isStale;
  return (
    note: wasCurrent
        ? edited.copyWith(
            enrichedHash: textHash(edited.transcript, edited.english))
        : edited,
    changed: changed,
  );
}

bool _clinicalMatches(ClinicalReport? c, TextReplacer r) =>
    c != null &&
    (r.count(c.interpretation) +
            r.count(c.noteEnglish) +
            r.count(c.noteNative) +
            c.verify.fold<int>(0, (a, v) => a + r.count(v))) >
        0;

/// A short stretch of [n]'s text around the first match of [query], for
/// showing why a note matched a search. Null when the match is in the title
/// or summary (already visible) or there is none.
String? matchSnippet(Note n, String query, {int radius = 40}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return null;
  for (final text in [n.transcript, n.english]) {
    final i = text.toLowerCase().indexOf(q);
    if (i < 0) continue;
    final start = (i - radius).clamp(0, text.length);
    final end = (i + q.length + radius).clamp(0, text.length);
    final body = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ');
    return '${start > 0 ? '…' : ''}$body${end < text.length ? '…' : ''}';
  }
  return null;
}
