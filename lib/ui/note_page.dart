import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/app_state.dart';
import '../data/srt_export.dart';
import '../data/templates.dart';
import '../models/note.dart';
import '../providers/ai_provider.dart';
import 'ask_page.dart';
import 'audio_input.dart';
import 'clinical_page.dart';
import 'folders.dart';
import 'format.dart';
import 'share_origin.dart';
import 'stale_banner.dart';
import 'tags.dart';
import 'templates_ui.dart';
import 'text_size.dart';
import 'theme.dart';

class NotePage extends StatefulWidget {
  final int noteId;
  const NotePage({super.key, required this.noteId});

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> {
  bool _showEnglish = false;
  bool _enriching = false;
  final _playback = Playback();

  @override
  void dispose() {
    _playback.dispose();
    super.dispose();
  }

  Future<void> _exportSrt(Note note,
      {required bool english, Rect? origin}) async {
    final dir = await getTemporaryDirectory();
    final safe = note.title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
    final file = File('${dir.path}/${safe.isEmpty ? 'subtitles' : safe}'
        '${english ? ' (English)' : ''}.srt');
    await file.writeAsString(srtText(note, english: english));
    await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], sharePositionOrigin: origin));
  }

  /// Opens what template [templateId] made from note [id].
  void _openOutput(int id, String templateId) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => templateId == clinicalTemplateId
              ? ClinicalPage(noteId: id)
              : TemplateOutputPage(noteId: id, templateId: templateId)));

  bool _made(Note n, String templateId) => templateId == clinicalTemplateId
      ? n.clinical != null
      : n.output(templateId) != null;

  /// Asks which template to use, makes it unless it already exists, and
  /// opens the result.
  Future<void> _turnInto(AppState state, Note note) async {
    final made = {
      for (final t in state.settings.allTemplates)
        if (_made(note, t.id)) t.id,
    };
    final choice = await showTurnIntoSheet(context, state, made);
    if (!mounted || choice == null) return;
    final NoteTemplate? t = switch (choice) {
      UseTemplate(:final template) => template,
      MakeTemplate() => await editTemplate(context, state, null),
    };
    if (t == null || !mounted) return;
    if (made.contains(t.id)) {
      _openOutput(note.id!, t.id);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _enriching = true);
    final err = await state.applyTemplate(note.id!, t);
    if (mounted) setState(() => _enriching = false);
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
    } else if (mounted) {
      _openOutput(note.id!, t.id);
    }
  }

  bool _regenerating = false;

  Future<void> _regenerate(AppState state, int id) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _regenerating = true);
    final err = await state.regenerate(id);
    if (mounted) setState(() => _regenerating = false);
    if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _deleteSegment(AppState state, Note note, Segment seg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this recording?'),
        content: const Text(
            'Its audio and text are removed from the note. The summary will be marked out of date.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _playback.stopIf(seg.id!);
    await state.deleteSegment(note.id!, seg.id!);
  }

  Future<void> _delete(AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text('The transcript and all its audio files will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await state.delete(widget.noteId);
      if (mounted) Navigator.pop(context);
    }
  }

  /// Shares the title, summary and the transcript currently on screen.
  Future<void> _share(BuildContext buttonContext, Note note, String text) {
    final title = note.title.trim();
    final summary = note.summary.trim();
    final body = [
      if (title.isNotEmpty) title,
      if (summary.isNotEmpty) 'Summary\n$summary',
      if (text.trim().isNotEmpty) text.trim(),
    ].join('\n\n');
    // iPad shows the share sheet as a popover anchored to the button.
    final box = buttonContext.findRenderObject() as RenderBox?;
    return SharePlus.instance.share(ShareParams(
      text: body,
      subject: title.isEmpty ? null : title,
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  /// Lets the user give each voice a name; "Speaker 1" until they do.
  Future<void> _nameSpeakers(AppState state, int noteId) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => _SpeakerNames(noteId: noteId),
    );
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$what copied')));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final note = state.byId(widget.noteId);
    if (note == null) return const Scaffold(body: SizedBox.shrink());

    // An English recording has nothing to translate, though some providers
    // still return an "English version" of it.
    final hasEnglish = note.english.trim().isNotEmpty &&
        !isEnglish(note.languageCode) &&
        note.english.trim() != note.transcript.trim();
    final showEnglish = _showEnglish && hasEnglish;
    final labelled = hasSpeakers(note);
    // With speakers known, copy and share carry "Name: ..." paragraphs.
    final text = labelled
        ? speakerTranscript(note, english: showEnglish)
        : (showEnglish ? note.english : note.transcript);
    final lang = languageLabel(note.languageCode);

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ready =
        note.status == NoteStatus.done || note.transcript.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (text.trim().isNotEmpty || note.summary.isNotEmpty)
            Builder(
              builder: (buttonContext) => IconButton(
                tooltip: 'Share',
                icon: Icon(theme.platform == TargetPlatform.iOS
                    ? Icons.ios_share
                    : Icons.share_outlined),
                onPressed: () => _share(buttonContext, note, text),
              ),
            ),
          IconButton(
            tooltip: 'Text size',
            icon: const Icon(Icons.format_size),
            onPressed: () => showTextSizeSheet(
              context,
              current: () => state.textScale,
              onChanged: state.setTextScale,
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'delete') {
                await _delete(state);
              } else if (v == 'regenerate') {
                await _regenerate(state, note.id!);
              } else if (v == 'retry') {
                await state.retry(note.id!);
              } else if (v == 'srt') {
                await _exportSrt(note,
                    english: showEnglish,
                    origin: shareOrigin(context, topRight: true));
              } else if (v == 'folder') {
                await moveNoteToFolder(context, note);
              } else if (v == 'tags') {
                await editNoteTags(context, note.id!);
              } else if (v == 'speakers') {
                await _nameSpeakers(state, note.id!);
              }
            },
            itemBuilder: (_) => [
              if (note.status == NoteStatus.done)
                PopupMenuItem(
                    value: 'regenerate',
                    child: Text(note.clinical != null || note.outputs.isNotEmpty
                        ? 'Regenerate summary and what was made from it'
                        : 'Regenerate summary')),
              if (hasTimedText(note))
                PopupMenuItem(
                    value: 'srt',
                    child: Text(showEnglish
                        ? 'Export English subtitles (SRT)'
                        : 'Export subtitles (SRT)')),
              if (labelled)
                const PopupMenuItem(
                    value: 'speakers', child: Text('Name the speakers')),
              const PopupMenuItem(
                  value: 'folder', child: Text('Move to folder')),
              const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
              if (note.segments.any((s) => s.hasAudio))
                const PopupMenuItem(
                    value: 'retry', child: Text('Transcribe again')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: scheme.secondary,
                      foregroundColor: scheme.onSecondary),
                  onPressed: () => recordAudio(context, noteId: note.id),
                  icon: const Icon(Icons.mic_none_rounded, size: 20),
                  label: const Text('Add recording'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => importAudio(context, noteId: note.id),
                  icon: const Icon(Icons.file_upload_outlined, size: 20),
                  label: const Text('Import audio'),
                ),
              ),
            ]),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              switch (note.status) {
                NoteStatus.processing when note.title.isEmpty =>
                  'Transcribing…',
                NoteStatus.failed when note.title.isEmpty =>
                  'Transcription failed',
                _ => note.title.isEmpty ? 'Untitled note' : note.title,
              },
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              [
                formatDate(note.createdAt),
                if (note.durationMs != null) formatDuration(note.durationMs!),
                ?lang,
                ProviderId.values.asNameMap()[note.provider]?.label ??
                    note.provider,
                ?state.folders
                    .where((f) => f.id == note.folderId)
                    .firstOrNull
                    ?.name,
              ].join(' · '),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 8),
          NoteTags(note: note),
          const SizedBox(height: 12),
          if (note.isStale && note.status != NoteStatus.processing) ...[
            StaleBanner(
              message: note.clinical != null || note.outputs.isNotEmpty
                  ? 'Recordings changed after the title, summary and what was '
                      'made from this note were written, so they may no '
                      'longer match.'
                  : 'Recordings changed after the title and summary were '
                      'written, so they may no longer match.',
              busy: _regenerating,
              onRegenerate: () => _regenerate(state, note.id!),
            ),
            const SizedBox(height: 12),
          ],
          if (note.segments.isNotEmpty) _recordings(state, note),
          if (ready) ...[
            if (note.summary.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                color: scheme.primaryContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionLabel('Summary',
                          padding: const EdgeInsets.only(bottom: 6),
                          color: scheme.primary),
                      SelectableText(note.summary,
                          style: theme.textTheme.bodyLarge?.copyWith(
                              color: scheme.onPrimaryContainer, height: 1.5)),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (hasEnglish) ...[
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, label: Text(lang ?? 'Original')),
                  const ButtonSegment(value: true, label: Text('English')),
                ],
                selected: {showEnglish},
                onSelectionChanged: (s) =>
                    setState(() => _showEnglish = s.first),
              ),
              const SizedBox(height: 16),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: text.isNotEmpty && hasTimedText(note)
                  ? _TimedTranscript(
                      note: note, english: showEnglish, playback: _playback)
                  : SelectableText(
                      text.isEmpty ? 'No speech detected.' : text,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontSize: 17, height: 1.6),
                    ),
            ),
            const SizedBox(height: 8),
            if (text.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _copy(
                      text, showEnglish ? 'English text' : 'Transcript'),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy text'),
                ),
              ),
            if (note.transcript.trim().isNotEmpty)
              ..._templatesEntry(state, note),
          ],
        ],
      ),
    );
  }

  /// A note with more recordings than this shows them folded into one row,
  /// so a long meeting does not push its summary and transcript far down.
  static const _foldAfter = 3;

  /// The note's recordings, each with its player and status.
  Widget _recordings(AppState state, Note note) {
    final segs = note.segments;
    final tiles = [
      for (final (i, seg) in segs.indexed) ...[
        if (i > 0) const Divider(height: 16),
        _SegmentTile(
          key: ValueKey(seg.id),
          index: i,
          segment: seg,
          count: segs.length,
          playback: _playback,
          onRetry: () => state.retrySegment(note.id!, seg.id!),
          onDelete: () => _deleteSegment(state, note, seg),
        ),
      ],
    ];
    if (segs.length <= _foldAfter) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(children: tiles),
        ),
      );
    }
    final failed = segs.where((s) => s.status == NoteStatus.failed).length;
    final pending =
        segs.where((s) => s.status == NoteStatus.processing).length;
    final total = note.durationMs;
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        // Open at first only when something needs the user.
        initiallyExpanded: failed > 0,
        leading: const Icon(Icons.graphic_eq),
        title: Text([
          '${segs.length} recordings',
          if (total != null) formatDuration(total),
        ].join(' · ')),
        subtitle: Text(failed > 0
            ? '$failed failed · open to retry'
            : pending > 0
                ? '${segs.length - pending} of ${segs.length} transcribed'
                : hasTimedText(note) && segs.any((s) => s.hasAudio)
                    ? 'Tap a line of the transcript to play from there'
                    : 'Open to play or delete them'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
        children: tiles,
      ),
    );
  }

  /// What was made from the note with templates, and the "Turn into…"
  /// button.
  List<Widget> _templatesEntry(AppState state, Note note) {
    final scheme = Theme.of(context).colorScheme;
    final c = note.clinical;
    Widget card(String templateId, String name, String detail) => Card(
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
            leading: Icon(templateIcon(templateId), color: scheme.primary),
            title: Text(name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle:
                Text(note.isStale ? 'Out of date. Regenerate before use.' : detail),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openOutput(note.id!, templateId),
          ),
        );
    final cards = [
      if (c != null)
        card(
            clinicalTemplateId,
            'Clinical note',
            c.verify.isEmpty
                ? 'Interpretation and note'
                : 'Interpretation, note and ${c.verify.length} '
                    '${c.verify.length == 1 ? 'item' : 'items'} to verify'),
      for (final o in note.outputs)
        card(o.templateId, o.name,
            o.sections.map((s) => s.heading).where((h) => h.isNotEmpty).join(', ')),
    ];
    return [
      if (cards.isNotEmpty) ...[
        const SectionLabel('Made from this note',
            padding: EdgeInsets.fromLTRB(4, 24, 4, 8)),
        ...cards,
      ],
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _enriching ? null : () => _turnInto(state, note),
        icon: _enriching
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.auto_fix_high),
        label: Text(_enriching ? 'Working…' : 'Turn into…'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => AskPage(noteId: note.id))),
        icon: const Icon(Icons.question_answer_outlined),
        label: const Text('Ask about this note'),
      ),
    ];
  }
}

