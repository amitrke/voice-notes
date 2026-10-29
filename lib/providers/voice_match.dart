import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'ai_provider.dart';
import 'wav_utils.dart';

/// Speaker id for the lines spoken by the phone's owner, once their voice is
/// recognised. Shown as "You".
const youSpeakerId = 'you';

/// How alike two voiceprints must be (cosine similarity) to count as the
/// same person. The speaker model scores the same voice well above this and
/// different voices well below; in between, a voice is left unnamed.
const sameVoice = 0.5;

/// At most this much of a voice is used to recognise it, to keep it quick.
const _sampleMs = 30 * 1000;
const _rate = 16000;

double cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < math.min(a.length, b.length); i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na == 0 || nb == 0 ? 0 : dot / math.sqrt(na * nb);
}

/// Which of [voices] (speaker id -> voiceprint) is the owner, whose
/// voiceprint is [mine]: the closest one, if it is close enough.
String? pickYou(Map<String, List<double>> voices, List<double> mine) {
  String? best;
  var score = sameVoice;
  for (final e in voices.entries) {
    final s = cosine(e.value, mine);
    if (s >= score) {
      best = e.key;
      score = s;
    }
  }
  return best;
}

/// [lines] with speaker [from] renamed to [youSpeakerId].
List<TimedLine> markAsYou(List<TimedLine> lines, String from) => [
      for (final l in lines)
        l.speaker == from ? l.copyWith(speaker: youSpeakerId) : l,
    ];

/// The voiceprint of the speech in [wav] (16 kHz mono WAV), or null if there
/// is too little of it.
Future<List<double>?> voiceprintOf(String wav, String embeddingModel) =>
    Isolate.run(() {
      sherpa.initBindings();
      final pcm = toMono16k(parseWav(File(wav).readAsBytesSync()));
      if (pcm.length < 3 * _rate) return null;
      return _embed(embeddingModel, [pcmToFloat(pcm, 0, pcm.length)]);
    });

/// Renames the lines spoken by the owner, whose voiceprint is [mine], to
/// [youSpeakerId]. [wav] is the recording [lines] came from, as a 16 kHz
/// mono WAV. Lines stay as they are when no voice matches.
Future<List<TimedLine>> recogniseYou(String wav, List<TimedLine> lines,
    List<double> mine, String embeddingModel) async {
  final ids = {for (final l in lines) ?l.speaker};
  if (ids.isEmpty) return lines;
  final voices = await Isolate.run(() {
    sherpa.initBindings();
    final pcm = toMono16k(parseWav(File(wav).readAsBytesSync()));
    final out = <String, List<double>>{};
    for (final id in ids) {
      final parts = <Float32List>[];
      var ms = 0;
      for (final l in lines.where((l) => l.speaker == id)) {
        if (ms >= _sampleMs) break;
        final start = (l.startMs * _rate ~/ 1000).clamp(0, pcm.length);
        final end = (l.endMs * _rate ~/ 1000).clamp(start, pcm.length);
        if (end - start < _rate ~/ 2) continue;
        parts.add(pcmToFloat(pcm, start, end - start));
        ms += l.endMs - l.startMs;
      }
      final print = parts.isEmpty ? null : _embed(embeddingModel, parts);
      if (print != null) out[id] = print;
    }
    return out;
  });
  final you = pickYou(voices, mine);
  return you == null ? lines : markAsYou(lines, you);
}

/// Runs in a background isolate.
List<double>? _embed(String model, List<Float32List> parts) {
  final extractor = sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(
          model: model, numThreads: 2, debug: false));
  final stream = extractor.createStream();
  try {
    for (final p in parts) {
      stream.acceptWaveform(samples: p, sampleRate: _rate);
    }
    stream.inputFinished();
    if (!extractor.isReady(stream)) return null;
    return extractor.compute(stream).toList();
  } finally {
    stream.free();
    extractor.free();
  }
}
