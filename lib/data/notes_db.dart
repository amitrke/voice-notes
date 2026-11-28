import 'dart:io';
import 'dart:math';

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

/// Notes deleted on this phone, kept so syncing does not bring them back
/// from another phone's backup. [uid] is the note's id across phones.
const _deletedNotesTable = '''
  CREATE TABLE IF NOT EXISTS deleted_notes (
    uid TEXT PRIMARY KEY,
    deleted_at INTEGER NOT NULL
  )''';

final _random = Random.secure();

/// A random id for a note, the same on every phone it is synced to.
String newNoteUid() => List.generate(
    16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

int _now() => DateTime.now().millisecondsSinceEpoch;

/// What [NotesDb.import] did.
class ImportResult {
  /// Notes that were not here and now are.
  final int added;

  /// Notes replaced by a newer copy (sync only).
  final int updated;

  /// Notes removed because another phone deleted them (sync only).
  final int removed;

  /// Recordings of the removed notes, for the caller to delete.
  final List<String> removedAudio;

  const ImportResult(
      {this.added = 0,
      this.updated = 0,
      this.removed = 0,
      this.removedAudio = const []});

  int get changed => added + updated + removed;
}

/// Tags a new install starts with; the user can rename or delete them.
const starterTags = ['Grocery', 'To-do', 'Work', 'Health', 'Ideas'];

class NotesDb {
  final Database _db;

  /// The folder recordings are kept in. Paths inside it are stored relative
  /// to it, because its absolute path is not stable: on iPhone it changes
  /// when the app moves to a new phone and can change on an update. Null
  /// (tests) stores paths as they are.
  final String? audioRoot;
  NotesDb._(this._db, this.audioRoot);

  /// [path] as stored: relative when it is inside [audioRoot].
  String _stored(String path) {
    final root = audioRoot;
    if (root == null || path.isEmpty || !p.isWithin(root, path)) return path;
    return p.relative(path, from: root);
  }

  /// A stored path as the absolute path the rest of the app uses.
  String _resolved(String stored) {
    final root = audioRoot;
    if (root == null || stored.isEmpty || p.isAbsolute(stored)) return stored;
    return p.join(root, stored);
  }

  Map<String, Object?> _out(Map<String, Object?> row) =>
      {...row, 'audio_path': _stored((row['audio_path'] as String?) ?? '')};

  Segment _segment(Map<String, Object?> row) => Segment.fromMap(
      {...row, 'audio_path': _resolved((row['audio_path'] as String?) ?? '')});

  /// Rewrites absolute paths saved by earlier versions as relative ones.
  Future<void> _relativiseAudioPaths() async {
    if (audioRoot == null) return;
    final rows = await _db.query('segments',
        columns: ['id', 'audio_path'], where: "audio_path != ''");
    for (final r in rows) {
      final path = r['audio_path'] as String;
      final stored = _stored(path);
      if (stored == path) continue;
      await _db.update('segments', {'audio_path': stored},
          where: 'id = ?', whereArgs: [r['id']]);
    }
  }

  static const version = 8;

  /// How long a deletion is remembered. A phone that was off for longer than
  /// this may bring a note back; that is accepted.
  static const deletionMemory = Duration(days: 90);

  int get _deletionCutoff =>
      DateTime.now().subtract(deletionMemory).millisecondsSinceEpoch;

  /// Forgets deletions older than [deletionMemory].
  Future<void> _pruneDeletions() => _db.delete('deleted_notes',
      where: 'deleted_at < ?', whereArgs: [_deletionCutoff]);

  /// Opens the database at [path] (default: the app's databases folder).
  /// [factory] lets tests use sqflite_common_ffi. See [audioRoot].
  static Future<NotesDb> open(
      {String? path, DatabaseFactory? factory, String? audioRoot}) async {
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
              tags_edited INTEGER NOT NULL DEFAULT 0,
              outputs TEXT,
              uid TEXT,
              updated_at INTEGER NOT NULL DEFAULT 0
            )''');
          await db.execute(_deletedNotesTable);
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
          if (from < 7) await _addColumn(db, 'notes', 'outputs');
          if (from < 8) await _addSyncColumns(db);
        },
      ),
    );
    final notes = NotesDb._(db, audioRoot);
    await notes._relativiseAudioPaths();
    await notes._pruneDeletions();
    return notes;
  }

  /// Adds a column (TEXT unless [type] says otherwise) unless a half-migrated database already has it.
  static Future<void> _addColumn(Database db, String table, String name,
      {String type = 'TEXT'}) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == name)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $name $type');
  }

  /// v8: every note gets an id that is the same on every phone and a time it
  /// was last changed, and deletions are remembered.
  static Future<void> _addSyncColumns(Database db) async {
    await _addColumn(db, 'notes', 'uid');
    await _addColumn(db, 'notes', 'updated_at',
        type: 'INTEGER NOT NULL DEFAULT 0');
    await db.execute(_deletedNotesTable);
    final rows = await db.query('notes',
        columns: ['id', 'created_at'], where: "uid IS NULL OR uid = ''");
    for (final r in rows) {
      await db.update(
          'notes', {'uid': newNoteUid(), 'updated_at': r['created_at']},
          where: 'id = ?', whereArgs: [r['id']]);
    }
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
    for (final s in segs.map(_segment)) {
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
      final id = await txn.insert('notes',
          {..._out(n.toMap()), 'uid': newNoteUid(), 'updated_at': _now()});
      final segs = <Segment>[];
      for (final s in n.segments) {
        final withNote = s.copyWith(noteId: id);
        final segId = await txn.insert('segments', _out(withNote.toMap()));
        segs.add(withNote.copyWith(id: segId));
      }
      return n.copyWith(id: id).withSegments(segs);
    });
  }

  /// Writes the note row only; segments are saved with [saveSegment].
  Future<void> update(Note n) => _db.update(
      'notes', {..._out(n.toMap()), 'updated_at': _now()},
      where: 'id = ?', whereArgs: [n.id]);

  /// Marks the note as changed now.
  Future<void> _touch(DatabaseExecutor db, int? noteId) async {
    if (noteId == null) return;
    await db.update('notes', {'updated_at': _now()},
        where: 'id = ?', whereArgs: [noteId]);
  }

  /// Inserts the segment when it has no id yet; returns it with its id.
  Future<Segment> saveSegment(Segment s) async {
    await _touch(_db, s.noteId);
    if (s.id == null) {
      return s.copyWith(id: await _db.insert('segments', _out(s.toMap())));
    }
    await _db.update('segments', _out(s.toMap()),
        where: 'id = ?', whereArgs: [s.id]);
    return s;
  }

  Future<void> deleteSegment(int id) async {
    final row = await _db.query('segments',
        columns: ['note_id'], where: 'id = ?', whereArgs: [id]);
    if (row.isNotEmpty) await _touch(_db, row.first['note_id'] as int?);
    await _db.delete('segments', where: 'id = ?', whereArgs: [id]);
  }

  /// Deletes the note and remembers that, so syncing does not bring it back.
  Future<void> delete(int id) => _db.transaction((txn) async {
        final row = await txn.query('notes',
            columns: ['uid'], where: 'id = ?', whereArgs: [id]);
        final uid = row.isEmpty ? null : row.first['uid'] as String?;
        if (uid != null && uid.isNotEmpty) {
          await txn.insert('deleted_notes', {'uid': uid, 'deleted_at': _now()},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
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
        await _touch(txn, noteId);
        await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [noteId]);
        for (final t in tagIds.toSet()) {
          await txn.insert('note_tags', {'note_id': noteId, 'tag_id': t});
        }
      });

  /// Every row of every table, for a backup file. Recordings are left out;
  /// their text is in the rows.
  Future<Map<String, Object?>> export() async => {
        'version': version,
        for (final t in _backedUp) t: await _db.query(t),
      };

  static const _backedUp = [
    'notes',
    'segments',
    'folders',
    'tags',
    'note_tags',
    'deleted_notes',
  ];

  /// Brings the notes in [backup] (from [export], on this phone or another)
  /// into the ones here. Folders and tags are matched by name.
  ///
  /// By default it only adds: a note already here (same id, or same time
  /// and text) is left alone, so restoring twice adds nothing and a restore
  /// can bring back a note that was deleted since.
  ///
  /// With [sync], the newer copy of a note wins, and a note another phone
  /// deleted is deleted here too, unless it was changed here after that.
  ///
  /// Recordings are not in a backup: added notes have text only, and a note
  /// replaced by a newer copy keeps the recordings it had.
  Future<ImportResult> import(Map<String, Object?> backup,
      {bool sync = false}) async {
    final from = backup['version'];
    if (from is! int || from > version) {
      throw const FormatException(
          'This backup was made by a newer version of Voice Notes. Update '
          'the app, then restore it.');
    }
    List<Map<String, Object?>> rows(String t) => [
          for (final r in (backup[t] as List?) ?? const [])
            Map<String, Object?>.from(r as Map),
        ];
    return _db.transaction((txn) async {
      // A backup from an older version may lack newer columns, and never
      // has unknown ones; keep only the columns this table has.
      Future<Map<String, Object?>> fit(
          String table, Map<String, Object?> r) async {
        final cols = {
          for (final c in await txn.rawQuery('PRAGMA table_info($table)'))
            c['name'] as String,
        };
        return {
          for (final e in r.entries)
            if (cols.contains(e.key) && e.key != 'id') e.key: e.value,
        };
      }

      Future<Map<String, Object?>?> one(
          String table, String where, List<Object?> args) async {
        final r =
            await txn.query(table, where: where, whereArgs: args, limit: 1);
        return r.isEmpty ? null : r.first;
      }

      Future<void> forget(int id) async {
        await txn.delete('segments', where: 'note_id = ?', whereArgs: [id]);
        await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [id]);
        await txn.delete('notes', where: 'id = ?', whereArgs: [id]);
      }

      final folders = <int, int>{};
      for (final f in rows('folders')) {
        final name = f['name'] as String;
        final same = await txn.query('folders',
            where: 'name = ? COLLATE NOCASE', whereArgs: [name], limit: 1);
        folders[f['id'] as int] = same.isNotEmpty
            ? same.first['id'] as int
            : await txn.insert('folders', {'name': name});
      }
      final tags = <int, int>{};
      for (final t in rows('tags')) {
        final same = await txn.query('tags',
            where: 'name = ?', whereArgs: [t['name']], limit: 1);
        tags[t['id'] as int] = same.isNotEmpty
            ? same.first['id'] as int
            : await txn.insert('tags', await fit('tags', t));
      }

      // Deletions made on the other phone.
      var removed = 0;
      final removedAudio = <String>[];
      if (sync) {
        for (final d in rows('deleted_notes')) {
          final uid = d['uid'] as String?;
          final at = d['deleted_at'];
          if (uid == null || uid.isEmpty || at is! int) continue;
          if (at < _deletionCutoff) continue;
          final local = await one('notes', 'uid = ?', [uid]);
          if (local != null) {
            // Changed here after it was deleted there: keep it.
            if ((local['updated_at'] as int? ?? 0) > at) continue;
            final id = local['id'] as int;
            for (final s in await txn.query('segments',
                columns: ['audio_path'],
                where: 'note_id = ?',
                whereArgs: [id])) {
              final path = _resolved((s['audio_path'] as String?) ?? '');
              if (path.isNotEmpty) removedAudio.add(path);
            }
            await forget(id);
            removed++;
          }
          final had = await one('deleted_notes', 'uid = ?', [uid]);
          if (had == null || (had['deleted_at'] as int) < at) {
            await txn.insert('deleted_notes', {'uid': uid, 'deleted_at': at},
                conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // Note id in the backup -> note id here, for the notes taken from it.
      final notes = <int, int>{};
      // Recordings of notes being replaced, by segment position.
      final audio = <int, Map<int, String>>{};
      var added = 0;
      var updated = 0;
      for (final n in rows('notes')) {
        final uid = n['uid'] is String && (n['uid'] as String).isNotEmpty
            ? n['uid'] as String
            : null;
        final at = (n['updated_at'] as int?) ?? (n['created_at'] as int? ?? 0);

        var local = uid == null ? null : await one('notes', 'uid = ?', [uid]);
        // Made before notes had ids, or by an older app.
        local ??= await one('notes', 'created_at = ? AND transcript = ?',
            [n['created_at'], n['transcript'] ?? '']);

        if (local != null) {
          if (!sync || at <= (local['updated_at'] as int? ?? 0)) continue;
        } else if (uid != null) {
          final gone = await one('deleted_notes', 'uid = ?', [uid]);
          if (gone != null) {
            // Deleted here: only a newer edit, or a restore, brings it back.
            if (sync && (gone['deleted_at'] as int) >= at) continue;
            await txn
                .delete('deleted_notes', where: 'uid = ?', whereArgs: [uid]);
          }
        }

        final folder = n['folder_id'];
        final row = {
          ...await fit('notes', n),
          'uid': uid ?? local?['uid'] ?? newNoteUid(),
          'updated_at': at,
          'folder_id': folder is int ? folders[folder] : null,
        };
        if (local == null) {
          notes[n['id'] as int] =
              await txn.insert('notes', {...row, 'audio_path': ''});
          added++;
        } else {
          final id = local['id'] as int;
          audio[id] = {
            for (final s in await txn.query('segments',
                columns: ['position', 'audio_path'],
                where: 'note_id = ?',
                whereArgs: [id]))
              s['position'] as int: (s['audio_path'] as String?) ?? '',
          };
          await txn.delete('segments', where: 'note_id = ?', whereArgs: [id]);
          await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [id]);
          await txn.update('notes', row, where: 'id = ?', whereArgs: [id]);
          notes[n['id'] as int] = id;
          updated++;
        }
      }
      for (final s in rows('segments')) {
        final note = notes[s['note_id']];
        if (note == null) continue;
        await txn.insert('segments', {
          ...await fit('segments', s),
          'note_id': note,
          'audio_path': audio[note]?[s['position']] ?? '',
        });
      }
      for (final l in rows('note_tags')) {
        final note = notes[l['note_id']];
        final tag = tags[l['tag_id']];
        if (note == null || tag == null) continue;
        await txn.insert('note_tags', {'note_id': note, 'tag_id': tag},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return ImportResult(
          added: added,
          updated: updated,
          removed: removed,
          removedAudio: removedAudio);
    });
  }

  Future<void> close() => _db.close();
}

/// Directory where recordings and imported audio are kept.
Future<Directory> audioDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, 'audio'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
