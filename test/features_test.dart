import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/dictionary.dart';
import 'package:voice_notes/data/find_replace.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/data/srt_export.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/providers/gemini_provider.dart';
import 'package:voice_notes/providers/openai_provider.dart';
import 'package:voice_notes/providers/speaker_assign.dart';
import 'package:voice_notes/services/model_store.dart';
import 'package:voice_notes/services/share_intake.dart';

class _Provider implements AiProvider {
  final Transcription result;
  final vocabularies = <List<String>>[];
  final speakerFlags = <bool>[];
  _Provider(this.result);

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio,
      {required bool translate,
      List<String> vocabulary = const [],
      bool speakers = false}) async {
    vocabularies.add(vocabulary);
    speakerFlags.add(speakers);
    return result;
  }

  @override
  Future<NoteSummary> summarize(String text) async =>
      NoteSummary('Title', 'Summary of: $text');

  @override
  Future<String> completeJson(String prompt) async => '{}';
}

class _Settings extends SettingsStore {
  final AiProvider provider;
  _Settings(this.provider);

  @override
  AiProvider? build(ProviderId id) => provider;
}

Note _note({
  String title = 'Visit',
  String summary = '',
  List<Segment> segments = const [],
  String? enrichedHash,
}) =>
    Note(
      id: 1,
      title: title,
      summary: summary,
      provider: 'gemini',
      createdAt: DateTime(2026, 1, 1),
      enrichedHash: enrichedHash,
    ).withSegments(segments);

