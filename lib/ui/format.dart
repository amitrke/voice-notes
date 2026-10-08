import 'package:intl/intl.dart';

const _languages = {
  'hi': 'Hindi',
  'bn': 'Bengali',
  'ta': 'Tamil',
  'te': 'Telugu',
  'kn': 'Kannada',
  'ml': 'Malayalam',
  'mr': 'Marathi',
  'gu': 'Gujarati',
  'pa': 'Punjabi',
  'od': 'Odia',
  'or': 'Odia',
  'as': 'Assamese',
  'ur': 'Urdu',
  'ne': 'Nepali',
  'en': 'English',
  'kok': 'Konkani',
  'ks': 'Kashmiri',
  'sd': 'Sindhi',
  'sa': 'Sanskrit',
  'sat': 'Santali',
  'mni': 'Manipuri',
  'brx': 'Bodo',
  'mai': 'Maithili',
  'doi': 'Dogri',
};

/// "hi-IN" -> "Hindi"; passes through names such as OpenAI's "hindi".
String? languageLabel(String? code) {
  if (code == null || code.isEmpty || code == 'unknown') return null;
  final base = code.split(RegExp(r'[-_]')).first.toLowerCase();
  return _languages[base] ??
      (code.length > 3 ? code[0].toUpperCase() + code.substring(1) : code);
}

/// True for codes and names that mean English ("en-IN", "english").
bool isEnglish(String? code) {
  if (code == null) return false;
  final base = code.split(RegExp(r'[-_]')).first.toLowerCase();
  return base == 'en' || base == 'english';
}

String formatDate(DateTime d) => DateFormat('d MMM yyyy, h:mm a').format(d);

String formatTime(DateTime d) => DateFormat('h:mm a').format(d);

/// Heading for the notes recorded on [d]'s day: "Today", "Yesterday", a
/// weekday within the last week, then a date (with the year only when it is
/// not the current one).
String dayLabel(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  // Compare calendar days in UTC so a daylight-saving change can't make a
  // day 23 hours long.
  final ago = DateTime.utc(n.year, n.month, n.day)
      .difference(DateTime.utc(d.year, d.month, d.day))
      .inDays;
  if (ago == 0) return 'Today';
  if (ago == 1) return 'Yesterday';
  if (ago > 1 && ago < 7) return DateFormat('EEEE').format(d);
  return DateFormat(d.year == n.year ? 'EEE, d MMM' : 'd MMM yyyy')
      .format(d);
}

String formatDuration(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
