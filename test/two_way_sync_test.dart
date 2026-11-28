import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/backup_sync.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/services/backup_folder.dart';

class _Cloud {
  final files = <String, String>{};
  final modified = <String, DateTime>{};
  var clock = DateTime(2026, 11, 1);
}

class _Folder implements BackupFolder {
  final _Cloud cloud;
  final String name;
  final String id;
  _Folder(this.cloud, this.name, this.id);

  @override
  Future<FolderInfo> location() async =>
      const FolderInfo('Drive', custom: true, account: 'a@b.c');
  @override
  Future<FolderInfo?> pick() async => const FolderInfo('Chosen', custom: true);
  @override
  Future<FolderInfo> reset() => location();
  @override
  Future<void> write(String name, String text) async {
    cloud.files[name] = text;
    cloud.modified[name] = cloud.clock = cloud.clock.add(const Duration(minutes: 1));
  }

  @override
  Future<List<BackupEntry>> list() async => [
    for (final n in cloud.files.keys) BackupEntry(n, cloud.modified[n]!),
  ];
  @override
  Future<String> read(String name) async => cloud.files[name]!;
  @override
  Future<({String name, String id})> device() async => (name: name, id: id);
}

class _Phone {
  final AppState state;
  final BackupSync sync;
  _Phone(this.state, this.sync);
  NotesDb get db => state.db;

  Future<Note> add(String text, DateTime at) async {
    final n = await db.insert(Note(
      title: text,
      transcript: text,
      provider: 'gemini',
      createdAt: at,
      status: NoteStatus.done,
    ));
    await state.init();
    return n;
  }

