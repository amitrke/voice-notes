import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/ai_provider.dart';
import '../providers/gemini_provider.dart';
import '../providers/on_device_provider.dart';
import '../providers/openai_provider.dart';
import '../providers/openrouter_provider.dart';
import '../providers/sarvam_provider.dart';
import '../services/audio_converter.dart';
import '../services/model_store.dart';
import 'dictionary.dart';
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
  ProviderId.onDevice: ModelDefaults('', ''),
};

/// API keys live in the platform keystore/keychain; everything else in
/// SharedPreferences. Values are cached in memory after [load].
class SettingsStore {
  final FlutterSecureStorage _secure;
  late final SharedPreferences _prefs;
  final _keys = <ProviderId, String>{};

  /// Downloaded offline models, for [ProviderId.onDevice].
  final ModelStore models;

  SettingsStore({FlutterSecureStorage? secure, ModelStore? models})
      : _secure = secure ?? const FlutterSecureStorage(),
        models = models ?? ModelStore();

  /// Provider that transcribes audio.
  ProviderId active = ProviderId.sarvam;

  /// Provider for text work (titles, summaries, clinical notes). Null means
  /// the same one as [active].
  ProviderId? enrichment;
  bool translate = true;
  bool autoSummary = true;
  bool clinical = false;
  double textScale = defaultTextScale;

  /// Remove a recording's audio file once its text has been saved.
  bool deleteAudioAfter = false;

  /// Label who is speaking, where the provider can tell voices apart.
  bool identifySpeakers = false;

  /// Names and terms the user wants spelled a certain way.
  Dictionary dictionary = Dictionary();

  /// The offline model the user picked; see [offlineModel].
  String? _offlineModel;

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
    _offlineModel = _prefs.getString('offlineModel');
    deleteAudioAfter = _prefs.getBool('deleteAudioAfter') ?? false;
    identifySpeakers = _prefs.getBool('identifySpeakers') ?? false;
    dictionary =
        Dictionary.fromLines(_prefs.getStringList('dictionary') ?? const []);
    for (final id in ProviderId.values) {
      final k = await _secure.read(key: 'apikey_${id.name}');
      if (k != null && k.isNotEmpty) _keys[id] = k;
    }
  }

  String apiKey(ProviderId id) => _keys[id] ?? '';
  bool hasKey(ProviderId id) => apiKey(id).isNotEmpty;

  /// The provider can be used: its key is saved, or for on-device
  /// transcription, a model has been downloaded.
  bool isReady(ProviderId id) =>
      id.needsKey ? hasKey(id) : offlineModel != null;

  /// The installed offline model to use: the one picked if it is installed,
  /// else any installed one.
  String? get offlineModel {
    if (_offlineModel != null && models.isInstalled(_offlineModel!)) {
      return _offlineModel;
    }
    return models.catalog.where((m) => models.isInstalled(m.id)).firstOrNull?.id;
  }

  Future<void> setOfflineModel(String id) async {
    _offlineModel = id;
    await _prefs.setString('offlineModel', id);
  }

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

  Future<void> setDeleteAudioAfter(bool v) async {
    deleteAudioAfter = v;
    await _prefs.setBool('deleteAudioAfter', v);
  }

  Future<void> setIdentifySpeakers(bool v) async {
    identifySpeakers = v;
    await _prefs.setBool('identifySpeakers', v);
  }

  Future<void> setDictionary(Dictionary d) async {
    dictionary = d;
    await _prefs.setStringList('dictionary', d.toLines());
  }

  /// Builds the provider for [id], or null when it is not ready (see
  /// [isReady]).
  AiProvider? build(ProviderId id) {
    if (!isReady(id)) return null;
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
      case ProviderId.onDevice:
        final m = models.installed(offlineModel!);
        return m == null
            ? null
            : OnDeviceProvider(
                model: m,
                toWav: convertToWav16kMono,
                speakerModels: models.installedSpeakers());
    }
  }
}
