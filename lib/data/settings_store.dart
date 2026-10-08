import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/ai_provider.dart';
import '../providers/gemini_provider.dart';
import '../providers/openai_provider.dart';
import '../providers/openrouter_provider.dart';
import '../providers/sarvam_provider.dart';
import '../services/audio_converter.dart';
import 'text_scale.dart';

class ModelDefaults {
  final String stt;
  final String text;
  const ModelDefaults(this.stt, this.text);
}

const modelDefaults = {
  ProviderId.sarvam: ModelDefaults('saaras:v3', 'sarvam-105b'),
  ProviderId.openai: ModelDefaults('whisper-1', 'gpt-4o-mini'),
  ProviderId.gemini: ModelDefaults('gemini-3.5-flash', 'gemini-3.5-flash'),
  ProviderId.openrouter: ModelDefaults('', 'openrouter/free'),
};

/// API keys live in the platform keystore/keychain; everything else in
/// SharedPreferences. Values are cached in memory after [load].
class SettingsStore {
  final FlutterSecureStorage _secure;
  late final SharedPreferences _prefs;
  final _keys = <ProviderId, String>{};

  SettingsStore({FlutterSecureStorage? secure})
      : _secure = secure ?? const FlutterSecureStorage();

  /// Provider that transcribes audio.
  ProviderId active = ProviderId.sarvam;

  /// Provider for text work (titles, summaries, clinical notes). Null means
  /// the same one as [active].
  ProviderId? enrichment;
  bool translate = true;
  bool autoSummary = true;
  bool clinical = false;
  double textScale = defaultTextScale;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    active = ProviderId.values.firstWhere(
      (p) => p.name == _prefs.getString('active'),
      orElse: () => ProviderId.sarvam,
    );
    final e = _prefs.getString('enrichment');
    enrichment = ProviderId.values.where((p) => p.name == e).firstOrNull;
    translate = _prefs.getBool('translate') ?? true;
    autoSummary = _prefs.getBool('autoSummary') ?? true;
    clinical = _prefs.getBool('clinical') ?? false;
    textScale = snapTextScale(_prefs.getDouble('textScale') ?? defaultTextScale);
    for (final id in ProviderId.values) {
      final k = await _secure.read(key: 'apikey_${id.name}');
      if (k != null && k.isNotEmpty) _keys[id] = k;
    }
  }

  String apiKey(ProviderId id) => _keys[id] ?? '';
  bool hasKey(ProviderId id) => apiKey(id).isNotEmpty;

  String sttModel(ProviderId id) =>
      _prefs.getString('stt_${id.name}') ?? modelDefaults[id]!.stt;
  String textModel(ProviderId id) =>
      _prefs.getString('text_${id.name}') ?? modelDefaults[id]!.text;

  Future<void> setApiKey(ProviderId id, String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      _keys.remove(id);
      await _secure.delete(key: 'apikey_${id.name}');
    } else {
      _keys[id] = v;
      await _secure.write(key: 'apikey_${id.name}', value: v);
    }
  }

  Future<void> setModels(ProviderId id, {String? stt, String? text}) async {
    Future<void> put(String key, String? v, String fallback) async {
      if (v == null) return;
      final t = v.trim();
      if (t.isEmpty || t == fallback) {
        await _prefs.remove(key);
      } else {
        await _prefs.setString(key, t);
      }
    }

    await put('stt_${id.name}', stt, modelDefaults[id]!.stt);
    await put('text_${id.name}', text, modelDefaults[id]!.text);
  }

  /// The provider used for text work.
  ProviderId get textActive => enrichment ?? active;

  Future<void> setEnrichment(ProviderId? id) async {
    enrichment = id;
    if (id == null) {
      await _prefs.remove('enrichment');
    } else {
      await _prefs.setString('enrichment', id.name);
    }
  }

  Future<void> setActive(ProviderId id) async {
    active = id;
    await _prefs.setString('active', id.name);
  }

  Future<void> setTranslate(bool v) async {
    translate = v;
    await _prefs.setBool('translate', v);
  }

  Future<void> setTextScale(double v) async {
    textScale = snapTextScale(v);
    await _prefs.setDouble('textScale', textScale);
  }

  Future<void> setClinical(bool v) async {
    clinical = v;
    await _prefs.setBool('clinical', v);
  }

  Future<void> setAutoSummary(bool v) async {
    autoSummary = v;
    await _prefs.setBool('autoSummary', v);
  }

  /// Builds the provider for [id], or null when no key has been saved.
  AiProvider? build(ProviderId id) {
    if (!hasKey(id)) return null;
    final key = apiKey(id);
    switch (id) {
      case ProviderId.sarvam:
        return SarvamProvider(
          apiKey: key,
          sttModel: sttModel(id),
          textModel: textModel(id),
          toWav: convertToWav16kMono,
        );
      case ProviderId.openai:
        return OpenAiProvider(
            apiKey: key, sttModel: sttModel(id), textModel: textModel(id));
      case ProviderId.gemini:
        return GeminiProvider(
            apiKey: key, sttModel: sttModel(id), textModel: textModel(id));
      case ProviderId.openrouter:
        return OpenRouterProvider(apiKey: key, textModel: textModel(id));
    }
  }
}
