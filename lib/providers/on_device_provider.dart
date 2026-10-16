import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../services/model_store.dart';
import 'ai_provider.dart';
import 'speaker_assign.dart';
import 'wav_utils.dart';

/// Whisper on the phone through sherpa-onnx. Whisper reads at most 30 s at a
/// time, so voice activity detection first cuts the recording into speech
/// pieces; each piece becomes one [TimedLine]. All of it runs in a background
/// isolate so the UI stays responsive.
class OnDeviceProvider implements AiProvider {
  final InstalledModel model;

  /// Converts non-WAV audio to a 16 kHz mono WAV file (null = cannot).
  final Future<File?> Function(File)? toWav;

  /// Models that tell voices apart; null when not downloaded, in which case
  /// lines come without speaker labels.
  final InstalledSpeakerModels? speakerModels;

  OnDeviceProvider({required this.model, this.toWav, this.speakerModels});

  @override
  ProviderId get id => ProviderId.onDevice;

  @override
  RecordingFormat get recordingFormat => RecordingFormat.wav16kMono;

  /// One recording at a time: each run loads the model into memory, and two
  /// copies of a large model at once can exhaust a phone's memory.
  static Future<void> _queue = Future.value();

  @override
  Future<Transcription> transcribe(File audio,
      {required bool translate,
      List<String> vocabulary = const [],
      bool speakers = false}) {
    final run = _queue.then((_) => _transcribe(audio, translate, speakers));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Transcription> _transcribe(
      File audio, bool translate, bool speakers) async {
    for (final path in [
      model.encoder,
      if (model.decoder.isNotEmpty) model.decoder,
      model.tokens,
      model.vad,
    ]) {
      if (!File(path).existsSync()) {
        throw const ProviderException(
            'The offline model is missing. Download it again in Settings.');
      }
    }
    // A missing speaker model only costs the labels, not the transcript.
    final diarize = speakers ? speakerModels : null;
    final canDiarize = diarize != null &&
        File(diarize.segmentation).existsSync() &&
        File(diarize.embedding).existsSync();
    File wav = audio;
    File? temp;
    if (p.extension(audio.path).toLowerCase() != '.wav') {
      temp = await toWav?.call(audio);
      if (temp == null) {
        throw const ProviderException(
            'This audio format could not be decoded on the device.');
      }
      wav = temp;
    }
    final job = _Job(
      wav: wav.path,
      encoder: model.encoder,
      decoder: model.decoder,
      tokens: model.tokens,
      vad: model.vad,
      kind: model.kind,
      language: model.model.language,
      translate: translate && model.model.canTranslate,
      segmentationModel: canDiarize ? diarize.segmentation : null,
      embeddingModel: canDiarize ? diarize.embedding : null,
      threads: math.min(4, math.max(1, Platform.numberOfProcessors ~/ 2)),
    );
    try {
      return await _inBackground(job);
    } on FormatException catch (e) {
      throw ProviderException('Could not read the recording: ${e.message}');
    } finally {
      if (temp != null) {
        try {
          await temp.delete();
        } catch (_) {}
      }
    }
  }

  @override
  Future<NoteSummary> summarize(String text,
          {List<String> tags = const []}) =>
      throw _noText;

  @override
  Future<String> completeJson(String prompt) => throw _noText;

  static const _noText = ProviderException(
      'On-device transcription has no text model. Choose a text provider '
      'under Settings > Titles, summaries and tags.');
}

class _Job {
  final String wav, encoder, decoder, tokens, vad;
  final bool translate;
  final int threads;
  final ModelKind kind;

  /// The one language of a single-language model.
  final String? language;

