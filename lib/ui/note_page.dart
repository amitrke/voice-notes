import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/app_state.dart';
import '../data/clinical_export.dart';
import '../models/note.dart';
import '../providers/ai_provider.dart';
import 'audio_input.dart';
import 'format.dart';
import 'text_size.dart';

class NotePage extends StatefulWidget {
  final int noteId;
  const NotePage({super.key, required this.noteId});

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> {
  bool _showEnglish = false;
  bool _enriching = false;

  Future<void> _enrich(AppState state, int id) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _enriching = true);
    final err = await state.enrichClinical(id);
    if (mounted) setState(() => _enriching = false);
    if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _exportTxt(Note note) async {
    final dir = await getTemporaryDirectory();
    final safe = note.title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
    final file =
        File('${dir.path}/${safe.isEmpty ? 'clinical-note' : safe}.txt');
    await file.writeAsString(clinicalReportText(note));
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
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
    if (ok == true) await state.deleteSegment(note.id!, seg.id!);
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
    final text = showEnglish ? note.english : note.transcript;
    final lang = languageLabel(note.languageCode);

    return Scaffold(
      appBar: AppBar(
        title: Text(note.status == NoteStatus.done && note.title.isNotEmpty
            ? note.title
            : 'Note'),
        actions: [
          if (text.trim().isNotEmpty || note.summary.isNotEmpty)
            Builder(
              builder: (buttonContext) => IconButton(
                tooltip: 'Share',
                icon: Icon(Theme.of(context).platform == TargetPlatform.iOS
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
              }
            },
            itemBuilder: (_) => [
              if (note.status == NoteStatus.done)
                PopupMenuItem(
                    value: 'regenerate',
                    child: Text(note.clinical != null
                        ? 'Regenerate summary and clinical note'
                        : 'Regenerate summary')),
              const PopupMenuItem(
                  value: 'retry', child: Text('Transcribe again')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            [
              formatDate(note.createdAt),
              ?lang,
              ProviderId.values.asNameMap()[note.provider]?.label ??
                  note.provider,
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (note.isStale && note.status != NoteStatus.processing)
            _StaleBanner(
              message: note.clinical != null
                  ? 'Recordings changed after the title, summary and clinical '
                      'note were written, so they may no longer match.'
                  : 'Recordings changed after the title and summary were '
                      'written, so they may no longer match.',
              busy: _regenerating,
              onRegenerate: () => _regenerate(state, note.id!),
            ),
          for (final (i, seg) in note.segments.indexed)
            _SegmentTile(
              key: ValueKey(seg.id),
              index: i,
              segment: seg,
              count: note.segments.length,
              onRetry: () => state.retrySegment(note.id!, seg.id!),
              onDelete: () => _deleteSegment(state, note, seg),
            ),
          Text('Add recording', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => recordAudio(context, noteId: note.id),
                icon: const Icon(Icons.mic, size: 18),
                label: const Text('Record'),
              ),
              OutlinedButton.icon(
                onPressed: () => importAudio(context, noteId: note.id),
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Import'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (note.status == NoteStatus.done ||
              note.transcript.trim().isNotEmpty) ...[
            if (note.summary.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Summary',
                          style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 4),
                      SelectableText(note.summary),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (hasEnglish)
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(lang ?? 'Original')),
                  const ButtonSegment(value: true, label: Text('English')),
                ],
                selected: {showEnglish},
                onSelectionChanged: (s) =>
                    setState(() => _showEnglish = s.first),
              ),
            const SizedBox(height: 12),
            SelectableText(
              text.isEmpty ? 'No speech detected.' : text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            if (text.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _copy(text, showEnglish ? 'English text' : 'Transcript'),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                ),
              ),
            if (note.transcript.trim().isNotEmpty)
              ..._clinicalSection(state, note),
          ],
        ],
      ),
    );
  }
}

extension on _NotePageState {
  List<Widget> _clinicalSection(AppState state, Note note) {
    final c = note.clinical;
    if (c == null) {
      if (!state.settings.clinical) return const [];
      return [
        const Divider(height: 32),
        FilledButton.icon(
          onPressed: _enriching ? null : () => _enrich(state, note.id!),
          icon: _enriching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.medical_services_outlined),
          label: Text(_enriching ? 'Working…' : 'Create clinical note'),
        ),
      ];
    }
    final lang = languageLabel(note.languageCode);
    return [
      const Divider(height: 32),
      Text('Clinical scribe', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (note.isStale)
        _StaleBanner(
          message: 'This clinical note was written before the recordings '
              'changed. Do not rely on it until it is regenerated.',
          busy: _regenerating,
          onRegenerate: () => _regenerate(state, note.id!),
        ),
      if (c.verify.isNotEmpty) _VerifyCard(items: c.verify),
      if (c.interpretation.isNotEmpty)
        _ClinicalCard(
            title: 'Clinical interpretation',
            body: c.interpretation,
            onCopy: () => _copy(c.interpretation, 'Interpretation')),
      if (c.noteEnglish.isNotEmpty)
        _ClinicalCard(
            title: 'Clinical note — English',
            body: c.noteEnglish,
            onCopy: () => _copy(c.noteEnglish, 'Clinical note')),
      if (c.noteNative.isNotEmpty)
        _ClinicalCard(
            title: 'Clinical note — ${lang ?? 'original language'}',
            body: c.noteNative,
            onCopy: () => _copy(c.noteNative, 'Clinical note')),
      const SizedBox(height: 4),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          onPressed: () => _exportTxt(note),
          icon: const Icon(Icons.ios_share, size: 18),
          label: const Text('Export TXT'),
        ),
        OutlinedButton.icon(
          onPressed: () => _copy(clinicalReportText(note), 'Full report'),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy all'),
        ),
      ]),
      const SizedBox(height: 8),
      Text(
        'AI-generated draft. A clinician must review it before use.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }
}

class _ClinicalCard extends StatelessWidget {
  final String title;
  final String body;
  final VoidCallback onCopy;
  const _ClinicalCard(
      {required this.title, required this.body, required this.onCopy});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.labelLarge)),
                IconButton(
                    tooltip: 'Copy',
                    visualDensity: VisualDensity.compact,
                    onPressed: onCopy,
                    icon: const Icon(Icons.copy, size: 18)),
              ]),
              SelectableText(body, style: const TextStyle(height: 1.5)),
            ],
          ),
        ),
      );
}

