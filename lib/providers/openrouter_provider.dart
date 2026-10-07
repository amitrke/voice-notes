import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// OpenRouter: one key for many text models, including free ones
/// (`openrouter/free` picks an available free model). It has no speech-to-text
/// here, so it is only used for titles, summaries and clinical notes.
class OpenRouterProvider implements AiProvider {
  static const _url = 'https://openrouter.ai/api/v1/chat/completions';

  final String apiKey;
  final String textModel;
  final http.Client _client;

  OpenRouterProvider({
    required this.apiKey,
    this.textModel = 'openrouter/free',
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  ProviderId get id => ProviderId.openrouter;

  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio, {required bool translate}) =>
      throw const ProviderException(
          'OpenRouter cannot transcribe audio. Pick Sarvam, OpenAI or Gemini '
          'for transcription in Settings.');

  @override
  Future<NoteSummary> summarize(String text) async =>
      summaryFromReply(await completeJson('$summaryPrompt$text'));

  @override
  Future<String> completeJson(String prompt) async {
    // No response_format: many free models reject it. The prompt asks for
    // JSON and extractJsonObject tolerates fences and reasoning preambles.
    final res = await _client.post(
      Uri.parse(_url),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': textModel,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );
    checkStatus(res.statusCode, res.body, 'OpenRouter');
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final choices = j['choices'] as List?;
    final content =
        choices == null || choices.isEmpty ? null : choices.first['message']?['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const ProviderException('OpenRouter returned an empty reply. Try again.');
    }
    return content;
  }
}
