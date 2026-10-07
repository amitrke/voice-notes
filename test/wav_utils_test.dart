import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_notes/providers/wav_utils.dart';

void main() {
  const fmt = WavFormat(1, 16000, 16);

  Uint8List pcmSeconds(int s) => Uint8List(fmt.bytesPerSecond * s);

  test('short audio is returned untouched', () {
    final wav = buildWav(fmt, pcmSeconds(10));
    expect(splitWav(wav), hasLength(1));
  });

  test('60 s audio splits into 25 s chunks that each parse as WAV', () {
    final wav = buildWav(fmt, pcmSeconds(60));
    final chunks = splitWav(wav, seconds: 25);
    expect(chunks, hasLength(3));
    final lengths = chunks.map((c) => parseWav(c).pcm.length).toList();
    expect(lengths[0], fmt.bytesPerSecond * 25);
    expect(lengths[1], fmt.bytesPerSecond * 25);
    expect(lengths[2], fmt.bytesPerSecond * 10);
    expect(lengths.reduce((a, b) => a + b), fmt.bytesPerSecond * 60);
    expect(parseWav(chunks.first).format.sampleRate, 16000);
  });

  test('chunks do not cut samples in half', () {
    final wav = buildWav(fmt, pcmSeconds(30));
    for (final c in splitWav(wav, seconds: 7)) {
      expect(parseWav(c).pcm.length % fmt.blockAlign, 0);
    }
  });

  test('streaming header with data size 0 reads to end of file', () {
    final wav = buildWav(fmt, pcmSeconds(2));
    ByteData.sublistView(wav).setUint32(40, 0, Endian.little);
    expect(parseWav(wav).pcm.length, fmt.bytesPerSecond * 2);
  });

  test('rejects non-WAV input', () {
    expect(() => parseWav(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()));
  });
}
