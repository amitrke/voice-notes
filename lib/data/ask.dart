import '../models/note.dart';
import '../providers/ai_provider.dart';
import 'templates.dart';

/// Most notes one question reads.
const askMaxNotes = 8;

/// Most characters of notes sent with one question (about 6,000 tokens).
const askBudgetChars = 24000;

/// How many earlier questions and answers a new question can see.
const askHistoryTurns = 6;

/// Where a question looks: every note, or those in one folder or with one
/// tag, optionally only the recent ones.
class AskScope {
  final int? folderId;
  final int? tagId;

  /// Only notes made within this long before [now]; null for any time.
  final Duration? within;
  const AskScope({this.folderId, this.tagId, this.within});

  bool matches(Note n, DateTime now) {
    if (folderId != null && n.folderId != folderId) return false;
    if (tagId != null && !n.tagIds.contains(tagId)) return false;
    if (within != null && now.difference(n.createdAt) > within!) return false;
    return true;
  }
}

/// One question and its answer, with the ids of the notes it came from.
class AskTurn {
  final String question;
  final String answer;
  final List<int> sourceIds;
  const AskTurn(this.question, this.answer, [this.sourceIds = const []]);
}

class AskAnswer {
  final String text;

  /// Notes the answer says it is based on, in the order it cited them.
  final List<int> sourceIds;
  const AskAnswer(this.text, this.sourceIds);
}

const _stopWords = {
  'a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'on', 'at', 'for', 'with',
  'is', 'are', 'was', 'were', 'be', 'been', 'do', 'did', 'does', 'i', 'me',
  'my', 'we', 'our', 'you', 'your', 'it', 'its', 'this', 'that', 'what',
  'when', 'where', 'who', 'whom', 'which', 'how', 'why', 'about', 'have',
  'has', 'had', 'say', 'said', 'tell', 'any', 'all', 'from', 'by', 'as',
  'not', 'there', 'they', 'them', 'he', 'she', 'his', 'her', 'can', 'could',
  'would', 'should', 'will', 'if', 'so', 'than', 'then', 'up', 'out', 'note',
  'notes', 'recording', 'recordings',
};

