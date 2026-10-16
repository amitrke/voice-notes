import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One file of a downloadable model, pinned by URL, size and SHA-256.
class ModelFile {
  final String name;
  final String url;
  final int size;
  final String sha256;
  const ModelFile(this.name, this.url, this.size, this.sha256);
}

/// How a model is run by sherpa-onnx.
enum ModelKind {
  /// OpenAI Whisper: an encoder and a decoder, any language, can translate.
  whisper,

  /// A NeMo CTC model (AI4Bharat IndicConformer): one file, one language.
  nemoCtc,

  /// Meta's Omnilingual ASR CTC model: one file, 1,600+ languages.
  omnilingual,
}

/// A speech model that runs on the device through sherpa-onnx.
class OfflineModel {
  final String id;
  final String label;
  final String blurb;

  /// The Whisper encoder; for single-file models ([kind] other than whisper),
  /// the model itself.
  final ModelFile encoder;

  /// The Whisper decoder; null for single-file models.
  final ModelFile? decoder;
  final ModelFile tokens;
  final ModelKind kind;

  /// The one language a single-language model speaks ("ta"); null otherwise.
  final String? language;

  /// Whisper's translate-to-English task. Turbo was trained without it, and
  /// the other kinds only transcribe.
  final bool canTranslate;

  const OfflineModel({
    required this.id,
    required this.label,
    required this.blurb,
    required this.encoder,
    this.decoder,
    required this.tokens,
    this.kind = ModelKind.whisper,
    this.language,
    bool? canTranslate,
  }) : canTranslate = canTranslate ?? kind == ModelKind.whisper;

  List<ModelFile> get files => [encoder, ?decoder, tokens];
  int get size => files.fold(0, (a, f) => a + f.size);
}

/// Hugging Face URLs pinned to a commit, so a file can never change under us.
String _hf(String repo, String commit, String file,
        {String owner = 'csukuangfj'}) =>
    'https://huggingface.co/$owner/$repo/resolve/$commit/$file';

const _tokensSha =
    'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126';
const _tokensSize = 816730;

ModelFile _whisperFile(String repo, String commit, String file, int size,
        String sha) =>
    ModelFile(file, _hf(repo, commit, file), size, sha);

const _baseCommit = 'bb53ee204431c90d314c1cc08d28d23e5b7927cc';
const _smallCommit = '8f3c18b358db4d1f2fc1eae49d75cd20989e4309';
const _turboCommit = '2ca6ff69fc878651b770880507669577ac41c2ff';

