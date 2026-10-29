import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/templates.dart';
import '../models/note.dart';
import '../providers/ai_provider.dart';
import '../services/background_recording.dart';
import '../services/recorder_service.dart';
import 'format.dart';
import 'templates_ui.dart';
import 'theme.dart';

/// Full-screen recorder that records until the user taps stop. The recording
/// is saved in parts (see [shouldSplit]), each transcribed while recording
/// goes on, so an hour-long meeting works like a short note. Adds them to
/// note [noteId], or to a new note, and pops with that note's id, or null
/// when cancelled.
class RecordScreen extends StatefulWidget {
  final RecordingFormat format;
  final int? noteId;
  const RecordScreen({super.key, required this.format, this.noteId});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

/// How many recent input levels the meter shows.
const _meterBars = 40;

class _RecordScreenState extends State<RecordScreen> {
  final _recorder = RecorderService();
  late final AppState _state = context.read<AppState>();
  Timer? _ticker;
  StreamSubscription<double>? _levelSub;
  final _levels = List<double>.filled(_meterBars, 0, growable: true);
  final _clock = Stopwatch();
  final _quiet = Stopwatch();
  String? _error;
  bool _recording = false;
  bool _splitting = false;

  /// The note the parts go to; set once the first part is saved.
  late int? _noteId = widget.noteId;

  /// Parts added to an existing note, removed again on cancel.
  final _added = <int>[];
  int _parts = 0;

  /// The template whose notes build up while recording, if any.
  NoteTemplate? _liveNotes;

  @override
  void initState() {
    super.initState();
    _liveNotes = _state.settings.liveNotesTemplate;
    if (widget.noteId != null) {
      _state.beginLive(widget.noteId!, liveNotes: _liveNotes);
    }
    _begin();
  }

  Future<void> _begin() async {
    try {
      await _recorder.start(widget.format);
      await keepRecordingInBackground(true);
      _clock.start();
      _levelSub = _recorder.levels().listen((v) {
        _levels
          ..removeAt(0)
          ..add(v);
        if (v < quietLevel) {
          if (!_quiet.isRunning) _quiet.start();
        } else {
          _quiet
            ..stop()
            ..reset();
        }
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _maybeSplit();
        setState(() {});
      });
      setState(() => _recording = true);
    } on MicPermissionDenied {
      setState(
        () => _error = 'Microphone access is off. Enable it for Voice Notes in system settings.',
      );
    } catch (e) {
      setState(() => _error = 'Could not start recording: $e');
    }
  }

  void _maybeSplit() {
    final started = _recorder.partStartedAt;
    if (_splitting || started == null) return;
    if (!shouldSplit(DateTime.now().difference(started), _quiet.elapsed)) {
      return;
    }
    _splitting = true;
    _recorder.split().then((part) async {
      if (part != null) await _addPart(part);
    }).whenComplete(() => _splitting = false);
  }

  /// Saves a finished part; it is transcribed in the background.
  Future<void> _addPart(RecordingResult part) async {
    // A sliver left over at the end is not worth a request.
    if (_parts > 0 && part.durationMs < 1000) {
      try {
        await File(part.path).delete();
      } catch (_) {}
      return;
    }
    _parts++;
    if (_noteId == null) {
      final n = await _state.addAudio(part.path,
          durationMs: part.durationMs, live: true, liveNotes: _liveNotes);
      _noteId = n.id;
    } else {
      final seg = await _state.addSegment(_noteId!, part.path,
          durationMs: part.durationMs);
      if (seg != null && widget.noteId != null) _added.add(seg.id!);
    }
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    await _levelSub?.cancel();
    while (_splitting) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final part = await _recorder.stop();
    await keepRecordingInBackground(false);
    if (part != null) await _addPart(part);
    final id = _noteId;
    // Waits for the last parts and then writes the summary; no need to hold
    // the screen open for it.
    if (id != null) unawaited(_state.endLive(id));
    if (mounted) Navigator.pop(context, id);
  }

