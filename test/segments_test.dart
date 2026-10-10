import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/clinical_export.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';

/// Returns canned text per audio file name and records what it was asked.
class FakeProvider implements AiProvider {
  final Map<String, Transcription> byFile;
  final transcribed = <String>[];
  final summarized = <String>[];
  final clinicalPrompts = <String>[];

  FakeProvider(this.byFile);

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio, {required bool translate}) async {
    final name = p.basename(audio.path);
    transcribed.add(name);
    final t = byFile[name];
    if (t == null) throw const ProviderException('boom');
    return t;
  }

  @override
  Future<NoteSummary> summarize(String text) async {
    summarized.add(text);
    return NoteSummary('Title ${summarized.length}', 'Summary of: $text');
  }

  @override
  Future<String> completeJson(String prompt) async {
    clinicalPrompts.add(prompt);
    return '{"interpretation": "i", "note_english": "n", "note_native": "", "verify": []}';
  }
}

class FakeSettings extends SettingsStore {
  final AiProvider? provider;
  FakeSettings(this.provider);

  @override
  AiProvider? build(ProviderId id) => provider;
}

const _v2Notes = '''
  CREATE TABLE notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL DEFAULT '',
    summary TEXT NOT NULL DEFAULT '',
    transcript TEXT NOT NULL DEFAULT '',
    english TEXT NOT NULL DEFAULT '',
    language_code TEXT,
    audio_path TEXT NOT NULL,
    provider TEXT NOT NULL,
    duration_ms INTEGER,
    created_at INTEGER NOT NULL,
    status TEXT NOT NULL,
    error TEXT,
    clinical TEXT
  )''';

