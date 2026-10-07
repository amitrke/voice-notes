import 'dart:convert';

import '../providers/ai_provider.dart';

enum NoteStatus { processing, done, failed }

class Note {
  final int? id;
  final String title;
  final String summary;
  final String transcript;
  final String english;
  final String? languageCode;
  final String audioPath;
  final String provider;
  final int? durationMs;
  final DateTime createdAt;
  final NoteStatus status;
  final String? error;
  final ClinicalReport? clinical;

  const Note({
    this.id,
    this.title = '',
    this.summary = '',
    this.transcript = '',
    this.english = '',
    this.languageCode,
    required this.audioPath,
    required this.provider,
    this.durationMs,
    required this.createdAt,
    this.status = NoteStatus.processing,
    this.error,
    this.clinical,
  });

  Note copyWith({
    int? id,
    String? title,
    String? summary,
    String? transcript,
    String? english,
    String? languageCode,
    String? provider,
    NoteStatus? status,
    String? error,
    ClinicalReport? clinical,
    bool clearError = false,
  }) =>
      Note(
        id: id ?? this.id,
        title: title ?? this.title,
        summary: summary ?? this.summary,
        transcript: transcript ?? this.transcript,
        english: english ?? this.english,
        languageCode: languageCode ?? this.languageCode,
        audioPath: audioPath,
        provider: provider ?? this.provider,
        durationMs: durationMs,
        createdAt: createdAt,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
        clinical: clinical ?? this.clinical,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'summary': summary,
        'transcript': transcript,
        'english': english,
        'language_code': languageCode,
        'audio_path': audioPath,
        'provider': provider,
        'duration_ms': durationMs,
        'created_at': createdAt.millisecondsSinceEpoch,
        'status': status.name,
        'error': error,
        'clinical': clinical == null ? null : jsonEncode(clinical!.toJson()),
      };

  factory Note.fromMap(Map<String, Object?> m) => Note(
        id: m['id'] as int?,
        title: (m['title'] as String?) ?? '',
        summary: (m['summary'] as String?) ?? '',
        transcript: (m['transcript'] as String?) ?? '',
        english: (m['english'] as String?) ?? '',
        languageCode: m['language_code'] as String?,
        audioPath: m['audio_path'] as String,
        provider: m['provider'] as String,
        durationMs: m['duration_ms'] as int?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        status: NoteStatus.values.firstWhere(
          (s) => s.name == m['status'],
          orElse: () => NoteStatus.failed,
        ),
        error: m['error'] as String?,
        clinical: _clinicalFrom(m['clinical'] as String?),
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
