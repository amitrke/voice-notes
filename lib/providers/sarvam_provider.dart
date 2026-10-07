import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'ai_provider.dart';
import 'wav_utils.dart';

/// Sarvam AI. Short audio goes through the synchronous REST endpoint (which
/// accepts about 30 s per request), so WAV files are split into chunks. Other
/// formats (e.g. imported m4a) go through the asynchronous batch job API.
class SarvamProvider implements AiProvider {
  static const _base = 'https://api.sarvam.ai';

  final String apiKey;
  final String sttModel;
  final String textModel;
  final http.Client _client;
  final Duration pollInterval;
  final Duration batchTimeout;

  /// Converts non-WAV audio to a 16 kHz mono WAV file (null = cannot).
  final Future<File?> Function(File)? toWav;

  SarvamProvider({
    required this.apiKey,
    this.sttModel = 'saaras:v3',
    this.textModel = 'sarvam-105b',
    http.Client? client,
    this.pollInterval = const Duration(seconds: 4),
    this.batchTimeout = const Duration(minutes: 15),
    this.toWav,
  }) : _client = client ?? http.Client();

  @override
  ProviderId get id => ProviderId.sarvam;

  @override
  RecordingFormat get recordingFormat => RecordingFormat.wav16kMono;

  Map<String, String> get _headers => {'api-subscription-key': apiKey};

  @override
  Future<Transcription> transcribe(File audio, {required bool translate}) async {
    final isWav = p.extension(audio.path).toLowerCase() == '.wav';
    if (isWav) return _transcribeWav(await audio.readAsBytes(), translate);

    // The instant endpoint reads speech reliably from 16 kHz mono WAV, while
    // the batch job returned empty transcripts for raw m4a. So convert first
    // and use the batch API only if the platform cannot.
    final converted = await toWav?.call(audio);
    if (converted != null) {
      try {
        return await _transcribeWav(await converted.readAsBytes(), translate);
      } finally {
        try {
          await converted.delete();
        } catch (_) {}
      }
    }

    final bytes = await audio.readAsBytes();
    final original = await _batch(audio, bytes, 'transcribe');
    final english =
        translate ? (await _batch(audio, bytes, 'translate')).text : '';
    return Transcription(
      text: original.text,
      english: english,
      languageCode: original.languageCode,
    );
  }

  Future<Transcription> _transcribeWav(Uint8List bytes, bool translate) async {
    final native = <String>[];
    final english = <String>[];
    String? language;
    for (final chunk in splitWav(bytes)) {
      final t = await _syncCall(chunk, 'transcribe');
      native.add(t.text);
      language ??= t.languageCode;
      if (translate) english.add((await _syncCall(chunk, 'translate')).text);
    }
    return Transcription(
      text: _join(native),
      english: _join(english),
      languageCode: language,
    );
  }

  static String _join(List<String> parts) =>
      parts.map((s) => s.trim()).where((s) => s.isNotEmpty).join(' ');