  /// Set when speakers are to be told apart.
  final String? segmentationModel, embeddingModel;
  const _Job({
    required this.wav,
    required this.encoder,
    required this.decoder,
    required this.tokens,
    required this.vad,
    required this.translate,
    required this.threads,
    this.kind = ModelKind.whisper,
    this.language,
    this.segmentationModel,
    this.embeddingModel,
  });
}

const _rate = 16000;

/// A top-level function, so the isolate's closure captures only [job].
Future<Transcription> _inBackground(_Job job) => Isolate.run(() => _run(job));

/// Runs in the background isolate.
Transcription _run(_Job job) {
  sherpa.initBindings();
  final pcm = toMono16k(parseWav(File(job.wav).readAsBytesSync()));
  final pieces = speechPieces(pcm, job.vad);
  if (pieces.isEmpty) return const Transcription(text: '');

  // CTC models know their language (or, for Omnilingual, do not report it).
  final language = job.kind == ModelKind.whisper
      ? _detectLanguage(job, pcm, pieces)
      : (job.language ?? '');
  final native = job.kind == ModelKind.whisper
      ? _decodeAll(job, pcm, pieces, language, 'transcribe')
      : _decodeCtc(job, pcm, pieces);
  // Translating English to English would only paraphrase it.
  final english = job.translate && language != 'en'
      ? _decodeAll(job, pcm, pieces, language, 'translate')
      : null;

  final lines = <TimedLine>[];
  for (var i = 0; i < pieces.length; i++) {
    final text = native[i];
    final en = english?[i] ?? '';
    if (text.isEmpty && en.isEmpty) continue;
    lines.add(TimedLine(
      pieces[i].start * 1000 ~/ _rate,
      (pieces[i].start + pieces[i].length) * 1000 ~/ _rate,
      text,
      english: en,
    ));
  }
  String join(Iterable<String> parts) =>
      parts.where((t) => t.isNotEmpty).join(' ');
  return Transcription(
    text: join(lines.map((l) => l.text)),
    english: english == null ? '' : join(lines.map((l) => l.english)),
    languageCode: language.isEmpty ? null : language,
    lines: job.segmentationModel == null
        ? lines
        : assignSpeakers(lines, _diarize(job, pcm)),
  );
}

/// Longest recording the speaker models are run on: they take the whole
/// recording as one array, which gets large for hours of audio.
const _maxDiarizeSamples = 45 * 60 * _rate;

/// Who talks when, from the whole recording. Empty when the recording is too
/// long, or the models fail: the transcript is still good without labels.
List<SpeakerTurn> _diarize(_Job job, Int16List pcm) {
  if (pcm.length > _maxDiarizeSamples) return const [];
  sherpa.OfflineSpeakerDiarization? diarizer;
  try {
    diarizer = sherpa.OfflineSpeakerDiarization(
      sherpa.OfflineSpeakerDiarizationConfig(
        segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
          pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
              model: job.segmentationModel!),
          numThreads: job.threads,
          debug: false,
        ),
        embedding: sherpa.SpeakerEmbeddingExtractorConfig(
            model: job.embeddingModel!, numThreads: job.threads, debug: false),
        // Unknown number of speakers: the threshold decides how many.
        clustering: const sherpa.FastClusteringConfig(threshold: 0.5),
        minDurationOn: 0.2,
        minDurationOff: 0.5,
      ),
    );
    final segments =
        diarizer.process(samples: pcmToFloat(pcm, 0, pcm.length));
    return [
      for (final s in segments)
        (
          startMs: (s.start * 1000).round(),
          endMs: (s.end * 1000).round(),
          speaker: s.speaker,
        ),
    ];
  } catch (_) {
    return const [];
  } finally {
    diarizer?.free();
  }
}

/// Where speech is, in samples.
typedef Piece = ({int start, int length});

List<Piece> speechPieces(Int16List pcm, String vadModel) {
  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: vadModel,
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        // Well under Whisper's 30 s window, and short enough to make useful
        // lines for following along during playback.
        maxSpeechDuration: 20,
      ),
      sampleRate: _rate,
      debug: false,
    ),
    bufferSizeInSeconds: 60,
  );
  final pieces = <Piece>[];
  void drain() {
    while (!vad.isEmpty()) {
      final s = vad.front();
      pieces.add((start: s.start, length: s.samples.length));
      vad.pop();
    }
  }

  const window = 512;
  for (var i = 0; i < pcm.length; i += window) {
    vad.acceptWaveform(pcmToFloat(pcm, i, window));
    drain();
  }
  vad.flush();
  drain();
  vad.free();
  return padPieces(pieces, pcm.length);
}

