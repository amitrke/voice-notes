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

/// A shared folder (iCloud Drive, say) that several phones write to.
class _Cloud {
  final files = <String, String>{};
  var writes = 0;
}

class _Folder implements BackupFolder {
  final _Cloud cloud;
  final String name;
  final String id;
  _Folder(this.cloud, this.name, this.id);

  @override
  Future<FolderInfo> location() async =>
      const FolderInfo('iCloud Drive › Voice Notes');
  @override
  Future<FolderInfo?> pick() async => const FolderInfo('Chosen', custom: true);
  @override
  Future<FolderInfo> reset() => location();
  @override
  Future<void> write(String name, String text) async {
    cloud.files[name] = text;
    cloud.writes++;
  }

  @override
  Future<List<BackupEntry>> list() async => [
    for (final n in cloud.files.keys) BackupEntry(n, DateTime(2026)),
  ];
  @override
  Future<String> read(String name) async => cloud.files[name]!;
  @override
  Future<({String name, String id})> device() async => (name: name, id: id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory tmp;
  final open = <NotesDb>[];
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('backup_sync_test');
  });
  tearDown(() async {
    for (final db in open) {
      await db.close();
    }
    open.clear();
    await tmp.delete(recursive: true);
  });

  Future<AppState> phone(String name) async {
    final s = SettingsStore();
    await s.load();
    final db = await NotesDb.open(
      path: p.join(tmp.path, '$name.db'),
      factory: databaseFactoryFfi,
    );
    open.add(db);
    final state = AppState(s, db);
    await state.init();
    return state;
  }

  Future<void> addNote(AppState state, String text, DateTime at) async {
    await state.db.insert(
      Note(
        title: text,
        transcript: text,
        provider: 'gemini',
        createdAt: at,
        status: NoteStatus.done,
      ),
    );
    await state.init();
    state.refresh();
  }

  test('each phone writes its own file, only when something changed', () async {
    final cloud = _Cloud();
    final state = await phone('a');
    final sync = BackupSync(
      state,
      _Folder(cloud, 'Amit’s iPhone', 'ABCDEF12-3456'),
      delay: const Duration(hours: 1),
    );
    await sync.start();

    // Nothing to keep yet, so a new phone leaves the folder alone.
    expect(await sync.syncNow(), isFalse);
    expect(cloud.files, isEmpty);

    await addNote(state, 'buy milk', DateTime(2026, 11, 1));
    expect(await sync.syncNow(), isTrue);
    expect(sync.fileName, 'voice-notes-amit-s-iphone-ABCDEF12.json');
    expect(cloud.files.keys, [sync.fileName]);
    expect(sync.lastSaved, isNotNull);

    expect(await sync.syncNow(), isFalse, reason: 'nothing changed');
    expect(cloud.writes, 1);

    await addNote(state, 'call mum', DateTime(2026, 11, 2));
    expect(await sync.syncNow(), isTrue);
    final b = jsonDecode(cloud.files[sync.fileName]!) as Map;
    expect(b['device'], 'Amit’s iPhone');
    expect((b['notes'] as Map)['notes'], hasLength(2));
    sync.dispose();
  });

  test('a new phone finds the other phone\'s backup and restores it', () async {
    final cloud = _Cloud();
    final old = await phone('old');
    final oldSync = BackupSync(old, _Folder(cloud, 'Pixel 8', 'aaaa1111'));
    await oldSync.start();
    await addNote(old, 'wash the dal', DateTime(2026, 10, 1));
    await oldSync.syncNow();
    cloud.files['notes.json'] = '{"something": "else"}';
    cloud.files['broken.json'] = '{not json';
    cloud.files['photo.jpg'] = 'xx';

    final fresh = await phone('new');
    final newSync = BackupSync(fresh, _Folder(cloud, 'iPhone', 'bbbb2222'));
    await newSync.start();
    await newSync.syncNow();
    expect(
      cloud.files.keys.where((k) => k.contains('iphone')),
      isEmpty,
      reason: 'an empty phone must not add a backup',
    );

    final found = await newSync.backups();
    expect(found, hasLength(1));
    expect(found.single.device, 'Pixel 8');
    expect(found.single.notes, 1);
    expect(found.single.mine, isFalse);

    expect((await fresh.restore(found.single.data)).added, 1);
    expect(fresh.allNotes.single.transcript, 'wash the dal');

    // Now it has notes, the new phone writes its own file beside the old one.
    await newSync.syncNow();
    final all = await newSync.backups();
    expect(all, hasLength(2));
    expect(all.where((b) => b.mine).single.device, 'iPhone');
    oldSync.dispose();
    newSync.dispose();
  });

  test('changes are backed up after a pause, unless backup is off', () async {
    final cloud = _Cloud();
    final state = await phone('a');
    final sync = BackupSync(
      state,
      _Folder(cloud, 'Phone', '1'),
      delay: const Duration(milliseconds: 20),
    );
    await sync.start();
    await addNote(state, 'one', DateTime(2026, 11, 1));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cloud.writes, 1);

    await sync.setAuto(false);
    expect(state.settings.autoBackup, isFalse);
    await addNote(state, 'two', DateTime(2026, 11, 2));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cloud.writes, 1);

    await sync.setAuto(true);
    expect(cloud.writes, 2, reason: 'turning it on backs up straight away');
    sync.dispose();
  });
}
