import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/dictionary.dart';
import 'ai_provider.dart';

/// Google Gemini: the audio goes in as inline data and one prompt returns the
/// detected language, the original-language transcript and the English text.
class GeminiProvider implements AiProvider {
  static const _base = 'https://generativelanguage.googleapis.com/v1beta/models';
  // Inline request bodies are capped at ~20 MB; base64 adds a third.
  static const _maxBytes = 14 * 1024 * 1024;

  final String apiKey;
  final String sttModel;
  final String textModel;
  final http.Client _client;

  GeminiProvider({
    required this.apiKey,
    this.sttModel = 'gemini-3.5-flash',
    this.textModel = 'gemini-3.5-flash',
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  ProviderId get id => ProviderId.gemini;

  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  static String mimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.wav':
        return 'audio/wav';
      case '.mp3':
        return 'audio/mp3';
      case '.aac':
        return 'audio/aac';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.flac':
        return 'audio/flac';
      case '.aiff':
        return 'audio/aiff';
      default:
        return 'audio/mp4'; // m4a / mp4
    }
  }

  Future<String> _generate(String model, List<Map<String, dynamic>> parts) async {
    final res = await _client.post(
      Uri.parse('$_base/$model:generateContent'),
      headers: {'x-goog-api-key': apiKey, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {'parts': parts},
        ],
        'generationConfig': {'responseMimeType': 'application/json'},
      }),
    );
    checkStatus(res.statusCode, res.body, 'Gemini');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final candidates = j['candidates'] as List?;
    final text = candidates == null || candidates.isEmpty
        ? null
        : (candidates.first['content']?['parts'] as List?)
            ?.map((e) => e['text'] ?? '')
            .join();
    if (text == null || text.isEmpty) {
      throw ProviderException(
          'Gemini returned no text (${j['promptFeedback'] ?? 'blocked or empty'}).');
    }
    return text;
  }

  @override
  Future<Transcription> transcribe(File audio,
      {required bool translate,
      List<String> vocabulary = const [],
      bool speakers = false}) async {
    if (await audio.length() > _maxBytes) {
      throw const ProviderException(
          'This recording is too large for Gemini inline upload (about 14 MB).');
    }
    final data = base64Encode(await audio.readAsBytes());
    final prompt = transcribePrompt(
        translate: translate, vocabulary: vocabulary, speakers: speakers);
    final reply = await _generate(sttModel, [
      {'text': prompt},
      {
        'inline_data': {'mime_type': mimeFor(audio.path), 'data': data},
      },
    ]);
    final j = extractJsonObject(reply);
    return speakers && j['turns'] is List
        ? transcriptionFromTurns(j)
        : Transcription(
            text: (j['transcript'] ?? '').toString().trim(),
            english: (j['english'] ?? '').toString().trim(),
            languageCode: j['language']?.toString(),
          );
  }

  /// The instruction sent with the audio.
  static String transcribePrompt({
    required bool translate,
    List<String> vocabulary = const [],
    bool speakers = false,
  }) {
    final hint = vocabularyHint(vocabulary);
    final vocab = hint.isEmpty
        ? ''
        : ' These names and terms may come up; spell them exactly like this '
            'when they are said: $hint.';
    if (speakers) {
      return 'Transcribe this audio exactly as spoken, in the original '
          'language and script, and separate it into turns by who is '
          'speaking. Label the voices "S1", "S2" and so on in the order they '
          'first speak, and use the same label every time the same person '
          'speaks. Reply with JSON only: '
          '{"language": "<BCP-47 code of the spoken language, e.g. hi-IN>", '
          '"turns": [{"speaker": "S1", "start": "MM:SS", "end": "MM:SS", '
          '"text": "<verbatim words>", '
          '"english": "${translate ? '<faithful English translation>' : ''}"}]}.'
          ' "start" and "end" are where the turn begins and ends in the '
          'recording.${translate ? '' : ' Leave "english" empty.'}$vocab';
    }
    return 'Transcribe this audio exactly as spoken, in the original '
        'language and script. Reply with JSON only: '
        '{"language": "<BCP-47 code of the spoken language, e.g. hi-IN>", '
        '"transcript": "<verbatim transcript>", '
        '"english": "${translate ? '<faithful English translation>' : ''}"}.'
        '${translate ? '' : ' Leave "english" empty.'}$vocab';
  }

  /// Builds a transcription from Gemini's speaker turns. Times that are
  /// missing or unreadable are filled in from the neighbouring turns, so
  /// the lines still run in order.
  static Transcription transcriptionFromTurns(Map<String, dynamic> j) {
    final raw = <({String? speaker, int? start, int? end, String text, String en})>[
      for (final t in (j['turns'] as List).whereType<Map>())
        if ((t['text'] ?? '').toString().trim().isNotEmpty)
          (
            speaker: _speakerId(t['speaker']),
            start: parseClock(t['start']),
            end: parseClock(t['end']),
            text: t['text'].toString().trim(),
            en: (t['english'] ?? '').toString().trim(),
          ),
    ];
    final lines = <TimedLine>[];
    var previousEnd = 0;
    for (var i = 0; i < raw.length; i++) {
      final t = raw[i];
      final start = t.start ?? previousEnd;
      final nextStart = i + 1 < raw.length ? raw[i + 1].start : null;
      var end = t.end ?? nextStart ?? start + 1000;
      if (end <= start) end = start + 1000;
      previousEnd = end;
      lines.add(TimedLine(start, end, t.text,
          english: t.en, speaker: t.speaker));
    }
    String join(Iterable<String> parts) =>
        parts.where((p) => p.isNotEmpty).join(' ');
    final anyEnglish = lines.any((l) => l.english.isNotEmpty);
    return Transcription(
      text: join(lines.map((l) => l.text)),
      english: anyEnglish ? join(lines.map((l) => l.english)) : '',
      languageCode: j['language']?.toString(),
      lines: lines,
    );
  }

  static String? _speakerId(Object? raw) {
    final s = (raw ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  /// "01:23", "1:02:03" or "83.5" as milliseconds; null if unreadable.
  static int? parseClock(Object? raw) {
    if (raw is num) return (raw * 1000).round();
    final s = (raw ?? '').toString().trim();
    if (s.isEmpty) return null;
    final parts = s.split(':');
    if (parts.length > 3) return null;
    var seconds = 0.0;
    for (final part in parts) {
      final v = double.tryParse(part);
      if (v == null || v < 0) return null;
      seconds = seconds * 60 + v;
    }
    return (seconds * 1000).round();
  }

  @override
  Future<NoteSummary> summarize(String text) async =>
      summaryFromReply(await completeJson('$summaryPrompt$text'));

  @override
  Future<String> completeJson(String prompt) => _generate(textModel, [
        {'text': prompt},
      ]);
}