/// One recording of a note: its player and, until it is done, its status.
class _SegmentTile extends StatelessWidget {
  final int index;
  final int count;
  final Segment segment;
  final Playback playback;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  const _SegmentTile({
    super.key,
    required this.index,
    required this.count,
    required this.segment,
    required this.playback,
    required this.onRetry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seg = segment;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (count > 1)
            Row(children: [
              Expanded(
                child: Text(
                  [
                    'Recording ${index + 1}',
                    if (seg.durationMs != null) formatDuration(seg.durationMs!),
                  ].join(' · '),
                  style: theme.textTheme.labelLarge,
                ),
              ),
              IconButton(
                tooltip: 'Delete this recording',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: onDelete,
              ),
            ]),
          if (seg.hasAudio)
            _AudioBar(
              path: seg.audioPath,
              knownDurationMs: seg.durationMs,
              segmentId: seg.id!,
              playback: playback,
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(Icons.delete_sweep_outlined,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Audio deleted after transcription. The text is kept.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ]),
            ),
          if (seg.status == NoteStatus.processing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Text('Transcribing…'),
              ]),
            ),
          if (seg.status == NoteStatus.failed)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(seg.error ?? 'Transcription failed.'),
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                        onPressed: onRetry, child: const Text('Retry')),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AudioBar extends StatefulWidget {
  final String path;

  /// Length recorded when the audio was captured, shown until the recording
  /// is played and the player reports its own.
  final int? knownDurationMs;
  final int segmentId;
  final Playback playback;
  const _AudioBar({
    required this.path,
    this.knownDurationMs,
    required this.segmentId,
    required this.playback,
  });

  @override
  State<_AudioBar> createState() => _AudioBarState();
}