  /// Edits the title the way the app does, and gives the change a moment.
  Future<void> retitle(int id, String title) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.update((await db.all()).firstWhere((n) => n.id == id).copyWith(title: title));
    await state.init();
  }

  Future<void> remove(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await state.delete(id);
  }

  List<String> get titles => [for (final n in state.allNotes) n.title]..sort();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory tmp;
  final open = <NotesDb>[];
  final syncs = <BackupSync>[];
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'autoImport': true});
    tmp = await Directory.systemTemp.createTemp('two_way_sync_test');
  });
  tearDown(() async {
    for (final s in syncs) {
      s.dispose();
    }
    syncs.clear();
    for (final db in open) {
      await db.close();
    }
    open.clear();
    await tmp.delete(recursive: true);
  });

  Future<_Phone> phone(_Cloud cloud, String name) async {
    final s = SettingsStore();
    await s.load();
    final db = await NotesDb.open(
      path: p.join(tmp.path, '$name.db'),
      factory: databaseFactoryFfi,
    );
    open.add(db);
    final state = AppState(s, db);
    await state.init();
    final sync = BackupSync(
      state,
      _Folder(cloud, name, name),
      delay: const Duration(hours: 1),
    );
    syncs.add(sync);
    await sync.start();
    return _Phone(state, sync);
  }

  /// [from] saves its backup and [to] picks it up.
  Future<int> flow(_Phone from, _Phone to) async {
    await from.sync.syncNow(force: true);
    return to.sync.importOthers();
  }

  test('a note made on one phone shows up on the other', () async {
    final cloud = _Cloud();
    final a = await phone(cloud, 'a');
    final b = await phone(cloud, 'b');
    await a.add('buy milk', DateTime(2026, 11, 1));

    expect(await flow(a, b), 1);
    expect(b.titles, ['buy milk']);

    // The same file again changes nothing.
    expect(await b.sync.importOthers(), 0);
    expect(await flow(a, b), 0);
  });

  test('the newer edit wins, whichever phone made it', () async {
    final cloud = _Cloud();
    final a = await phone(cloud, 'a');
    final b = await phone(cloud, 'b');
    final n = await a.add('trip', DateTime(2026, 11, 1));
    await flow(a, b);
    final onB = b.state.allNotes.single;

    await a.retitle(n.id!, 'Trip to Coorg');
    await b.retitle(onB.id!, 'Trip to Goa'); // later than A's edit

    // B's edit is newer, so A takes it and B keeps it.
    expect(await flow(b, a), 1);
    expect(a.titles, ['Trip to Goa']);
    expect(await flow(a, b), 0, reason: 'A now holds the same copy');
    expect(b.titles, ['Trip to Goa']);
    expect(b.state.allNotes, hasLength(1), reason: 'an edit is not a new note');
  });

  test('an older copy never replaces a newer one', () async {
    final cloud = _Cloud();
    final a = await phone(cloud, 'a');
    final b = await phone(cloud, 'b');
    final n = await a.add('plan', DateTime(2026, 11, 1));
    await flow(a, b);
    await a.sync.syncNow(force: true); // A's file holds the first version

    await b.retitle(b.state.allNotes.single.id!, 'Plan v2');
    expect(await b.sync.importOthers(), 0);
    expect(b.titles, ['Plan v2']);
    expect(n.id, isNotNull);
  });

  test('a note deleted on one phone is deleted on the other', () async {
    final cloud = _Cloud();
    final a = await phone(cloud, 'a');
    final b = await phone(cloud, 'b');
    final n = await a.add('old', DateTime(2026, 11, 1));
    await a.add('keep', DateTime(2026, 11, 2));
    await flow(a, b);
    expect(b.titles, ['keep', 'old']);

    await a.remove(n.id!);
    expect(await flow(a, b), 1);
    expect(b.titles, ['keep']);

    // And it does not come back from B's file.
    await b.sync.syncNow(force: true);
    expect(await a.sync.importOthers(), 0);
    expect(a.titles, ['keep']);
  });

  test('a note edited after it was deleted elsewhere is kept', () async {
    final cloud = _Cloud();
    final a = await phone(cloud, 'a');
    final b = await phone(cloud, 'b');
    final n = await a.add('shared', DateTime(2026, 11, 1));
    await flow(a, b);

    await a.remove(n.id!);
    await b.retitle(b.state.allNotes.single.id!, 'shared, edited');

    await flow(a, b);
    expect(b.titles, ['shared, edited'], reason: 'B changed it after the delete');
    // ...and A gets it back, because the edit is newer than its delete.
    expect(await flow(b, a), 1);
    expect(a.titles, ['shared, edited']);
  });

  test('a replaced note keeps the recordings on this phone', () async {
    final cloud = _Cloud();
    final a = await phone(cloud, 'a');
    final b = await phone(cloud, 'b');
    final audio = p.join(tmp.path, 'rec.m4a');
    await File(audio).writeAsString('x');
    final n = await a.db.insert(Note(
      title: 'with audio',
      transcript: 'hello',
      provider: 'gemini',
      createdAt: DateTime(2026, 11, 1),
      status: NoteStatus.done,
      segments: [
        Segment(audioPath: audio, transcript: 'hello', status: NoteStatus.done),
      ],
    ));
    await a.state.init();
    await flow(a, b);
    // Pretend B recorded it: give its copy the recording.
    final copy = (await b.db.all()).single;
    await b.db.saveSegment(copy.segments.single.copyWith(audioPath: audio));

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.db.update(
        (await a.db.all()).single.copyWith(title: 'renamed on A'));
    await a.state.init();
    expect(n.id, isNotNull);
    expect(await flow(a, b), 1);

    final after = (await b.db.all()).single;
    expect(after.title, 'renamed on A');
    expect(after.segments.single.audioPath, audio);
    expect(File(audio).existsSync(), isTrue);
  });

  test('restoring by hand still only adds, and can undelete', () async {
    final cloud = _Cloud();
    final a = await phone(cloud, 'a');
    final n = await a.add('oops', DateTime(2026, 11, 1));
    final backup = jsonDecode(jsonEncode(await a.state.backup())) as Map;

    await a.remove(n.id!);
    expect(a.titles, isEmpty);
    final r = await a.state.restore(Map<String, Object?>.from(backup));
    expect(r.added, 1, reason: 'a restore brings back what was deleted');
    expect(a.titles, ['oops']);
    expect((await a.state.restore(Map<String, Object?>.from(backup))).changed, 0);
  });

  test('notes from before ids, and old backups, still match', () async {
    final cloud = _Cloud();
    final a = await phone(cloud, 'a');
    await a.add('legacy', DateTime(2026, 11, 1));
    final backup = Map<String, Object?>.from(
        jsonDecode(jsonEncode(await a.state.backup())) as Map);
    // A version 7 file: no ids, no times, no deletions.
    final notes = Map<String, Object?>.from(backup['notes'] as Map);
    notes['version'] = 7;
    notes.remove('deleted_notes');
    notes['notes'] = [
      for (final n in notes['notes'] as List)
        {...Map<String, Object?>.from(n as Map)}
          ..remove('uid')
          ..remove('updated_at'),
    ];
    backup['notes'] = notes;

    final r = await a.state.restore(backup, sync: true);
    expect(r.changed, 0, reason: 'same time and text: the same note');
    expect(a.state.allNotes, hasLength(1));
  });

  test('deletions are forgotten after 90 days', () async {
    final path = p.join(tmp.path, 'ttl.db');
    final first = await NotesDb.open(path: path, factory: databaseFactoryFfi);
    await first.close();
    final now = DateTime.now();
    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.insert('deleted_notes', {
      'uid': 'old',
      'deleted_at': now.subtract(const Duration(days: 91)).millisecondsSinceEpoch,
    });
    await raw.insert('deleted_notes', {
      'uid': 'recent',
      'deleted_at': now.subtract(const Duration(days: 89)).millisecondsSinceEpoch,
    });
    await raw.close();

    final db = await NotesDb.open(path: path, factory: databaseFactoryFfi);
    open.add(db);
    final kept = (await db.export())['deleted_notes'] as List;
    expect(kept.map((r) => (r as Map)['uid']), ['recent']);

    // A deletion that old, arriving from another phone, is not applied.
    final n = await db.insert(Note(
      title: 'still here',
      transcript: 'x',
      provider: 'gemini',
      createdAt: DateTime(2026, 11, 1),
      status: NoteStatus.done,
    ));
    final uid = ((await db.export())['notes'] as List).cast<Map>().single['uid'];
    final r = await db.import({
      'version': NotesDb.version,
      'deleted_notes': [
        {
          'uid': uid,
          'deleted_at': now.subtract(const Duration(days: 200)).millisecondsSinceEpoch,
        },
      ],
    }, sync: true);
    expect(r.removed, 0);
    expect(n.id, isNotNull);
    expect(await db.all(), hasLength(1));
  });

  test('a database from before ids gets them, and keeps its notes', () async {
    final path = p.join(tmp.path, 'v7.db');
    final raw = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 7,
            onCreate: (db, _) async {
              await db.execute('''
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
                  speakers TEXT,
                  tags_edited INTEGER NOT NULL DEFAULT 0,
                  outputs TEXT
                )''');
              await db.execute('''
                CREATE TABLE segments (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  note_id INTEGER NOT NULL,
                  position INTEGER NOT NULL,
                  audio_path TEXT NOT NULL,
                  transcript TEXT NOT NULL DEFAULT '',
                  english TEXT NOT NULL DEFAULT '',
                  language_code TEXT,
                  status TEXT NOT NULL,
                  error TEXT,
                  duration_ms INTEGER,
                  lines TEXT
                )''');
              await db.execute(
                  'CREATE TABLE folders (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)');
              await db.execute('''
                CREATE TABLE tags (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                  approved INTEGER NOT NULL DEFAULT 1
                )''');
              await db.execute('''
                CREATE TABLE note_tags (
                  note_id INTEGER NOT NULL,
                  tag_id INTEGER NOT NULL,
                  PRIMARY KEY (note_id, tag_id)
                )''');
              for (final t in ['one', 'two']) {
                await db.insert('notes', {
                  'title': t,
                  'transcript': t,
                  'audio_path': '',
                  'provider': 'gemini',
                  'created_at': 1000,
                  'status': 'done',
                });
              }
            }));
    await raw.close();

    final db = await NotesDb.open(path: path, factory: databaseFactoryFfi);
    open.add(db);
    final out = await db.export();
    final rows = (out['notes'] as List).cast<Map<String, Object?>>();
    expect(rows, hasLength(2));
    expect(rows.map((r) => r['uid']).toSet(), hasLength(2));
    expect(rows.every((r) => (r['uid'] as String).length == 32), isTrue);
    expect(rows.every((r) => r['updated_at'] == 1000), isTrue);
    expect(out['deleted_notes'], isEmpty);
  });
}