class _VerifyCard extends StatelessWidget {
  final List<String> items;
  const _VerifyCard({required this.items});

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Verification required',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final i in items) SelectableText('⚠ $i'),
            ],
          ),
        ),
      );
}

class _StaleBanner extends StatelessWidget {
  final String message;
  final bool busy;
  final VoidCallback onRegenerate;
  const _StaleBanner(
      {required this.message, required this.busy, required this.onRegenerate});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.update, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Text('Out of date',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onErrorContainer)),
            ]),
            const SizedBox(height: 4),
            Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy ? null : onRegenerate,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 18),
              label: Text(busy ? 'Working…' : 'Regenerate'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One recording of a note: its player and, until it is done, its status.
class _SegmentTile extends StatelessWidget {
  final int index;
  final int count;
  final Segment segment;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  const _SegmentTile({
    super.key,
    required this.index,
    required this.count,
    required this.segment,
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
          _AudioBar(path: seg.audioPath, knownDurationMs: seg.durationMs),
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

  /// Length recorded when the audio was captured, shown until the player
  /// has loaded the file and reports its own.
  final int? knownDurationMs;
  const _AudioBar({required this.path, this.knownDurationMs});

  @override
  State<_AudioBar> createState() => _AudioBarState();
}

class _AudioBarState extends State<_AudioBar> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<dynamic>>[];
  PlayerState _state = PlayerState.stopped;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _missing = !File(widget.path).existsSync();
    _subs
      ..add(_player.onPlayerStateChanged.listen((s) => setState(() => _state = s)))
      ..add(_player.onPositionChanged.listen((d) => setState(() => _pos = d)))
      ..add(_player.onDurationChanged.listen((d) => setState(() => _dur = d)))
      ..add(_player.onPlayerComplete
          .listen((_) => setState(() => _pos = Duration.zero)));
    // Loading the file up front gives the length (imports don't record one)
    // and lets the slider seek before the first play.
    if (!_missing) _player.setSource(DeviceFileSource(widget.path));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) {
      await _player.pause();
    } else if (_state == PlayerState.paused) {
      await _player.resume();
    } else {
      await _player.play(DeviceFileSource(widget.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_missing) return const Text('Audio file is no longer available.');
    final playing = _state == PlayerState.playing;
    final maxMs = _dur.inMilliseconds.toDouble();
    final totalMs =
        _dur > Duration.zero ? _dur.inMilliseconds : widget.knownDurationMs;
    return Row(
      children: [
        IconButton.filledTonal(
          onPressed: _toggle,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        ),
        Expanded(
          child: Slider(
            value: maxMs <= 0 ? 0 : _pos.inMilliseconds.clamp(0, maxMs.toInt()).toDouble(),
            max: maxMs <= 0 ? 1 : maxMs,
            onChanged: maxMs <= 0
                ? null
                : (v) => _player.seek(Duration(milliseconds: v.toInt())),
          ),
        ),
        Text(
          [
            // Always shown, so the label keeps its width when play starts.
            formatDuration(_pos.inMilliseconds),
            if (totalMs != null) formatDuration(totalMs),
          ].join(' / '),
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}