class _AudioBarState extends State<_AudioBar> {
  late bool _missing = !File(widget.path).existsSync();

  @override
  void didUpdateWidget(_AudioBar old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _missing = !File(widget.path).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    if (_missing) return const Text('Audio file is no longer available.');
    final playback = widget.playback;
    final id = widget.segmentId;
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final playing = playback.isPlaying(id);
        final dur = playback.durationOf(id);
        final posMs = playback.positionOf(id);
        final maxMs = dur.inMilliseconds.toDouble();
        final totalMs =
            dur > Duration.zero ? dur.inMilliseconds : widget.knownDurationMs;
        return Row(
          children: [
            IconButton.filled(
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: () => playback.toggle(id, widget.path),
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            Expanded(
              child: Slider(
                value: maxMs <= 0 ? 0 : posMs.clamp(0, maxMs.toInt()).toDouble(),
                max: maxMs <= 0 ? 1 : maxMs,
                onChanged:
                    maxMs <= 0 ? null : (v) => playback.seek(v.toInt()),
              ),
            ),
            Text(
              [
                // Always shown, so the label keeps its width when play starts.
                formatDuration(posMs),
                if (totalMs != null) formatDuration(totalMs),
              ].join(' / '),
              style:
                  const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ],
        );
      },
    );
  }
}