  Future<void> _pickLiveNotes() async {
    final picked = await showModalBottomSheet<_LiveChoice>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('Notes while you record',
                    style: Theme.of(sheet).textTheme.titleMedium),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.notes_outlined),
                title: const Text('Off'),
                subtitle: const Text('Just the transcript, then a summary'),
                trailing: _liveNotes == null ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sheet, const _LiveChoice(null)),
              ),
              for (final t in _state.settings.enabledTemplates
                  .where((t) => !t.isClinical && t.id != speakingTemplateId))
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  leading: Icon(templateIcon(t.id)),
                  title: Text(t.name),
                  subtitle:
                      Text(t.blurb.isNotEmpty ? t.blurb : 'Your template'),
                  trailing:
                      _liveNotes?.id == t.id ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(sheet, _LiveChoice(t)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                child: Text(
                  'Updated every few minutes, about a dozen requests an hour, '
                  'then rewritten from the full transcript when you stop.',
                  style: Theme.of(sheet).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _liveNotes = picked.template);
    await _state.settings.setLiveNotes(picked.template?.id);
    final id = _noteId;
    if (id != null) _state.live(id)?.liveNotes = picked.template;
  }

  /// Recordings shorter than this are discarded without asking.
  static const _confirmAfter = Duration(seconds: 5);

  Future<void> _cancel() async {
    if (_recording && _clock.elapsed >= _confirmAfter) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard this recording?'),
          content: Text(
            'The ${formatDuration(_clock.elapsedMilliseconds)} you have '
            'recorded will be lost.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep recording'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    _ticker?.cancel();
    await _levelSub?.cancel();
    while (_splitting) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_recording) await _recorder.cancel();
    await keepRecordingInBackground(false);
    final id = _noteId;
    if (id != null) {
      await _state.endLive(id, discard: true);
      if (widget.noteId == null) {
        await _state.delete(id);
      } else {
        for (final s in _added) {
          await _state.deleteSegment(id, s);
        }
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _levelSub?.cancel();
    _recorder.dispose();
    keepRecordingInBackground(false);
    super.dispose();
  }

  /// Parts transcribed so far, the last words heard, and the live notes.
  List<Widget> _progress(TextTheme text, Color fg, Color muted) {
    final id = _noteId;
    final note = id == null ? null : context.watch<AppState>().byId(id);
    final session = id == null ? null : _state.live(id);
    final known = session?.knownSegments ?? const <int>{};
    final mine = note?.segments.where((s) => !known.contains(s.id)).toList() ??
        const <Segment>[];
    final done = mine.where((s) => s.status == NoteStatus.done).toList();
    final failed = mine.where((s) => s.status == NoteStatus.failed).length;
    final heard = done.isEmpty ? '' : done.last.transcript.trim();
    final out = _liveNotes == null ? null : note?.output(_liveNotes!.id);
    final card = BoxDecoration(
      color: Colors.white.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(12),
    );
    final label = text.labelMedium?.copyWith(color: muted);
    return [
      if (mine.isNotEmpty)
        Text(
          '${done.length} of ${mine.length} '
          '${mine.length == 1 ? 'part' : 'parts'} transcribed'
          '${failed > 0 ? ' · $failed failed, kept to retry' : ''}',
          style: label,
        ),
      if (heard.isNotEmpty) ...[
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: card,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Just heard', style: label),
              const SizedBox(height: 4),
              Text(
                heard.length > 160
                    ? '…${heard.substring(heard.length - 160)}'
                    : heard,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(color: fg, height: 1.4),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 12),
      Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _pickLiveNotes,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: card,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _liveNotes == null
                            ? 'Live notes: off'
                            : 'Live notes: ${_liveNotes!.name}',
                        style: label,
                      ),
                    ),
                    Text(
                      session?.updating == true
                          ? 'Updating…'
                          : session?.updatedAt != null
                              ? 'Updated ${_ago(session!.updatedAt!)}'
                              : _liveNotes == null
                                  ? 'Turn on'
                                  : 'First update in a few minutes',
                      style: label,
                    ),
                  ],
                ),
                if (session?.error != null) ...[
                  const SizedBox(height: 4),
                  Text(session!.error!,
                      style: text.bodySmall
                          ?.copyWith(color: const Color(0xFFFF8A7E))),
                ],
                if (out != null)
                  for (final s in out.sections) ...[
                    const SizedBox(height: 8),
                    if (s.heading.isNotEmpty)
                      Text(s.heading,
                          style: text.titleSmall?.copyWith(color: fg)),
                    Text(s.body,
                        style:
                            text.bodyMedium?.copyWith(color: fg, height: 1.4)),
                  ],
              ],
            ),
          ),
        ),
      ),
    ];
  }

  static String _ago(DateTime t) {
    final m = DateTime.now().difference(t).inMinutes;
    return m < 1 ? 'just now' : '$m min ago';
  }

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFFF2F3F1);
    const muted = Color(0xFFA9AFB8);
    final theme = Theme.of(context);
    final textTheme = theme.textTheme.apply(bodyColor: fg, displayColor: fg);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: recorderBackground,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
            child: _error != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.mic_off,
                        size: 48,
                        color: Color(0xFFFF8A7E),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: fg,
                          foregroundColor: recorderBackground,
                        ),
                        onPressed: _cancel,
                        child: const Text('Close'),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Row(
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFC8CCD2),
                              minimumSize: const Size(64, 44),
                              textStyle: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onPressed: _cancel,
                            child: const Text('Cancel'),
                          ),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_recording)
                                  Container(
                                    width: 10,
                                    height: 10,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFFF5A4A),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                Text(
                                  _recording ? 'Recording' : 'Starting…',
                                  style: textTheme.labelLarge?.copyWith(
                                    color: const Color(0xFFFF8A7E),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Balances the Cancel button so the label centres.
                          const SizedBox(width: 80),
                        ],
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Column(
                            children: [
                              const SizedBox(height: 32),
                              Text(
                                formatDuration(_clock.elapsedMilliseconds),
                                style: textTheme.displayLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 32),
                              ExcludeSemantics(
                                child: SizedBox(
                                  height: 100,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      for (final v in _levels)
                                        Container(
                                          width: 4,
                                          height: 6 + v * 90,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: fg,
                                            borderRadius:
                                                BorderRadius.circular(2),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 32),
                              Text(
                                _clock.elapsed < const Duration(minutes: 1)
                                    ? 'Speak in any language.'
                                    : 'Recording other people? Let them know.',
                                textAlign: TextAlign.center,
                                style: textTheme.bodyMedium?.copyWith(
                                  color: muted,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 20),
                              ..._progress(textTheme, fg, muted),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Semantics(
                        button: true,
                        label: 'Stop and save',
                        excludeSemantics: true,
                        child: InkResponse(
                          onTap: _recording ? _stop : null,
                          radius: 48,
                          child: Container(
                            width: 88,
                            height: 88,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: fg, width: 4),
                            ),
                            alignment: Alignment.center,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: _recording
                                    ? const Color(0xFFFF5A4A)
                                    : muted,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Stop and save',
                        style: textTheme.labelLarge?.copyWith(
                          color: const Color(0xFFC8CCD2),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _LiveChoice {
  final NoteTemplate? template;
  const _LiveChoice(this.template);
}