final offlineModels = <OfflineModel>[
  OfflineModel(
    id: 'base',
    label: 'Base',
    blurb: 'Fastest. Good for clear speech.',
    encoder: _whisperFile('sherpa-onnx-whisper-base', _baseCommit,
        'base-encoder.int8.onnx', 29120534,
        '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11'),
    decoder: _whisperFile('sherpa-onnx-whisper-base', _baseCommit,
        'base-decoder.int8.onnx', 130672026,
        '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d'),
    tokens: _whisperFile('sherpa-onnx-whisper-base', _baseCommit,
        'base-tokens.txt', _tokensSize, _tokensSha),
  ),
  OfflineModel(
    id: 'small',
    label: 'Small',
    blurb: 'More accurate, about three times slower than Base.',
    encoder: _whisperFile('sherpa-onnx-whisper-small', _smallCommit,
        'small-encoder.int8.onnx', 112442483,
        '4cbe7b22fa9026b843b60a68640c747de05bafb1a11b57edc0e66c232d9f33a9'),
    decoder: _whisperFile('sherpa-onnx-whisper-small', _smallCommit,
        'small-decoder.int8.onnx', 262226114,
        'acad50b5c782696e91b55914cc5ab4f756f1532f76e22aa6fc615f39fb69a8ee'),
    tokens: _whisperFile('sherpa-onnx-whisper-small', _smallCommit,
        'small-tokens.txt', _tokensSize, _tokensSha),
  ),
  OfflineModel(
    id: 'turbo',
    label: 'High accuracy (Turbo)',
    blurb: 'Best accuracy, for recent phones with plenty of memory. '
        'Cannot translate to English on the device.',
    encoder: _whisperFile('sherpa-onnx-whisper-turbo', _turboCommit,
        'turbo-encoder.int8.onnx', 674716297,
        'b02dcdf54f348741e93fe732b67d933c8dcb6735655f710640143081db38878b'),
    decoder: _whisperFile('sherpa-onnx-whisper-turbo', _turboCommit,
        'turbo-decoder.int8.onnx', 361080764,
        '20accd02388482eb3a46bd615631adfdc85e1eb2c7db9ea3f02a40ffe6b81547'),
    tokens: _whisperFile('sherpa-onnx-whisper-turbo', _turboCommit,
        'turbo-tokens.txt', _tokensSize, _tokensSha),
    canTranslate: false,
  ),
  // Meta's Omnilingual ASR (the successor to MMS, Apache-2.0). One model for
  // many languages, including the Indian ones, but it neither detects the
  // language nor translates.
  OfflineModel(
    id: 'omnilingual',
    label: 'Many languages (Omnilingual)',
    blurb: 'Meta model for 1,600+ languages, including Hindi, Tamil, '
        'Telugu, Bengali and more. Transcribes only; it does not translate '
        'or name the language.',
    kind: ModelKind.omnilingual,
    encoder: ModelFile(
      'omnilingual-model.int8.onnx',
      'https://huggingface.co/csukuangfj/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12/resolve/6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094/model.int8.onnx',
      365352120,
      'e7c4e54ee4c4c47829cc6667d5d00ed8ea7bef1dcfeef0fce766f77752a2726c',
    ),
    tokens: ModelFile(
      'omnilingual-tokens.txt',
      'https://huggingface.co/csukuangfj/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12/resolve/6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094/tokens.txt',
      86423,
      'a7a044c52cb29cbe8b0dc1953e92cefd4ca16b0ed968177b6beab21f9a7d0b31',
    ),
  ),
  // AI4Bharat IndicConformer (MIT), converted for sherpa-onnx by a community
  // contributor (not by AI4Bharat). Each model speaks one language.
  _indic('ta', 'Tamil', 'a41ba03ed8e489eda5e108cb49099b7c9cf83e8b',
      'dfedd42ca1a143fa0f08808b6b5d8f03d1a86e904d68375b335e39417128c0de',
      137563718, 3299,
      '61c6ad5e1d4b28ebbd38853209cf169bdc4dcd62cc32d9ec5185f3530371636d'),
  _indic('te', 'Telugu', '638940e6fe0302e50042e865a26d5e45579ebce5',
      '076cce7dfc7103d35776323c29cb13422be914d58018f625c08cbb0471683359',
      137563720, 2963,
      '02488cdcc1e893b392b1ba24f47508e7b7c64b117be249a0d09c5d8b65ecdfcb'),
  _indic('ml', 'Malayalam', '394e2c20b57eb0db12839ecff00f904a55ea9f47',
      '357382eb9ad4ef45c9269042af953e627ec9ca66a396cad1a2f4ed8562c012a1',
      137563723, 3080,
      '60eb97740574a55504786d4ac0699b14280977ec346a7d9a9bbef4deeb1e559b'),
];

OfflineModel _indic(String code, String name, String commit, String modelSha,
        int modelSize, int tokensSize, String tokensSha) =>
    OfflineModel(
      id: 'indic-$code',
      label: '$name only (IndicConformer)',
      blurb: 'Made for $name only, so it cannot detect other languages or '
          'translate. AI4Bharat model, converted by a community contributor.',
      kind: ModelKind.nemoCtc,
      language: code,
      encoder: ModelFile(
        'model.int8.onnx',
        _hf('sherpa-onnx-indicconformer-$code-int8', commit, 'model.int8.onnx',
            owner: 'csndhanasekar'),
        modelSize,
        modelSha,
      ),
      tokens: ModelFile(
        'tokens.txt',
        _hf('sherpa-onnx-indicconformer-$code-int8', commit, 'tokens.txt',
            owner: 'csndhanasekar'),
        tokensSize,
        tokensSha,
      ),
    );

/// Silero voice activity detection: splits recordings into the short speech
/// pieces Whisper can take (it reads at most 30 s at a time). Downloaded with
/// whichever model is installed first.
const vadFile = ModelFile(
  'silero_vad.onnx',
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
  643854,
  '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
);

/// The two small models that tell voices apart on the device: pyannote
/// segmentation (who talks when) and a speaker embedding (whose voice it is).
/// Pinned to Hugging Face commits like the Whisper files.
const speakerSegmentationFile = ModelFile(
  'segmentation.int8.onnx',
  'https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.int8.onnx',
  1540506,
  'd582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d',
);

const speakerEmbeddingFile = ModelFile(
  'embedding.onnx',
  'https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/0743f301363dec56491a490f6d6cbc9d67f9a3bf/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
  28281164,
  'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2',
);

