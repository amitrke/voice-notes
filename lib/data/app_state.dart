import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/note.dart';
import '../providers/ai_provider.dart';
import '../ui/format.dart';
import 'find_replace.dart';
import 'notes_db.dart';
import 'settings_store.dart';

class AppState extends ChangeNotifier {
  final SettingsStore settings;
  final NotesDb db;

  AppState(this.settings, this.db) {
    // A finished or deleted model download changes whether the on-device
    // provider is ready. Progress ticks alone don't need a rebuild.
    var ready = settings.offlineModel;
    settings.models.addListener(() {
      if (settings.offlineModel == ready) return;
      ready = settings.offlineModel;
      notifyListeners();
    });
  }

  List<Note> _notes = [];
  List<Folder> _folders = [];
  List<Tag> _tags = [];
  String _query = '';
  int? _folder;
  int? _tag;

  /// Choice for [folderFilter] that shows only notes in no folder.
  static const unfiled = -1;

  List<Folder> get folders => List.unmodifiable(_folders);

  /// Which notes the list shows: null = all, [unfiled], or a folder id.
  int? get folderFilter => _folder;

  set folderFilter(int? v) {
    _folder = v;
    notifyListeners();
  }

  /// Every tag, approved or suggested, by name.
  List<Tag> get tags => List.unmodifiable(_tags);

  /// The tags notes can carry and the model may choose from.
  List<Tag> get approvedTags => _tags.where((t) => t.approved).toList();

  /// Tags the model proposed that wait for the user's approval.
  List<Tag> get suggestedTags => _tags.where((t) => !t.approved).toList();

  /// Which notes the list shows: null = any tag, or a tag id.
  int? get tagFilter => _tag;

  set tagFilter(int? v) {
    _tag = v;
    notifyListeners();
  }

  /// The note's approved tags, by name. A suggestion still waiting for
  /// approval is not shown.
  List<Tag> tagsOf(Note n) =>
      approvedTags.where((t) => n.tagIds.contains(t.id)).toList();

  int noteCountTagged(int tagId) =>
      _notes.where((n) => n.tagIds.contains(tagId)).length;

  String get query => _query;

  /// Notes in the chosen folder and tag that match the search text.
  List<Note> get notes {
    final q = _query.trim().toLowerCase();
    return _notes.where((n) {
      if (_folder == unfiled && n.folderId != null) return false;
      if (_folder != null && _folder != unfiled && n.folderId != _folder) {
        return false;
      }
      if (_tag != null && !n.tagIds.contains(_tag)) return false;
      if (q.isEmpty) return true;
      return n.title.toLowerCase().contains(q) ||
          n.summary.toLowerCase().contains(q) ||
          n.transcript.toLowerCase().contains(q) ||
          n.english.toLowerCase().contains(q);
    }).toList();
  }

  /// Every note, whatever the search or folder.
  List<Note> get allNotes => List.unmodifiable(_notes);

  int noteCountIn(int? folderId) => folderId == unfiled
      ? _notes.where((n) => n.folderId == null).length
      : _notes.where((n) => n.folderId == folderId).length;

  bool get hasAnyNotes => _notes.isNotEmpty;
  bool get hasActiveKey => settings.isReady(settings.active);

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
    _folders = await db.folders();
    _tags = await db.tags();
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

  // ---- Folders --------------------------------------------------------------

