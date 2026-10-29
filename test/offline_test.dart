import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/srt_export.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/on_device_provider.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/providers/openai_provider.dart';
import 'package:voice_notes/providers/wav_utils.dart';
import 'package:voice_notes/services/model_store.dart';

ModelFile _file(String name, List<int> bytes) => ModelFile(
    name, 'https://example.test/$name', bytes.length, sha256.convert(bytes).toString());

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('offline_test'));
  tearDown(() async => tmp.delete(recursive: true));

  group('ModelStore', () {
    final content = {
      'enc.onnx': utf8.encode('encoder bytes'),
      'dec.onnx': utf8.encode('decoder bytes, a bit longer'),
      'tokens.txt': utf8.encode('tokens'),
      'vad.onnx': utf8.encode('vad'),
    };
    final model = OfflineModel(
      id: 'tiny',
      label: 'Tiny',
      blurb: '',
      encoder: _file('enc.onnx', content['enc.onnx']!),
      decoder: _file('dec.onnx', content['dec.onnx']!),
      tokens: _file('tokens.txt', content['tokens.txt']!),
    );
    final vad = _file('vad.onnx', content['vad.onnx']!);

    ModelStore store(MockClient client) => ModelStore(
          baseDir: () async => tmp,
          client: () => client,
          catalog: [model],
          vad: vad,
        );

    test('downloads, verifies and installs every file', () async {
      final asked = <String>[];
      final s = store(MockClient((req) async {
        final name = req.url.pathSegments.last;
        asked.add(name);
        return http.Response.bytes(content[name]!, 200);
      }));
      await s.load();
      expect(s.isInstalled('tiny'), isFalse);

      expect(await s.download('tiny'), isNull);
      expect(s.isInstalled('tiny'), isTrue);
      expect(asked, ['enc.onnx', 'dec.onnx', 'tokens.txt', 'vad.onnx']);
      final m = s.installed('tiny')!;
      expect(await File(m.decoder).readAsString(), 'decoder bytes, a bit longer');
      expect(File('${m.decoder}.part').existsSync(), isFalse);

      // A fresh store finds it on disk.
      final again = store(MockClient((_) async => http.Response('', 500)));
      await again.load();
      expect(again.isInstalled('tiny'), isTrue);
    });

    test('a damaged file is removed and the model is not installed', () async {
      final s = store(MockClient((req) async {
        final name = req.url.pathSegments.last;
        final bytes = List<int>.from(content[name]!);
        if (name == 'dec.onnx') bytes[0] ^= 1; // Same size, wrong hash.
        return http.Response.bytes(bytes, 200);
      }));
      await s.load();
      final err = await s.download('tiny');
      expect(err, contains('damaged'));
      expect(s.isInstalled('tiny'), isFalse);
      final dec = p.join(tmp.path, 'models', 'tiny', 'dec.onnx');
      expect(File(dec).existsSync(), isFalse);
      expect(File('$dec.part').existsSync(), isFalse);
      // The good file before it is kept, so a retry needn't fetch it again.
      expect(File(p.join(tmp.path, 'models', 'tiny', 'enc.onnx')).existsSync(),
          isTrue);
    });

    test('resumes a partial file with a Range request', () async {
      final dec = content['dec.onnx']!;
      final part = File(p.join(tmp.path, 'models', 'tiny', 'dec.onnx.part'));
      await part.parent.create(recursive: true);
      await part.writeAsBytes(dec.sublist(0, 10));
      String? range;
      final s = store(MockClient((req) async {
        final name = req.url.pathSegments.last;
        if (name != 'dec.onnx') return http.Response.bytes(content[name]!, 200);
        range = req.headers['Range'];
        return http.Response.bytes(dec.sublist(10), 206);
      }));
      await s.load();
      expect(await s.download('tiny'), isNull);
      expect(range, 'bytes=10-');
      expect(await File(s.installed('tiny')!.decoder).readAsBytes(), dec);
    });

    test('starts over when the server ignores the range', () async {
      final dec = content['dec.onnx']!;
      final part = File(p.join(tmp.path, 'models', 'tiny', 'dec.onnx.part'));
      await part.parent.create(recursive: true);
      await part.writeAsBytes(dec.sublist(0, 10));
      final s = store(MockClient(
          (req) async => http.Response.bytes(content[req.url.pathSegments.last]!, 200)));
      await s.load();
      expect(await s.download('tiny'), isNull);
      expect(await File(s.installed('tiny')!.decoder).readAsBytes(), dec);
    });

    test('an HTTP error is reported', () async {
      final s = store(MockClient((_) async => http.Response('nope', 404)));
      await s.load();
      expect(await s.download('tiny'), contains('404'));
      expect(s.error, contains('404'));
      expect(s.downloading, isNull);
    });

    test('delete removes the model and, with the last one, voice detection',
        () async {
      final s = store(MockClient(
          (req) async => http.Response.bytes(content[req.url.pathSegments.last]!, 200)));
      await s.load();
      await s.download('tiny');
      await s.delete('tiny');
      expect(s.isInstalled('tiny'), isFalse);
      expect(Directory(p.join(tmp.path, 'models', 'tiny')).existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, 'models', 'vad')).existsSync(), isFalse);
    });

    test('the real catalog is pinned and sized', () {
      for (final m in offlineModels) {
        for (final f in m.files) {
          expect(f.url, contains('/resolve/'));
          expect(f.url, isNot(contains('/main/')));
          expect(f.sha256, hasLength(64));
          expect(f.size, greaterThan(0));
        }
      }
      expect(offlineModelById('turbo')!.canTranslate, isFalse);
    });
  });

  group('toMono16k', () {
    test('passes 16 kHz mono through', () {
      final pcm = Int16List.fromList([1, -2, 3, -4]);
      final out = toMono16k(
          WavData(const WavFormat(1, 16000, 16), pcm.buffer.asUint8List()));
      expect(out, [1, -2, 3, -4]);
    });

    test('averages channels and resamples', () {
      // One second of 48 kHz stereo; left 1000, right 3000.
      final frames = Int16List(48000 * 2);
      for (var i = 0; i < 48000; i++) {
        frames[i * 2] = 1000;
        frames[i * 2 + 1] = 3000;
      }
      final out = toMono16k(
          WavData(const WavFormat(2, 48000, 16), frames.buffer.asUint8List()));
      expect(out.length, 16000);
      expect(out.every((v) => v == 2000), isTrue);
    });

    test('rejects other sample formats', () {
      expect(
          () => toMono16k(WavData(const WavFormat(1, 16000, 8), Uint8List(4))),
          throwsFormatException);
    });

    test('pcmToFloat scales and clamps the range', () {
      final f = pcmToFloat(Int16List.fromList([0, 16384, -32768]), 1, 5);
      expect(f, [0.5, -1.0]);
    });
  });

  test('speech pieces are padded without overlapping', () {
    final out = padPieces([
      (start: 100, length: 1000),
      (start: 1300, length: 500),
      (start: 5000, length: 1000),
    ], 6100, pad: 400);
    expect(out, [
      // Clamped at the start of the audio and at the next piece's speech.
      (start: 0, length: 1300),
      (start: 1300, length: 900),
      (start: 4600, length: 1500), // Clamped at the end of the audio.
    ]);
  });

  group('timestamps', () {
    test('OpenAI verbose_json segments become lines', () {
      final lines = timedLines([
        {'start': 0.0, 'end': 2.5, 'text': ' Hello there. '},
        {'start': 2.5, 'end': 4.0, 'text': ''},
        {'start': 4.0, 'end': 6.25, 'text': 'Second.'},
      ]);
      expect(lines.map((l) => (l.startMs, l.endMs, l.text)),
          [(0, 2500, 'Hello there.'), (4000, 6250, 'Second.')]);
      expect(timedLines(null), isEmpty);
    });

    test('lines survive the database', () async {
      sqfliteFfiInit();
      final db = await NotesDb.open(
          path: p.join(tmp.path, 'lines.db'), factory: databaseFactoryFfi);
      final note = await db.insert(Note(
        provider: 'onDevice',
        createdAt: DateTime(2026),
        segments: const [
          Segment(audioPath: '/a.wav', status: NoteStatus.done, lines: [
            TimedLine(0, 1500, 'नमस्ते', english: 'Hello'),
            TimedLine(1500, 3000, 'दूसरा'),
          ]),
        ],
      ));
      expect(note.segments.single.id, isNotNull);
      final back = (await db.all()).single.segments.single.lines;
      expect(back.map((l) => (l.startMs, l.endMs, l.text, l.english)), [
        (0, 1500, 'नमस्ते', 'Hello'),
        (1500, 3000, 'दूसरा', ''),
      ]);
      await db.close();
    });

    test('srtTime formats hours, minutes, seconds and milliseconds', () {
      expect(srtTime(0), '00:00:00,000');
      expect(srtTime(3723004), '01:02:03,004');
    });

    test('SRT offsets each recording by the ones before it', () {
      final note = Note(
        provider: 'onDevice',
        createdAt: DateTime(2026),
      ).withSegments(const [
        Segment(
            audioPath: '/1.wav',
            status: NoteStatus.done,
            durationMs: 10000,
            lines: [TimedLine(1000, 4000, 'one', english: 'ONE')]),
        // No timestamps (another provider), but its length still counts.
        Segment(
            audioPath: '/2.m4a',
            status: NoteStatus.done,
            durationMs: 5000,
            transcript: 'plain'),
        Segment(
            audioPath: '/3.wav',
            status: NoteStatus.done,
            lines: [TimedLine(500, 2000, 'three')]),
      ]);
      expect(hasTimedText(note), isTrue);
      expect(
          srtText(note),
          '1\n00:00:01,000 --> 00:00:04,000\none\n\n'
          '2\n00:00:15,500 --> 00:00:17,000\nthree\n\n');
      expect(srtText(note, english: true), contains('ONE'));
      expect(srtText(note, english: true), contains('three'));
    });

    test('a note without timestamps has nothing to export', () {
      final note = Note(provider: 'sarvam', createdAt: DateTime(2026))
          .withSegments(const [
        Segment(audioPath: '/1.wav', status: NoteStatus.done, transcript: 'x'),
      ]);
      expect(hasTimedText(note), isFalse);
    });
  });
}
