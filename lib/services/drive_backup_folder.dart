import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_folder.dart';
import 'google_config.dart';

/// Lets the app see and change only the files it created in the user's
/// Drive. They stay visible to the user, in a "Voice Notes" folder, and the
/// scope needs no Google security review.
const driveFileScope = 'https://www.googleapis.com/auth/drive.file';

/// No Google account is signed in, or its permission ran out and asking
/// again needs the user.
class DriveSignedOut implements Exception {
  const DriveSignedOut();
  @override
  String toString() => 'Signed out of Google Drive. Choose Google Drive '
      'again in "Backup folder" to sign in.';
}

/// Google sign-in or Drive failed while setting up. The message is for the
/// user; the detail goes to the debug log.
class DriveUnreachable implements Exception {
  final String message;
  const DriveUnreachable([
    this.message = 'Could not reach Google Drive. Try again.',
  ]);
  @override
  String toString() => message;
}

/// Signing in to Google and getting a token for [driveFileScope].
abstract class DriveAuth {
  /// Whether this build has the Google client IDs it needs.
  bool get available;

  /// The account already signed in, found without asking the user.
  /// Null when there is none.
  Future<String?> restore();

  /// Asks the user to sign in and allow Drive access. Returns the account's
  /// email, or null if they cancel.
  Future<String?> signIn();

  Future<void> signOut();

  /// A current access token, without asking the user. Throws
  /// [DriveSignedOut] when there is none.
  Future<String> token();

  /// Drops a token that Drive refused, so [token] fetches a new one.
  Future<void> discard(String token);
}

/// [DriveAuth] using the google_sign_in plugin.
class GoogleDriveAuth implements DriveAuth {
  final String webClientId;
  final String iosClientId;

  GoogleDriveAuth({
    this.webClientId = GoogleConfig.webClientId,
    this.iosClientId = GoogleConfig.iosClientId,
  });

  GoogleSignIn get _g => GoogleSignIn.instance;
  Future<void>? _init;
  GoogleSignInAccount? _account;

  /// The one quiet sign-in attempt of this run of the app. Its result,
  /// signed out included, stands until the user signs in or out: asking the
  /// platform again on every backup could show Android's sign-in sheet
  /// over and over.
  Future<void>? _restored;

  @override
  bool get available =>
      webClientId.isNotEmpty && (!Platform.isIOS || iosClientId.isNotEmpty);

  Future<void> _ready() {
    if (!available) throw StateError('Google Drive is not set up in this build.');
    return _init ??= _g.initialize(
      clientId: Platform.isIOS ? iosClientId : null,
      serverClientId: webClientId,
    );
  }

  @override
  Future<String?> restore() async {
    await _ready();
    await (_restored ??= () async {
      try {
        _account = await _g.attemptLightweightAuthentication();
      } catch (_) {
        _account = null;
      }
    }());
    return _account?.email;
  }

  @override
  Future<String?> signIn() async {
    await _ready();
    try {
      final account = await _g.authenticate(scopeHint: const [driveFileScope]);
      await account.authorizationClient.authorizeScopes(const [driveFileScope]);
      _account = account;
      _restored = Future.value();
      return account.email;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    await _ready();
    _account = null;
    _restored = Future.value();
    await _g.signOut();
  }

  @override
  Future<String> token() async {
    if (await restore() == null) throw const DriveSignedOut();
    final auth = await _account!.authorizationClient.authorizationForScopes(
      const [driveFileScope],
    );
    if (auth == null) {
      // Access was removed: signed out until the user signs in again.
      _account = null;
      throw const DriveSignedOut();
    }
    return auth.accessToken;
  }

  @override
  Future<void> discard(String token) =>
      _g.authorizationClient.clearAuthorizationToken(accessToken: token);
}

/// A file in Drive.
class DriveFile {
  final String id;
  final String name;
  final DateTime modified;
  const DriveFile(this.id, this.name, this.modified);
}

/// The few Drive calls backups need. Split out so tests can fake Drive.
abstract class DriveFiles {
  /// The app's backup folders, oldest first, whatever the user renamed them
  /// to or moved them into. Usually one; two phones setting up at the same
  /// moment can make two.
  Future<List<String>> folders();

  /// Makes a backup folder called [name] in My Drive, marked so [folders]
  /// finds it.
  Future<String> createFolder(String name);
  Future<List<DriveFile>> list(String folderId);
  /// Returns the new file's id.
  Future<String> create(String folderId, String name, String text);
  Future<void> update(String fileId, String text);
  Future<String> download(String fileId);
}

/// [DriveFiles] over the Drive v3 REST API.
class GoogleDriveFiles implements DriveFiles {
  final DriveAuth auth;
  final http.Client Function() _client;

