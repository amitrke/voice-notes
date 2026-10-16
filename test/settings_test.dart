import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_notes/data/dictionary.dart';
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

  group('use case', () {
    test('defaults to general notes', () async {
      final s = await _load({});
      expect(s.useCase, UseCase.general);
      expect(s.clinical, isFalse);
    });

    test('carries over the old clinical switch', () async {
      expect((await _load({'clinical': true})).useCase, UseCase.clinical);
      expect((await _load({'clinical': false})).useCase, UseCase.general);
    });

    test('a saved use case wins over the old switch and persists', () async {
      final s = await _load({'clinical': true, 'useCase': 'general'});
      expect(s.useCase, UseCase.general);
      await s.setUseCase(UseCase.clinical);
      expect(s.clinical, isTrue);
      final again = SettingsStore();
      await again.load();
      expect(again.useCase, UseCase.clinical);
    });
  });

  group('status lines', () {
    test('transcription names the provider and whether it is ready', () async {
      final s = await _load({'active': 'gemini'});
      expect(transcriptionStatus(s), '${ProviderId.gemini.label} · no key yet');
      await s.setActive(ProviderId.onDevice);
      expect(transcriptionStatus(s), endsWith('· no model downloaded'));
    });

    test('options sum up translation, speakers and the dictionary', () async {
      final s = await _load({});
      expect(optionsStatus(s), 'Translate on · Speakers off');
      await s.setTranslate(false);
      await s.setIdentifySpeakers(true);
      await s.setDictionary(Dictionary.fromLines(['Amoxicillin']));
      expect(optionsStatus(s), 'Translate off · Speakers on · 1 word');
    });
  });
}
