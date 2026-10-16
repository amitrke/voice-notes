import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/note.dart';

const _segmentsTable = '''
  CREATE TABLE IF NOT EXISTS segments (
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
  )''';

const _foldersTable = '''
  CREATE TABLE IF NOT EXISTS folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL
  )''';

const _tagsTable = '''
  CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
    approved INTEGER NOT NULL DEFAULT 1
  )''';

const _noteTagsTable = '''
  CREATE TABLE IF NOT EXISTS note_tags (
    note_id INTEGER NOT NULL,
    tag_id INTEGER NOT NULL,
    PRIMARY KEY (note_id, tag_id)
  )''';

/// Tags a new install starts with; the user can rename or delete them.
const starterTags = ['Grocery', 'To-do', 'Work', 'Health', 'Ideas'];

class NotesDb {
  final Database _db;
  NotesDb._(this._db);

  static const version = 6;

  /// Opens the database at [path] (default: the app's databases folder).
  /// [factory] lets tests use sqflite_common_ffi.
  static Future<NotesDb> open({String? path, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path ?? p.join(await getDatabasesPath(), 'voice_notes.db'),
      options: OpenDatabaseOptions(
        version: version,
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
              tags_edited INTEGER NOT NULL DEFAULT 0
            )''');
          await db.execute(_segmentsTable);
          await db.execute(_foldersTable);
          await _addTags(db);
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) await _addColumn(db, 'notes', 'clinical');
          if (from < 3) await _toSegments(db);
          if (from < 4) await _addColumn(db, 'segments', 'lines');
          if (from < 5) {
            await _addColumn(db, 'notes', 'folder_id', type: 'INTEGER');
            await _addColumn(db, 'notes', 'speakers');
            await db.execute(_foldersTable);
          }
          if (from < 6) {
            await _addColumn(db, 'notes', 'tags_edited',
                type: 'INTEGER NOT NULL DEFAULT 0');
            await _addTags(db);
          }
        },
      ),
    );
    return NotesDb._(db);
  }

  /// Adds a column (TEXT unless [type] says otherwise) unless a half-migrated database already has it.
  static Future<void> _addColumn(Database db, String table, String name,
      {String type = 'TEXT'}) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == name)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $name $type');
  }

  /// v6: tag tables, seeded with [starterTags].
  static Future<void> _addTags(Database db) async {
    await db.execute(_tagsTable);
    await db.execute(_noteTagsTable);
    for (final name in starterTags) {
      await db.insert('tags', {'name': name, 'approved': 1},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  /// v3: every existing note becomes a note with one recording, and its
  /// current title/summary/clinical note count as up to date.
  static Future<void> _toSegments(Database db) async {
    await _addColumn(db, 'notes', 'enriched_hash');
    await db.execute(_segmentsTable);
    await db.execute('''
      INSERT INTO segments (note_id, position, audio_path, transcript, english,
                            language_code, status, error, duration_ms)
      SELECT id, 0, audio_path, transcript, english, language_code, status,
             error, duration_ms FROM notes
      WHERE id NOT IN (SELECT note_id FROM segments)''');
    final rows = await db.query('notes',
        columns: ['id', 'transcript', 'english', 'summary', 'clinical']);
    for (final r in rows) {
      final enriched = ((r['summary'] as String?) ?? '').isNotEmpty ||
          ((r['clinical'] as String?) ?? '').isNotEmpty;
      if (!enriched) continue;
      await db.update(
        'notes',
        {
          'enriched_hash': textHash((r['transcript'] as String?) ?? '',
              (r['english'] as String?) ?? '')
        },
        where: 'id = ?',
        whereArgs: [r['id']],
      );
    }
  }

  Future<List<Note>> all() async {
    final rows = await _db.query('notes', orderBy: 'created_at DESC');
    final segs = await _db.query('segments', orderBy: 'note_id, position');
    final byNote = <int, List<Segment>>{};
    for (final s in segs.map(Segment.fromMap)) {
      byNote.putIfAbsent(s.noteId!, () => []).add(s);
    }
    final links = await _db.query('note_tags', orderBy: 'note_id, tag_id');
    final tagsByNote = <int, List<int>>{};
    for (final l in links) {
      tagsByNote.putIfAbsent(l['note_id'] as int, () => []).add(l['tag_id'] as int);
    }
    return rows
        .map((r) => Note.fromMap(r, byNote[r['id'] as int] ?? const [],
            tagsByNote[r['id'] as int] ?? const []))
        .toList();
  }

  /// Inserts [n] and its segments; returns them with ids.
  Future<Note> insert(Note n) {
    return _db.transaction((txn) async {
      final id = await txn.insert('notes', n.toMap());
      final segs = <Segment>[];
      for (final s in n.segments) {
        final withNote = s.copyWith(noteId: id);
        final segId = await txn.insert('segments', withNote.toMap());
        segs.add(withNote.copyWith(id: segId));
      }
      return n.copyWith(id: id).withSegments(segs);
    });
  }

  /// Writes the note row only; segments are saved with [saveSegment].
  Future<void> update(Note n) =>
      _db.update('notes', n.toMap(), where: 'id = ?', whereArgs: [n.id]);

  /// Inserts the segment when it has no id yet; returns it with its id.
  Future<Segment> saveSegment(Segment s) async {
    if (s.id == null) {
      return s.copyWith(id: await _db.insert('segments', s.toMap()));
    }
    await _db.update('segments', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
    return s;
  }

  Future<void> deleteSegment(int id) =>
      _db.delete('segments', where: 'id = ?', whereArgs: [id]);

  Future<void> delete(int id) => _db.transaction((txn) async {
        await txn.delete('segments', where: 'note_id = ?', whereArgs: [id]);
        await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [id]);
        await txn.delete('notes', where: 'id = ?', whereArgs: [id]);
      });

  Future<List<Folder>> folders() async => (await _db.query('folders',
          orderBy: 'name COLLATE NOCASE'))
      .map(Folder.fromMap)
      .toList();

  Future<Folder> insertFolder(String name) async =>
      Folder(id: await _db.insert('folders', {'name': name}), name: name);

  Future<void> renameFolder(int id, String name) =>
      _db.update('folders', {'name': name}, where: 'id = ?', whereArgs: [id]);

  /// Removes the folder; its notes stay, unfiled.
  Future<void> deleteFolder(int id) => _db.transaction((txn) async {
        await txn.update('notes', {'folder_id': null},
            where: 'folder_id = ?', whereArgs: [id]);
        await txn.delete('folders', where: 'id = ?', whereArgs: [id]);
      });

  Future<List<Tag>> tags() async =>
      (await _db.query('tags', orderBy: 'name COLLATE NOCASE'))
          .map(Tag.fromMap)
          .toList();

  Future<Tag> insertTag(String name, {bool approved = true}) async {
    final t = Tag(name: name, approved: approved);
    return Tag(id: await _db.insert('tags', t.toMap()), name: name, approved: approved);
  }

  Future<void> updateTag(Tag t) =>
      _db.update('tags', t.toMap(), where: 'id = ?', whereArgs: [t.id]);

  /// Removes the tag from every note, then the tag itself.
  Future<void> deleteTag(int id) => _db.transaction((txn) async {
        await txn.delete('note_tags', where: 'tag_id = ?', whereArgs: [id]);
        await txn.delete('tags', where: 'id = ?', whereArgs: [id]);
      });

  /// Replaces the note's tags with [tagIds].
  Future<void> setNoteTags(int noteId, Iterable<int> tagIds) =>
      _db.transaction((txn) async {
        await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [noteId]);
        for (final t in tagIds.toSet()) {
          await txn.insert('note_tags', {'note_id': noteId, 'tag_id': t});
        }
      });

  Future<void> close() => _db.close();
}

/// Directory where recordings and imported audio are kept.
Future<Directory> audioDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, 'audio'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
