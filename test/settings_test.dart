import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/ui/settings_page.dart';

Future<SettingsStore> _load(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final s = SettingsStore();
  await s.load();
  return s;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('status lines', () {
    test('transcription names the provider and whether it is ready', () async {
      final s = await _load({'active': 'gemini'});
      expect(transcriptionStatus(s), '${ProviderId.gemini.label} · no key yet');
      await s.setActive(ProviderId.onDevice);
      expect(transcriptionStatus(s), endsWith('· no model downloaded'));
    });

    test('keys lists the providers with a key saved', () async {
      final s = await _load({});
      expect(keysStatus(s), 'No keys saved yet');
      await s.setApiKey(ProviderId.sarvam, 'k1');
      expect(keysStatus(s), 'Sarvam saved');
      await s.setApiKey(ProviderId.gemini, 'k2');
      await s.setApiKey(ProviderId.openrouter, 'k3');
      expect(keysStatus(s), 'Sarvam, ${ProviderId.gemini.label} and OpenRouter saved');
    });

    test('written by says when it follows transcription', () async {
      final s = await _load({'active': 'gemini'});
      expect(writtenByStatus(s), 'Same as transcription (${ProviderId.gemini.label})');
      await s.setEnrichment(ProviderId.openrouter);
      expect(writtenByStatus(s), 'OpenRouter');
      await s.setEnrichment(null);
      await s.setActive(ProviderId.onDevice);
      expect(writtenByStatus(s), contains('can\'t write text'));
    });
  });

  group('setup problem', () {
    test('asks for the transcription key first', () async {
      final s = await _load({'active': 'gemini'});
      final p = setupProblem(s)!;
      expect(p.message, 'Add your ${ProviderId.gemini.label} key to start transcribing');
      expect(p.fix, SetupFix.keys);
    });

    test('asks for a model when transcribing on the device', () async {
      final s = await _load({'active': 'onDevice'});
      expect(setupProblem(s)!.fix, SetupFix.provider);
    });

    test('then for the text provider key, unless summaries are off', () async {
      final s = await _load({'active': 'gemini'});
      await s.setApiKey(ProviderId.gemini, 'k');
      expect(setupProblem(s), isNull);
      await s.setEnrichment(ProviderId.openrouter);
      expect(setupProblem(s)!.message,
          'Add your OpenRouter key for titles and summaries');
      await s.setAutoSummary(false);
      expect(setupProblem(s), isNull);
    });
  });

  group('blocked switches', () {
    test('speakers need a provider that can tell them apart', () async {
      final s = await _load({'active': 'sarvam'});
      expect(speakersBlocked(s), startsWith('Sarvam can\'t'));
      await s.setActive(ProviderId.gemini);
      expect(speakersBlocked(s), isNull);
    });

    test('translate is open for cloud providers', () async {
      final s = await _load({'active': 'openai'});
      expect(translateBlocked(s), isNull);
    });
  });

}
