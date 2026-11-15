import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/providers/voice_match.dart';
import 'package:voice_notes/ui/home_page.dart';
import 'package:voice_notes/ui/theme.dart';

/// Transcribes each file as lines spoken by "S1" then "S2", except files
/// named bad*, which fail.
class _Provider implements AiProvider {
  int summaries = 0;

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio,
      {required bool translate,
      List<String> vocabulary = const [],
      bool speakers = false}) async {
    if (p.basename(audio.path).startsWith('bad')) {
      throw const ProviderException('No luck.');
    }
    return const Transcription(text: 'hello there', languageCode: 'en', lines: [
      TimedLine(0, 1000, 'hello', speaker: 'S1'),
      TimedLine(1000, 2000, 'there', speaker: 'S2'),
    ]);
  }

  @override
  Future<NoteSummary> summarize(String text,
      {List<String> tags = const []}) async {
    summaries++;
    return NoteSummary('Title', 'Summary of: $text');
  }

  @override
  Future<String> completeJson(String prompt) async => '{}';
}

class _Settings extends SettingsStore {
  final AiProvider provider;
  _Settings(this.provider);

  @override
  AiProvider? build(ProviderId id) => provider;
}

void main() {
  sqfliteFfiInit();
  final ffi = databaseFactoryFfi;
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('fixes'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> audio(String name, [Directory? dir]) =>
      File(p.join((dir ?? tmp).path, name)).writeAsBytes([1, 2, 3]);

  group('speaker ids across the recordings of a note', () {
    test('the first recording keeps its ids', () {
      expect(noteSpeakerIds(ids: ['S1', 'S2'], known: {}),
          {'S1': 'S1', 'S2': 'S2'});
    });

    test('unrecognised voices in a later recording get fresh numbers', () {
      expect(
          noteSpeakerIds(ids: ['S1', 'S2'], known: {}, taken: {'S1', 'S2'}),
          {'S1': 'S3', 'S2': 'S4'});
    });

    test('a recognised voice takes the id it already has', () {
      final known = {
        'S1': [1.0, 0.0],
        'S2': [0.0, 1.0],
      };
      final ids = noteSpeakerIds(
        ids: ['S1', 'S2'],
        // This recording heard them in the other order, plus a stranger
        // with no usable voiceprint.
        voices: {
          'S1': [0.1, 0.9],
          'S2': [0.9, 0.1],
        },
        known: known,
        taken: {'S1', 'S2'},
      );
      expect(ids, {'S1': 'S2', 'S2': 'S1'});
      expect(
          noteSpeakerIds(ids: ['S1'], known: known, taken: {'S1', 'S2'}),
          {'S1': 'S3'});
    });

    test('"You" is left alone and renaming applies the map', () {
      expect(noteSpeakerIds(ids: [youSpeakerId, 'S1'], known: {}, taken: {'S1'}),
          {'S1': 'S2'});
      final lines = renameSpeakers(const [
        TimedLine(0, 1, 'a', speaker: 'S1'),
        TimedLine(1, 2, 'b', speaker: youSpeakerId),
        TimedLine(2, 3, 'c'),
      ], {
        'S1': 'S2'
      });
      expect(lines.map((l) => l.speaker), ['S2', youSpeakerId, null]);
    });

    test('a second recording never reuses the first one\'s numbers', () async {
      final db = await NotesDb.open(path: p.join(tmp.path, 's.db'), factory: ffi);
      final state = AppState(_Settings(_Provider()), db,
          audioDirectory: () async => tmp);
      final note = await state.addAudio((await audio('a.m4a')).path);
      await state.settled();
      await state.addSegment(note.id!, (await audio('b.m4a')).path);
      await state.settled();
      expect(state.byId(note.id!)!.speakerIds, ['S1', 'S2', 'S3', 'S4']);
      await db.close();
    });
  });

  group('recordings whose folder moved', () {
    test('are found again by name; missing ones keep their text', () async {
      final path = p.join(tmp.path, 'm.db');
      final now = await Directory(p.join(tmp.path, 'now')).create();
      var db = await NotesDb.open(path: path, factory: ffi);
      await db.insert(Note(
        provider: 'gemini',
        createdAt: DateTime(2026),
        segments: const [
          Segment(
              audioPath: '/var/old-container/Documents/audio/rec_1.m4a',
              transcript: 'kept',
              status: NoteStatus.done),
          Segment(
              position: 1,
              audioPath: '/var/old-container/Documents/audio/rec_2.m4a',
              transcript: 'gone',
              status: NoteStatus.done),
        ],
      ));
      await audio('rec_1.m4a', now);
      await db.close();

      db = await NotesDb.open(path: path, factory: ffi, audioRoot: now.path);
      final state = AppState(_Settings(_Provider()), db,
          audioDirectory: () async => now);
      await state.init();
      final segs = state.allNotes.single.segments;
      expect(segs[0].audioPath, p.join(now.path, 'rec_1.m4a'));
      expect(segs[1].hasAudio, isFalse);
      expect(state.allNotes.single.transcript, contains('gone'));
      // And it is saved, not just patched in memory.
      expect((await db.all()).single.segments[0].audioPath,
          p.join(now.path, 'rec_1.m4a'));
      await db.close();
    });
  });

  test('a failed last recording does not hold back the summary', () async {
    final db = await NotesDb.open(path: p.join(tmp.path, 'f.db'), factory: ffi);
    final provider = _Provider();
    final settings = _Settings(provider);
    final state = AppState(settings, db, audioDirectory: () async => tmp);
    final note = await state.addAudio((await audio('a.m4a')).path, live: true);
    await state.addSegment(note.id!, (await audio('bad.m4a')).path);
    await state.endLive(note.id!);
    await state.settled();
    final n = state.byId(note.id!)!;
    expect(n.segments.map((s) => s.status),
        [NoteStatus.done, NoteStatus.failed]);
    expect(n.summary, isNotEmpty);
    expect(provider.summaries, 1);
    expect(state.live(note.id!), isNull);
    await db.close();
  });

  test('a note whose only recording failed gets no made-up title', () async {
    final db = await NotesDb.open(path: p.join(tmp.path, 'g.db'), factory: ffi);
    final provider = _Provider();
    final state =
        AppState(_Settings(provider), db, audioDirectory: () async => tmp);
    final note = await state.addAudio((await audio('bad.m4a')).path);
    await state.settled();
    expect(state.byId(note.id!)!.title, isEmpty);
    expect(provider.summaries, 0);
    await db.close();
  });

  group('TimeoutClient', () {
    test('gives up on a provider that never answers', () async {
      final client = TimeoutClient(
          inner: MockClient((_) => Completer<http.Response>().future),
          reply: const Duration(milliseconds: 20));
      expect(
          client.get(Uri.parse('https://example.invalid')),
          throwsA(isA<ProviderException>()));
    });

    test('passes a normal reply through', () async {
      final client =
          TimeoutClient(inner: MockClient((_) async => http.Response('ok', 200)));
      expect((await client.get(Uri.parse('https://example.invalid'))).body, 'ok');
    });
  });

  group('home screen fits', () {
    for (final (name, size, scale) in [
      ('a phone on its side', const Size(640, 360), 1.0),
      ('a small phone at 200% text', const Size(360, 640), 2.0),
    ]) {
      testWidgets(name, (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late AppState state;
        await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp('home');
          final db =
              await NotesDb.open(path: p.join(dir.path, 'h.db'), factory: ffi);
          for (var i = 0; i < 6; i++) {
            await db.insert(Note(
              title: 'Note $i',
              summary: 'Summary $i',
              provider: 'gemini',
              createdAt: DateTime.now().subtract(Duration(hours: i)),
              status: NoteStatus.done,
              segments: const [
                Segment(
                    audioPath: '', transcript: 'hello', status: NoteStatus.done)
              ],
            ));
          }
          // No key saved, so the setup banner shows too: the tallest case.
          state = AppState(SettingsStore(), db);
          await state.init();
          await state.createFolder('Work');
        });
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: const HomePage(),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
        // The notes can be reached by scrolling.
        await tester.scrollUntilVisible(find.text('Note 5'), 200,
            scrollable: find.byType(Scrollable).first);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
