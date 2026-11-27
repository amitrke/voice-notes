import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/backup_sync.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/services/backup_folder.dart';
import 'package:voice_notes/services/drive_backup_folder.dart';

/// One Google account's Drive, as the app sees it with drive.file.
class _FakeDrive implements DriveFiles {
  final folderIds = <String>[];
  final names = <String, String>{}; // file id -> name
  final parents = <String, String>{}; // file id -> folder id
  final content = <String, String>{}; // file id -> text
  var _next = 0;
  var creates = 0;
  var updates = 0;

  String _id() => 'id${_next++}';

  @override
  Future<List<String>> folders(String name) async =>
      [for (final id in folderIds) if (names[id] == name) id];

  @override
  Future<String> createFolder(String name) async {
    final id = _id();
    folderIds.add(id);
    names[id] = name;
    return id;
  }

  @override
  Future<List<DriveFile>> list(String folderId) async => [
    for (final e in parents.entries)
      if (e.value == folderId) DriveFile(e.key, names[e.key]!, DateTime(2026)),
  ];

  @override
  Future<String> create(String folderId, String name, String text) async {
    final id = _id();
    names[id] = name;
    parents[id] = folderId;
    content[id] = text;
    creates++;
    return id;
  }

  @override
  Future<void> update(String fileId, String text) async {
    if (!content.containsKey(fileId)) {
      throw drive.DetailedApiRequestError(404, 'File not found');
    }
    content[fileId] = text;
    updates++;
  }

  @override
  Future<String> download(String fileId) async => content[fileId]!;

  /// The user deletes a file in the Drive app.
  void delete(String fileId) {
    names.remove(fileId);
    parents.remove(fileId);
    content.remove(fileId);
  }

  Map<String, String> filesIn(String folderId) => {
    for (final e in parents.entries)
      if (e.value == folderId) names[e.key]!: content[e.key]!,
  };
}

class _FakeAuth implements DriveAuth {
  String? account;
  String? willSignInAs;
  var tokens = 0;
  final discarded = <String>[];
  _FakeAuth({this.account, this.willSignInAs});

  @override
  bool available = true;
  @override
  Future<String?> restore() async => account;
  @override
  Future<String?> signIn() async => account = willSignInAs;
  @override
  Future<void> signOut() async => account = null;
  @override
  Future<String> token() async {
    if (account == null) throw const DriveSignedOut();
    return 'token${tokens++}';
  }

  @override
  Future<void> discard(String token) async => discarded.add(token);
}

/// The folder on the phone (iCloud Drive or Documents).
class _PhoneFolder implements BackupFolder {
  final String name;
  final files = <String, String>{};
  _PhoneFolder(this.name);

  @override
  Future<FolderInfo> location() async =>
      const FolderInfo('Documents › Voice Notes');
  @override
  Future<FolderInfo?> pick() async => const FolderInfo('Chosen', custom: true);
  @override
  Future<FolderInfo> reset() => location();
  @override
  Future<void> write(String name, String text) async => files[name] = text;
  @override
  Future<List<BackupEntry>> list() async => [
    for (final n in files.keys) BackupEntry(n, DateTime(2026)),
  ];
  @override
  Future<String> read(String name) async => files[name]!;
  @override
  Future<({String name, String id})> device() async =>
      (name: name, id: '${name.hashCode.abs()}0000');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory tmp;
  final open = <NotesDb>[];
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('drive_backup_test');
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

  BackupDestinations destinations(_PhoneFolder local, DriveAuth auth,
          _FakeDrive drive) =>
      BackupDestinations(
        local,
        DriveBackupFolder(auth, drive, phone: local.device),
      );

