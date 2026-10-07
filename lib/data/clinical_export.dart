import 'package:path/path.dart' as p;

import '../models/note.dart';
import '../ui/format.dart';

const _bar = '====================================================';
const _rule = '----------------------------------------------------';

/// The clinical scribe report as plain text, in the layout clinicians asked
/// for. Sections without content are left out and the rest renumbered.
String clinicalReportText(Note note) {
  final c = note.clinical;
  if (c == null) return '';
  final lang = languageLabel(note.languageCode);
  final sections = <(String, String)>[
    ('ORIGINAL TRANSCRIPT', note.transcript),
    ('ENGLISH TRANSCRIPT', note.english),
    ('CLINICAL INTERPRETATION', c.interpretation),
    ('CLINICAL NOTE — ENGLISH', c.noteEnglish),
    (
      'CLINICAL NOTE — ${(lang ?? 'ORIGINAL LANGUAGE').toUpperCase()}',
      c.noteNative
    ),
    ('VERIFICATION REQUIRED', c.verify.map((v) => '⚠ $v').join('\n')),
  ].where((s) => s.$2.trim().isNotEmpty).toList();

  final b = StringBuffer()
    ..writeln(_bar)
    ..writeln('              CLINICAL SCRIBE')
    ..writeln(_bar)
    ..writeln()
    ..writeln('LANGUAGE')
    ..writeln(lang ?? 'Unknown')
    ..writeln()
    ..writeln('AUDIO')
    ..writeln(p.basename(note.audioPath))
    ..writeln()
    ..writeln('DATE')
    ..writeln(formatDate(note.createdAt));
  for (var i = 0; i < sections.length; i++) {
    b
      ..writeln()
      ..writeln(_rule)
      ..writeln('${i + 1}. ${sections[i].$1}')
      ..writeln(_rule)
      ..writeln()
      ..writeln(sections[i].$2.trim());
  }
  b
    ..writeln()
    ..writeln(_rule)
    ..writeln('AI-generated draft. A clinician must review and verify it before')
    ..writeln('it is used in patient care.')
    ..writeln(_bar);
  return b.toString();
}
