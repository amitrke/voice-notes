import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/ai_provider.dart';
import '../services/recorder_service.dart';
import 'format.dart';
import 'theme.dart';

/// Full-screen recorder that records until the user taps stop. Pops with a
/// [RecordingResult], or null when cancelled.
class RecordScreen extends StatefulWidget {
  final RecordingFormat format;
  const RecordScreen({super.key, required this.format});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

/// How many recent input levels the meter shows.
const _meterBars = 40;

class _RecordScreenState extends State<RecordScreen> {
  final _recorder = RecorderService();
  Timer? _ticker;
  StreamSubscription<double>? _levelSub;
  final _levels = List<double>.filled(_meterBars, 0, growable: true);
  final _clock = Stopwatch();
  String? _error;
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    try {
      await _recorder.start(widget.format);
      _clock.start();
      _levelSub = _recorder.levels().listen((v) {
        _levels
          ..removeAt(0)
          ..add(v);
      });
      _ticker = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => setState(() {}),
      );
      setState(() => _recording = true);
    } on MicPermissionDenied {
      setState(
        () => _error = 'Microphone access is off. Enable it for Voice Notes in system settings.',
      );
    } catch (e) {
      setState(() => _error = 'Could not start recording: $e');
    }
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    await _levelSub?.cancel();
    final result = await _recorder.stop();
    if (mounted) Navigator.pop(context, result);
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
    if (_recording) await _recorder.cancel();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _levelSub?.cancel();
    _recorder.dispose();
    super.dispose();
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
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              formatDuration(_clock.elapsedMilliseconds),
                              style: textTheme.displayLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(height: 40),
                            ExcludeSemantics(
                              child: SizedBox(
                                height: 120,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    for (final v in _levels)
                                      Container(
                                        width: 4,
                                        height: 6 + v * 110,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: fg,
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 40),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 40,
                              ),
                              child: Text(
                                'Speak in any language.',
                                textAlign: TextAlign.center,
                                style: textTheme.bodyMedium?.copyWith(
                                  color: muted,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
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