  group('DriveBackupFolder', () {
    test('makes one Voice Notes folder and keeps one file per name', () async {
      final drive = _FakeDrive();
      final auth = _FakeAuth(willSignInAs: 'me@example.com');
      final folder = DriveBackupFolder(auth, drive,
          phone: () async => (name: 'Pixel', id: '1'));

      expect((await folder.location()).account, isEmpty,
          reason: 'not signed in yet');
      final info = await folder.pick();
      expect(info!.label, 'Google Drive › Voice Notes');
      expect(info.account, 'me@example.com');
      expect(info.onDrive, isTrue);
      expect(drive.folderIds, hasLength(1));

      await folder.write('a.json', 'one');
      await folder.write('a.json', 'two');
      await folder.write('b.json', 'three');
      expect(drive.creates, 2);
      expect(drive.updates, 1);
      expect(drive.filesIn(drive.folderIds.single),
          {'a.json': 'two', 'b.json': 'three'});
      expect((await folder.list()).map((e) => e.name),
          unorderedEquals(['a.json', 'b.json']));
      expect(await folder.read('a.json'), 'two');
    });

    test('reuses the folder another phone made', () async {
      final drive = _FakeDrive();
      final existing = await drive.createFolder('Voice Notes');
      await drive.create(existing, 'old.json', 'x');
      final folder = DriveBackupFolder(
          _FakeAuth(willSignInAs: 'me@example.com'), drive,
          phone: () async => (name: 'iPhone', id: '2'));
      await folder.pick();
      expect(drive.folderIds, [existing]);
      expect(await folder.read('old.json'), 'x');
    });

    test('makes a file again if it was deleted in Drive', () async {
      final drive = _FakeDrive();
      final folder = DriveBackupFolder(
          _FakeAuth(willSignInAs: 'me@example.com'), drive,
          phone: () async => (name: 'Pixel', id: '1'));
      await folder.pick();
      await folder.write('a.json', 'one');
      drive.delete(drive.parents.keys.single);
      await folder.write('a.json', 'two');
      expect(drive.filesIn(drive.folderIds.single), {'a.json': 'two'});
    });

    test('cancelling sign-in changes nothing', () async {
      final drive = _FakeDrive();
      final folder = DriveBackupFolder(_FakeAuth(), drive,
          phone: () async => (name: 'Pixel', id: '1'));
      expect(await folder.pick(), isNull);
      expect(drive.folderIds, isEmpty);
    });

    test('writing while signed out says so', () async {
      final folder = DriveBackupFolder(_FakeAuth(), _FakeDrive(),
          phone: () async => (name: 'Pixel', id: '1'));
      expect(() => folder.write('a.json', 'x'),
          throwsA(isA<DriveSignedOut>()));
    });
  });

  group('BackupDestinations', () {
    test('remembers Google Drive, and signing out goes back to the folder',
        () async {
      final local = _PhoneFolder('Pixel');
      final auth = _FakeAuth(willSignInAs: 'me@example.com');
      final drive = _FakeDrive();
      final d = destinations(local, auth, drive);
      expect((await d.location()).onDrive, isFalse);
      expect(d.driveAvailable, isTrue);

      expect((await d.useDrive())!.account, 'me@example.com');
      await d.write('x.json', '{}');
      expect(local.files, isEmpty);
      expect(drive.content.values, ['{}']);

      // The app starts again.
      final again = destinations(local, auth, drive);
      expect((await again.location()).account, 'me@example.com');

      final back = await again.signOutDrive();
      expect(back.onDrive, isFalse);
      expect(auth.account, isNull);
      await again.write('x.json', 'local');
      expect(local.files, {'x.json': 'local'});
      expect((await destinations(local, auth, drive).location()).onDrive,
          isFalse);
    });

    test('choosing a folder on the phone leaves Drive', () async {
      final local = _PhoneFolder('Pixel');
      final d = destinations(
          local, _FakeAuth(willSignInAs: 'me@example.com'), _FakeDrive());
      await d.useDrive();
      await d.pick();
      expect((await d.location()).onDrive, isFalse);
    });

    test('is unavailable without the Google client IDs', () {
      final auth = _FakeAuth()..available = false;
      expect(
          destinations(_PhoneFolder('P'), auth, _FakeDrive()).driveAvailable,
          isFalse);
    });
  });

