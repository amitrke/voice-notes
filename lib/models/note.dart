import 'dart:convert';

import '../providers/ai_provider.dart';

enum NoteStatus { processing, done, failed }

/// One audio recording belonging to a [Note], with its own transcription state.
class Segment {
  final int? id;
  final int? noteId;
  final int position;
  final String audioPath;
  final String transcript;
  final String english;
  final String? languageCode;
  final NoteStatus status;
  final String? error;
  final int? durationMs;

  const Segment({
    this.id,
    this.noteId,
    this.position = 0,
    required this.audioPath,
    this.transcript = '',
    this.english = '',
    this.languageCode,
    this.status = NoteStatus.processing,
    this.error,
    this.durationMs,
  });

  Segment copyWith({
    int? id,
    int? noteId,
    int? position,
    String? transcript,
    String? english,
    String? languageCode,
    NoteStatus? status,
    String? error,
    bool clearError = false,
  }) =>
      Segment(
        id: id ?? this.id,
        noteId: noteId ?? this.noteId,
        position: position ?? this.position,
        audioPath: audioPath,
        transcript: transcript ?? this.transcript,
        english: english ?? this.english,
        languageCode: languageCode ?? this.languageCode,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
        durationMs: durationMs,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'note_id': noteId,
        'position': position,
        'audio_path': audioPath,
        'transcript': transcript,
        'english': english,
        'language_code': languageCode,
        'status': status.name,
        'error': error,
        'duration_ms': durationMs,
      };

  factory Segment.fromMap(Map<String, Object?> m) => Segment(
        id: m['id'] as int?,
        noteId: m['note_id'] as int?,
        position: (m['position'] as int?) ?? 0,
        audioPath: m['audio_path'] as String,
        transcript: (m['transcript'] as String?) ?? '',
        english: (m['english'] as String?) ?? '',
        languageCode: m['language_code'] as String?,
        status: NoteStatus.values.firstWhere(
          (s) => s.name == m['status'],
          orElse: () => NoteStatus.failed,
        ),
        error: m['error'] as String?,
        durationMs: m['duration_ms'] as int?,
      );
}

/// Fingerprint of the text a title, summary or clinical note was generated
/// from (FNV-1a, 64-bit). Compared against the current text to spot staleness.
String textHash(String transcript, String english) {
  var h = 0xcbf29ce484222325;
  for (final c in '$transcript\u0000$english'.codeUnits) {
    h = (h ^ c) * 0x100000001b3;
  }
  return h.toRadixString(16);
}

/// A note owns an ordered list of recordings. [transcript] and [english] are
/// the in-order join of the recordings' text, so search and export read them
/// without knowing about segments.
class Note {
  final int? id;
  final String title;
  final String summary;
  final String transcript;
  final String english;
  final String? languageCode;
  final List<Segment> segments;
  final String provider;
  final DateTime createdAt;
  final NoteStatus status;
  final String? error;
  final ClinicalReport? clinical;

  /// [textHash] of the text the title/summary/clinical note were generated
  /// from; null if they never were.
  final String? enrichedHash;

  const Note({
    this.id,
    this.title = '',
    this.summary = '',
    this.transcript = '',
    this.english = '',
    this.languageCode,
    this.segments = const [],
    required this.provider,
    required this.createdAt,
    this.status = NoteStatus.processing,
    this.error,
    this.clinical,
    this.enrichedHash,
  });

  /// First recording's file (also kept in the legacy `audio_path` column).
  String get audioPath => segments.isEmpty ? '' : segments.first.audioPath;

  int? get durationMs {
    final d = segments.map((s) => s.durationMs).whereType<int>();
    return d.isEmpty ? null : d.fold<int>(0, (a, b) => a + b);
  }

  bool get hasEnrichment => summary.isNotEmpty || clinical != null;

  /// True when the text changed after the summary/clinical note were made.
  bool get isStale =>
      hasEnrichment && enrichedHash != textHash(transcript, english);

  /// Joins the text of finished [segments] in order. If any recording has an
  /// English version, recordings without one contribute their original text
  /// to it, so no recording drops out of the English text.
  static ({
    String transcript,
    String english,
    String? languageCode,
    NoteStatus status,
    String? error,
  }) combine(List<Segment> segments) {
    final done = segments.where((s) => s.status == NoteStatus.done).toList();
    String join(Iterable<String> parts) =>
        parts.map((t) => t.trim()).where((t) => t.isNotEmpty).join('\n\n');
    final anyEnglish = done.any((s) => s.english.trim().isNotEmpty);
    final NoteStatus status;
    if (segments.any((s) => s.status == NoteStatus.processing)) {
      status = NoteStatus.processing;
    } else if (segments.isNotEmpty && done.isEmpty) {
      status = NoteStatus.failed;
    } else {
      status = NoteStatus.done;
    }
    return (
      transcript: join(done.map((s) => s.transcript)),
      english: anyEnglish
          ? join(done.map(
              (s) => s.english.trim().isNotEmpty ? s.english : s.transcript))
          : '',
      languageCode:
          done.map((s) => s.languageCode).whereType<String>().firstOrNull,
      status: status,
      error: segments.map((s) => s.error).whereType<String>().firstOrNull,
    );
  }

  Note copyWith({
    int? id,
    String? title,
    String? summary,
    String? provider,
    ClinicalReport? clinical,
    String? enrichedHash,
  }) =>
      Note(
        id: id ?? this.id,
        title: title ?? this.title,
        summary: summary ?? this.summary,
        transcript: transcript,
        english: english,
        languageCode: languageCode,
        segments: segments,
        provider: provider ?? this.provider,
        createdAt: createdAt,
        status: status,
        error: error,
        clinical: clinical ?? this.clinical,
        enrichedHash: enrichedHash ?? this.enrichedHash,
      );

  /// Replaces [segments] and re-derives the joined text, language and status.
  Note withSegments(List<Segment> segments) {
    final c = combine(segments);
    return Note(
      id: id,
      title: title,
      summary: summary,
      transcript: c.transcript,
      english: c.english,
      languageCode: c.languageCode,
      segments: segments,
      provider: provider,
      createdAt: createdAt,
      status: c.status,
      error: c.error,
      clinical: clinical,
      enrichedHash: enrichedHash,
    );
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'summary': summary,
        'transcript': transcript,
        'english': english,
        'language_code': languageCode,
        // Legacy columns from before notes had several recordings.
        'audio_path': audioPath,
        'duration_ms': durationMs,
        'provider': provider,
        'created_at': createdAt.millisecondsSinceEpoch,
        'status': status.name,
        'error': error,
        'clinical': clinical == null ? null : jsonEncode(clinical!.toJson()),
        'enriched_hash': enrichedHash,
      };

  factory Note.fromMap(Map<String, Object?> m,
          [List<Segment> segments = const []]) =>
      Note(
        id: m['id'] as int?,
        title: (m['title'] as String?) ?? '',
        summary: (m['summary'] as String?) ?? '',
        transcript: (m['transcript'] as String?) ?? '',
        english: (m['english'] as String?) ?? '',
        languageCode: m['language_code'] as String?,
        segments: segments,
        provider: m['provider'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        status: NoteStatus.values.firstWhere(
          (s) => s.name == m['status'],
          orElse: () => NoteStatus.failed,
        ),
        error: m['error'] as String?,
        clinical: _clinicalFrom(m['clinical'] as String?),
        enrichedHash: m['enriched_hash'] as String?,
      );

  static ClinicalReport? _clinicalFrom(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return ClinicalReport.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
