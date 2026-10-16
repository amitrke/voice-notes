import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/dictionary.dart';
import 'ai_provider.dart';

/// OpenAI: Whisper for transcription (reports the spoken language) and
/// Whisper's translations endpoint for English.
class OpenAiProvider implements AiProvider {
  static const _base = 'https://api.openai.com/v1';
  static const _maxBytes = 25 * 1024 * 1024;

  final String apiKey;
  final String sttModel;
  final String textModel;
  final http.Client _client;

  OpenAiProvider({
    required this.apiKey,
    this.sttModel = 'whisper-1',
    this.textModel = 'gpt-4o-mini',
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  ProviderId get id => ProviderId.openai;

  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  Map<String, String> get _auth => {'Authorization': 'Bearer $apiKey'};

  @override
  Future<Transcription> transcribe(File audio,
      {required bool translate,
      List<String> vocabulary = const [],
      bool speakers = false}) async {
    if (await audio.length() > _maxBytes) {
      throw const ProviderException(
          'OpenAI accepts audio up to 25 MB. Use a shorter recording or another provider.');
    }
    final hint = vocabularyHint(vocabulary);
    final original =
        await _upload('transcriptions', audio, 'verbose_json', prompt: hint);
    var english = '';
    if (translate) {
      english = (await _upload('translations', audio, 'json', prompt: hint))['text']
              ?.toString() ??
          '';
    }
    return Transcription(
      text: (original['text'] ?? '').toString(),
      english: english,
      languageCode: original['language'] as String?,
      lines: timedLines(original['segments']),
    );
  }

  Future<Map<String, dynamic>> _upload(
      String endpoint, File audio, String format,
      {String prompt = ''}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/audio/$endpoint'))
      ..headers.addAll(_auth)
      ..fields['model'] = sttModel
      ..fields['response_format'] = format
      // Whisper treats the prompt as text that came just before, which biases
      // it towards these spellings.
      ..fields.addAll(prompt.isEmpty ? {} : {'prompt': prompt})
      ..files.add(await http.MultipartFile.fromPath('file', audio.path,
          filename: p.basename(audio.path)));
    final res = await http.Response.fromStream(await _client.send(req));
    checkStatus(res.statusCode, res.body, 'OpenAI');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @override
  Future<NoteSummary> summarize(String text,
          {List<String> tags = const []}) async =>
      summaryFromReply(await completeJson(summaryPrompt(text, tags: tags)),
          allowed: tags);

  @override
  Future<String> completeJson(String prompt) async {
    final res = await _client.post(
      Uri.parse('$_base/chat/completions'),
      headers: {..._auth, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': textModel,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );
    checkStatus(res.statusCode, res.body, 'OpenAI');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return (j['choices'] as List).first['message']['content'] as String;
  }
}

/// Whisper's verbose_json segments (times in seconds) as [TimedLine]s.
List<TimedLine> timedLines(Object? segments) {
  if (segments is! List) return const [];
  final lines = <TimedLine>[];
  for (final seg in segments) {
    if (seg is! Map) continue;
    final start = seg['start'], end = seg['end'];
    final text = (seg['text'] ?? '').toString().trim();
    if (start is! num || end is! num || text.isEmpty) continue;
    lines.add(TimedLine((start * 1000).round(), (end * 1000).round(), text));
  }
  return lines;
}
