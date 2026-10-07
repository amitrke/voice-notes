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

String formatDate(DateTime d) => DateFormat('d MMM yyyy, h:mm a').format(d);

String formatDuration(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