/// The one audio player of a note page. Every recording's bar and the
/// transcript drive it, so a note with fifty recordings still holds a single
/// player, and a tapped line plays whether or not its bar is on screen.
class Playback extends ChangeNotifier {
  AudioPlayer? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  int? _segment;
  int _posMs = 0;
  Duration _dur = Duration.zero;
  PlayerState _state = PlayerState.stopped;
  bool _disposed = false;

  /// The recording playing (or paused), if any.
  int? get segment => _segment;
  int get positionMs => _posMs;

  bool isPlaying(int segmentId) =>
      _segment == segmentId && _state == PlayerState.playing;

  /// Where [segmentId] is in its playback; zero when it is not the one loaded.
  int positionOf(int segmentId) => _segment == segmentId ? _posMs : 0;

  /// The length of [segmentId], known once it is loaded.
  Duration durationOf(int segmentId) =>
      _segment == segmentId ? _dur : Duration.zero;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Created on first use, so opening a note costs no player.
  AudioPlayer _ready() {
    final existing = _player;
    if (existing != null) return existing;
    final player = _player = AudioPlayer();
    _subs
      ..add(player.onPlayerStateChanged.listen((s) {
        _state = s;
        _changed();
      }))
      ..add(player.onPositionChanged.listen((d) {
        _posMs = d.inMilliseconds;
        _changed();
      }))
      ..add(player.onDurationChanged.listen((d) {
        _dur = d;
        _changed();
      }))
      ..add(player.onPlayerComplete.listen((_) {
        _segment = null;
        _posMs = 0;
        _dur = Duration.zero;
        _changed();
      }));
    return player;
  }

  bool get _loaded =>
      _state == PlayerState.playing || _state == PlayerState.paused;

  /// Plays the recording [segmentId], stored at [path], from [ms]. Whatever
  /// else was playing stops.
  Future<void> playAt(int segmentId, String path, int ms) async {
    final player = _ready();
    final same = _segment == segmentId && _loaded;
    _segment = segmentId;
    _posMs = ms;
    if (!same) _dur = Duration.zero;
    _changed();
    try {
      if (same) {
        await player.seek(Duration(milliseconds: ms));
        if (_state == PlayerState.paused) await player.resume();
      } else {
        await player.stop();
        await player.play(DeviceFileSource(path),
            position: Duration(milliseconds: ms));
      }
    } catch (_) {
      // An unreadable file: show it as not playing rather than stuck.
      if (_segment == segmentId) _segment = null;
      _changed();
    }
  }

