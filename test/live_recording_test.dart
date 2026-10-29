import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/data/templates.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/services/recorder_service.dart';

/// Transcribes each part as a long sentence naming the file, and answers
/// template prompts with one section.
class _Provider implements AiProvider {
  final prompts = <String>[];
  final summarised = <String>[];

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio,
          {required bool translate,
          List<String> vocabulary = const [],
          bool speakers = false}) async =>
      Transcription(
          text: '${p.basenameWithoutExtension(audio.path)}: '
              '${'we agreed to move the launch to November. ' * 8}');

  @override
  Future<NoteSummary> summarize(String text,
      {List<String> tags = const []}) async {
    summarised.add(text);
    return const NoteSummary('Launch planning', 'The launch moves.');
  }

  @override
  Future<String> completeJson(String prompt) async {
    prompts.add(prompt);
    return '{"sections": [{"heading": "Decisions", '
        '"body": "- Launch in November (${prompts.length})"}]}';
  }
}

class _Settings extends SettingsStore {
  final AiProvider provider;
  _Settings(this.provider);

  @override
  AiProvider? build(ProviderId id) => provider;
}

NoteTemplate get _minutes =>
    builtInTemplates.firstWhere((t) => t.id == 'meeting');

void main() {
  sqfliteFfiInit();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('splitting', () {
    test('waits for a pause after a minute, never past three', () {
      expect(shouldSplit(const Duration(seconds: 30), const Duration(seconds: 2)),
          isFalse);
      expect(shouldSplit(const Duration(seconds: 70), Duration.zero), isFalse);
      expect(
          shouldSplit(const Duration(seconds: 70),
              const Duration(milliseconds: 800)),
          isTrue);
      expect(shouldSplit(const Duration(minutes: 3), Duration.zero), isTrue);
    });
  });

  group('live recording', () {
    late Directory tmp;
    late NotesDb db;
    late _Provider provider;
    late AppState state;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('live_test');
      db = await NotesDb.open(
          path: p.join(tmp.path, 'notes.db'), factory: databaseFactoryFfi);
      provider = _Provider();
      state = AppState(_Settings(provider), db);
    });
    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<String> part(String name) async {
      final f = File(p.join(tmp.path, name));
      await f.writeAsBytes([0, 1, 2]);
      return f.path;
    }

    test('sums up only once the recording ends', () async {
      final note = await state.addAudio(await part('one.m4a'), live: true);
      await state.settled();
      await state.addSegment(note.id!, await part('two.m4a'));
      await state.settled();

      var n = state.byId(note.id!)!;
      expect(n.segments, hasLength(2));
      expect(provider.summarised, isEmpty);
      expect(n.title, startsWith('one:'));

      await state.endLive(note.id!);
      await state.settled();
      n = state.byId(note.id!)!;
      expect(provider.summarised.single, contains('two:'));
      expect(n.summary, 'The launch moves.');
      expect(state.live(note.id!), isNull);
    });

    test('live notes fold in new parts, then get a last full pass', () async {
      final note = await state.addAudio(await part('one.m4a'),
          live: true, liveNotes: _minutes);
      await state.settled();

      expect(provider.prompts, hasLength(1));
      expect(provider.prompts.single, contains('Notes so far:\n(none yet)'));
      expect(provider.prompts.single, contains('Said since:\none:'));
      expect(state.byId(note.id!)!.output('meeting'), isNotNull);
      expect(state.live(note.id!)!.updatedAt, isNotNull);

      // Too soon after the last update: waits.
      await state.addSegment(note.id!, await part('two.m4a'));
      await state.settled();
      expect(provider.prompts, hasLength(1));

      await state.endLive(note.id!);
      await state.settled();
      expect(provider.prompts, hasLength(2));
      expect(provider.prompts.last, contains('You turn voice notes into'));
      expect(provider.prompts.last, contains('two:'));
      final n = state.byId(note.id!)!;
      expect(n.output('meeting')!.text, contains('(2)'));
      expect(n.isStale, isFalse);
    });

    test('a discarded recording leaves nothing to sum up', () async {
      final note = await state.addAudio(await part('one.m4a'), live: true);
      await state.endLive(note.id!, discard: true);
      await state.delete(note.id!);
      await state.settled();
      expect(state.byId(note.id!), isNull);
      expect(provider.summarised, isEmpty);
    });
  });
}
