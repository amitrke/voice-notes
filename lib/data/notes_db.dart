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
    duration_ms INTEGER
  )''';

class NotesDb {
  final Database _db;
  NotesDb._(this._db);

  static const version = 3;

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
              enriched_hash TEXT
            )''');
          await db.execute(_segmentsTable);
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) await _addColumn(db, 'clinical');
          if (from < 3) await _toSegments(db);
        },
      ),
    );
    return NotesDb._(db);
  }

  /// Adds a TEXT column to notes unless a half-migrated database already has it.
  static Future<void> _addColumn(Database db, String name) async {
    final cols = await db.rawQuery('PRAGMA table_info(notes)');
    if (cols.any((c) => c['name'] == name)) return;
    await db.execute('ALTER TABLE notes ADD COLUMN $name TEXT');
  }

  /// v3: every existing note becomes a note with one recording, and its
  /// current title/summary/clinical note count as up to date.
  static Future<void> _toSegments(Database db) async {
    await _addColumn(db, 'enriched_hash');
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
    return rows
        .map((r) => Note.fromMap(r, byNote[r['id'] as int] ?? const []))
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
        await txn.delete('notes', where: 'id = ?', whereArgs: [id]);
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
