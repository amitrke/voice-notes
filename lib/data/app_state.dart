import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/note.dart';
import '../providers/ai_provider.dart';
import '../providers/voice_match.dart';
import '../services/audio_converter.dart';
import '../ui/format.dart';
import 'dictionary.dart';
import 'find_replace.dart';
import 'notes_db.dart';
import 'settings_store.dart';
import 'templates.dart';

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

  /// Everything needed to bring the notes to another phone: every note's
  /// text and what was made from it, folders and tags, and the user's own
  /// dictionary and templates. Not the recordings, offline models, API keys
  /// or voiceprint.
  Future<Map<String, Object?>> backup() async => {
        'format': backupFormat,
        'made': DateTime.now().toIso8601String(),
        'notes': await db.export(),
        'dictionary': settings.dictionary.toLines(),
        'templates': [for (final t in settings.customTemplates) t.toJson()],
      };

  /// Adds what [b] (from [backup]) holds to this phone, keeping everything
  /// already here. Returns how many notes were added.
  Future<int> restore(Map<String, Object?> b) async {
    if (b['format'] != backupFormat) {
      throw const FormatException('This is not a Voice Notes backup.');
    }
    final added =
        await db.import(Map<String, Object?>.from(b['notes'] as Map));
    final words = [for (final w in (b['dictionary'] as List?) ?? []) '$w'];
    if (words.isNotEmpty) {
      await settings.setDictionary(Dictionary.fromLines(
          {...settings.dictionary.toLines(), ...words}.toList()));
    }
    for (final j in (b['templates'] as List?) ?? []) {
      final t = NoteTemplate.fromJson(Map<String, dynamic>.from(j as Map));
      if (t.id.isNotEmpty && settings.template(t.id) == null) {
        await settings.saveTemplate(t);
      }
    }
    _notes = await db.all();
    _folders = await db.folders();
    _tags = await db.tags();
    notifyListeners();
    return added;
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
    // Notes restored onto a new phone by its own backup come without their
    // recordings; keep the text, as if the audio had been deleted.
    for (final n in _notes.toList()) {
      if (!n.segments.any((s) => s.hasAudio && !File(s.audioPath).existsSync())) {
        continue;
      }
      final segs = <Segment>[];
      for (final s in n.segments) {
        segs.add(s.hasAudio && !File(s.audioPath).existsSync()
            ? await db.saveSegment(s.copyWith(audioPath: ''))
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
  /// With [live], the recording is still going: see [beginLive].
  Future<Note> addAudio(String audioPath,
      {int? durationMs, bool live = false, NoteTemplate? liveNotes}) async {
    final note = await db.insert(Note(
      segments: [Segment(audioPath: audioPath, durationMs: durationMs)],
      provider: settings.active.name,
      createdAt: DateTime.now(),
    ));
    // Registered before the note is in the list, so its first recording
    // counts as part of the live one.
    if (live) {
      _live[note.id!] = LiveSession(
          liveNotes: liveNotes, summarise: true, knownSegments: const {});
    }
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
      final heard = dictionary.applyTo(await provider.transcribe(File(path),
          translate: settings.translate,
          vocabulary: dictionary.hints,
          speakers: settings.identifySpeakers));
      final t = Transcription(
          text: heard.text,
          english: heard.english,
          languageCode: heard.languageCode,
          lines: await _recogniseYou(path, heard.lines));
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
    await _updateLiveNotes(noteId);
    await _afterTranscription(noteId);
  }

  /// Labels the owner's lines "You" when their voiceprint is set up and the
  /// speaker models are downloaded. Any failure just leaves the labels as
  /// they were.
  Future<List<TimedLine>> _recogniseYou(
      String audio, List<TimedLine> lines) async {
    final mine = settings.voiceprint;
    if (mine == null || !lines.any((l) => l.speaker != null)) return lines;
    final models = settings.models.installedSpeakers();
    if (models == null) return lines;
    File? temp;
    try {
      var wav = audio;
      if (p.extension(audio).toLowerCase() != '.wav') {
        temp = await convertToWav16kMono(File(audio));
        if (temp == null) return lines;
        wav = temp.path;
      }
      return await recogniseYou(wav, lines, mine, models.embedding);
    } catch (_) {
      return lines;
    } finally {
      try {
        await temp?.delete();
      } catch (_) {}
    }
  }

  final _live = <int, LiveSession>{};

  /// The recording going on for note [id], if any.
  LiveSession? live(int id) => _live[id];

  /// Marks note [id] as being recorded: its parts are transcribed as they
  /// arrive, but the title and summary wait for [endLive]. With [liveNotes],
  /// that template's notes are updated as the text grows.
  void beginLive(int id, {NoteTemplate? liveNotes}) {
    final n = byId(id);
    _live[id] = LiveSession(
      liveNotes: liveNotes,
      summarise: n == null || n.enrichedHash == null,
      knownSegments: {for (final s in n?.segments ?? <Segment>[]) s.id!},
    );
  }

  /// The recording of note [id] has ended. Once every part is transcribed,
  /// the title and summary are written and the live notes get a last pass
  /// over the full text. With [discard], none of that happens.
  Future<void> endLive(int id, {bool discard = false}) async {
    final s = _live[id];
    if (s == null) return;
    if (discard) {
      _live.remove(id);
      return;
    }
    s.ended = true;
    notifyListeners();
    if (byId(id)?.status != NoteStatus.processing) await _afterTranscription(id);
  }

  /// Folds the text transcribed since the last update into the live notes.
  /// Waits for a few hundred characters and a few minutes between updates,
  /// so an hour costs about a dozen requests.
  Future<void> _updateLiveNotes(int id) async {
    final s = _live[id];
    final t = s?.liveNotes;
    final n = byId(id);
    if (s == null || t == null || n == null || s.ended || s.updating) return;
    final fresh = n.segments
        .where((g) =>
            g.status == NoteStatus.done &&
            !s.usedSegments.contains(g.id) &&
            !s.knownSegments.contains(g.id))
        .toList();
    final text = fresh
        .map((g) => g.english.trim().isNotEmpty ? g.english : g.transcript)
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .join('\n\n');
    final due = s.updatedAt == null ||
        DateTime.now().difference(s.updatedAt!) >= liveNotesEvery;
    if (text.length < 300 || !due) return;
    final provider = settings.textActive.canText
        ? settings.build(settings.textActive)
        : null;
    if (provider == null) {
      s.error = _noTextProvider;
      notifyListeners();
      return;
    }
    s.updating = true;
    notifyListeners();
    try {
      final out = templateOutputFromReply(
          t,
          await provider.completeJson(liveNotesPrompt(t,
              current: n.output(t.id)?.text ?? '', newText: text)));
      s.usedSegments.addAll(fresh.map((g) => g.id!));
      s.updatedAt = DateTime.now();
      s.error = null;
      await _edit(
          id,
          (cur) => cur.copyWith(
              outputs: _withOutput(cur.outputs, out),
              enrichedHash: textHash(n.transcript, n.english)));
    } catch (e) {
      s.error = _describe(e);
    } finally {
      s.updating = false;
      notifyListeners();
    }
  }

  Future<void> _afterTranscription(int noteId) async {
    final n = byId(noteId);
    // Wait until the last pending recording has finished.
    if (n == null || n.status == NoteStatus.processing) return;
    final live = _live[noteId];
    // Still recording: more is coming, so it is too early to sum up. A
    // stand-in title keeps the note recognisable in the list meanwhile.
    if (live != null && !live.ended) {
      if (n.title.isEmpty && n.transcript.trim().isNotEmpty) {
        await _edit(noteId, (n) => n.copyWith(title: _fallbackTitle(n.transcript)));
      }
      return;
    }
    if (live != null) {
      _live.remove(noteId);
      await _finishLive(noteId, live);
      return;
    }
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

  /// The last pass once a recording has ended: the title and summary, and the
  /// live notes rewritten from the full text.
  Future<void> _finishLive(int noteId, LiveSession live) async {
    final n = byId(noteId);
    if (n == null) return;
    if (!n.hasEnrichment && n.title.isEmpty) {
      final text = n.english.isNotEmpty ? n.english : n.transcript;
      await _edit(
          noteId,
          (n) => n.copyWith(
              title: text.trim().isEmpty
                  ? 'No speech detected'
                  : _fallbackTitle(text)));
    }
    if (n.transcript.trim().isEmpty) return;
    final provider = settings.textActive.canText
        ? settings.build(settings.textActive)
        : null;
    if (provider == null) return;
    if (settings.autoSummary && live.summarise) {
      await _summarize(noteId, provider);
    }
    final t = live.liveNotes;
    if (t != null) await applyTemplate(noteId, t);
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

  /// Turns note [id] into what template [t] describes, replacing anything
  /// that template made before. Returns an error message, or null on success.
  Future<String?> applyTemplate(int id, NoteTemplate t) async {
    if (t.isClinical) return enrichClinical(id);
    final n = byId(id);
    if (n == null) return null;
    final provider = settings.build(settings.textActive);
    if (provider == null || !settings.textActive.canText) return _noTextProvider;
    try {
      final out = await buildTemplateOutput(provider, t, n);
      final hash = n.hasEnrichment && n.isStale
          ? n.enrichedHash
          : textHash(n.transcript, n.english);
      await _edit(
          id,
          (n) => n.copyWith(
              outputs: _withOutput(n.outputs, out), enrichedHash: hash));
      return null;
    } catch (e) {
      return _describe(e);
    }
  }

  static List<TemplateOutput> _withOutput(
          List<TemplateOutput> all, TemplateOutput out) =>
      [
        for (final o in all)
          if (o.templateId != out.templateId) o,
        out,
      ];

  /// Removes what template [templateId] made from note [id].
  Future<void> deleteOutput(int id, String templateId) => _edit(
      id,
      (n) => n.copyWith(
          outputs: [
        for (final o in n.outputs)
          if (o.templateId != templateId) o,
      ]));

  /// Regenerates the title and summary, the clinical note if the note has
  /// one, and anything else templates made from it, from the combined text of
  /// all recordings. Clears the out-of-date
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
      // A template the user has since deleted can't be rerun; its output
      // stays as it was.
      final outputs = [
        for (final o in n.outputs)
          switch (settings.template(o.templateId)) {
            final t? => await buildTemplateOutput(provider, t, n),
            null => o,
          },
      ];
      await _edit(
          id,
          (cur) => cur.copyWith(
                title: s.title.isEmpty ? cur.title : s.title,
                summary: s.summary,
                clinical: report,
                outputs: outputs,
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

/// Marks a file made by [AppState.backup].
const backupFormat = 'voice-notes-backup';

/// How often live notes are updated while recording.
const liveNotesEvery = Duration(minutes: 3);

/// A recording in progress on a note; see [AppState.beginLive].
class LiveSession {
  /// The template whose notes are kept up to date while recording.
  NoteTemplate? liveNotes;

  /// Write the title and summary at the end: the note had none before.
  final bool summarise;

  /// Recordings the note already had; live notes cover only the new ones.
  final Set<int> knownSegments;

  /// Recordings already folded into the live notes.
  final usedSegments = <int>{};

  DateTime? updatedAt;
  bool updating = false;
  bool ended = false;

  /// Why the last live notes update failed, if it did.
  String? error;

  LiveSession(
      {this.liveNotes, required this.summarise, required this.knownSegments});
}