  Future<Folder?> createFolder(String name) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    final existing =
        _folders.where((f) => f.name.toLowerCase() == n.toLowerCase());
    if (existing.isNotEmpty) return existing.first;
    final f = await db.insertFolder(n);
    _folders = [..._folders, f]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
    return f;
  }

  Future<void> renameFolder(int id, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    await db.renameFolder(id, n);
    _folders = [
      for (final f in _folders) f.id == id ? Folder(id: id, name: n) : f,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
  }

  /// Deletes the folder. Its notes are kept and become unfiled.
  Future<void> deleteFolder(int id) async {
    await db.deleteFolder(id);
    _folders = _folders.where((f) => f.id != id).toList();
    _notes = [
      for (final n in _notes)
        n.folderId == id ? n.copyWith(clearFolder: true) : n,
    ];
    if (_folder == id) _folder = null;
    notifyListeners();
  }

  /// Files the note in [folderId], or takes it out of its folder when null.
  Future<void> moveToFolder(int noteId, int? folderId) => _edit(
      noteId,
      (n) =>
          folderId == null ? n.copyWith(clearFolder: true) : n.copyWith(folderId: folderId));

  // ---- Tags -----------------------------------------------------------------

  Tag? _tagNamed(String name) {
    final key = name.trim().toLowerCase();
    return _tags.where((t) => t.name.toLowerCase() == key).firstOrNull;
  }

  void _sortTags() =>
      _tags.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Adds an approved tag. A tag of that name that was only suggested is
  /// approved instead; an existing one is returned as it is.
  Future<Tag?> createTag(String name) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    final existing = _tagNamed(n);
    if (existing != null) {
      if (!existing.approved) await approveTag(existing.id!);
      return _tagNamed(n);
    }
    final t = await db.insertTag(n);
    _tags = [..._tags, t];
    _sortTags();
    notifyListeners();
    return t;
  }

  /// Renames the tag; false when another tag already has that name.
  Future<bool> renameTag(int id, String name) async {
    final n = name.trim();
    if (n.isEmpty) return false;
    final clash = _tagNamed(n);
    if (clash != null && clash.id != id) return false;
    final cur = _tags.where((t) => t.id == id).firstOrNull;
    if (cur == null) return false;
    final next = Tag(id: id, name: n, approved: cur.approved);
    await db.updateTag(next);
    _tags = [for (final t in _tags) t.id == id ? next : t];
    _sortTags();
    notifyListeners();
    return true;
  }

  /// Approves a suggested tag. Notes it was suggested for show it from now on.
  Future<void> approveTag(int id) async {
    final cur = _tags.where((t) => t.id == id).firstOrNull;
    if (cur == null || cur.approved) return;
    final next = Tag(id: id, name: cur.name);
    await db.updateTag(next);
    _tags = [for (final t in _tags) t.id == id ? next : t];
    notifyListeners();
  }

  /// Deletes the tag (or rejects a suggestion) and takes it off every note.
  Future<void> deleteTag(int id) async {
    await db.deleteTag(id);
    _tags = _tags.where((t) => t.id != id).toList();
    _notes = [
      for (final n in _notes)
        n.tagIds.contains(id)
            ? n.copyWith(tagIds: n.tagIds.where((t) => t != id).toList())
            : n,
    ];
    if (_tag == id) _tag = null;
    notifyListeners();
  }

  /// The user's choice of tags for the note. From now on enrichment no longer
  /// changes them, and a pending suggestion is dropped from the note.
  Future<void> setNoteTags(int noteId, Iterable<int> tagIds) async {
    final approved = {for (final t in approvedTags) t.id};
    final ids = tagIds.where(approved.contains).toSet().toList();
    await db.setNoteTags(noteId, ids);
    await _edit(noteId, (n) => n.copyWith(tagIds: ids, tagsEdited: true));
  }

  /// Adds or removes one tag by hand; see [setNoteTags].
  Future<void> toggleNoteTag(int noteId, int tagId) async {
    final n = byId(noteId);
    if (n == null) return;
    final visible = tagsOf(n).map((t) => t.id!).toSet();
    if (!visible.remove(tagId)) visible.add(tagId);
    await setNoteTags(noteId, visible);
  }

  /// The approved tag names enrichment may choose from.
  List<String> get _tagNames => [for (final t in approvedTags) t.name];

  /// Applies the tags enrichment chose, unless the user has edited the note's
  /// tags by hand. A suggested new tag is stored unapproved and linked to the
  /// note, so approving it later tags the note without asking the model again.
  Future<void> _applyTags(int noteId, NoteSummary s) async {
    if (byId(noteId)?.tagsEdited ?? true) return;
    final ids = <int>[
      for (final name in s.tags)
        if (_tagNamed(name) case final Tag t when t.approved) t.id!,
    ];
    final suggested = s.suggestedTag;
    if (suggested != null) {
      var t = _tagNamed(suggested);
      if (t == null) {
        t = await db.insertTag(suggested, approved: false);
        _tags = [..._tags, t];
        _sortTags();
      }
      ids.add(t.id!);
    }
    // The user may have edited the tags while the model was answering.
    if (byId(noteId)?.tagsEdited ?? true) return;
    await db.setNoteTags(noteId, ids);
    await _edit(noteId, (n) => n.copyWith(tagIds: ids.toSet().toList()));
  }

  // ---- Speakers -------------------------------------------------------------

  /// Names speaker [speakerId] in the note; an empty [name] goes back to the
  /// default "Speaker N".
  Future<void> renameSpeaker(int noteId, String speakerId, String name) =>
      _edit(noteId, (n) {
        final names = {...n.speakerNames};
        final t = name.trim();
        if (t.isEmpty) {
          names.remove(speakerId);
        } else {
          names[speakerId] = t;
        }
        return n.copyWith(speakerNames: names);
      });

  // ---- Find and replace -----------------------------------------------------

  /// How many times the text appears in each note that has it, newest first.
  List<({Note note, int count})> findMatches(TextReplacer r) => [
        for (final n in _notes)
          if (countInNote(n, r) > 0) (note: n, count: countInNote(n, r)),
      ];

  /// Applies [r] to the notes in [noteIds]; returns how many were changed.
  Future<int> replaceIn(Iterable<int> noteIds, TextReplacer r) async {
    var changedNotes = 0;
    for (final id in noteIds) {
      final n = byId(id);
      if (n == null) continue;
      final edit = replaceInNote(n, r);
      if (edit == null) continue;
      for (final s in edit.changed) {
        await db.saveSegment(s);
      }
      await _save(edit.note);
      changedNotes++;
    }
    return changedNotes;
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
    final seg = byId(noteId)?.segments.where((s) => s.id == segId).firstOrNull;
    if (seg == null || !seg.hasAudio) return;
    await _editSegment(noteId, segId,
        (s) => s.copyWith(status: NoteStatus.processing, clearError: true));
    _run(_process(noteId, segId));
  }

  /// Deletes a recording's audio file but keeps its text.
  Future<void> _discardAudio(int noteId, int segId, String path) async {
    await _editSegment(noteId, segId, (s) => s.copyWith(audioPath: ''));
    await _deleteFile(path);
  }

  /// Removes one recording (and its audio file) from a note that has others.
  Future<void> deleteSegment(int noteId, int segId) async {
    final n = byId(noteId);
    final seg = n?.segments.where((s) => s.id == segId).firstOrNull;
    if (n == null || seg == null || n.segments.length < 2) return;
    await db.deleteSegment(segId);
    await _edit(noteId,
        (n) => n.withSegments(n.segments.where((s) => s.id != segId).toList()));
    if (seg.hasAudio) await _deleteFile(seg.audioPath);
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
              error: providerId.needsKey
                  ? 'Add your ${providerId.label} API key in Settings, then retry.'
                  : 'Download an offline model in Settings, then retry.'));
      return;
    }
    final path =
        byId(noteId)?.segments.where((s) => s.id == segId).firstOrNull?.audioPath;
    if (path == null) return;
    // Its audio was deleted after the first transcription; nothing to redo.
    if (path.isEmpty) return;
    try {
      final dictionary = settings.dictionary;
      final t = dictionary.applyTo(await provider.transcribe(File(path),
          translate: settings.translate,
          vocabulary: dictionary.hints,
          speakers: settings.identifySpeakers));
      await _editSegment(
          noteId,
          segId,
          (s) => s.copyWith(
                transcript: t.text,
                english: t.english,
                languageCode: t.languageCode,
                lines: t.lines,
                status: NoteStatus.done,
                clearError: true,
              ));
      // Only once the text is safely stored, and only if there is some:
      // an empty result may just mean the audio was bad, and deserves a retry.
      if (settings.deleteAudioAfter && t.text.trim().isNotEmpty) {
        await _discardAudio(noteId, segId, path);
      }
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
    final provider = settings.textActive.canText
        ? settings.build(settings.textActive)
        : null;
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
      final s = await provider.summarize(source, tags: _tagNames);
      await _edit(
          noteId,
          (n) => n.copyWith(
                title: s.title.isEmpty ? n.title : s.title,
                summary: s.summary,
                enrichedHash: textHash(note.transcript, note.english),
              ));
      await _applyTags(noteId, s);
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
    if (provider == null || !settings.textActive.canText) return _noTextProvider;
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
    if (provider == null || !settings.textActive.canText) return _noTextProvider;
    try {
      final source = n.english.isNotEmpty ? n.english : n.transcript;
      final s = await provider.summarize(source, tags: _tagNames);
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
      await _applyTags(id, s);
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
      if (s.hasAudio) await _deleteFile(s.audioPath);
    }
  }

  static Future<void> _deleteFile(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  String get _noTextProvider => settings.textActive.canText
      ? 'Add an API key for ${settings.textActive.label} in Settings.'
      : 'On-device transcription has no text model. Choose a text provider '
          'under Settings > Written by.';

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
