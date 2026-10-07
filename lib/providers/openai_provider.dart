import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

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
  Future<Transcription> transcribe(File audio, {required bool translate}) async {
    if (await audio.length() > _maxBytes) {
      throw const ProviderException(
          'OpenAI accepts audio up to 25 MB. Use a shorter recording or another provider.');
    }
    final original = await _upload('transcriptions', audio, 'verbose_json');
    var english = '';
    if (translate) {
      english = (await _upload('translations', audio, 'json'))['text']
              ?.toString() ??
          '';
    }
    return Transcription(
      text: (original['text'] ?? '').toString(),
      english: english,
      languageCode: original['language'] as String?,
    );
  }

  Future<Map<String, dynamic>> _upload(
      String endpoint, File audio, String format) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/audio/$endpoint'))
      ..headers.addAll(_auth)
      ..fields['model'] = sttModel
      ..fields['response_format'] = format
      ..files.add(await http.MultipartFile.fromPath('file', audio.path,
          filename: p.basename(audio.path)));
    final res = await http.Response.fromStream(await _client.send(req));
    checkStatus(res.statusCode, res.body, 'OpenAI');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @override
  Future<NoteSummary> summarize(String text) async =>
      summaryFromReply(await completeJson('$summaryPrompt$text'));

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
