import 'package:flutter/services.dart';

/// Where backups are kept, as the user would recognise it.
class FolderInfo {
  /// For example "iCloud Drive › Voice Notes" or "Documents › Voice Notes".
  final String label;

  /// True when the user chose the folder; false for the default.
  final bool custom;

  /// False when the default folder only lives on this phone (iCloud is
  /// signed out, or an old Android version), so a backup there will not
  /// reach another phone.
  final bool syncs;

  const FolderInfo(this.label, {this.custom = false, this.syncs = true});

  factory FolderInfo.fromMap(Map<Object?, Object?> m) => FolderInfo(
    '${m['label']}',
    custom: m['custom'] == true,
    syncs: m['syncs'] != false,
  );
}

/// A backup file found in the folder.
class BackupEntry {
  final String name;
  final DateTime modified;
  const BackupEntry(this.name, this.modified);
}

/// The folder backups are written to and restored from. The phone's own
/// cloud folder by default (iCloud Drive on iPhone, Documents on Android),
/// or one the user picks.
abstract class BackupFolder {
  Future<FolderInfo> location();

  /// Asks the user for a folder. Null when they cancel.
  Future<FolderInfo?> pick();

  /// Goes back to the default folder.
  Future<FolderInfo> reset();

  Future<void> write(String name, String text);
  Future<List<BackupEntry>> list();
  Future<String> read(String name);

  /// A name for this phone, and an id that a new phone restored from this
  /// one's backup does not inherit.
  Future<({String name, String id})> device();
}

/// [BackupFolder] backed by native code (MainActivity.kt, AppDelegate.swift).
class NativeBackupFolder implements BackupFolder {
  static const _ch = MethodChannel('com.subnext.voicenotes/backup');

  Future<Map<Object?, Object?>> _map(
    String method, [
    Map<String, Object?>? args,
  ]) async => (await _ch.invokeMapMethod<Object?, Object?>(method, args))!;

  @override
  Future<FolderInfo> location() async =>
      FolderInfo.fromMap(await _map('location'));

  @override
  Future<FolderInfo?> pick() async {
    final m = await _ch.invokeMapMethod<Object?, Object?>('pick');
    return m == null ? null : FolderInfo.fromMap(m);
  }

  @override
  Future<FolderInfo> reset() async => FolderInfo.fromMap(await _map('reset'));

  @override
  Future<void> write(String name, String text) =>
      _ch.invokeMethod('write', {'name': name, 'text': text});

  @override
  Future<List<BackupEntry>> list() async {
    final l = await _ch.invokeListMethod<Object?>('list') ?? const [];
    return [
      for (final e in l.cast<Map<Object?, Object?>>())
        BackupEntry(
          '${e['name']}',
          DateTime.fromMillisecondsSinceEpoch((e['modified'] as num).toInt()),
        ),
    ];
  }

  @override
  Future<String> read(String name) async =>
      (await _ch.invokeMethod<String>('read', {'name': name}))!;

  @override
  Future<({String name, String id})> device() async {
    final m = await _map('device');
    return (name: '${m['name']}', id: '${m['id']}');
  }
}
