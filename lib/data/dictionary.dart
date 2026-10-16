import '../providers/ai_provider.dart';

/// One word the user wants spelled a certain way: a name, a drug, jargon.
/// [heard] lists spellings a speech model tends to produce instead.
class DictionaryEntry {
  final String term;
  final List<String> heard;
  const DictionaryEntry(this.term, [this.heard = const []]);

  /// Parses "term" or "wrong, also wrong => term". Null for a blank line.
  static DictionaryEntry? parse(String line) {
    final i = line.indexOf('=>');
    final term = (i < 0 ? line : line.substring(i + 2)).trim();
    if (term.isEmpty) return null;
    final heard = i < 0
        ? <String>[]
        : line
            .substring(0, i)
            .split(',')
            .map((h) => h.trim())
            .where((h) => h.isNotEmpty)
            .toList();
    return DictionaryEntry(term, heard);
  }

  String toLine() => heard.isEmpty ? term : '${heard.join(', ')} => $term';
}

/// The user's custom vocabulary. It helps in two ways: terms are sent to
/// providers that take a hint (OpenAI, Gemini), and every transcript is then
/// corrected afterwards, which also covers providers that take no hint.
class Dictionary {
  final List<DictionaryEntry> entries;
  Dictionary([this.entries = const []]);

  factory Dictionary.fromLines(Iterable<String> lines) => Dictionary([
        for (final l in lines) ?DictionaryEntry.parse(l),
      ]);

  List<String> toLines() => [for (final e in entries) e.toLine()];

  bool get isEmpty => entries.isEmpty;

  /// The terms to tell a provider to listen for.
  List<String> get hints => [for (final e in entries) e.term];

  late final List<(RegExp, String)> _rules = _buildRules();

  List<(RegExp, String)> _buildRules() {
    final rules = <(RegExp, String)>[];
    for (final e in entries) {
      // The term itself is included so "kubernetes" becomes "Kubernetes".
      for (final spelling in {...e.heard, e.term}) {
        rules.add((
          RegExp(
            '(?<![\\p{L}\\p{N}])${RegExp.escape(spelling)}(?![\\p{L}\\p{N}])',
            caseSensitive: false,
            unicode: true,
          ),
          e.term,
        ));
      }
    }
    // Longer spellings first, so "new york city" wins over "new york".
    rules.sort((a, b) => b.$1.pattern.length.compareTo(a.$1.pattern.length));
    return rules;
  }

  /// [text] with every known misspelling replaced by the right spelling.
  String apply(String text) {
    if (text.isEmpty || entries.isEmpty) return text;
    var out = text;
    for (final (pattern, term) in _rules) {
      out = out.replaceAll(pattern, term);
    }
    return out;
  }

  Transcription applyTo(Transcription t) {
    if (entries.isEmpty) return t;
    return Transcription(
      text: apply(t.text),
      english: apply(t.english),
      languageCode: t.languageCode,
      lines: [
        for (final l in t.lines)
          TimedLine(l.startMs, l.endMs, apply(l.text),
              english: apply(l.english), speaker: l.speaker),
      ],
    );
  }
}

/// "Vocabulary: a, b, c" for providers that take a free-text hint, cut to
/// [maxChars] so it stays within their prompt limits. Empty with no terms.
String vocabularyHint(List<String> terms, {int maxChars = 600}) {
  final kept = <String>[];
  var length = 0;
  for (final t in terms) {
    if (length + t.length + 2 > maxChars) break;
    kept.add(t);
    length += t.length + 2;
  }
  return kept.isEmpty ? '' : kept.join(', ');
}
