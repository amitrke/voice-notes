import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import '../data/notes_db.dart';
import '../providers/ai_provider.dart';

class RecordingResult {
  final String path;
  final int durationMs;
  const RecordingResult(this.path, this.durationMs);
}

class MicPermissionDenied implements Exception {
  const MicPermissionDenied();
  @override
  String toString() => 'Microphone permission was denied.';
}

/// A recording is saved in parts so each can be transcribed while recording
/// goes on. A part ends at the first pause once it is [splitAfter] long, or at
/// [splitBy] whatever is being said.
const splitAfter = Duration(seconds: 60);
const splitBy = Duration(minutes: 3);

/// How long the input must stay quiet to count as a pause.
const pauseLength = Duration(milliseconds: 700);

/// Input level (see [RecorderService.levels]) below which it counts as quiet.
const quietLevel = 0.3;

/// Whether to end the current part, [part] long, after [quiet] of quiet.
bool shouldSplit(Duration part, Duration quiet) =>
    part >= splitBy || (part >= splitAfter && quiet >= pauseLength);

class RecorderService {
  final AudioRecorder _rec = AudioRecorder();
  DateTime? _startedAt;
  RecordingFormat? _format;

  /// When the part being recorded now began.
  DateTime? get partStartedAt => _startedAt;

  Future<void> start(RecordingFormat format) async {
    _format = format;
    if (!await _rec.hasPermission()) throw const MicPermissionDenied();
    final dir = await audioDir();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final wav = format == RecordingFormat.wav16kMono;
    final path = p.join(dir.path, 'rec_$stamp.${wav ? 'wav' : 'm4a'}');
    await _rec.start(
      wav
          ? const RecordConfig(
              encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1)
          : const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
      path: path,
    );
    _startedAt = DateTime.now();
  }

  Future<RecordingResult?> stop() async {
    final path = await _rec.stop();
    final started = _startedAt;
    _startedAt = null;
    if (path == null || started == null) return null;
    return RecordingResult(
        path, DateTime.now().difference(started).inMilliseconds);
  }

  /// Ends the part being recorded and starts the next one straight away.
  Future<RecordingResult?> split() async {
    final format = _format;
    final done = await stop();
    if (format != null) await start(format);
    return done;
  }

  /// Input level from 0 (silence) to 1 (loud), sampled every [interval].
  Stream<double> levels(
          {Duration interval = const Duration(milliseconds: 100)}) =>
      _rec
          .onAmplitudeChanged(interval)
          .map((a) => ((a.current + 50) / 50).clamp(0.0, 1.0));

  Future<void> cancel() async {
    _startedAt = null;
    await _rec.cancel();
  }

  Future<void> dispose() => _rec.dispose();
}