  GoogleDriveFiles(this.auth, {http.Client Function()? client})
    : _client = client ?? http.Client.new;

  static const _folderType = 'application/vnd.google-apps.folder';
  static const _json = 'application/json';

  /// Runs [call] with a signed-in Drive client, once more with a new token
  /// if Drive says the first one expired.
  Future<T> _drive<T>(Future<T> Function(drive.DriveApi api) call) async {
    for (var attempt = 0; ; attempt++) {
      final token = await auth.token();
      final client = _Bearer(token, _client());
      try {
        return await call(drive.DriveApi(client));
      } on drive.DetailedApiRequestError catch (e) {
        if (e.status != 401 || attempt > 0) rethrow;
        await auth.discard(token);
      } finally {
        client.close();
      }
    }
  }

  static String _quote(String s) =>
      "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  /// Marks the app's backup folder, so it is found after a rename or move.
  static const _marker = {'voiceNotesBackups': '1'};

  @override
  Future<List<String>> folders() => _drive((api) async {
    final r = await api.files.list(
      q: "mimeType = '$_folderType' and trashed = false and appProperties "
          "has { key = 'voiceNotesBackups' and value = '1' }",
      orderBy: 'createdTime',
      spaces: 'drive',
      $fields: 'files(id)',
    );
    return [for (final f in r.files ?? const <drive.File>[]) f.id!];
  });

  @override
  Future<String> createFolder(String name) => _drive((api) async {
    final f = await api.files.create(
      drive.File(name: name, mimeType: _folderType, appProperties: _marker),
      $fields: 'id',
    );
    return f.id!;
  });

  @override
  Future<List<DriveFile>> list(String folderId) => _drive((api) async {
    final out = <DriveFile>[];
    String? page;
    do {
      final r = await api.files.list(
        q: '${_quote(folderId)} in parents and trashed = false '
            "and mimeType != '$_folderType'",
        spaces: 'drive',
        pageSize: 100,
        pageToken: page,
        $fields: 'nextPageToken, files(id, name, modifiedTime)',
      );
      for (final f in r.files ?? const <drive.File>[]) {
        out.add(DriveFile(
          f.id!,
          f.name ?? '',
          f.modifiedTime?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
        ));
      }
      page = r.nextPageToken;
    } while (page != null);
    return out;
  });

  drive.Media _media(String text) {
    final bytes = utf8.encode(text);
    return drive.Media(Stream.value(bytes), bytes.length, contentType: _json);
  }

  @override
  Future<String> create(String folderId, String name, String text) =>
      _drive((api) async {
        final f = await api.files.create(
          drive.File(name: name, parents: [folderId], mimeType: _json),
          uploadMedia: _media(text),
          $fields: 'id',
        );
        return f.id!;
      });

  @override
  Future<void> update(String fileId, String text) => _drive(
    (api) => api.files.update(drive.File(), fileId,
        uploadMedia: _media(text), $fields: 'id'),
  );

