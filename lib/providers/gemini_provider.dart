import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

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
    this.sttModel = 'gemini-2.5-flash',
    this.textModel = 'gemini-2.5-flash',
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
  Future<Transcription> transcribe(File audio, {required bool translate}) async {
    if (await audio.length() > _maxBytes) {
      throw const ProviderException(
          'This recording is too large for Gemini inline upload (about 14 MB).');
    }
    final data = base64Encode(await audio.readAsBytes());
    final prompt = 'Transcribe this audio exactly as spoken, in the original '
        'language and script. Reply with JSON only: '
        '{"language": "<BCP-47 code of the spoken language, e.g. hi-IN>", '
        '"transcript": "<verbatim transcript>", '
        '"english": "${translate ? '<faithful English translation>' : ''}"}.'
        '${translate ? '' : ' Leave "english" empty.'}';
    final reply = await _generate(sttModel, [
      {'text': prompt},
      {
        'inline_data': {'mime_type': mimeFor(audio.path), 'data': data},
      },
    ]);
    final j = extractJsonObject(reply);
    return Transcription(
      text: (j['transcript'] ?? '').toString().trim(),
      english: (j['english'] ?? '').toString().trim(),
      languageCode: j['language']?.toString(),
    );
  }

  @override
  Future<NoteSummary> summarize(String text) async {
    final reply = await _generate(textModel, [
      {'text': '$summaryPrompt$text'},
    ]);
    return summaryFromReply(reply);
  }
}