void main() {
  sqfliteFfiInit();
  final ffi = databaseFactoryFfi;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('segments_test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<NotesDb> freshDb() =>
      NotesDb.open(path: p.join(tmp.path, 'new.db'), factory: ffi);

  Future<File> audio(String name) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes([0, 1, 2]);
    return f;
  }

  group('migration', () {
    test('tolerates a v1 database that already has the v2 clinical column',
        () async {
      final path = p.join(tmp.path, 'half.db');
      final old = await ffi.openDatabase(path,
          options: OpenDatabaseOptions(
              version: 1, onCreate: (db, _) => db.execute(_v2Notes)));
      await old.insert('notes', {
        'provider': 'gemini',
        'created_at': 1000,
        'status': 'done',
        'audio_path': '/a/one.m4a',
      });
      await old.close();

      final db = await NotesDb.open(path: path, factory: ffi);
      final notes = await db.all();
      expect(notes.single.segments, hasLength(1));
      await db.close();
    });

    test('turns each existing note into a note with one recording', () async {
      final path = p.join(tmp.path, 'old.db');
      final old = await ffi.openDatabase(path,
          options: OpenDatabaseOptions(
              version: 2, onCreate: (db, _) => db.execute(_v2Notes)));
      Future<void> put(Map<String, Object?> m) => old.insert('notes', {
            'provider': 'gemini',
            'created_at': 1000,
            'status': 'done',
            ...m,
          });
      await put({
        'title': 'Fever',
        'summary': 'Patient has fever',
        'transcript': 'జ్వరం',
        'english': 'fever',
        'language_code': 'te-IN',
        'audio_path': '/a/one.m4a',
        'duration_ms': 4200,
        'clinical': '{"interpretation": "i"}',
      });
      await put({
        'status': 'failed',
        'error': 'No internet connection.',
        'audio_path': '/a/two.m4a',
        'created_at': 500,
      });
      await old.close();

      final db = await NotesDb.open(path: path, factory: ffi);
      final notes = await db.all();
      expect(notes, hasLength(2));

      final fever = notes.first;
      expect(fever.segments, hasLength(1));
      final s = fever.segments.single;
      expect(s.audioPath, '/a/one.m4a');
      expect(s.transcript, 'జ్వరం');
      expect(s.english, 'fever');
      expect(s.languageCode, 'te-IN');
      expect(s.durationMs, 4200);
      expect(s.status, NoteStatus.done);
      expect(s.position, 0);
      expect(fever.audioPath, '/a/one.m4a');
      expect(fever.durationMs, 4200);
      expect(fever.transcript, 'జ్వరం');
      expect(fever.clinical, isNotNull);
      // Existing enrichment is treated as current, not stale.
      expect(fever.isStale, isFalse);

      final failed = notes.last.segments.single;
      expect(failed.status, NoteStatus.failed);
      expect(failed.error, 'No internet connection.');
      expect(notes.last.isStale, isFalse);
      await db.close();
    });
  });

  group('joined text', () {
    test('is in recording order and skips unfinished ones', () {
      final c = Note.combine(const [
        Segment(
            audioPath: 'a',
            transcript: 'first',
            languageCode: 'te-IN',
            status: NoteStatus.done),
        Segment(audioPath: 'b', status: NoteStatus.failed, error: 'x'),
        Segment(audioPath: 'c', transcript: 'third', status: NoteStatus.done),
      ]);
      expect(c.transcript, 'first\n\nthird');
      expect(c.english, '');
      expect(c.languageCode, 'te-IN');
      expect(c.status, NoteStatus.done);
      expect(c.error, 'x');
    });

    test('English falls back to the original for a recording without one', () {
      final c = Note.combine(const [
        Segment(
            audioPath: 'a',
            transcript: 'జ్వరం',
            english: 'fever',
            status: NoteStatus.done),
        Segment(audioPath: 'b', transcript: 'cough', status: NoteStatus.done),
      ]);
      expect(c.english, 'fever\n\ncough');
    });

    test('note is processing while any recording is, failed if none worked', () {
      expect(
          Note.combine(const [
            Segment(audioPath: 'a', status: NoteStatus.done),
            Segment(audioPath: 'b'),
          ]).status,
          NoteStatus.processing);
      expect(
          Note.combine(const [Segment(audioPath: 'a', status: NoteStatus.failed)])
              .status,
          NoteStatus.failed);
    });
  });

  group('appending recordings', () {
    late NotesDb db;
    late FakeProvider provider;
    late AppState state;

    setUp(() async {
      db = await freshDb();
      provider = FakeProvider({
        'one.m4a': const Transcription(
            text: 'జ్వరం', english: 'fever', languageCode: 'te-IN'),
        'two.m4a': const Transcription(
            text: 'దగ్గు', english: 'cough', languageCode: 'te-IN'),
      });
      state = AppState(FakeSettings(provider), db);
    });
    tearDown(() => db.close());

    test('transcribes only the new recording and marks the note stale',
        () async {
      final one = await audio('one.m4a');
      final two = await audio('two.m4a');
      final note = await state.addAudio(one.path, durationMs: 1000);
      await state.settled();

      var n = state.byId(note.id!)!;
      expect(n.status, NoteStatus.done);
      expect(n.summary, startsWith('Summary of: fever'));
      expect(n.isStale, isFalse);
      final firstTitle = n.title;
      final firstSummary = n.summary;
      expect(provider.transcribed, ['one.m4a']);
      expect(provider.summarized, ['fever']);

      await state.addSegment(note.id!, two.path, durationMs: 2000);
      // Right after appending, before the new one is transcribed.
      expect(state.byId(note.id!)!.status, NoteStatus.processing);
      await state.settled();

      n = state.byId(note.id!)!;
      expect(provider.transcribed, ['one.m4a', 'two.m4a']);
      expect(n.segments.map((s) => p.basename(s.audioPath)),
          ['one.m4a', 'two.m4a']);
      expect(n.segments.map((s) => s.position), [0, 1]);
      expect(n.transcript, 'జ్వరం\n\nదగ్గు');
      expect(n.english, 'fever\n\ncough');
      expect(n.durationMs, 3000);
      expect(n.status, NoteStatus.done);
      // Not regenerated behind the user's back.
      expect(provider.summarized, ['fever']);
      expect(n.title, firstTitle);
      expect(n.summary, firstSummary);
      expect(n.isStale, isTrue);

      // The same state comes back from the database.
      final reloaded = (await db.all()).single;
      expect(reloaded.segments, hasLength(2));
      expect(reloaded.transcript, 'జ్వరం\n\nదగ్గు');
      expect(reloaded.isStale, isTrue);
    });

    test('regenerate uses the combined text and clears the flag', () async {
      final note = await state.addAudio((await audio('one.m4a')).path);
      await state.settled();
      await state.addSegment(note.id!, (await audio('two.m4a')).path);
      await state.settled();
      expect(state.byId(note.id!)!.isStale, isTrue);

      expect(await state.regenerate(note.id!), isNull);

      final n = state.byId(note.id!)!;
      expect(provider.summarized.last, 'fever\n\ncough');
      expect(n.summary, 'Summary of: fever\n\ncough');
      expect(n.isStale, isFalse);
      expect((await db.all()).single.isStale, isFalse);
    });

    test('a clinical note is flagged stale on append and rebuilt on regenerate',
        () async {
      final note = await state.addAudio((await audio('one.m4a')).path);
      await state.settled();
      expect(await state.enrichClinical(note.id!), isNull);
      expect(state.byId(note.id!)!.clinical, isNotNull);
      expect(state.byId(note.id!)!.isStale, isFalse);

      await state.addSegment(note.id!, (await audio('two.m4a')).path);
      await state.settled();
      final stale = state.byId(note.id!)!;
      expect(stale.isStale, isTrue);
      expect(clinicalReportText(stale), contains('OUT OF DATE'));

      provider.clinicalPrompts.clear();
      await state.regenerate(note.id!);
      expect(provider.clinicalPrompts, hasLength(1));
      expect(provider.clinicalPrompts.single, contains('cough'));
      final fresh = state.byId(note.id!)!;
      expect(fresh.isStale, isFalse);
      expect(clinicalReportText(fresh), isNot(contains('OUT OF DATE')));
    });

    test('a failed recording can be retried on its own', () async {
      final note = await state.addAudio((await audio('one.m4a')).path);
      await state.settled();
      final bad = await audio('three.m4a');
      final seg = await state.addSegment(note.id!, bad.path);
      await state.settled();

      var n = state.byId(note.id!)!;
      expect(n.segments.last.status, NoteStatus.failed);
      expect(n.segments.last.error, 'boom');
      expect(n.status, NoteStatus.done);
      expect(n.transcript, 'జ్వరం');

      provider.byFile['three.m4a'] = const Transcription(text: 'x', english: 'rash');
      provider.transcribed.clear();
      await state.retrySegment(note.id!, seg!.id!);
      await state.settled();
      n = state.byId(note.id!)!;
      expect(provider.transcribed, ['three.m4a']);
      expect(n.segments.last.status, NoteStatus.done);
      expect(n.english, 'fever\n\nrash');
    });

    test('deleting a note removes every recording file', () async {
      final one = await audio('one.m4a');
      final two = await audio('two.m4a');
      final note = await state.addAudio(one.path);
      await state.settled();
      await state.addSegment(note.id!, two.path);
      await state.settled();

      await state.delete(note.id!);
      expect(one.existsSync(), isFalse);
      expect(two.existsSync(), isFalse);
      expect(await db.all(), isEmpty);
    });

    test('deleting one recording keeps the others and flags the note', () async {
      final one = await audio('one.m4a');
      final two = await audio('two.m4a');
      final note = await state.addAudio(one.path);
      await state.settled();
      final seg = await state.addSegment(note.id!, two.path);
      await state.settled();

      await state.deleteSegment(note.id!, seg!.id!);
      final n = state.byId(note.id!)!;
      expect(n.segments, hasLength(1));
      expect(two.existsSync(), isFalse);
      expect(one.existsSync(), isTrue);
      expect(n.transcript, 'జ్వరం');

      // The only recording left cannot be deleted this way.
      await state.deleteSegment(note.id!, n.segments.single.id!);
      expect(state.byId(note.id!)!.segments, hasLength(1));
    });
  });
}