  @override
  Future<String> download(String fileId) => _drive((api) async {
    final m = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    return utf8.decode(await m.stream.expand((b) => b).toList());
  });
}

class _Bearer extends http.BaseClient {
  final String token;
  final http.Client inner;
  _Bearer(this.token, this.inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $token';
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

/// Backups in a "Voice Notes" folder in the user's Google Drive, which the
/// app creates. Android and iPhone signed in to the same Google account
/// share it.
class DriveBackupFolder implements BackupFolder {
  final DriveAuth auth;
  final DriveFiles files;
  /// This phone's name and id, from the folder on the phone.
  final Future<({String name, String id})> Function() phone;

  DriveBackupFolder(this.auth, this.files, {required this.phone});

  static const folderName = 'Voice Notes';

  /// File ids by name, from the last [list].
  final _ids = <String, String>{};

  FolderInfo _info(String? email) => email == null
      ? const FolderInfo('Google Drive (signed out)',
          custom: true, syncs: false, account: '')
      : FolderInfo('Google Drive › $folderName',
          custom: true, account: email);

  @override
  Future<FolderInfo> location() async {
    String? email;
    try {
      email = await auth.restore();
    } catch (_) {
      email = null;
    }
    return _info(email);
  }

  /// Signs in and finds or makes the backup folder. Null when the user
  /// cancels. If Drive cannot be reached, signs out again, so nothing is
  /// left half set up.
  @override
  Future<FolderInfo?> pick() async {
    final String? email;
    try {
      email = await auth.signIn();
    } catch (e) {
      debugPrint('Google sign-in failed: $e');
      throw const DriveUnreachable('Could not sign in to Google. Try again.');
    }
    if (email == null) return null;
    _ids.clear();
    try {
      await _folders();
    } catch (e) {
      debugPrint('Google Drive unreachable: $e');
      try {
        await auth.signOut();
      } catch (_) {}
      throw const DriveUnreachable();
    }
    return _info(email);
  }

  /// Signs out of Google.
  @override
  Future<FolderInfo> reset() async {
    _ids.clear();
    await auth.signOut();
    return _info(null);
  }

  /// The backup folders, oldest first; makes one if there is none. Asked of
  /// Drive each time, so a folder the user trashed is not written into.
  Future<List<String>> _folders() async {
    if (await auth.restore() == null) throw const DriveSignedOut();
    final found = await files.folders();
    return found.isNotEmpty ? found : [await files.createFolder(folderName)];
  }

  @override
  Future<void> write(String name, String text) async {
    // Looked up afresh each time: Drive lets the app update a file the user
    // trashed, and the backup would then go to the trash with it.
    final folders = await _folders();
    await _list(folders);
    final id = _ids[name];
    if (id == null) {
      _ids[name] = await files.create(folders.first, name, text);
      return;
    }
    try {
      await files.update(id, text);
    } on drive.DetailedApiRequestError catch (e) {
      // Deleted in Drive since: make it again.
      if (e.status != 404) rethrow;
      _ids[name] = await files.create(folders.first, name, text);
    }
  }

  /// Every backup in every backup folder. Where two folders hold a file of
  /// the same name, the newer one counts.
  Future<List<DriveFile>> _list(List<String> folders) async {
    final byName = <String, DriveFile>{};
    for (final folder in folders) {
      for (final f in await files.list(folder)) {
        final had = byName[f.name];
        if (had == null || f.modified.isAfter(had.modified)) byName[f.name] = f;
      }
    }
    _ids
      ..clear()
      ..addEntries([for (final f in byName.values) MapEntry(f.name, f.id)]);
    return byName.values.toList();
  }

  @override
  Future<List<BackupEntry>> list() async => [
    for (final f in await _list(await _folders()))
      BackupEntry(f.name, f.modified),
  ];

  @override
  Future<String> read(String name) async {
    var id = _ids[name];
    if (id == null) {
      await list();
      id = _ids[name];
    }
    if (id == null) throw StateError('$name is no longer in Google Drive.');
    return files.download(id);
  }

  @override
  Future<({String name, String id})> device() => phone();
}

/// The backup destination the user chose: a folder ([folder], the default)
/// or Google Drive ([drive]). Remembers the choice.
class BackupDestinations implements BackupFolder {
  final BackupFolder folder;
  final DriveBackupFolder drive;

  BackupDestinations(this.folder, this.drive);

  static const _key = 'backupDestination';

  bool? _onDrive;

  Future<bool> get _isDrive async =>
      _onDrive ??= (await SharedPreferences.getInstance()).getString(_key) ==
          'drive';

  Future<void> _set(bool drive) async {
    _onDrive = drive;
    await (await SharedPreferences.getInstance())
        .setString(_key, drive ? 'drive' : 'device');
  }

  Future<BackupFolder> get _current async =>
      await _isDrive ? drive : folder;

  /// Whether this build can sign in to Google.
  bool get driveAvailable => drive.auth.available;

  /// Signs in to Google Drive and backs up there from now on. Null when
  /// the user cancels.
  Future<FolderInfo?> useDrive() async {
    final info = await drive.pick();
    if (info != null) await _set(true);
    return info;
  }

  /// Signs out of Google Drive and goes back to the default folder.
  Future<FolderInfo> signOutDrive() async {
    await drive.reset();
    await _set(false);
    return folder.location();
  }

  @override
  Future<FolderInfo> location() async => (await _current).location();

  /// Leaves Google Drive, signing out so the app does not stay signed in
  /// to an account it no longer uses.
  Future<void> _leaveDrive() async {
    if (await _isDrive) {
      try {
        await drive.reset();
      } catch (e) {
        debugPrint('Google sign-out failed: $e');
      }
    }
    await _set(false);
  }

  /// Picks a folder on the phone (leaving Google Drive, if it was in use).
  @override
  Future<FolderInfo?> pick() async {
    final info = await folder.pick();
    if (info != null) await _leaveDrive();
    return info;
  }

  @override
  Future<FolderInfo> reset() async {
    await _leaveDrive();
    return folder.reset();
  }

  @override
  Future<void> write(String name, String text) async =>
      (await _current).write(name, text);

  @override
  Future<List<BackupEntry>> list() async => (await _current).list();

  @override
  Future<String> read(String name) async => (await _current).read(name);

  @override
  Future<({String name, String id})> device() => folder.device();
}
