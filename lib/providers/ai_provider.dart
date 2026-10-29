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
      canTranscribe: false),
  // Whisper running on the phone: no key and no network, but no text model,
  // so titles and summaries need another provider.
  onDevice('On this device', 'Works offline. Download a model first',
      RecordingFormat.wav16kMono,
      needsKey: false, canText: false);

  final String label;
  final String blurb;
  final RecordingFormat recordingFormat;
  final bool canTranscribe;
  final bool canText;
  final bool needsKey;
  const ProviderId(this.label, this.blurb, this.recordingFormat,
      {this.canTranscribe = true, this.canText = true, this.needsKey = true});
}

/// A stretch of a recording and what was said in it. Times are milliseconds
/// from the start of that recording.
class TimedLine {
  final int startMs;
  final int endMs;
  final String text;

  /// English for the same stretch, when the provider translates line by line.
  final String english;

  /// Who spoke, as an id such as "S1" that the note maps to a name. Null when
  /// speakers were not identified.
  final String? speaker;
  const TimedLine(this.startMs, this.endMs, this.text,
      {this.english = '', this.speaker});

  TimedLine copyWith({String? text, String? english, String? speaker}) =>
      TimedLine(startMs, endMs, text ?? this.text,
          english: english ?? this.english, speaker: speaker ?? this.speaker);

  Map<String, Object?> toJson() => {
        's': startMs,
        'e': endMs,
        't': text,
        if (english.isNotEmpty) 'en': english,
        if (speaker != null) 'sp': speaker,
      };

  factory TimedLine.fromJson(Map<String, dynamic> j) => TimedLine(
        (j['s'] as num).toInt(),
        (j['e'] as num).toInt(),
        (j['t'] ?? '').toString(),
        english: (j['en'] ?? '').toString(),
        speaker: j['sp'] as String?,
      );
}

class Transcription {
  final String text;
  final String english;
  final String? languageCode;

  /// Timestamps for the text, when the provider gives them.
  final List<TimedLine> lines;
  const Transcription({
    required this.text,
    this.english = '',
    this.languageCode,
    this.lines = const [],
  });
}

class NoteSummary {
  final String title;
  final String summary;

  /// Tags picked from the approved list the model was given.
  final List<String> tags;

  /// A new tag the model proposes when none of the approved ones fit.
  final String? suggestedTag;
  const NoteSummary(this.title, this.summary,
      {this.tags = const [], this.suggestedTag});
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
  /// set, also returns an English version. [vocabulary] lists names and terms
  /// to listen for, by providers that accept a hint; the rest ignore it. With
  /// [speakers], providers that can tell voices apart label each line.
  Future<Transcription> transcribe(File audio,
      {required bool translate,
      List<String> vocabulary = const [],
      bool speakers = false});

  /// Produces a short title and summary for [text]. With [tags] (the user's
  /// approved tags), also picks the ones that fit; see [summaryPrompt].
  Future<NoteSummary> summarize(String text, {List<String> tags = const []});

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

/// The prompt every text provider uses to title and summarise [text], and,
/// when the user has approved [tags], to tag it from that list.
String summaryPrompt(String text, {List<String> tags = const []}) {
  if (tags.isEmpty) {
    return 'You title and summarise voice notes. Reply with JSON only, in the '
        'form {"title": "<max 6 words>", "summary": "<1-3 sentences>"}. Write '
        'the title and summary in English.\n\nVoice note:\n$text';
  }
  return 'You title, summarise and tag voice notes. Reply with JSON only, in '
      'the form {"title": "<max 6 words>", "summary": "<1-3 sentences>", '
      '"tags": ["..."], "suggested_tag": "<tag or empty>"}. Write the title '
      'and summary in English.\n'
      '- "tags": every tag from this list that fits the note, spelled exactly '
      'as given, or an empty list: ${jsonEncode(tags)}. Never use a tag that '
      'is not in the list.\n'
      '- "suggested_tag": only if no tag in the list fits, one short new tag '
      '(1-2 words, English, like the ones in the list); otherwise an empty '
      'string.\n\nVoice note:\n$text';
}

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

/// Parses the reply to [summaryPrompt]. Tags not in [allowed] are dropped
/// (matched ignoring case, returned with the user's spelling). A suggested
/// tag that is already in [allowed] counts as a chosen tag instead.
NoteSummary summaryFromReply(String reply,
    {List<String> allowed = const []}) {
  final j = extractJsonObject(reply);
  final byKey = {for (final t in allowed) t.trim().toLowerCase(): t};
  final raw = j['tags'];
  final tags = <String>{
    if (raw is List)
      for (final t in raw) ?byKey[t.toString().trim().toLowerCase()],
  };
  String? suggested;
  final s = j['suggested_tag'];
  if (allowed.isNotEmpty && s is String) {
    final name = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    final known = byKey[name.toLowerCase()];
    if (known != null) {
      tags.add(known);
    } else if (name.isNotEmpty && name.length <= 30 && tags.isEmpty) {
      suggested = name;
    }
  }
  return NoteSummary(
    (j['title'] ?? '').toString().trim(),
    (j['summary'] ?? '').toString().trim(),
    tags: tags.toList(),
    suggestedTag: suggested,
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
