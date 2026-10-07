import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/ai_provider.dart';
import '../services/recorder_service.dart';
import 'format.dart';

/// Bottom sheet that records until the user taps stop. Pops with a
/// [RecordingResult], or null when cancelled.
class RecordSheet extends StatefulWidget {
  final RecordingFormat format;
  const RecordSheet({super.key, required this.format});

  @override
  State<RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<RecordSheet> {
  final _recorder = RecorderService();
  Timer? _ticker;
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
      _ticker = Timer.periodic(
          const Duration(milliseconds: 250), (_) => setState(() {}));
      setState(() => _recording = true);
    } on MicPermissionDenied {
      setState(() => _error =
          'Microphone access is off. Enable it for Voice Notes in system settings.');
    } catch (e) {
      setState(() => _error = 'Could not start recording: $e');
    }
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    final result = await _recorder.stop();
    if (mounted) Navigator.pop(context, result);
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    if (_recording) await _recorder.cancel();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              Icon(Icons.mic_off, size: 40, color: scheme.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _cancel, child: const Text('Close')),
            ] else ...[
              Text(
                formatDuration(_clock.elapsedMilliseconds),
                style: Theme.of(context)
                    .textTheme
                    .displayMedium
                    ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const SizedBox(height: 4),
              Text(_recording ? 'Recording…' : 'Starting…'),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(onPressed: _cancel, child: const Text('Cancel')),
                  const SizedBox(width: 24),
                  FloatingActionButton.large(
                    onPressed: _recording ? _stop : null,
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                    child: const Icon(Icons.stop_rounded, size: 40),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
