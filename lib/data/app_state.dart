import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/note.dart';
import '../providers/ai_provider.dart';
import '../ui/format.dart';
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
    for (final n in _notes.toList()) {
      if (!n.segments.any((s) => s.status == NoteStatus.processing)) continue;
      final segs = <Segment>[];
      for (final s in n.segments) {
        segs.add(s.status == NoteStatus.processing
            ? await db.saveSegment(s.copyWith(
                status: NoteStatus.failed, error: 'Interrupted. Tap retry.'))
            : s);
      }
      await _save(n.withSegments(segs));
    }
  }

  Future<void> _save(Note n) async {
    final i = _notes.indexWhere((e) => e.id == n.id);
    if (i >= 0) _notes[i] = n;
    notifyListeners();
    await db.update(n);
  }

  /// Applies [change] to the latest copy of the note, so a slow call (a
  /// transcription, a summary) never overwrites edits made while it ran.
  Future<void> _edit(int id, Note Function(Note) change) async {
    final n = byId(id);
    if (n != null) await _save(change(n));
  }

  Future<void> _editSegment(
      int noteId, int segId, Segment Function(Segment) change) async {
    final cur = byId(noteId)?.segments.where((s) => s.id == segId).firstOrNull;
    if (cur == null) return;
    final next = change(cur);
    await db.saveSegment(next);
    await _edit(
        noteId,
        (n) => n.withSegments(
            [for (final s in n.segments) s.id == segId ? next : s]));
  }

  final _inflight = <Future<void>>{};

  void _run(Future<void> work) {
    _inflight.add(work);
    work.whenComplete(() => _inflight.remove(work));
  }

  /// Completes when all background transcription and summary work is done.
  Future<void> settled() async {
    while (_inflight.isNotEmpty) {
      await Future.wait(_inflight.toList());
    }
  }

  /// Stores a note for [audioPath] right away (so nothing is lost if the
  /// network fails) and transcribes it in the background.
  Future<Note> addAudio(String audioPath, {int? durationMs}) async {
    final note = await db.insert(Note(
      segments: [Segment(audioPath: audioPath, durationMs: durationMs)],
      provider: settings.active.name,
      createdAt: DateTime.now(),
    ));
    _notes.insert(0, note);
    notifyListeners();
    _run(_process(note.id!, note.segments.first.id!));
    return note;
  }

  /// Appends another recording to an existing note and transcribes only that
  /// one. The note's title, summary and clinical note are left as they are and
  /// show as out of date until [regenerate] is called.
  Future<Segment?> addSegment(int noteId, String audioPath,
      {int? durationMs}) async {
    final n = byId(noteId);
    if (n == null) return null;
    final seg = await db.saveSegment(Segment(
      noteId: noteId,
      position: n.segments.isEmpty ? 0 : n.segments.last.position + 1,
      audioPath: audioPath,
      durationMs: durationMs,
    ));
    await _edit(noteId, (n) => n.withSegments([...n.segments, seg]));
    _run(_process(noteId, seg.id!));
    return seg;
  }

  /// Copies a picked file into app storage so it survives cache cleanup.
  Future<String> importFile(String sourcePath) async {
    final dir = await audioDir();
    final name = '${DateTime.now().millisecondsSinceEpoch}_${p.basename(sourcePath)}';
    final dest = p.join(dir.path, name);
    await File(sourcePath).copy(dest);
    return dest;
  }

  /// Transcribes every recording of the note again.
  Future<void> retry(int id) async {
    final n = byId(id);
    if (n == null) return;
    for (final s in n.segments) {
      await retrySegment(id, s.id!);
    }
  }

  Future<void> retrySegment(int noteId, int segId) async {
    await _editSegment(noteId, segId,
        (s) => s.copyWith(status: NoteStatus.processing, clearError: true));
    _run(_process(noteId, segId));
  }

  /// Removes one recording (and its audio file) from a note that has others.
  Future<void> deleteSegment(int noteId, int segId) async {
    final n = byId(noteId);
    final seg = n?.segments.where((s) => s.id == segId).firstOrNull;
    if (n == null || seg == null || n.segments.length < 2) return;
    await db.deleteSegment(segId);
    await _edit(noteId,
        (n) => n.withSegments(n.segments.where((s) => s.id != segId).toList()));
    await _deleteFile(seg.audioPath);
  }

  Future<void> _process(int noteId, int segId) async {
    // Always the provider that is active now, so a retry after switching
    // providers or fixing a key just works.
    final providerId = settings.active;
    await _edit(noteId, (n) => n.copyWith(provider: providerId.name));
    final provider = settings.build(providerId);
    if (provider == null) {
      await _editSegment(
          noteId,
          segId,
          (s) => s.copyWith(
              status: NoteStatus.failed,
              error:
                  'Add your ${providerId.label} API key in Settings, then retry.'));
      return;
    }
    final path =
        byId(noteId)?.segments.where((s) => s.id == segId).firstOrNull?.audioPath;
    if (path == null) return;
    try {
      final t = await provider.transcribe(File(path),
          translate: settings.translate);
      await _editSegment(
          noteId,
          segId,
          (s) => s.copyWith(
                transcript: t.text,
                english: t.english,
                languageCode: t.languageCode,
                status: NoteStatus.done,
                clearError: true,
              ));
    } catch (e) {
      await _editSegment(noteId, segId,
          (s) => s.copyWith(status: NoteStatus.failed, error: _describe(e)));
      return;
    }
    await _afterTranscription(noteId);
  }

  Future<void> _afterTranscription(int noteId) async {
    final n = byId(noteId);
    // Wait until the last pending recording has finished.
    if (n == null || n.status == NoteStatus.processing) return;
    if (!n.hasEnrichment) {
      final text = n.english.isNotEmpty ? n.english : n.transcript;
      await _edit(
          noteId,
          (n) => n.copyWith(
              title: text.trim().isEmpty
                  ? 'No speech detected'
                  : _fallbackTitle(text)));
    }
    // Only the first summary is automatic. After that, new recordings leave
    // the note out of date for the user to regenerate.
    final provider = settings.build(settings.textActive);
    if (settings.autoSummary &&
        n.transcript.trim().isNotEmpty &&
        n.enrichedHash == null &&
        provider != null) {
      await _summarize(noteId, provider);
    }
  }

  Future<void> _summarize(int noteId, AiProvider provider) async {
    final note = byId(noteId);
    if (note == null) return;
    try {
      final source = note.english.isNotEmpty ? note.english : note.transcript;
      final s = await provider.summarize(source);
      await _edit(
          noteId,
          (n) => n.copyWith(
                title: s.title.isEmpty ? n.title : s.title,
                summary: s.summary,
                enrichedHash: textHash(note.transcript, note.english),
              ));
    } catch (_) {
      // The transcript is the valuable part; a failed summary is not fatal.
    }
  }

  /// Builds (or rebuilds) the clinical write-up for a finished note. Returns an
  /// error message, or null on success.
  Future<String?> enrichClinical(int id) async {
    final n = byId(id);
    if (n == null) return null;
    final provider = settings.build(settings.textActive);
    if (provider == null) {
      return 'Add an API key for ${settings.textActive.label} in Settings.';
    }
    try {
      final report = await buildClinicalReport(
        provider,
        transcript: n.transcript,
        english: n.english,
        language: languageLabel(n.languageCode),
      );
      // A summary that is already out of date stays flagged; otherwise the
      // note is now in step with the text the report was made from.
      final hash = n.hasEnrichment && n.isStale
          ? n.enrichedHash
          : textHash(n.transcript, n.english);
      await _edit(id, (n) => n.copyWith(clinical: report, enrichedHash: hash));
      return null;
    } catch (e) {
      return _describe(e);
    }
  }

  /// Regenerates the title and summary, and the clinical note if the note has
  /// one, from the combined text of all recordings. Clears the out-of-date
  /// flag only if everything succeeded. Returns an error message or null.
  Future<String?> regenerate(int id) async {
    final n = byId(id);
    if (n == null) return null;
    final provider = settings.build(settings.textActive);
    if (provider == null) {
      return 'Add an API key for ${settings.textActive.label} in Settings.';
    }
    try {
      final source = n.english.isNotEmpty ? n.english : n.transcript;
      final s = await provider.summarize(source);
      final report = n.clinical == null
          ? null
          : await buildClinicalReport(
              provider,
              transcript: n.transcript,
              english: n.english,
              language: languageLabel(n.languageCode),
            );
      await _edit(
          id,
          (cur) => cur.copyWith(
                title: s.title.isEmpty ? cur.title : s.title,
                summary: s.summary,
                clinical: report,
                // The text the new summary was made from, not the latest: if
                // a recording landed meanwhile the note stays out of date.
                enrichedHash: textHash(n.transcript, n.english),
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
    for (final s in n.segments) {
      await _deleteFile(s.audioPath);
    }
  }

  static Future<void> _deleteFile(String path) async {
    try {
      final f = File(path);
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