  test('an Android phone and an iPhone share backups through Drive', () async {
    final drive = _FakeDrive(); // the same Google account on both
    final android = await phone('android');
    final aSync = BackupSync(
      android,
      destinations(_PhoneFolder('Pixel 8'),
          _FakeAuth(willSignInAs: 'me@example.com'), drive),
      delay: const Duration(hours: 1),
    );
    await aSync.start();
    expect(aSync.driveAvailable, isTrue);
    await addNote(android, 'wash the dal', DateTime(2026, 10, 1));
    expect(await aSync.useDrive(), isTrue);
    expect(aSync.info!.onDrive, isTrue);
    expect(drive.content, hasLength(1), reason: 'moving backs up at once');

    final iphone = await phone('iphone');
    final iSync = BackupSync(
      iphone,
      destinations(_PhoneFolder('iPhone'),
          _FakeAuth(willSignInAs: 'me@example.com'), drive),
      delay: const Duration(hours: 1),
    );
    await iSync.start();
    await iSync.useDrive();
    expect(drive.content, hasLength(1),
        reason: 'an empty phone must not add a backup');

    final found = await iSync.backups();
    expect(found.single.device, 'Pixel 8');
    expect(await iphone.restore(found.single.data), 1);
    await iSync.syncNow();
    expect(await iSync.backups(), hasLength(2));

    await iSync.signOutDrive();
    expect(iSync.info!.onDrive, isFalse);
    aSync.dispose();
    iSync.dispose();
  });

  group('GoogleDriveFiles', () {
    test('sends the token, and retries once with a new one on 401', () async {
      final auth = _FakeAuth(account: 'me@example.com');
      final seen = <String>[];
      final files = GoogleDriveFiles(auth, client: () => MockClient((req) async {
        seen.add(req.headers['Authorization']!);
        if (seen.length == 1) return http.Response('{}', 401);
        return http.Response(
          jsonEncode({
            'files': [
              {'id': 'f1', 'name': 'a.json', 'modifiedTime': '2026-11-01T10:00:00Z'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }));
      final list = await files.list('folder1');
      expect(list.single.name, 'a.json');
      expect(seen, ['Bearer token0', 'Bearer token1']);
      expect(auth.discarded, ['token0']);
    });

    test('lists only the folder\'s files, quoting the id', () async {
      late Uri asked;
      final files = GoogleDriveFiles(_FakeAuth(account: 'me@example.com'),
          client: () => MockClient((req) async {
                asked = req.url;
                return http.Response('{"files": []}', 200,
                    headers: {'content-type': 'application/json'});
              }));
      await files.list("it's");
      expect(asked.queryParameters['q'],
          startsWith(r"'it\'s' in parents and trashed = false"));
    });

    test('uploads into the folder', () async {
      late http.Request sent;
      final files = GoogleDriveFiles(_FakeAuth(account: 'me@example.com'),
          client: () => MockClient((req) async {
                sent = req;
                return http.Response('{"id": "new1"}', 200,
                    headers: {'content-type': 'application/json'});
              }));
      expect(await files.create('folder1', 'a.json', '{"x":1}'), 'new1');
      expect(sent.url.path, '/upload/drive/v3/files');
      expect(sent.body, contains('"parents":["folder1"]'));
      expect(sent.body, contains(base64.encode(utf8.encode('{"x":1}'))));
    });

    test('signed out: no request is made', () async {
      var calls = 0;
      final files = GoogleDriveFiles(_FakeAuth(),
          client: () => MockClient((req) async {
                calls++;
                return http.Response('{}', 200);
              }));
      await expectLater(files.list('f'), throwsA(isA<DriveSignedOut>()));
      expect(calls, 0);
    });
  });
}
