import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';

/// Transcribes a file as its name; files named "bad" fail.
class _Provider implements AiProvider {
  final summarised = <String>[];

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio,
      {required bool translate,
      List<String> vocabulary = const [],
      bool speakers = false}) async {
    final name = p.basenameWithoutExtension(audio.path);
    // Slow enough to finish after the parts that work.
    if (name == 'bad') {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      throw const ProviderException('boom');
    }
    return Transcription(text: 'heard $name');
  }

  @override
  Future<NoteSummary> summarize(String text,
      {List<String> tags = const []}) async {
    summarised.add(text);
    return const NoteSummary('A title', 'A summary.');
  }

  @override
  Future<String> completeJson(String prompt) async => '{}';
}

class _Settings extends SettingsStore {
  final AiProvider provider;
  _Settings(this.provider);

  @override
  AiProvider? build(ProviderId id) => provider;
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('vn_loss');
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<String> file(String dir, String name) async {
    await Directory(dir).create(recursive: true);
    final f = File(p.join(dir, name));
    await f.writeAsBytes([0]);
    return f.path;
  }

  Future<NotesDb> open(String root) => NotesDb.open(
      path: p.join(tmp.path, 'notes.db'),
      factory: databaseFactoryFfi,
      audioRoot: root);

  Note note(String audioPath) => Note(
        segments: [
          Segment(
              audioPath: audioPath, transcript: 'hi', status: NoteStatus.done)
        ],
        provider: 'gemini',
        createdAt: DateTime(2026),
      );

  group('recordings folder that moves', () {
    test('a recording is found again under the new folder', () async {
      final oldRoot = p.join(tmp.path, 'old', 'audio');
      final newRoot = p.join(tmp.path, 'new', 'audio');
      var db = await open(oldRoot);
      await db.insert(note(await file(oldRoot, 'rec_1.m4a')));
      await db.close();

      await Directory(oldRoot).rename(await Directory(newRoot)
          .parent
          .create(recursive: true)
          .then((_) => newRoot));
      db = await open(newRoot);
      final settings = _Settings(_Provider());
      await settings.load();
      final state = AppState(settings, db);
      await state.init();

      final seg = state.allNotes.single.segments.single;
      expect(seg.audioPath, p.join(newRoot, 'rec_1.m4a'));
      expect(File(seg.audioPath).existsSync(), isTrue);
      await db.close();
    });

    test('an absolute path from an earlier version is found by name',
        () async {
      final oldRoot = p.join(tmp.path, 'old', 'audio');
      final newRoot = p.join(tmp.path, 'new', 'audio');
      // Earlier versions stored the full path.
      var db = await NotesDb.open(
          path: p.join(tmp.path, 'notes.db'), factory: databaseFactoryFfi);
      await db.insert(note(p.join(oldRoot, 'rec_1.m4a')));
      await db.close();
      await file(newRoot, 'rec_1.m4a');

      db = await open(newRoot);
      final settings = _Settings(_Provider());
      await settings.load();
      final state = AppState(settings, db);
      await state.init();
      expect(state.allNotes.single.segments.single.audioPath,
          p.join(newRoot, 'rec_1.m4a'));
      await db.close();

      // Saved relative, so it survives the next move without a search.
      final raw = await databaseFactoryFfi
          .openDatabase(p.join(tmp.path, 'notes.db'));
      expect((await raw.query('segments')).single['audio_path'], 'rec_1.m4a');
      await raw.close();
    });

    test('a recording that is really gone leaves the text', () async {
      final root = p.join(tmp.path, 'audio');
      final db = await open(root);
      await db.insert(note(p.join(root, 'gone.m4a')));
      final settings = _Settings(_Provider());
      await settings.load();
      final state = AppState(settings, db);
      await state.init();
      final seg = state.allNotes.single.segments.single;
      expect(seg.hasAudio, isFalse);
      expect(seg.transcript, 'hi');
      await db.close();
    });
  });

  group('a part that fails', () {
    late NotesDb db;
    late _Provider provider;
    late AppState state;

    setUp(() async {
      db = await NotesDb.open(
          path: p.join(tmp.path, 'notes.db'), factory: databaseFactoryFfi);
      provider = _Provider();
      final settings = _Settings(provider);
      await settings.load();
      state = AppState(settings, db);
    });
    tearDown(() => db.close());

    test('last of all still leaves the note titled and summarised', () async {
      final n = await state.addAudio(await file(tmp.path, 'good.m4a'),
          live: true);
      await state.addSegment(n.id!, await file(tmp.path, 'bad.m4a'));
      await state.endLive(n.id!);
      await state.settled();

      final done = state.byId(n.id!)!;
      expect(done.segments.last.status, NoteStatus.failed);
      expect(done.summary, 'A summary.');
      expect(done.title, 'A title');
      expect(state.live(n.id!), isNull);
    });

    test('alone does not title the note "No speech detected"', () async {
      final n = await state.addAudio(await file(tmp.path, 'bad.m4a'));
      await state.settled();
      final failed = state.byId(n.id!)!;
      expect(failed.status, NoteStatus.failed);
      expect(failed.title, isEmpty);
      expect(provider.summarised, isEmpty);
    });
  });
}
