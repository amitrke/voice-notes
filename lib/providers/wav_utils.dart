import 'dart:typed_data';

class WavFormat {
  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  const WavFormat(this.channels, this.sampleRate, this.bitsPerSample);

  int get blockAlign => channels * bitsPerSample ~/ 8;
  int get bytesPerSecond => sampleRate * blockAlign;
}

class WavData {
  final WavFormat format;
  final Uint8List pcm;
  const WavData(this.format, this.pcm);
}

/// Parses a PCM WAV file by walking its chunks. Tolerates streaming headers
/// whose data-chunk size is 0 or 0xFFFFFFFF by reading to the end of file.
WavData parseWav(Uint8List b) {
  if (b.length < 12 ||
      String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('Not a WAV file');
  }
  final bd = ByteData.sublistView(b);
  WavFormat? fmt;
  var pos = 12;
  while (pos + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(pos, pos + 4));
    final size = bd.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      fmt = WavFormat(
        bd.getUint16(body + 2, Endian.little),
        bd.getUint32(body + 4, Endian.little),
        bd.getUint16(body + 14, Endian.little),
      );
    } else if (id == 'data') {
      if (fmt == null) throw const FormatException('WAV data before fmt');
      final remaining = b.length - body;
      final len = (size == 0 || size == 0xFFFFFFFF || size > remaining)
          ? remaining
          : size;
      return WavData(fmt, Uint8List.sublistView(b, body, body + len));
    }
    pos = body + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('WAV has no data chunk');
}

Uint8List buildWav(WavFormat f, Uint8List pcm) {
  final out = ByteData(44 + pcm.length);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, f.channels, Endian.little);
  out.setUint32(24, f.sampleRate, Endian.little);
  out.setUint32(28, f.bytesPerSecond, Endian.little);
  out.setUint16(32, f.blockAlign, Endian.little);
  out.setUint16(34, f.bitsPerSample, Endian.little);
  tag(36, 'data');
  out.setUint32(40, pcm.length, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(44, 44 + pcm.length, pcm);
  return bytes;
}

/// Splits a WAV into standalone WAV files of at most [seconds] each.
List<Uint8List> splitWav(Uint8List wav, {int seconds = 25}) {
  final data = parseWav(wav);
  final f = data.format;
  var chunkBytes = f.bytesPerSecond * seconds;
  chunkBytes -= chunkBytes % f.blockAlign;
  if (data.pcm.length <= chunkBytes) return [wav];
  final chunks = <Uint8List>[];
  for (var i = 0; i < data.pcm.length; i += chunkBytes) {
    final end = (i + chunkBytes).clamp(0, data.pcm.length);
    chunks.add(buildWav(f, Uint8List.sublistView(data.pcm, i, end)));
  }
  return chunks;
}