/// The words of [question] worth looking for in notes.
List<String> askTerms(String question) => [
      for (final w in question
          .toLowerCase()
          .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
        if (w.length >= 2 && !_stopWords.contains(w)) w,
    ];

int _count(String text, String term, int cap) {
  var n = 0;
  var from = 0;
  while (n < cap) {
    final i = text.indexOf(term, from);
    if (i < 0) break;
    n++;
    from = i + term.length;
  }
  return n;
}

/// How well [n] matches [terms]: a hit in the title counts most, then the
/// summary, then the text.
int scoreNote(Note n, List<String> terms) {
  final title = n.title.toLowerCase();
  final summary = n.summary.toLowerCase();
  final body = '${n.transcript}\n${n.english}'.toLowerCase();
  var score = 0;
  for (final t in terms) {
    score += 5 * _count(title, t, 2) +
        3 * _count(summary, t, 2) +
        _count(body, t, 5);
  }
  return score;
}

/// The notes to send with [question]: all of [candidates] when they are few
/// and short, otherwise the best matches, padded with the most recent notes
/// when the words of the question hardly match anything (a question about
/// "last week", or in another language than the notes).
List<Note> pickNotes(List<Note> candidates, String question,
    {int max = askMaxNotes, int budget = askBudgetChars}) {
  final byDate = [...candidates]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final size = byDate.fold<int>(0, (a, n) => a + n.transcript.length);
  if (byDate.length <= max && size <= budget) return byDate;
  final terms = askTerms(question);
  final scored = [
    for (final n in byDate) (n, scoreNote(n, terms)),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final picked = [
    for (final (n, s) in scored)
      if (s > 0) n,
  ].take(max).toList();
  // Too few matches: add the newest notes so the model has something to read.
  for (final n in byDate) {
    if (picked.length >= 3) break;
    if (!picked.contains(n)) picked.add(n);
  }
  return picked;
}

/// At most [limit] characters of [text], keeping the stretches around
/// [terms] when it is longer, else its beginning.
String excerpt(String text, List<String> terms, int limit) {
  if (text.length <= limit) return text;
  final lower = text.toLowerCase();
  final spots = <int>[];
  for (final t in terms) {
    var from = 0;
    while (spots.length < 40) {
      final i = lower.indexOf(t, from);
      if (i < 0) break;
      spots.add(i);
      from = i + t.length;
    }
  }
  if (spots.isEmpty) return '${text.substring(0, limit)}…';
  spots.sort();
  const around = 300;
  final windows = <(int, int)>[];
  for (final i in spots) {
    final s = (i - around).clamp(0, text.length);
    final e = (i + around).clamp(0, text.length);
    if (windows.isNotEmpty && s <= windows.last.$2) {
      windows[windows.length - 1] = (windows.last.$1, e);
    } else {
      windows.add((s, e));
    }
  }
  final parts = <String>[];
  var used = 0;
  for (final (s, e) in windows) {
    if (used + (e - s) > limit) {
      final room = limit - used;
      if (room > 80) parts.add(text.substring(s, s + room));
      break;
    }
    parts.add(text.substring(s, e));
    used += e - s;
  }
  return parts.join(' … ');
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
  'Nov', 'Dec',
];

String _date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// The prompt for [question] over [notes] (already picked), after [history].
String askPrompt(String question, List<Note> notes,
    {List<AskTurn> history = const [], int budget = askBudgetChars}) {
  final terms = askTerms(question);
  final each = notes.isEmpty ? budget : budget ~/ notes.length;
  final b = StringBuffer()
    ..writeln('You answer questions about the user\'s voice notes. Use only '
        'the notes below. If they do not contain the answer, say so plainly; '
        'never invent names, dates, numbers or details. Quote or name the '
        'note a fact comes from when that helps. Answer in the language the '
        'question is asked in, briefly. Reply with JSON only, in the form '
        '{"answer": "...", "sources": ["N1"]}, where "sources" lists the '
        'labels of the notes the answer is based on (empty if none).')
    ..writeln()
    ..writeln('Notes:');
  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    b.writeln('[N${i + 1}] "${n.title.isEmpty ? 'Untitled' : n.title}" · '
        '${_date(n.createdAt)}');
    if (n.summary.isNotEmpty) b.writeln('Summary: ${n.summary}');
    b.writeln('Text: ${excerpt(labelledText(n), terms, each)}');
    b.writeln();
  }
  final recent = history.length > askHistoryTurns
      ? history.sublist(history.length - askHistoryTurns)
      : history;
  if (recent.isNotEmpty) {
    b.writeln('Conversation so far:');
    for (final t in recent) {
      b
        ..writeln('Q: ${t.question}')
        ..writeln('A: ${t.answer}');
    }
    b.writeln();
  }
  b.write('Question: $question');
  return b.toString();
}

/// Reads the reply to [askPrompt]. A reply that is not JSON is taken as the
/// answer itself, without sources.
AskAnswer parseAskReply(String reply, List<Note> notes) {
  Map<String, dynamic> j;
  try {
    j = extractJsonObject(reply);
  } on ProviderException {
    final text = reply.trim();
    if (text.isEmpty) {
      throw const ProviderException('The model returned no answer.');
    }
    return AskAnswer(text, const []);
  }
  final text = (j['answer'] ?? '').toString().trim();
  if (text.isEmpty) {
    throw const ProviderException('The model returned no answer.');
  }
  final ids = <int>[];
  final raw = j['sources'];
  if (raw is List) {
    for (final s in raw) {
      final m = RegExp(r'\d+').firstMatch(s.toString());
      final i = m == null ? null : int.parse(m.group(0)!) - 1;
      if (i == null || i < 0 || i >= notes.length) continue;
      final id = notes[i].id;
      if (id != null && !ids.contains(id)) ids.add(id);
    }
  }
  return AskAnswer(text, ids);
}

/// Answers [question] from [candidates] with [provider].
Future<AskAnswer> askNotes(
  AiProvider provider,
  String question,
  List<Note> candidates, {
  List<AskTurn> history = const [],
}) async {
  if (candidates.isEmpty) {
    return const AskAnswer('There are no notes to look in.', []);
  }
  final picked = pickNotes(candidates, question);
  final reply =
      await provider.completeJson(askPrompt(question, picked, history: history));
  return parseAskReply(reply, picked);
}
