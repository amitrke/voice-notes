import 'dart:convert';
import 'dart:io';

/// Container the recorder should capture in for a provider.
enum RecordingFormat { wav16kMono, m4a }

enum ProviderId {
  // Sarvam's sync API takes ~30 s clips, so recordings are WAV and get chunked.
  sarvam('Sarvam', 'Best for Indian languages', RecordingFormat.wav16kMono),
  openai('OpenAI', 'Whisper transcription + GPT', RecordingFormat.m4a),
  gemini('Google Gemini', 'Transcribes and translates in one step',
      RecordingFormat.m4a),
  // Text only: no speech-to-text, so it is offered for enrichment but not
  // for transcription.
  openrouter('OpenRouter', 'Text models only, including free ones',
      RecordingFormat.m4a,
      canTranscribe: false);

  final String label;
  final String blurb;
  final RecordingFormat recordingFormat;
  final bool canTranscribe;
  const ProviderId(this.label, this.blurb, this.recordingFormat,
      {this.canTranscribe = true});
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

  /// Sends [prompt] to the provider's text model and returns the raw reply,
  /// which the prompt asks to be a JSON object.
  Future<String> completeJson(String prompt);
}

/// A structured clinical write-up of a dictated note. AI-generated, so it is a
/// draft for the clinician to check, never a finished record.
class ClinicalReport {
  final String interpretation;
  final String noteEnglish;
  final String noteNative;
  final List<String> verify;
  const ClinicalReport({
    this.interpretation = '',
    this.noteEnglish = '',
    this.noteNative = '',
    this.verify = const [],
  });

  Map<String, Object?> toJson() => {
        'interpretation': interpretation,
        'note_english': noteEnglish,
        'note_native': noteNative,
        'verify': verify,
      };

  factory ClinicalReport.fromJson(Map<String, dynamic> j) {
    String s(String k) => (j[k] ?? '').toString().trim();
    final v = j['verify'];
    return ClinicalReport(
      interpretation: s('interpretation'),
      noteEnglish: s('note_english'),
      noteNative: s('note_native'),
      verify: v is List
          ? v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
          : const [],
    );
  }
}

String clinicalPrompt({
  required String transcript,
  required String english,
  String? language,
}) {
  final native = (language == null || language == 'English') ? null : language;
  return 'You are a clinical scribe. Below is a clinician\'s dictated note'
      '${native == null ? '' : ' (spoken in $native, possibly mixed with English)'}'
      '. Reply with JSON only, in the form {"interpretation": "...", '
      '"note_english": "...", "note_native": "...", "verify": ["..."]}.\n'
      '- "interpretation": a structured reading of what was said, as plain-text '
      'lines such as "Patient:", "Complaint:", "Findings:", "Diagnosis:", '
      '"Medications:", "Plan:". Omit a line if it was not mentioned.\n'
      '- "note_english": a clean clinical note in English (SOAP style where it '
      'fits), using standard medical terminology.\n'
      '- "note_native": the same clinical note written in '
      '${native ?? 'the spoken language'}'
      '${native == null ? ', or an empty string if the note was in English' : ' (keep drug names, doses and standard medical terms in English)'}.\n'
      '- "verify": short items the clinician must double-check: drug names or '
      'doses that may be misheard or misspelled, ambiguous abbreviations '
      '(e.g. "SOS"), numbers, laterality, allergies, and anything unclear. '
      'Use an empty list only if nothing is doubtful.\n'
      'Use only what was said. Never invent findings, doses, diagnoses or '
      'names; if something is missing, leave it out.\n\n'
      'Transcript:\n$transcript'
      '${english.isEmpty ? '' : '\n\nEnglish translation:\n$english'}';
}

Future<ClinicalReport> buildClinicalReport(
  AiProvider provider, {
  required String transcript,
  required String english,
  String? language,
}) async {
  final reply = await provider.completeJson(
      clinicalPrompt(transcript: transcript, english: english, language: language));
  return ClinicalReport.fromJson(extractJsonObject(reply));
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
