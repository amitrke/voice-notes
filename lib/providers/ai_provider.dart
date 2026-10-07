import 'dart:convert';
import 'dart:io';

/// Container the recorder should capture in for a provider.
enum RecordingFormat { wav16kMono, m4a }

enum ProviderId {
  // Sarvam's sync API takes ~30 s clips, so recordings are WAV and get chunked.
  sarvam('Sarvam', 'Best for Indian languages', RecordingFormat.wav16kMono),
  openai('OpenAI', 'Whisper transcription + GPT', RecordingFormat.m4a),
  gemini('Google Gemini', 'Transcribes and translates in one step',
      RecordingFormat.m4a);

  final String label;
  final String blurb;
  final RecordingFormat recordingFormat;
  const ProviderId(this.label, this.blurb, this.recordingFormat);
}

class Transcription {
  final String text;
  final String english;
  final String? languageCode;
  const Transcription({
    required this.text,
    this.english = '',
    this.languageCode,
  });
}

class NoteSummary {
  final String title;
  final String summary;
  const NoteSummary(this.title, this.summary);
}

class ProviderException implements Exception {
  final String message;
  const ProviderException(this.message);
  @override
  String toString() => message;
}

abstract class AiProvider {
  ProviderId get id;
  RecordingFormat get recordingFormat;

  /// Transcribes [audio] in its original language and, when [translate] is
  /// set, also returns an English version.
  Future<Transcription> transcribe(File audio, {required bool translate});

  /// Produces a short title and summary for [text].
  Future<NoteSummary> summarize(String text);
}

const summaryPrompt =
    'You title and summarise voice notes. Reply with JSON only, in the form '
    '{"title": "<max 6 words>", "summary": "<1-3 sentences>"}. Write the title '
    'and summary in English.\n\nVoice note:\n';

/// Pulls the first JSON object out of an LLM reply, tolerating code fences
/// and reasoning preambles.
Map<String, dynamic> extractJsonObject(String reply) {
  final cleaned =
      reply.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
  final start = cleaned.indexOf('{');
  final end = cleaned.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw const ProviderException('The model did not return JSON.');
  }
  final decoded = jsonDecode(cleaned.substring(start, end + 1));
  if (decoded is! Map<String, dynamic>) {
    throw const ProviderException('The model did not return a JSON object.');
  }
  return decoded;
}

NoteSummary summaryFromReply(String reply) {
  final j = extractJsonObject(reply);
  return NoteSummary(
    (j['title'] ?? '').toString().trim(),
    (j['summary'] ?? '').toString().trim(),
  );
}

/// Throws a [ProviderException] with the API's own error message when [status]
/// is not a success.
void checkStatus(int status, String body, String provider) {
  if (status >= 200 && status < 300) return;
  var detail = body;
  try {
    final j = jsonDecode(body);
    final err = j is Map ? (j['error'] ?? j['message'] ?? j['detail']) : null;
    if (err is Map) {
      detail = (err['message'] ?? err).toString();
    } else if (err != null) {
      detail = err.toString();
    }
  } catch (_) {}
  if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
  final hint = (status == 401 || status == 403)
      ? ' Check your API key in Settings.'
      : status == 429
          ? ' Rate limit or quota reached.'
          : '';
  throw ProviderException('$provider error ($status): $detail$hint');
}
