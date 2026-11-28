import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

import '../services/backup_folder.dart';
import '../services/drive_backup_folder.dart';
import 'app_state.dart';

/// A backup file in the backup folder, read and checked.
class FoundBackup {
  final String file;

  /// The phone that wrote it.
  final String device;
  final DateTime made;
  final int notes;

  /// Written by this phone.
  final bool mine;
  final Map<String, Object?> data;

  const FoundBackup({
    required this.file,
    required this.device,
    required this.made,
    required this.notes,
    required this.mine,
    required this.data,
  });
}

/// Keeps this phone's backup file in the backup folder up to date, a short
/// while after notes change and when the app goes to the background.
///
/// Each phone writes its own file, named after the phone, so two phones
/// sharing a folder never overwrite each other, and a new phone with no
/// notes yet cannot replace the backup it is about to restore from.
class BackupSync extends ChangeNotifier with WidgetsBindingObserver {
  final AppState state;
  final BackupFolder folder;

  /// How long after the last change to wait before writing.
  final Duration delay;

  BackupSync(
    this.state,
    this.folder, {
    this.delay = const Duration(seconds: 15),
  });

  FolderInfo? info;
  DateTime? lastSaved;
  String? error;
  ({String name, String id})? _device;
  String? _lastHash;
  Timer? _timer;
  Future<bool>? _running;
  bool _started = false;

  /// Name of this phone's file in the folder.
  String get fileName {
    final d = _device;
    if (d == null) return 'voice-notes-backup.json';
    final slug = d.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final id = d.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return 'voice-notes-${slug.isEmpty ? 'phone' : slug}-'
        '${id.length > 8 ? id.substring(0, 8) : id}.json';
  }

  Future<void> start() async {
    try {
      info = await folder.location();
      _device = await folder.device();
    } catch (e) {
      error = 'Backup folder unavailable: $e';
    }
    if (_started) return;
    _started = true;
    state.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _changed();
    notifyListeners();
    if (state.settings.autoImport) unawaited(importOthers());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_started) {
      state.removeListener(_changed);
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && this.state.settings.autoImport) {
      unawaited(importOthers());
    }
    if (state == AppLifecycleState.paused && _timer != null) {
      _timer!.cancel();
      _timer = null;
      unawaited(syncNow());
    }
  }

  void _changed() {
    if (!state.settings.autoBackup) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(syncNow());
    });
  }

  /// Writes this phone's backup if anything changed since the last one.
  /// [force] writes it even when nothing did. Returns whether it wrote.
  Future<bool> syncNow({bool force = false}) async {
    // One write at a time; a change during one is picked up by the next.
    while (_running != null) {
      await _running;
    }
    final run = _sync(force);
    _running = run;
    try {
      return await run;
    } finally {
      _running = null;
    }
  }

  Future<bool> _sync(bool force) async {
    try {
      final b = await state.backup();
      // Nothing worth keeping yet (a new phone): leave the folder alone.
      if (!force && state.allNotes.isEmpty) return false;
      b['device'] = _device?.name ?? 'Phone';
      final content = Map.of(b)..remove('made');
      final hash = sha1.convert(utf8.encode(jsonEncode(content))).toString();
      if (!force && hash == _lastHash) return false;
      await folder.write(fileName, jsonEncode(b));
      _lastHash = hash;
      lastSaved = DateTime.now();
      error = null;
      notifyListeners();
      return true;
    } catch (e) {
      error = 'Could not back up: $e';
      notifyListeners();
      return false;
    }
  }

  /// Backup files already brought in, by name, and when they were saved.
  /// A file saved again is read again.
  final _imported = <String, DateTime>{};
  Future<int>? _importing;

  /// When notes from other phones were last brought in.
  DateTime? lastImported;

  /// Brings in what the other phones' backup files hold: notes this phone
  /// lacks, newer copies of notes, and notes deleted there. Skips this
  /// phone's own file. Returns how many notes changed.
  Future<int> importOthers() => _importing ??= _importOthers().whenComplete(
        () => _importing = null,
      );

  Future<int> _importOthers() async {
    var changed = 0;
    try {
      for (final e in await folder.list()) {
        if (!e.name.toLowerCase().endsWith('.json') || e.name == fileName) {
          continue;
        }
        if (_imported[e.name] == e.modified) continue;
        try {
          final data = jsonDecode(await folder.read(e.name));
          if (data is! Map || data['format'] != backupFormat) continue;
          final r = await state.restore(
            Map<String, Object?>.from(data),
            sync: true,
          );
          changed += r.changed;
          _imported[e.name] = e.modified;
        } catch (err) {
          debugPrint('Could not import ${e.name}: $err');
        }
      }
      lastImported = DateTime.now();
      notifyListeners();
    } catch (e) {
      debugPrint('Could not look for other phones\' notes: $e');
    }
    return changed;
  }

  /// Lets the user choose another folder, then writes a backup there.
  Future<bool> pickFolder() async {
    final picked = await folder.pick();
    if (picked == null) return false;
    await _moved(picked);
    return true;
  }

  Future<void> useDefaultFolder() async => _moved(await folder.reset());

  BackupDestinations? get _destinations {
    final f = folder;
    return f is BackupDestinations ? f : null;
  }

  /// Whether Google Drive can be chosen in this build.
  bool get driveAvailable => _destinations?.driveAvailable ?? false;

  /// Signs in to Google Drive and backs up there from now on. False when
  /// the user cancels.
  Future<bool> useDrive() async {
    final d = _destinations;
    if (d == null) return false;
    final to = await d.useDrive();
    if (to == null) return false;
    error = null;
    await _moved(to);
    return true;
  }

  /// Signs out of Google Drive and goes back to the folder on the phone.
  Future<void> signOutDrive() async {
    final d = _destinations;
    if (d == null) return;
    error = null;
    await _moved(await d.signOutDrive());
  }

  Future<void> _moved(FolderInfo to) async {
    info = to;
    _imported.clear();
    if (state.settings.autoImport) unawaited(importOthers());
    _lastHash = null;
    lastSaved = null;
    notifyListeners();
    if (state.settings.autoBackup) await syncNow();
  }

  Future<void> setAutoImport(bool on) async {
    await state.settings.setAutoImport(on);
    if (on) await importOthers();
    notifyListeners();
  }

  Future<void> setAuto(bool on) async {
    await state.settings.setAutoBackup(on);
    if (on) {
      await syncNow();
    } else {
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  /// Every Voice Notes backup in the folder, newest first. Files that are
  /// not backups, or cannot be read, are left out.
  Future<List<FoundBackup>> backups() async {
    final found = <FoundBackup>[];
    for (final e in await folder.list()) {
      if (!e.name.toLowerCase().endsWith('.json')) continue;
      try {
        final data = jsonDecode(await folder.read(e.name));
        if (data is! Map || data['format'] != backupFormat) continue;
        final notes = data['notes'];
        found.add(
          FoundBackup(
            file: e.name,
            device: '${data['device'] ?? 'Unknown phone'}',
            made: DateTime.tryParse('${data['made']}') ?? e.modified,
            notes: notes is Map && notes['notes'] is List
                ? (notes['notes'] as List).length
                : 0,
            mine: e.name == fileName,
            data: Map<String, Object?>.from(data),
          ),
        );
      } catch (err) {
        debugPrint('Skipping ${e.name}: $err');
      }
    }
    found.sort((a, b) => b.made.compareTo(a.made));
    return found;
  }
}
