import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/providers/openrouter_provider.dart';

void main() {
  group('OpenRouter', () {
    test('sends the model and parses the JSON reply', () async {
      late Map<String, dynamic> sent;
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://openrouter.ai/api/v1/chat/completions');
        expect(req.headers['Authorization'], 'Bearer k');
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'choices': [
              {
                'message': {'content': '```json\n{"title":"Labour","summary":"CTG."}\n```'},
              },
            ],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final s = await OpenRouterProvider(apiKey: 'k', client: client)
          .summarize('notes');
      expect(sent['model'], 'openrouter/free');
      expect(sent.containsKey('response_format'), isFalse);
      expect(s.title, 'Labour');
    });

    test('an empty reply is a readable error', () async {
      final client = MockClient((_) async => http.Response(
          jsonEncode({'choices': []}), 200,
          headers: {'content-type': 'application/json'}));
      expect(
        OpenRouterProvider(apiKey: 'k', client: client).completeJson('x'),
        throwsA(isA<ProviderException>()),
      );
    });

    test('cannot transcribe audio', () {
      expect(ProviderId.openrouter.canTranscribe, isFalse);
      expect(
        () => OpenRouterProvider(apiKey: 'k').transcribe(File('x.m4a'), translate: false),
        throwsA(anything),
      );
    });
  });

  group('SettingsStore enrichment provider', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('defaults to the transcription provider', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore();
      await store.load();
      expect(store.enrichment, isNull);
      expect(store.textActive, store.active);
    });

    test('a separate choice is saved, restored and can be cleared', () async {
      SharedPreferences.setMockInitialValues({});
      final first = SettingsStore();
      await first.load();
      await first.setEnrichment(ProviderId.openrouter);
      expect(first.textActive, ProviderId.openrouter);
      expect(first.active, ProviderId.sarvam);

      final second = SettingsStore();
      await second.load();
      expect(second.textActive, ProviderId.openrouter);

      await second.setEnrichment(null);
      expect(second.textActive, second.active);
    });

    test('build uses the OpenRouter default model', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore();
      await store.load();
      expect(store.build(ProviderId.openrouter), isNull); // no key yet
      await store.setApiKey(ProviderId.openrouter, 'k');
      expect(store.build(ProviderId.openrouter), isA<OpenRouterProvider>());
      expect(store.textModel(ProviderId.openrouter), 'openrouter/free');
    });
  });
}
