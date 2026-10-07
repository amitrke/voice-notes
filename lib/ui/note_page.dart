import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../models/note.dart';
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

  Future<void> _delete(AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text('The transcript and the audio file will be removed.'),
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

    final hasEnglish = note.english.trim().isNotEmpty;
    final showEnglish = _showEnglish && hasEnglish;
    final text = showEnglish ? note.english : note.transcript;
    final lang = languageLabel(note.languageCode);

    return Scaffold(
      appBar: AppBar(
        title: Text(note.status == NoteStatus.done && note.title.isNotEmpty
            ? note.title
            : 'Note'),
        actions: [
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
              } else if (v == 'summary') {
                final messenger = ScaffoldMessenger.of(context);
                final err = await state.regenerateSummary(note.id!);
                if (err != null) {
                  messenger.showSnackBar(SnackBar(content: Text(err)));
                }
              } else if (v == 'retry') {
                await state.retry(note.id!);
              }
            },
            itemBuilder: (_) => [
              if (note.status == NoteStatus.done)
                const PopupMenuItem(
                    value: 'summary', child: Text('Regenerate summary')),
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
              note.provider,
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _AudioBar(path: note.audioPath),
          const SizedBox(height: 16),
          if (note.status == NoteStatus.processing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Column(children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Transcribing…'),
                ]),
              ),
            ),
          if (note.status == NoteStatus.failed)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(note.error ?? 'Transcription failed.'),
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                      onPressed: () => state.retry(note.id!),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          if (note.status == NoteStatus.done) ...[
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
          ],
        ],
      ),
    );
  }
}

class _AudioBar extends StatefulWidget {
  final String path;
  const _AudioBar({required this.path});

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
      ..add(_player.onDurationChanged.listen((d) => setState(() => _dur = d)));
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
        Text(formatDuration(_dur.inMilliseconds)),
      ],
    );
  }
}
