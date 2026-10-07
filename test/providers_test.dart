import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/providers/gemini_provider.dart';
import 'package:voice_notes/providers/openai_provider.dart';
import 'package:voice_notes/providers/sarvam_provider.dart';
import 'package:voice_notes/providers/wav_utils.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

File tempAudio(String name, List<int> bytes) {
  final f = File('${Directory.systemTemp.createTempSync().path}/$name');
  f.writeAsBytesSync(bytes);
  return f;
}

void main() {
  group('Sarvam sync (WAV)', () {
    test('chunks long audio, transcribes and translates each chunk', () async {
      const fmt = WavFormat(1, 16000, 16);
      final wav = buildWav(fmt, Uint8List(fmt.bytesPerSecond * 60)); // 3 chunks
      final file = tempAudio('a.wav', wav);

      final modes = <String>[];
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://api.sarvam.ai/speech-to-text');
        expect(req.headers['api-subscription-key'], 'k');
        final body = utf8.decode(req.bodyBytes, allowMalformed: true);
        final mode = RegExp(r'name="mode"\r\n\r\n(\w+)').firstMatch(body)![1]!;
        modes.add(mode);
        return json({
          'transcript': mode == 'translate' ? 'hello' : 'नमस्ते',
          'language_code': 'hi-IN',
        });
      });

      final t = await SarvamProvider(apiKey: 'k', client: client)
          .transcribe(file, translate: true);
      expect(modes.where((m) => m == 'transcribe'), hasLength(3));
      expect(modes.where((m) => m == 'translate'), hasLength(3));
      expect(t.text, 'नमस्ते नमस्ते नमस्ते');
      expect(t.english, 'hello hello hello');
      expect(t.languageCode, 'hi-IN');
    });

    test('translate off makes no translate calls', () async {
      const fmt = WavFormat(1, 16000, 16);
      final file =
          tempAudio('a.wav', buildWav(fmt, Uint8List(fmt.bytesPerSecond * 5)));
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return json({'transcript': 'x', 'language_code': 'ta-IN'});
      });
      final t = await SarvamProvider(apiKey: 'k', client: client)
          .transcribe(file, translate: false);
      expect(calls, 1);
      expect(t.english, '');
    });

    test('API errors surface a readable message', () async {
      const fmt = WavFormat(1, 16000, 16);
      final file =
          tempAudio('a.wav', buildWav(fmt, Uint8List(fmt.bytesPerSecond)));
      final client = MockClient(
          (_) async => json({'error': {'message': 'bad key'}}, 403));
      expect(
        SarvamProvider(apiKey: 'k', client: client)
            .transcribe(file, translate: false),
        throwsA(predicate((e) =>
            e is ProviderException &&
            e.message.contains('bad key') &&
            e.message.contains('API key'))),
      );
    });
  });

  group('Sarvam batch (m4a)', () {
    test('walks create, upload, start, poll and download', () async {
      final file = tempAudio('note.m4a', List.filled(100, 1));
      final seen = <String>[];
      final client = MockClient((req) async {
        final path = req.url.path;
        seen.add('${req.method} ${req.url.host}$path');
        if (req.method == 'PUT') return http.Response('', 201);
        if (path == '/speech-to-text/job/v1') return json({'job_id': 'j1'});
        if (path.endsWith('/upload-files')) {
          return json({
            'upload_urls': {
              'note.m4a': {'file_url': 'https://blob.example.com/u'},
            },
          });
        }
        if (path.endsWith('/start')) return json({});
        if (path.endsWith('/status')) {
          return json({
            'job_state': 'Completed',
            'job_details': [
              {
                'outputs': [
                  {'file_name': '0.json'},
                ],
              },
            ],
          });
        }
        if (path.endsWith('/download-files')) {
          return json({
            'download_urls': {
              '0.json': {'file_url': 'https://blob.example.com/d'},
            },
          });
        }
        if (req.url.host == 'blob.example.com') {
          return json({'transcript': 'long text', 'language_code': 'kn-IN'});
        }
        return http.Response('unexpected $path', 500);
      });

      final t = await SarvamProvider(
        apiKey: 'k',
        client: client,
        pollInterval: Duration.zero,
      ).transcribe(file, translate: false);
      expect(t.text, 'long text');
      expect(t.languageCode, 'kn-IN');
      expect(seen.first, 'POST api.sarvam.ai/speech-to-text/job/v1');
      expect(seen, contains('PUT blob.example.com/u'));
    });

    test('a failed job raises an error', () async {
      final file = tempAudio('note.m4a', [1, 2, 3]);
      final client = MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'PUT') return http.Response('', 201);
        if (path == '/speech-to-text/job/v1') return json({'job_id': 'j'});
        if (path.endsWith('/upload-files')) {
          return json({'urls': ['https://x.example.com/u']});
        }
        if (path.endsWith('/status')) {
          return json({'job_state': 'Failed', 'error_message': 'boom'});
        }
        return json({});
      });
      expect(
        SarvamProvider(apiKey: 'k', client: client, pollInterval: Duration.zero)
            .transcribe(file, translate: false),
        throwsA(isA<ProviderException>()),
      );
    });
  });

  group('OpenAI', () {
    test('transcribes then translates', () async {
      final file = tempAudio('a.m4a', [1, 2, 3]);
      final client = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer k');
        if (req.url.path.endsWith('/transcriptions')) {
          return json({'text': 'नमस्ते', 'language': 'hindi'});
        }
        return json({'text': 'hello'});
      });
      final t = await OpenAiProvider(apiKey: 'k', client: client)
          .transcribe(file, translate: true);
      expect(t.text, 'नमस्ते');
      expect(t.english, 'hello');
      expect(t.languageCode, 'hindi');
    });

    test('summarize parses JSON from the chat reply', () async {
      final client = MockClient((_) async => json({
            'choices': [
              {
                'message': {'content': '{"title":"Groceries","summary":"Buy milk."}'},
              },
            ],
          }));
      final s = await OpenAiProvider(apiKey: 'k', client: client)
          .summarize('buy milk');
      expect(s.title, 'Groceries');
      expect(s.summary, 'Buy milk.');
    });
  });

  group('Gemini', () {
    test('returns language, transcript and English from one call', () async {
      final file = tempAudio('a.m4a', [1, 2, 3]);
      final client = MockClient((req) async {
        expect(req.headers['x-goog-api-key'], 'k');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final parts = body['contents'][0]['parts'] as List;
        expect(parts[1]['inline_data']['mime_type'], 'audio/mp4');
        return json({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text':
                        '```json\n{"language":"te-IN","transcript":"హలో","english":"hello"}\n```',
                  },
                ],
              },
            },
          ],
        });
      });
      final t = await GeminiProvider(apiKey: 'k', client: client)
          .transcribe(file, translate: true);
      expect(t.text, 'హలో');
      expect(t.english, 'hello');
      expect(t.languageCode, 'te-IN');
    });
  });

  group('helpers', () {
    test('extractJsonObject ignores reasoning blocks and fences', () {
      final j = extractJsonObject(
          '<think>hmm {not json}</think>\n```json\n{"a": 1}\n```');
      expect(j['a'], 1);
    });

    test('findUploadUrl prefers the entry for the file name', () {
      final url = findUploadUrl({
        'x': 'https://other',
        'files': {'a.m4a': 'https://right'},
      }, 'a.m4a');
      expect(url, 'https://right');
    });
  });
}