  Future<({String text, String? languageCode})> _syncCall(
      Uint8List wav, String mode) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/speech-to-text'))
      ..headers.addAll(_headers)
      ..fields['model'] = sttModel
      ..fields['mode'] = mode
      ..fields['language_code'] = 'unknown'
      ..files.add(http.MultipartFile.fromBytes('file', wav,
          filename: 'chunk.wav'));
    final res = await http.Response.fromStream(await _client.send(req));
    checkStatus(res.statusCode, res.body, 'Sarvam');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      text: (j['transcript'] ?? '').toString(),
      languageCode: j['language_code'] as String?,
    );
  }

  // ---- Batch job API -------------------------------------------------------

  Future<({String text, String? languageCode})> _batch(
      File audio, Uint8List bytes, String mode) async {
    final name = p.basename(audio.path);
    final jsonHeaders = {..._headers, 'Content-Type': 'application/json'};

    final created = await _postJson('$_base/speech-to-text/job/v1', {
      'job_parameters': {
        'model': sttModel,
        'mode': mode,
        'language_code': 'unknown',
      },
    }, jsonHeaders);
    final jobId = findString(created, 'job_id');
    if (jobId == null) {
      throw const ProviderException('Sarvam did not return a job id.');
    }

    final upload = await _postJson(
      '$_base/speech-to-text/job/v1/upload-files',
      {
        'job_id': jobId,
        'files': [name],
      },
      jsonHeaders,
    );
    final uploadUrl = findUploadUrl(upload, name);
    if (uploadUrl == null) {
      throw const ProviderException('Sarvam did not return an upload URL.');
    }
    final put = await _client.put(Uri.parse(uploadUrl), headers: {
      'Content-Type': 'application/octet-stream',
      if (uploadUrl.contains('blob.core.windows.net'))
        'x-ms-blob-type': 'BlockBlob',
    }, body: bytes);
    if (put.statusCode >= 300) {
      throw ProviderException('Audio upload failed (${put.statusCode}).');
    }

    await _postJson(
        '$_base/speech-to-text/job/v1/$jobId/start', <String, dynamic>{}, jsonHeaders);

    final deadline = DateTime.now().add(batchTimeout);
    Map<String, dynamic> status;
    while (true) {
      final res = await _client.get(
        Uri.parse('$_base/speech-to-text/job/v1/$jobId/status'),
        headers: _headers,
      );
      checkStatus(res.statusCode, res.body, 'Sarvam');
      status = jsonDecode(res.body) as Map<String, dynamic>;
      final state = (status['job_state'] ?? '').toString().toLowerCase();
      if (state == 'completed') break;
      if (state == 'failed') {
        throw ProviderException(
            'Sarvam job failed: ${findString(status, 'error_message') ?? 'unknown error'}');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const ProviderException('Sarvam took too long to transcribe.');
      }
      await Future<void>.delayed(pollInterval);
    }

    final outputName = outputFileName(status) ?? '0.json';
    final dl = await _postJson('$_base/speech-to-text/job/v1/download-files', {
      'job_id': jobId,
      'files': [outputName],
    }, jsonHeaders);

    var result = dl;
    if (findString(dl, 'transcript') == null) {
      final url = findUploadUrl(dl, outputName);
      if (url == null) {
        throw const ProviderException('Sarvam returned no transcript.');
      }
      final res = await _client.get(Uri.parse(url));
      checkStatus(res.statusCode, res.body, 'Sarvam');
      result = jsonDecode(res.body);
    }
    return (
      text: findString(result, 'transcript') ?? '',
      languageCode: findString(result, 'language_code'),
    );
  }

  Future<dynamic> _postJson(
      String url, Map<String, dynamic> body, Map<String, String> headers) async {
    final res = await _client.post(Uri.parse(url),
        headers: headers, body: jsonEncode(body));
    checkStatus(res.statusCode, res.body, 'Sarvam');
    return res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
  }

  // ---- Text model ----------------------------------------------------------

  @override
  Future<NoteSummary> summarize(String text) async =>
      summaryFromReply(await completeJson('$summaryPrompt$text'));

  @override
  Future<String> completeJson(String prompt) async {
    final res = await _client.post(
      Uri.parse('$_base/v1/chat/completions'),
      headers: {
        ..._headers,
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': textModel,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );
    checkStatus(res.statusCode, res.body, 'Sarvam');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return (j['choices'] as List).first['message']['content'] as String;
  }
}

/// The first result file listed in a job status (`job_details[].outputs[]`),
/// ignoring the `inputs` entries that carry the uploaded file's own name.
String? outputFileName(dynamic status) {
  final details = status is Map ? status['job_details'] : null;
  if (details is List) {
    for (final d in details) {
      final outputs = d is Map ? d['outputs'] : null;
      if (outputs is List) {
        for (final o in outputs) {
          final name = o is Map ? o['file_name'] : null;
          if (name is String && name.isNotEmpty) return name;
        }
      }
    }
  }
  return null;
}

/// Depth-first search for the first string value stored under [key].
String? findString(dynamic node, String key) {
  if (node is Map) {
    final v = node[key];
    if (v is String && v.isNotEmpty) return v;
    for (final child in node.values) {
      final r = findString(child, key);
      if (r != null) return r;
    }
  } else if (node is List) {
    for (final child in node) {
      final r = findString(child, key);
      if (r != null) return r;
    }
  }
  return null;
}

/// Finds a presigned URL in a response whose exact shape is not documented:
/// prefers a URL stored under [fileName], else the first http(s) string.
String? findUploadUrl(dynamic node, String fileName) {
  String? first;
  String? walk(dynamic n, {bool underName = false}) {
    if (n is String) {
      if (n.startsWith('http')) {
        if (underName) return n;
        first ??= n;
      }
    } else if (n is Map) {
      for (final e in n.entries) {
        final r = walk(e.value, underName: underName || e.key == fileName);
        if (r != null) return r;
      }
    } else if (n is List) {
      for (final c in n) {
        final r = walk(c, underName: underName);
        if (r != null) return r;
      }
    }
    return null;
  }

  return walk(node) ?? first;
}