/// Id [ModelStore.download] and [ModelStore.delete] take for the speaker
/// models, which are installed separately from the Whisper models.
const speakerModelsId = 'speakers';

OfflineModel? offlineModelById(String? id) =>
    offlineModels.where((m) => m.id == id).firstOrNull;

/// Paths of an installed model, as the recognizer needs them.
class InstalledModel {
  final OfflineModel model;
  final String encoder;

  /// Empty for single-file models.
  final String decoder;
  final String tokens;
  final String vad;
  const InstalledModel(
      this.model, this.encoder, this.decoder, this.tokens, this.vad);

  ModelKind get kind => model.kind;
}

/// Paths of the installed speaker models.
class InstalledSpeakerModels {
  final String segmentation;
  final String embedding;
  const InstalledSpeakerModels(this.segmentation, this.embedding);
}

class ModelDownloadException implements Exception {
  final String message;
  const ModelDownloadException(this.message);
  @override
  String toString() => message;
}

class _Cancelled implements Exception {}

/// Downloads, verifies and deletes offline models. Files go to the app
/// support folder (not documents, and excluded from iCloud backup) under
/// `models/<id>/`. A file is written as `.part`, resumed with a Range request
/// after an interruption, checked against its SHA-256 and only then renamed,
/// so a half-downloaded model never counts as installed.
class ModelStore extends ChangeNotifier {
  final Future<Directory> Function() _baseDir;
  final http.Client Function() _newClient;

  /// The models on offer ([offlineModels]; tests pass small fakes).
  final List<OfflineModel> catalog;
  final ModelFile vad;
  final ModelFile speakerSegmentation;
  final ModelFile speakerEmbedding;

  ModelStore({
    Future<Directory> Function()? baseDir,
    http.Client Function()? client,
    List<OfflineModel>? catalog,
    this.vad = vadFile,
    this.speakerSegmentation = speakerSegmentationFile,
    this.speakerEmbedding = speakerEmbeddingFile,
  })  : _baseDir = baseDir ?? getApplicationSupportDirectory,
        _newClient = client ?? http.Client.new,
        catalog = catalog ?? offlineModels;

  OfflineModel? byId(String? id) => catalog.where((m) => m.id == id).firstOrNull;

  late Directory _root;
  final _installed = <String>{};
  bool _speakersInstalled = false;

  String? _downloading;
  int _received = 0;
  int _total = 0;
  String? _error;
  http.Client? _active;
  bool _cancel = false;

  /// Id of the model being downloaded, if any.
  String? get downloading => _downloading;

  /// Fraction of the current download, 0 to 1.
  double get progress => _total == 0 ? 0 : (_received / _total).clamp(0, 1);
  int get receivedBytes => _received;

  /// Message from the last failed download, until the next one starts.
  String? get error => _error;

  bool isInstalled(String id) =>
      id == speakerModelsId ? _speakersInstalled : _installed.contains(id);
  bool get hasAny => _installed.isNotEmpty;

  Future<void> load() async {
    _root = Directory(p.join((await _baseDir()).path, 'models'));
    _installed.clear();
    for (final m in catalog) {
      if (await _complete(m)) _installed.add(m.id);
    }
    _speakersInstalled = await _speakersComplete();
    notifyListeners();
  }

  String _path(String folder, ModelFile f) => p.join(_root.path, folder, f.name);
  String _modelPath(OfflineModel m, ModelFile f) => _path(m.id, f);
  String get _vadPath => _path('vad', vad);

  /// Final files exist with the expected sizes. Hashes are checked once, when
  /// the file is downloaded.
  Future<bool> _complete(OfflineModel m) async {
    Future<bool> ok(String path, int size) async {
      final f = File(path);
      return await f.exists() && await f.length() == size;
    }

    for (final f in m.files) {
      if (!await ok(_modelPath(m, f), f.size)) return false;
    }
    return ok(_vadPath, vad.size);
  }

  List<(ModelFile, String)> get _speakerFiles => [
        (speakerSegmentation, _path('speakers', speakerSegmentation)),
        (speakerEmbedding, _path('speakers', speakerEmbedding)),
      ];

  Future<bool> _speakersComplete() async {
    for (final (f, path) in _speakerFiles) {
      final file = File(path);
      if (!await file.exists() || await file.length() != f.size) return false;
    }
    return true;
  }

  /// The speaker models, once downloaded.
  InstalledSpeakerModels? installedSpeakers() => _speakersInstalled
      ? InstalledSpeakerModels(_speakerFiles[0].$2, _speakerFiles[1].$2)
      : null;