/// Widens each piece by up to [pad] samples on both sides without
/// overlapping its neighbours. Detection starts a little after speech does,
/// and without this the first word of a sentence can be lost.
List<Piece> padPieces(List<Piece> pieces, int total, {int pad = _rate ~/ 4}) {
  final out = <Piece>[];
  for (var i = 0; i < pieces.length; i++) {
    final prevEnd = out.isEmpty ? 0 : out.last.start + out.last.length;
    final nextStart = i + 1 < pieces.length ? pieces[i + 1].start : total;
    final start = math.max(prevEnd, pieces[i].start - pad);
    final end = math.min(nextStart, pieces[i].start + pieces[i].length + pad);
    out.add((start: start, length: end - start));
  }
  return out;
}

/// Whisper's language code ("hi", "en", ...) from up to 30 s of speech, or
/// '' if it could not tell.
String _detectLanguage(_Job job, Int16List pcm, List<Piece> pieces) {
  final lid = sherpa.SpokenLanguageIdentification(
    sherpa.SpokenLanguageIdentificationConfig(
      whisper: sherpa.SpokenLanguageIdentificationWhisperConfig(
          encoder: job.encoder, decoder: job.decoder),
      numThreads: job.threads,
    ),
  );
  try {
    final sample = <double>[];
    for (final piece in pieces) {
      final room = 30 * _rate - sample.length;
      if (room <= 0) break;
      sample.addAll(pcmToFloat(pcm, piece.start, math.min(piece.length, room)));
    }
    final stream = lid.createStream();
    stream.acceptWaveform(
        samples: Float32List.fromList(sample), sampleRate: _rate);
    final lang = lid.compute(stream).lang.trim();
    stream.free();
    return lang;
  } finally {
    lid.free();
  }
}

List<String> _decodeAll(_Job job, Int16List pcm, List<Piece> pieces,
    String language, String task) {
  final recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: job.encoder,
        decoder: job.decoder,
        language: language,
        task: task,
      ),
      tokens: job.tokens,
      modelType: 'whisper',
      numThreads: job.threads,
      debug: false,
    ),
  ));
  try {
    return [
      for (final piece in pieces) _decode(recognizer, pcm, piece),
    ];
  } finally {
    recognizer.free();
  }
}

/// Single-file CTC models (IndicConformer, Omnilingual): no language or task
/// to pass in, just the model and its token list.
List<String> _decodeCtc(_Job job, Int16List pcm, List<Piece> pieces) {
  final model = job.kind == ModelKind.omnilingual
      ? sherpa.OfflineModelConfig(
          omnilingual:
              sherpa.OfflineOmnilingualAsrCtcModelConfig(model: job.encoder),
          tokens: job.tokens,
          numThreads: job.threads,
          debug: false,
        )
      : sherpa.OfflineModelConfig(
          nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: job.encoder),
          tokens: job.tokens,
          modelType: 'nemo_ctc',
          numThreads: job.threads,
          debug: false,
        );
  final recognizer =
      sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(model: model));
  try {
    return [for (final piece in pieces) _decode(recognizer, pcm, piece)];
  } finally {
    recognizer.free();
  }
}

String _decode(sherpa.OfflineRecognizer r, Int16List pcm, Piece piece) {
  final stream = r.createStream();
  try {
    stream.acceptWaveform(
        samples: pcmToFloat(pcm, piece.start, piece.length), sampleRate: _rate);
    r.decode(stream);
    return r.getResult(stream).text.trim();
  } finally {
    stream.free();
  }
}
