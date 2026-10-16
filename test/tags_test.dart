import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';

/// Transcribes everything as [text] and answers the summary prompt with
/// [reply], parsed the way the real providers parse it.
class _TagProvider implements AiProvider {
  final String text;
  String reply;
  final offered = <List<String>>[];
  _TagProvider(this.text, this.reply);

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio,
          {required bool translate,
          List<String> vocabulary = const [],
          bool speakers = false}) async =>
      Transcription(text: text);

  @override
  Future<NoteSummary> summarize(String text,
      {List<String> tags = const []}) async {
    offered.add(tags);
    return summaryFromReply(reply, allowed: tags);
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

const _v5Notes = '''
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
    clinical TEXT,
    enriched_hash TEXT,
    folder_id INTEGER,
    speakers TEXT
  )''';

void main() {
  sqfliteFfiInit();
  final ffi = databaseFactoryFfi;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tags_test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<NotesDb> freshDb() =>
      NotesDb.open(path: p.join(tmp.path, 'new.db'), factory: ffi);

  group('summary reply parsing', () {
    const allowed = ['Grocery', 'To-do', 'Work'];

    test('keeps only approved tags, with the user\'s spelling', () {
      final s = summaryFromReply(
          '{"title": "Milk", "summary": "Buy milk.", '
          '"tags": ["grocery", "Shopping", "TO-DO", "grocery"], '
          '"suggested_tag": ""}',
          allowed: allowed);
      expect(s.tags, ['Grocery', 'To-do']);
      expect(s.suggestedTag, isNull);
    });

    test('a suggestion is kept only when no approved tag fits', () {
      expect(
          summaryFromReply(
                  '{"title": "t", "summary": "s", "tags": [], '
                  '"suggested_tag": "  Travel  plans "}',
                  allowed: allowed)
              .suggestedTag,
          'Travel plans');
      expect(
          summaryFromReply(
                  '{"title": "t", "summary": "s", "tags": ["Work"], '
                  '"suggested_tag": "Meetings"}',
                  allowed: allowed)
              .suggestedTag,
          isNull);
    });

    test('a suggestion that is already approved becomes a tag', () {
      final s = summaryFromReply(
          '{"title": "t", "summary": "s", "tags": [], '
          '"suggested_tag": "work"}',
          allowed: allowed);
      expect(s.tags, ['Work']);
      expect(s.suggestedTag, isNull);
    });

    test('without approved tags, tags in the reply are ignored', () {
      final s = summaryFromReply(
          '{"title": "t", "summary": "s", "tags": ["Grocery"], '
          '"suggested_tag": "Food"}');
      expect(s.tags, isEmpty);
      expect(s.suggestedTag, isNull);
    });

    test('tolerates a missing or malformed tags field', () {
      expect(summaryFromReply('{"title": "t", "summary": "s"}', allowed: allowed).tags,
          isEmpty);
      expect(
          summaryFromReply('{"title": "t", "summary": "s", "tags": "Work"}',
                  allowed: allowed)
              .tags,
          isEmpty);
    });

    test('the prompt lists the approved tags only when there are some', () {
      expect(summaryPrompt('milk', tags: allowed), contains('["Grocery","To-do","Work"]'));
      expect(summaryPrompt('milk', tags: allowed), endsWith('milk'));
      expect(summaryPrompt('milk'), isNot(contains('tags')));
    });
  });

  group('tags in the database', () {
    test('a new database starts with the starter tags, approved', () async {
      final db = await freshDb();
      final tags = await db.tags();
      expect(tags.map((t) => t.name).toSet(), starterTags.toSet());
      expect(tags.every((t) => t.approved), isTrue);
      await db.close();
    });

    test('note tags and the manual flag round-trip', () async {
      final db = await freshDb();
      final grocery = (await db.tags()).firstWhere((t) => t.name == 'Grocery');
      final pending = await db.insertTag('Travel', approved: false);
      var note = await db.insert(Note(
        provider: 'gemini',
        createdAt: DateTime(2026, 1, 1),
        segments: const [Segment(audioPath: '/a.m4a')],
      ));
      await db.setNoteTags(note.id!, [grocery.id!, pending.id!]);
      await db.update(note.copyWith(tagsEdited: true));

      note = (await db.all()).single;
      expect(note.tagIds, unorderedEquals([grocery.id, pending.id]));
      expect(note.tagsEdited, isTrue);
      expect((await db.tags()).firstWhere((t) => t.id == pending.id).approved,
          isFalse);

      await db.deleteTag(grocery.id!);
      expect((await db.all()).single.tagIds, [pending.id]);

      await db.delete(note.id!);
      await db.setNoteTags(99, const []);
      await db.close();
    });

    test('tag names are unique ignoring case', () async {
      final db = await freshDb();
      expect(() => db.insertTag('grocery'), throwsA(anything));
      await db.close();
    });

    test('a version 5 database gains tag tables and keeps its notes', () async {
      final path = p.join(tmp.path, 'v5.db');
      final old = await ffi.openDatabase(path,
          options: OpenDatabaseOptions(
              version: 5,
              onCreate: (db, _) async {
                await db.execute(_v5Notes);
                await db.execute('CREATE TABLE segments (id INTEGER PRIMARY '
                    'KEY AUTOINCREMENT, note_id INTEGER NOT NULL, position '
                    'INTEGER NOT NULL, audio_path TEXT NOT NULL, transcript '
                    'TEXT NOT NULL DEFAULT \'\', english TEXT NOT NULL '
                    'DEFAULT \'\', language_code TEXT, status TEXT NOT NULL, '
                    'error TEXT, duration_ms INTEGER, lines TEXT)');
                await db.execute(
                    'CREATE TABLE folders (id INTEGER PRIMARY KEY, name TEXT)');
              }));
      await old.insert('notes', {
        'title': 'Old',
        'provider': 'gemini',
        'created_at': 1000,
        'status': 'done',
        'audio_path': '/a/one.m4a',
      });
      await old.close();

      final db = await NotesDb.open(path: path, factory: ffi);
      final note = (await db.all()).single;
      expect(note.title, 'Old');
      expect(note.tagIds, isEmpty);
      expect(note.tagsEdited, isFalse);
      expect((await db.tags()).length, starterTags.length);
      await db.close();
    });
  });

  group('tagging during enrichment', () {
    late NotesDb db;
    late _TagProvider provider;
    late AppState state;

    setUp(() async {
      db = await freshDb();
      provider = _TagProvider(
          'running low on milk and dal',
          '{"title": "Groceries", "summary": "Buy milk and dal.", '
              '"tags": ["Grocery", "Errands"], "suggested_tag": ""}');
      state = AppState(_Settings(provider), db);
      await state.init();
    });
    tearDown(() => db.close());

    Future<Note> record() async {
      final f = File(p.join(tmp.path, 'one.m4a'));
      await f.writeAsBytes([0, 1, 2]);
      final note = await state.addAudio(f.path);
      await state.settled();
      return state.byId(note.id!)!;
    }

    List<String> names(Note n) => [for (final t in state.tagsOf(n)) t.name];

    test('applies the approved tags the model picked', () async {
      final n = await record();
      expect(provider.offered.single, containsAll(starterTags));
      expect(names(n), ['Grocery']);
      // Stored, not just in memory.
      expect((await db.all()).single.tagIds, n.tagIds);
    });

    test('a suggested tag waits for approval, then shows on the note',
        () async {
      provider.reply = '{"title": "Trip", "summary": "s", "tags": [], '
          '"suggested_tag": "Travel"}';
      final n = await record();
      expect(names(n), isEmpty);
      final travel = state.suggestedTags.single;
      expect(travel.name, 'Travel');
      expect(state.approvedTags.map((t) => t.name), isNot(contains('Travel')));

      await state.approveTag(travel.id!);
      expect(names(state.byId(n.id!)!), ['Travel']);
      expect(provider.offered.length, 1);
    });

    test('rejecting a suggestion removes it from the note', () async {
      provider.reply = '{"title": "Trip", "summary": "s", "tags": [], '
          '"suggested_tag": "Travel"}';
      final n = await record();
      await state.deleteTag(state.suggestedTags.single.id!);
      expect(state.byId(n.id!)!.tagIds, isEmpty);
      expect((await db.tags()).map((t) => t.name), isNot(contains('Travel')));
    });

    test('regenerating retags a note the user never tagged by hand', () async {
      final n = await record();
      provider.reply = '{"title": "Work", "summary": "s", "tags": ["Work"]}';
      expect(await state.regenerate(n.id!), isNull);
      expect(names(state.byId(n.id!)!), ['Work']);
    });

    test('tags edited by hand survive regeneration', () async {
      final n = await record();
      final health = state.approvedTags.firstWhere((t) => t.name == 'Health');
      await state.toggleNoteTag(n.id!, health.id!);
      expect(names(state.byId(n.id!)!), ['Grocery', 'Health']);

      provider.reply = '{"title": "Work", "summary": "s", "tags": ["Work"], '
          '"suggested_tag": ""}';
      expect(await state.regenerate(n.id!), isNull);
      final after = state.byId(n.id!)!;
      expect(after.title, 'Work');
      expect(names(after), ['Grocery', 'Health']);
      expect(after.tagsEdited, isTrue);

      // Also after a restart.
      final reloaded = (await db.all()).single;
      expect(reloaded.tagsEdited, isTrue);
      expect(reloaded.tagIds.toSet(), after.tagIds.toSet());
    });

    test('removing every tag by hand also counts as an edit', () async {
      final n = await record();
      final grocery = state.approvedTags.firstWhere((t) => t.name == 'Grocery');
      await state.toggleNoteTag(n.id!, grocery.id!);
      expect(await state.regenerate(n.id!), isNull);
      expect(state.byId(n.id!)!.tagIds, isEmpty);
    });

    test('filters the note list by tag', () async {
      final n = await record();
      final grocery = state.approvedTags.firstWhere((t) => t.name == 'Grocery');
      final work = state.approvedTags.firstWhere((t) => t.name == 'Work');
      state.tagFilter = grocery.id;
      expect(state.notes.map((e) => e.id), [n.id]);
      state.tagFilter = work.id;
      expect(state.notes, isEmpty);
      await state.deleteTag(work.id!);
      expect(state.tagFilter, isNull);
    });

    test('creating, renaming and approving by name', () async {
      expect(await state.createTag('  '), isNull);
      final t = await state.createTag('Family');
      expect(t!.approved, isTrue);
      expect(await state.renameTag(t.id!, 'work'), isFalse);
      expect(await state.renameTag(t.id!, 'Home'), isTrue);
      expect(state.approvedTags.map((t) => t.name), contains('Home'));

      provider.reply = '{"title": "t", "summary": "s", "tags": [], '
          '"suggested_tag": "Travel"}';
      await record();
      // Adding a tag the model already suggested approves it.
      await state.createTag('travel');
      expect(state.suggestedTags, isEmpty);
      expect(state.approvedTags.map((t) => t.name), contains('Travel'));
    });
  });
}