  /// Play, pause or resume [segmentId].
  Future<void> toggle(int segmentId, String path) async {
    final player = _player;
    if (player != null && _segment == segmentId && _loaded) {
      return _state == PlayerState.playing ? player.pause() : player.resume();
    }
    return playAt(segmentId, path, 0);
  }

  /// Moves the loaded recording to [ms].
  Future<void> seek(int ms) async =>
      _player?.seek(Duration(milliseconds: ms));

  /// Stops [segmentId] if it is the one loaded (it is being deleted).
  Future<void> stopIf(int segmentId) async {
    if (_segment != segmentId) return;
    _segment = null;
    _posMs = 0;
    _dur = Duration.zero;
    _changed();
    try {
      await _player?.stop();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }
}

/// The transcript line by line. The line being played is highlighted, and
/// tapping a line plays the recording from there. Recordings without
/// timestamps show as plain text.
class _TimedTranscript extends StatelessWidget {
  final Note note;
  final bool english;
  final Playback playback;
  const _TimedTranscript(
      {required this.note, required this.english, required this.playback});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style =
        theme.textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.6);
    final done =
        note.segments.where((s) => s.status == NoteStatus.done).toList();
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final children = <Widget>[];
        for (final seg in done) {
          // English needs every line translated to follow along; otherwise
          // fall back to the recording's English text as a whole.
          final timed = seg.lines.isNotEmpty &&
              (!english || seg.lines.every((l) => l.english.isNotEmpty));
          if (children.isNotEmpty) children.add(const SizedBox(height: 12));
          if (!timed) {
            final plain = english && seg.english.trim().isNotEmpty
                ? seg.english
                : seg.transcript;
            if (plain.trim().isNotEmpty) {
              children.add(SelectableText(plain.trim(), style: style));
            }
            continue;
          }
          String? lastSpeaker;
          for (final l in seg.lines) {
            if (l.speaker != null && l.speaker != lastSpeaker) {
              children.add(Padding(
                padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                child: Text(
                  note.speakerLabel(l.speaker!),
                  style: theme.textTheme.labelLarge?.copyWith(
                      color: _speakerColor(scheme, l.speaker!, note),
                      fontWeight: FontWeight.w700),
                ),
              ));
            }
            lastSpeaker = l.speaker;
            final active = playback.segment == seg.id &&
                playback.positionMs >= l.startMs &&
                playback.positionMs < l.endMs;
            children.add(InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: seg.hasAudio
                  ? () => playback.playAt(seg.id!, seg.audioPath, l.startMs)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: active ? scheme.secondaryContainer : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  english ? l.english : l.text,
                  style: style?.copyWith(
                      color: active ? scheme.onSecondaryContainer : null),
                ),
              ),
            ));
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
      },
    );
  }
}

/// A steady colour per voice, so turns are easy to tell apart.
Color _speakerColor(ColorScheme scheme, String id, Note note) {
  final palette = [
    scheme.primary,
    scheme.tertiary,
    scheme.secondary,
    scheme.error,
  ];
  final i = note.speakerIds.indexOf(id);
  return palette[(i < 0 ? 0 : i) % palette.length];
}

/// Sheet to rename the voices heard in a note.
class _SpeakerNames extends StatefulWidget {
  final int noteId;
  const _SpeakerNames({required this.noteId});

  @override
  State<_SpeakerNames> createState() => _SpeakerNamesState();
}

class _SpeakerNamesState extends State<_SpeakerNames> {
  final _controllers = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final note = state.byId(widget.noteId);
    if (note == null) return const SizedBox.shrink();
    final ids = note.speakerIds;
    for (final id in ids) {
      _controllers.putIfAbsent(
          id, () => TextEditingController(text: note.speakerNames[id] ?? ''));
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 0, 24, MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name the speakers',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Tell the voices apart by listening to a few lines. Names appear '
              'in the transcript, copies and subtitles.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (final id in ids) ...[
              TextField(
                controller: _controllers[id],
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Name',
                  hintText: note.speakerLabel(id),
                ),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: () async {
                final nav = Navigator.of(context);
                for (final id in ids) {
                  await state.renameSpeaker(
                      widget.noteId, id, _controllers[id]!.text);
                }
                nav.pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