  InstalledModel? installed(String id) {
    final m = byId(id);
    if (m == null || !isInstalled(id)) return null;
    final decoder = m.decoder;
    return InstalledModel(
        m,
        _modelPath(m, m.encoder),
        decoder == null ? '' : _modelPath(m, decoder),
        _modelPath(m, m.tokens),
        _vadPath);
  }

  /// Downloads every missing file of [id]. Returns an error message, or null
  /// when the model is installed (or the download was cancelled).
  Future<String?> download(String id) async {
    final speakers = id == speakerModelsId;
    final m = byId(id);
    if ((m == null && !speakers) || _downloading != null) return null;
    final todo = speakers
        ? _speakerFiles
        : <(ModelFile, String)>[
            for (final f in m!.files) (f, _modelPath(m, f)),
            (vad, _vadPath),
          ];
    _downloading = id;
    _error = null;
    _cancel = false;
    _total = todo.fold(0, (a, t) => a + t.$1.size);
    _received = 0;
    notifyListeners();
    final client = _active = _newClient();
    try {
      for (final (f, path) in todo) {
        await _fetch(client, f, path);
      }
      if (speakers) {
        _speakersInstalled = true;
      } else {
        _installed.add(id);
      }
      await _excludeFromBackup(_root.path);
      return null;
    } on _Cancelled {
      return null;
    } catch (e) {
      if (_cancel) return null;
      _error = e is ModelDownloadException
          ? e.message
          : e is SocketException || e is http.ClientException
              ? 'Download interrupted. Check your connection and try again; '
                  'it will continue where it stopped.'
              : 'Download failed: $e';
      return _error;
    } finally {
      client.close();
      _active = null;
      _downloading = null;
      notifyListeners();
    }
  }

  /// Stops the current download. What has arrived so far is kept, so the next
  /// download of the same model resumes.
  void cancel() {
    _cancel = true;
    _active?.close();
  }

  Future<void> _fetch(http.Client client, ModelFile f, String path) async {
    final done = File(path);
    if (await done.exists() && await done.length() == f.size) {
      _received += f.size;
      notifyListeners();
      return;
    }
    await done.parent.create(recursive: true);
    final part = File('$path.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > f.size) {
      await part.delete();
      have = 0;
    }
    if (have < f.size) {
      final req = http.Request('GET', Uri.parse(f.url));
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      final res = await client.send(req);
      if (res.statusCode == 200) {
        have = 0; // The server ignored the range: start over.
      } else if (res.statusCode != 206) {
        throw ModelDownloadException(
            'Download failed (HTTP ${res.statusCode}). Try again later.');
      }
      _received += have;
      notifyListeners();
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var last = DateTime.now();
      try {
        await for (final chunk in res.stream) {
          if (_cancel) throw _Cancelled();
          sink.add(chunk);
          _received += chunk.length;
          // Rebuilding on every chunk is wasteful; a few times a second is plenty.
          final now = DateTime.now();
          if (now.difference(last).inMilliseconds > 200) {
            last = now;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
    } else {
      _received += have;
    }
    if (_cancel) throw _Cancelled();
    if (await part.length() != f.size || await fileSha256(part) != f.sha256) {
      await part.delete();
      throw ModelDownloadException(
          '${f.name} was damaged in transit and has been removed. Try again.');
    }
    await part.rename(path);
  }

  /// Removes [id]'s files. The voice detection file goes with the last model.
  Future<void> delete(String id) async {
    if (id == speakerModelsId) {
      final dir = Directory(p.join(_root.path, 'speakers'));
      if (await dir.exists()) await dir.delete(recursive: true);
      _speakersInstalled = false;
      notifyListeners();
      return;
    }
    final m = byId(id);
    if (m == null) return;
    final dir = Directory(p.join(_root.path, m.id));
    if (await dir.exists()) await dir.delete(recursive: true);
    _installed.remove(id);
    if (_installed.isEmpty) {
      final vad = Directory(p.join(_root.path, 'vad'));
      if (await vad.exists()) await vad.delete(recursive: true);
    }
    notifyListeners();
  }
}

Future<String> fileSha256(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();

const _channel = MethodChannel('com.subnext.voicenotes/audio');

/// Keeps re-downloadable models out of the user's iCloud backup.
Future<void> _excludeFromBackup(String path) async {
  if (!Platform.isIOS) return;
  try {
    await _channel.invokeMethod<void>('excludeFromBackup', {'path': path});
  } on PlatformException {
    // Not fatal: the model still works, it is just backed up.
  } on MissingPluginException {
    // Same.
  }
}
