import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/note.dart';

class NotesDb {
  final Database _db;
  NotesDb._(this._db);

  static Future<NotesDb> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'voice_notes.db'),
      version: 2,
      onCreate: (db, _) => db.execute('''
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
        )'''),
      onUpgrade: (db, from, _) async {
        if (from < 2) await db.execute('ALTER TABLE notes ADD COLUMN clinical TEXT');
      },
    );
    return NotesDb._(db);
  }

  Future<List<Note>> all() async {
    final rows = await _db.query('notes', orderBy: 'created_at DESC');
    return rows.map(Note.fromMap).toList();
  }

  Future<Note> insert(Note n) async {
    final id = await _db.insert('notes', n.toMap());
    return n.copyWith(id: id);
  }

  Future<void> update(Note n) =>
      _db.update('notes', n.toMap(), where: 'id = ?', whereArgs: [n.id]);

  Future<void> delete(int id) =>
      _db.delete('notes', where: 'id = ?', whereArgs: [id]);
}

/// Directory where recordings and imported audio are kept.
Future<Directory> audioDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, 'audio'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