void main() {
  sqfliteFfiInit();
  final ffi = databaseFactoryFfi;
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('features'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<File> audio(String name) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes([0, 1, 2]);
    return f;
  }

  group('custom dictionary', () {
    test('parses terms and "sounds like" spellings', () {
      final d = Dictionary.fromLines([
        'Amoxicillin',
        'amoxicilin, amox a sill in => Amoxicillin',
        '   ',
        'Rao',
      ]);
      expect(d.entries.map((e) => e.term), ['Amoxicillin', 'Amoxicillin', 'Rao']);
      expect(d.entries[1].heard, ['amoxicilin', 'amox a sill in']);
      expect(d.hints, ['Amoxicillin', 'Amoxicillin', 'Rao']);
      expect(Dictionary.fromLines(d.toLines()).toLines(), d.toLines());
    });

    test('corrects misspellings and casing as whole words only', () {
      final d = Dictionary.fromLines([
        'amoxicilin => Amoxicillin',
        'dr rao => Dr. Rao',
        'Kubernetes',
      ]);
      expect(d.apply('Give Amoxicilin and see DR RAO.'),
          'Give Amoxicillin and see Dr. Rao.');
      expect(d.apply('run kubernetes today'), 'run Kubernetes today');
      // Not inside a longer word.
      expect(d.apply('amoxicilins'), 'amoxicilins');
    });

    test('longer spellings win over their prefixes', () {
      final d = Dictionary.fromLines(['new york => NY', 'new york city => NYC']);
      expect(d.apply('in new york city'), 'in NYC');
    });

    test('keeps special characters in a spelling literal', () {
      final d = Dictionary.fromLines(['c++ => C++']);
      expect(d.apply('I like c++ a lot'), 'I like C++ a lot');
    });

    test('applies to text, English and every line, keeping speakers', () {
      final d = Dictionary.fromLines(['rao => Rao']);
      final t = d.applyTo(const Transcription(
        text: 'hi rao',
        english: 'hello rao',
        languageCode: 'en',
        lines: [TimedLine(0, 1000, 'hi rao', english: 'hello rao', speaker: 'S1')],
      ));
      expect(t.text, 'hi Rao');
      expect(t.english, 'hello Rao');
      expect(t.lines.single.text, 'hi Rao');
      expect(t.lines.single.english, 'hello Rao');
      expect(t.lines.single.speaker, 'S1');
      expect(t.languageCode, 'en');
    });

    test('hint is trimmed to fit a provider prompt', () {
      expect(vocabularyHint(['a', 'b']), 'a, b');
      expect(vocabularyHint([]), '');
      final long = vocabularyHint([for (var i = 0; i < 500; i++) 'word$i']);
      expect(long.length, lessThanOrEqualTo(600));
      expect(long, startsWith('word0, word1'));
    });

    test('is used when transcribing: hint sent, result corrected', () async {
      final db = await NotesDb.open(path: p.join(tmp.path, 'd.db'), factory: ffi);
      final provider =
          _Provider(const Transcription(text: 'see dr rao', languageCode: 'en'));
      final settings = _Settings(provider)
        ..dictionary = Dictionary.fromLines(['dr rao => Dr. Rao', 'Aspirin']);
      final state = AppState(settings, db);
      final note = await state.addAudio((await audio('a.m4a')).path);
      await state.settled();

      expect(provider.vocabularies.single, ['Dr. Rao', 'Aspirin']);
      expect(state.byId(note.id!)!.transcript, 'see Dr. Rao');
      await db.close();
    });
  });

  group('providers', () {
    test('OpenAI sends the vocabulary as the prompt', () async {
      final prompts = <String?>[];
      final client = MockClient((req) async {
        final body = utf8.decode(req.bodyBytes, allowMalformed: true);
        prompts.add(
            RegExp(r'name="prompt"\r\n\r\n([^\r]*)').firstMatch(body)?[1]);
        return http.Response(jsonEncode({'text': 'x', 'language': 'en'}), 200);
      });
      final f = await audio('a.m4a');
      await OpenAiProvider(apiKey: 'k', client: client).transcribe(f,
          translate: true, vocabulary: ['Rao', 'Aspirin']);
      expect(prompts, ['Rao, Aspirin', 'Rao, Aspirin']);

      prompts.clear();
      await OpenAiProvider(apiKey: 'k', client: client)
          .transcribe(f, translate: false);
      expect(prompts, [null]);
    });

    test('Gemini prompt carries the vocabulary and the speaker request', () {
      final plain = GeminiProvider.transcribePrompt(
          translate: true, vocabulary: ['Rao']);
      expect(plain, contains('spell them exactly like this when they are said: Rao'));
      expect(plain, isNot(contains('"turns"')));
      final labelled =
          GeminiProvider.transcribePrompt(translate: false, speakers: true);
      expect(labelled, contains('"turns"'));
      expect(labelled, contains('Leave "english" empty'));
      expect(labelled, isNot(contains('spell them')));
    });

    test('Gemini speaker turns become labelled, timed lines', () {
      final t = GeminiProvider.transcriptionFromTurns({
        'language': 'en-US',
        'turns': [
          {'speaker': 'S1', 'start': '00:01', 'end': '00:04', 'text': 'Hello'},
          {'speaker': 'S2', 'start': '00:04', 'end': '01:10.5', 'text': 'Hi there'},
          {'speaker': 'S1', 'start': 'oops', 'end': '', 'text': 'Bye'},
          {'speaker': 'S2', 'text': '   '},
        ],
      });
      expect(t.languageCode, 'en-US');
      expect(t.text, 'Hello Hi there Bye');
      expect(t.lines.map((l) => l.speaker), ['S1', 'S2', 'S1']);
      expect(t.lines[0].startMs, 1000);
      expect(t.lines[0].endMs, 4000);
      expect(t.lines[1].endMs, 70500);
      // Unreadable times fall back to the previous line's end.
      expect(t.lines[2].startMs, 70500);
      expect(t.lines[2].endMs, greaterThan(t.lines[2].startMs));
      expect(t.english, '');
    });

    test('clock times parse in several shapes', () {
      expect(GeminiProvider.parseClock('1:02:03'), 3723000);
      expect(GeminiProvider.parseClock('00:07'), 7000);
      expect(GeminiProvider.parseClock(7.5), 7500);
      expect(GeminiProvider.parseClock('abc'), isNull);
      expect(GeminiProvider.parseClock(null), isNull);
      expect(GeminiProvider.parseClock('1:2:3:4'), isNull);
    });
  });

  group('speakers', () {
    test('lines take the voice that talks longest, numbered by appearance', () {
      const lines = [
        TimedLine(0, 4000, 'a'),
        TimedLine(4000, 8000, 'b'),
        TimedLine(8000, 12000, 'c'),
        TimedLine(12000, 14000, 'd'),
      ];
      final out = assignSpeakers(lines, [
        (startMs: 0, endMs: 3500, speaker: 5),
        (startMs: 3500, endMs: 9000, speaker: 2),
        (startMs: 9000, endMs: 12000, speaker: 5),
      ]);
      expect(out.map((l) => l.speaker), ['S1', 'S2', 'S1', 'S1']);
      expect(out.first.text, 'a');
    });

    test('without any turns lines are left unlabelled', () {
      const lines = [TimedLine(0, 1000, 'a')];
      expect(assignSpeakers(lines, const []).single.speaker, isNull);
    });

    test('names fall back to Speaker N and survive storage', () async {
      final db = await NotesDb.open(path: p.join(tmp.path, 's.db'), factory: ffi);
      final provider = _Provider(const Transcription(
        text: 'hello hi',
        languageCode: 'en',
        lines: [
          TimedLine(0, 1000, 'hello', speaker: 'S1'),
          TimedLine(1000, 2000, 'hi', speaker: 'S2'),
        ],
      ));
      final state = AppState(_Settings(provider)..identifySpeakers = true, db);
      final note = await state.addAudio((await audio('a.m4a')).path);
      await state.settled();
      expect(provider.speakerFlags.single, isTrue);

      var n = state.byId(note.id!)!;
      expect(n.speakerIds, ['S1', 'S2']);
      expect(n.speakerLabel('S2'), 'Speaker 2');

      await state.renameSpeaker(n.id!, 'S1', '  Dr. Rao ');
      n = state.byId(n.id!)!;
      expect(n.speakerLabel('S1'), 'Dr. Rao');

      final reloaded = (await db.all()).single;
      expect(reloaded.speakerLabel('S1'), 'Dr. Rao');
      expect(reloaded.segments.single.lines.map((l) => l.speaker), ['S1', 'S2']);

      expect(speakerTranscript(reloaded), 'Dr. Rao: hello\n\nSpeaker 2: hi');
      expect(srtText(reloaded), contains('Dr. Rao: hello'));

      // An empty name goes back to the default.
      await state.renameSpeaker(n.id!, 'S1', '');
      expect(state.byId(n.id!)!.speakerLabel('S1'), 'Speaker 1');
      await db.close();
    });

    test('same speaker in a row is one paragraph', () {
      final n = _note(segments: [
        const Segment(
          audioPath: 'a',
          status: NoteStatus.done,
          transcript: 'one two three',
          lines: [
            TimedLine(0, 1, 'one', speaker: 'S1'),
            TimedLine(1, 2, 'two', speaker: 'S1'),
            TimedLine(2, 3, 'three', speaker: 'S2'),
          ],
        ),
        const Segment(audioPath: 'b', status: NoteStatus.done, transcript: 'plain'),
      ]);
      expect(speakerTranscript(n), 'Speaker 1: one two\n\nSpeaker 2: three\n\nplain');
      expect(hasSpeakers(n), isTrue);
    });

    test('speaker models download and install separately from Whisper', () async {
      final seg = utf8.encode('segmentation');
      final emb = utf8.encode('embedding model');
      ModelFile file(String name, List<int> b) => ModelFile(name,
          'https://example.test/$name', b.length, sha256.convert(b).toString());
      final store = ModelStore(
        baseDir: () async => tmp,
        client: () => MockClient((req) async => http.Response.bytes(
            req.url.pathSegments.last == 's.onnx' ? seg : emb, 200)),
        catalog: const [],
        speakerSegmentation: file('s.onnx', seg),
        speakerEmbedding: file('e.onnx', emb),
      );
      await store.load();
      expect(store.isInstalled(speakerModelsId), isFalse);
      expect(store.installedSpeakers(), isNull);

      expect(await store.download(speakerModelsId), isNull);
      expect(store.isInstalled(speakerModelsId), isTrue);
      final paths = store.installedSpeakers()!;
      expect(File(paths.segmentation).readAsBytesSync(), seg);
      expect(File(paths.embedding).readAsBytesSync(), emb);

      final again = ModelStore(
        baseDir: () async => tmp,
        catalog: const [],
        speakerSegmentation: file('s.onnx', seg),
        speakerEmbedding: file('e.onnx', emb),
      );
      await again.load();
      expect(again.isInstalled(speakerModelsId), isTrue);

      await again.delete(speakerModelsId);
      expect(again.isInstalled(speakerModelsId), isFalse);
      expect(File(paths.segmentation).existsSync(), isFalse);
    });
  });

  group('find and replace', () {
    final seg = Segment(
      audioPath: 'a',
      status: NoteStatus.done,
      transcript: 'Jon came. jon left.',
      english: 'Jon came. jon left.',
      lines: const [
        TimedLine(0, 1, 'Jon came.', english: 'Jon came.'),
        TimedLine(1, 2, 'jon left.', english: 'jon left.'),
      ],
    );

    test('counts matches, optionally matching case', () {
      final n = _note(title: 'About Jon', segments: [seg]);
      expect(countInNote(n, TextReplacer('jon', 'John')), 1 + 2 + 2);
      expect(countInNote(n, TextReplacer('jon', 'John', matchCase: true)), 1 + 1);
      expect(countInNote(n, TextReplacer('', 'x')), 0);
      expect(countInNote(n, TextReplacer('zzz', 'x')), 0);
    });

    test('treats the search as plain text, not a pattern', () {
      final r = TextReplacer('a.b', 'X');
      expect(r.apply('a.b axb'), 'X axb');
    });

    test('replaces everywhere and reports the recordings that changed', () {
      final other = const Segment(
          audioPath: 'b', status: NoteStatus.done, transcript: 'nothing here');
      final n = _note(title: 'Jon', summary: 'Jon visited', segments: [seg, other]);
      final r = replaceInNote(n, TextReplacer('jon', 'John'))!;
      expect(r.note.title, 'John');
      expect(r.note.summary, 'John visited');
      expect(r.note.transcript, 'John came. John left.\n\nnothing here');
      expect(r.changed, hasLength(1));
      expect(r.changed.single.lines.map((l) => l.text),
          ['John came.', 'John left.']);
      expect(r.changed.single.lines.first.english, 'John came.');
      expect(replaceInNote(n, TextReplacer('zzz', 'x')), isNull);
    });

    test('an up-to-date summary stays up to date, a stale one stays stale', () {
      final current = _note(
          summary: 'Jon visited',
          segments: [seg],
          enrichedHash: textHash(seg.transcript, seg.english));
      expect(current.isStale, isFalse);
      expect(replaceInNote(current, TextReplacer('jon', 'John'))!.note.isStale,
          isFalse);

      final stale = _note(
          summary: 'Jon visited', segments: [seg], enrichedHash: 'old');
      expect(stale.isStale, isTrue);
      expect(replaceInNote(stale, TextReplacer('jon', 'John'))!.note.isStale,
          isTrue);
    });

    test('also fixes the clinical note', () {
      final n = Note(
        id: 1,
        provider: 'gemini',
        createdAt: DateTime(2026),
        clinical: const ClinicalReport(
            interpretation: 'Patient: Jon', verify: ['Jon allergy']),
      ).withSegments([seg]);
      final r = replaceInNote(n, TextReplacer('jon', 'John'))!;
      expect(r.note.clinical!.interpretation, 'Patient: John');
      expect(r.note.clinical!.verify, ['John allergy']);
    });

    test('a snippet shows the words around the match', () {
      final n = _note(segments: [
        Segment(
            audioPath: 'a',
            status: NoteStatus.done,
            transcript: '${'word ' * 30}needle${' word' * 30}'),
      ]);
      final s = matchSnippet(n, 'NEEDLE', radius: 10)!;
      expect(s, startsWith('…'));
      expect(s, endsWith('…'));
      expect(s, contains('needle'));
      expect(s.length, lessThan(40));
      expect(matchSnippet(n, 'absent'), isNull);
      expect(matchSnippet(n, '  '), isNull);
    });

    test('replaceIn saves changes and only touches the chosen notes', () async {
      final db = await NotesDb.open(path: p.join(tmp.path, 'r.db'), factory: ffi);
      final provider =
          _Provider(const Transcription(text: 'Jon here', languageCode: 'en'));
      final state = AppState(_Settings(provider), db);
      final a = await state.addAudio((await audio('a.m4a')).path);
      final b = await state.addAudio((await audio('b.m4a')).path);
      await state.settled();

      final hits = state.findMatches(TextReplacer('jon', 'John'));
      expect(hits, hasLength(2));
      expect(await state.replaceIn([a.id!], TextReplacer('jon', 'John')), 1);

      expect(state.byId(a.id!)!.transcript, 'John here');
      expect(state.byId(b.id!)!.transcript, 'Jon here');
      final stored = {for (final n in await db.all()) n.id: n};
      expect(stored[a.id]!.transcript, 'John here');
      expect(stored[a.id]!.segments.single.transcript, 'John here');
      expect(stored[b.id]!.transcript, 'Jon here');
      expect(state.findMatches(TextReplacer('jon', 'x')).single.note.id, b.id);
      await db.close();
    });
  });

  group('folders', () {
    test('create, file, filter, rename and delete', () async {
      final db = await NotesDb.open(path: p.join(tmp.path, 'f.db'), factory: ffi);
      final state = AppState(
          _Settings(_Provider(const Transcription(text: 'hi', languageCode: 'en'))),
          db);
      final a = await state.addAudio((await audio('a.m4a')).path);
      final b = await state.addAudio((await audio('b.m4a')).path);
      await state.settled();

      expect(await state.createFolder('  '), isNull);
      final work = (await state.createFolder('Work'))!;
      // The same name, in any case, is the same folder.
      expect((await state.createFolder('work'))!.id, work.id);
      expect(state.folders, hasLength(1));

      await state.moveToFolder(a.id!, work.id);
      expect(state.byId(a.id!)!.folderId, work.id);
      expect((await db.all()).firstWhere((n) => n.id == a.id).folderId, work.id);

      state.folderFilter = work.id;
      expect(state.notes.map((n) => n.id), [a.id]);
      state.folderFilter = AppState.unfiled;
      expect(state.notes.map((n) => n.id), [b.id]);
      state.folderFilter = null;
      expect(state.notes, hasLength(2));
      expect(state.noteCountIn(work.id), 1);
      expect(state.noteCountIn(AppState.unfiled), 1);

      // The search applies inside the folder.
      state.folderFilter = work.id;
      state.query = 'zzz';
      expect(state.notes, isEmpty);
      state.query = '';

      await state.renameFolder(work.id!, 'Clinic');
      expect(state.folders.single.name, 'Clinic');

      await state.deleteFolder(work.id!);
      expect(state.folders, isEmpty);
      expect(state.folderFilter, isNull, reason: 'the open folder is gone');
      expect(state.byId(a.id!)!.folderId, isNull, reason: 'notes are kept');
      expect((await db.all()), hasLength(2));
      expect((await db.folders()), isEmpty);

      await state.moveToFolder(a.id!, work.id);
      await state.moveToFolder(a.id!, null);
      expect(state.byId(a.id!)!.folderId, isNull);
      await db.close();
    });

    test('a version 4 database upgrades without losing notes', () async {
      final path = p.join(tmp.path, 'v4.db');
      final old = await ffi.openDatabase(path,
          options: OpenDatabaseOptions(
              version: 4,
              onCreate: (db, _) async {
                await db.execute('''
                  CREATE TABLE notes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '',
                    transcript TEXT NOT NULL DEFAULT '', english TEXT NOT NULL DEFAULT '',
                    language_code TEXT, audio_path TEXT NOT NULL, provider TEXT NOT NULL,
                    duration_ms INTEGER, created_at INTEGER NOT NULL, status TEXT NOT NULL,
                    error TEXT, clinical TEXT, enriched_hash TEXT)''');
                await db.execute('''
                  CREATE TABLE segments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, note_id INTEGER NOT NULL,
                    position INTEGER NOT NULL, audio_path TEXT NOT NULL,
                    transcript TEXT NOT NULL DEFAULT '', english TEXT NOT NULL DEFAULT '',
                    language_code TEXT, status TEXT NOT NULL, error TEXT,
                    duration_ms INTEGER, lines TEXT)''');
              }));
      await old.insert('notes', {
        'title': 'Old',
        'provider': 'gemini',
        'created_at': 1000,
        'status': 'done',
        'audio_path': '/a.m4a',
      });
      await old.close();

      final db = await NotesDb.open(path: path, factory: ffi);
      final n = (await db.all()).single;
      expect(n.title, 'Old');
      expect(n.folderId, isNull);
      expect(n.speakerNames, isEmpty);
      final f = await db.insertFolder('Fresh');
      await db.update(n.copyWith(folderId: f.id));
      expect((await db.all()).single.folderId, f.id);
      await db.close();
    });
  });

  group('deleting audio after transcription', () {
    test('keeps the text, removes the file, and cannot be retried', () async {
      final db = await NotesDb.open(path: p.join(tmp.path, 'x.db'), factory: ffi);
      final provider =
          _Provider(const Transcription(text: 'hello', languageCode: 'en'));
      final state = AppState(_Settings(provider)..deleteAudioAfter = true, db);
      final file = await audio('a.m4a');
      final note = await state.addAudio(file.path, durationMs: 1000);
      await state.settled();

      expect(file.existsSync(), isFalse);
      final n = state.byId(note.id!)!;
      expect(n.status, NoteStatus.done);
      expect(n.transcript, 'hello');
      expect(n.segments.single.hasAudio, isFalse);
      expect((await db.all()).single.segments.single.audioPath, '');

      await state.retry(n.id!);
      await state.settled();
      expect(provider.vocabularies, hasLength(1), reason: 'not transcribed again');
      expect(state.byId(n.id!)!.transcript, 'hello');
      expect(state.byId(n.id!)!.status, NoteStatus.done);

      // The note can still be deleted, and other recordings still added.
      final more = await audio('b.m4a');
      await state.addSegment(n.id!, more.path);
      await state.settled();
      expect(state.byId(n.id!)!.segments, hasLength(2));
      await state.delete(n.id!);
      await db.close();
    });

    test('is off by default', () async {
      final db = await NotesDb.open(path: p.join(tmp.path, 'y.db'), factory: ffi);
      final state = AppState(
          _Settings(_Provider(const Transcription(text: 'hello'))), db);
      final file = await audio('a.m4a');
      await state.addAudio(file.path);
      await state.settled();
      expect(file.existsSync(), isTrue);
      await db.close();
    });

    test('keeps the audio when nothing was heard', () async {
      final db = await NotesDb.open(path: p.join(tmp.path, 'z.db'), factory: ffi);
      final state = AppState(
          _Settings(_Provider(const Transcription(text: '  ')))
            ..deleteAudioAfter = true,
          db);
      final file = await audio('a.m4a');
      await state.addAudio(file.path);
      await state.settled();
      expect(file.existsSync(), isTrue);
      await db.close();
    });
  });

  group('Indian-language models', () {
    test('catalog entries are pinned, checksummed and described', () {
      final ids = offlineModels.map((m) => m.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(
          ids,
          containsAll(['omnilingual', 'indic-hi', 'indic-ta', 'indic-te',
              'indic-ml']));
      for (final m in offlineModels) {
        for (final f in m.files) {
          expect(f.url, startsWith('https://huggingface.co/'), reason: f.name);
          expect(f.url, matches(RegExp(r'/resolve/[0-9a-f]{40}/')),
              reason: '${f.name} must be pinned to a commit');
          expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.name);
          expect(f.size, greaterThan(0));
        }
      }
    });

    test('single-file models have no decoder and cannot translate', () {
      for (final id in [
        'omnilingual',
        'indic-hi',
        'indic-ta',
        'indic-te',
        'indic-ml'
      ]) {
        final m = offlineModelById(id)!;
        expect(m.kind, isNot(ModelKind.whisper));
        expect(m.decoder, isNull);
        expect(m.canTranslate, isFalse);
        expect(m.files, hasLength(2));
      }
      expect(offlineModelById('indic-ta')!.language, 'ta');
      expect(offlineModelById('indic-ta')!.kind, ModelKind.nemoCtc);
      expect(offlineModelById('indic-hi')!.language, 'hi');
      expect(offlineModelById('indic-hi')!.encoder.url,
          contains('/ngiftsun/indicconformer-hi-int8-sherpa/'));
      expect(offlineModelById('omnilingual')!.language, isNull);
      expect(offlineModelById('omnilingual')!.kind, ModelKind.omnilingual);
      expect(offlineModelById('base')!.canTranslate, isTrue);
      expect(offlineModelById('base')!.kind, ModelKind.whisper);
    });

    test('download fetches the model, its tokens and voice detection only',
        () async {
      final modelBytes = utf8.encode('ctc model');
      final tokenBytes = utf8.encode('<unk> 0');
      final vadBytes = utf8.encode('vad');
      ModelFile file(String name, List<int> b) => ModelFile(name,
          'https://example.test/$name', b.length, sha256.convert(b).toString());
      final model = OfflineModel(
        id: 'ctc',
        label: 'CTC',
        blurb: '',
        kind: ModelKind.nemoCtc,
        language: 'ta',
        encoder: file('model.onnx', modelBytes),
        tokens: file('tokens.txt', tokenBytes),
      );
      final asked = <String>[];
      final store = ModelStore(
        baseDir: () async => tmp,
        client: () => MockClient((req) async {
          final name = req.url.pathSegments.last;
          asked.add(name);
          return http.Response.bytes(
              {'model.onnx': modelBytes, 'tokens.txt': tokenBytes}[name] ??
                  vadBytes,
              200);
        }),
        catalog: [model],
        vad: file('vad.onnx', vadBytes),
      );
      await store.load();
      expect(await store.download('ctc'), isNull);
      expect(asked, ['model.onnx', 'tokens.txt', 'vad.onnx']);
      final installed = store.installed('ctc')!;
      expect(installed.kind, ModelKind.nemoCtc);
      expect(installed.decoder, '');
      expect(File(installed.encoder).readAsBytesSync(), modelBytes);
      expect(File(installed.tokens).readAsBytesSync(), tokenBytes);

      final again = ModelStore(
          baseDir: () async => tmp,
          catalog: [model],
          vad: file('vad.onnx', vadBytes));
      await again.load();
      expect(again.isInstalled('ctc'), isTrue);
    });
  });

  group('shared files', () {
    const channel = MethodChannel('com.subnext.voicenotes/share');

    setUp(TestWidgetsFlutterBinding.ensureInitialized);

    test('imports what the platform has waiting, then removes the copies',
        () async {
      final a = await audio('shared_a.ogg');
      final b = await audio('shared_b.ogg');
      var asked = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'take');
        asked++;
        return asked == 1 ? [a.path, b.path] : <String>[];
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final imported = <String>[];
      await ShareIntake(onFile: (path) async {
        imported.add(p.basename(path));
        if (path == a.path) throw Exception('bad file');
      }).drain();

      expect(imported, ['shared_a.ogg', 'shared_b.ogg'],
          reason: 'one failure does not stop the rest');
      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isFalse);

      await ShareIntake(onFile: (_) async => fail('nothing left')).drain();
    });

    test('does nothing on a platform without share support', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await ShareIntake(onFile: (_) async => fail('no files')).drain();
    });
  });
}
