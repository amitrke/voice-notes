import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/note.dart';
import '../providers/ai_provider.dart';
import 'notes_db.dart';
import 'settings_store.dart';

class AppState extends ChangeNotifier {
  final SettingsStore settings;
  final NotesDb db;

  AppState(this.settings, this.db);

  List<Note> _notes = [];
  String _query = '';

  List<Note> get notes {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _notes;
    return _notes
        .where((n) =>
            n.title.toLowerCase().contains(q) ||
            n.summary.toLowerCase().contains(q) ||
            n.transcript.toLowerCase().contains(q) ||
            n.english.toLowerCase().contains(q))
        .toList();
  }

  bool get hasAnyNotes => _notes.isNotEmpty;
  bool get hasActiveKey => settings.hasKey(settings.active);

  double get textScale => settings.textScale;

  Future<void> setTextScale(double v) async {
    await settings.setTextScale(v);
    notifyListeners();
  }

  /// Lets screens that edit [settings] directly trigger a rebuild.
  void refresh() => notifyListeners();

  Note? byId(int id) {
    for (final n in _notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  set query(String v) {
    _query = v;
    notifyListeners();
  }

  Future<void> init() async {
    _notes = await db.all();
    // Anything left "processing" by a previous run was interrupted.
    for (final n in _notes.where((n) => n.status == NoteStatus.processing)) {
      await _save(n.copyWith(
          status: NoteStatus.failed, error: 'Interrupted. Tap retry.'));
    }
  }

  Future<void> _save(Note n) async {
    await db.update(n);
    final i = _notes.indexWhere((e) => e.id == n.id);
    if (i >= 0) _notes[i] = n;
    notifyListeners();
  }

  /// Stores a note for [audioPath] right away (so nothing is lost if the
  /// network fails) and transcribes it in the background.
  Future<Note> addAudio(String audioPath, {int? durationMs}) async {
    final note = await db.insert(Note(
      audioPath: audioPath,
      provider: settings.active.name,
      durationMs: durationMs,
      createdAt: DateTime.now(),
    ));
    _notes.insert(0, note);
    notifyListeners();
    _process(note);
    return note;
  }

  /// Copies a picked file into app storage so it survives cache cleanup.
  Future<String> importFile(String sourcePath) async {
    final dir = await audioDir();
    final name = '${DateTime.now().millisecondsSinceEpoch}_${p.basename(sourcePath)}';
    final dest = p.join(dir.path, name);
    await File(sourcePath).copy(dest);
    return dest;
  }

  Future<void> retry(int id) async {
    final n = byId(id);
    if (n == null) return;
    final fresh = n.copyWith(status: NoteStatus.processing, clearError: true);
    await _save(fresh);
    _process(fresh);
  }

  Future<void> _process(Note note) async {
    // Always the provider that is active now, so a retry after switching
    // providers or fixing a key just works.
    final providerId = settings.active;
    note = note.copyWith(provider: providerId.name);
    final provider = settings.build(providerId);
    if (provider == null) {
      await _save(note.copyWith(
          status: NoteStatus.failed,
          error: 'Add your ${providerId.label} API key in Settings, then retry.'));
      return;
    }
    try {
      final t = await provider.transcribe(File(note.audioPath),
          translate: settings.translate);
      var done = note.copyWith(
        transcript: t.text,
        english: t.english,
        languageCode: t.languageCode,
        status: NoteStatus.done,
        clearError: true,
      );
      if (t.text.trim().isEmpty) {
        done = done.copyWith(title: 'No speech detected');
      } else {
        done = done.copyWith(title: _fallbackTitle(t.english.isNotEmpty ? t.english : t.text));
      }
      await _save(done);
      if (settings.autoSummary && t.text.trim().isNotEmpty) {
        await _summarize(done, provider);
      }
    } catch (e) {
      await _save(note.copyWith(
          status: NoteStatus.failed, error: _describe(e)));
    }
  }

  Future<void> _summarize(Note note, AiProvider provider) async {
    try {
      final source = note.english.isNotEmpty ? note.english : note.transcript;
      final s = await provider.summarize(source);
      await _save(note.copyWith(
        title: s.title.isEmpty ? note.title : s.title,
        summary: s.summary,
      ));
    } catch (_) {
      // The transcript is the valuable part; a failed summary is not fatal.
    }
  }

  /// Re-runs title/summary generation for an existing note.
  Future<String?> regenerateSummary(int id) async {
    final n = byId(id);
    if (n == null) return null;
    final provider = settings.build(settings.active);
    if (provider == null) return 'Add an API key for ${settings.active.label} in Settings.';
    try {
      final source = n.english.isNotEmpty ? n.english : n.transcript;
      final s = await provider.summarize(source);
      await _save(n.copyWith(
        title: s.title.isEmpty ? n.title : s.title,
        summary: s.summary,
      ));
      return null;
    } catch (e) {
      return _describe(e);
    }
  }

  Future<void> delete(int id) async {
    final n = byId(id);
    if (n == null) return;
    await db.delete(id);
    _notes.removeWhere((e) => e.id == id);
    notifyListeners();
    try {
      final f = File(n.audioPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static String _fallbackTitle(String text) {
    final words = text.trim().split(RegExp(r'\s+'));
    final t = words.take(6).join(' ');
    return words.length > 6 ? '$t…' : t;
  }

  static String _describe(Object e) {
    if (e is ProviderException) return e.message;
    if (e is SocketException) return 'No internet connection.';
    return e.toString();
  }
}
