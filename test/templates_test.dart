import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/find_replace.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/data/templates.dart';
import 'package:voice_notes/providers/ai_provider.dart';

const _recipeReply = '''
{"sections": [
  {"heading": "Ingredients", "body": "- 1 cup toor dal"},
  {"heading": "", "body": ""},
  {"heading": "Steps", "body": "1. Wash the dal."}
]}''';

/// Transcribes every file as [text] and answers template prompts with a
/// recipe.
class _Provider implements AiProvider {
  final prompts = <String>[];
  String text = 'wash the dal';

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio,
          {required bool translate,
          List<String> vocabulary = const [],
          bool speakers = false}) async =>
      Transcription(text: text);

  @override
  Future<NoteSummary> summarize(String text,
          {List<String> tags = const []}) async =>
      const NoteSummary('Dal', 'How to make dal.');

  @override
  Future<String> completeJson(String prompt) async {
    prompts.add(prompt);
    return _recipeReply;
  }
}

class _Settings extends SettingsStore {
  final AiProvider provider;
  _Settings(this.provider);

  @override
  AiProvider? build(ProviderId id) => provider;
}

NoteTemplate get _recipe => builtInTemplates.firstWhere((t) => t.id == 'recipe');

Future<SettingsStore> _load(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final s = SettingsStore();
  await s.load();
  return s;
}

void main() {
  sqfliteFfiInit();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('prompt and reply', () {
    test('the prompt carries the template and the note', () {
      final prompt = templatePrompt(_recipe,
          transcript: 'dal banao', english: 'make dal');
      expect(prompt, contains('"Recipe"'));
      expect(prompt, contains('Ingredients'));
      expect(prompt, contains('never invent'));
      expect(prompt, contains('dal banao'));
      expect(prompt, contains('English translation:\nmake dal'));
    });

    test('empty sections are dropped; an empty reply is an error', () {
      final out = templateOutputFromReply(_recipe, _recipeReply);
      expect(out.name, 'Recipe');
      expect(out.sections.map((s) => s.heading), ['Ingredients', 'Steps']);
      expect(out.text, contains('Steps\n1. Wash the dal.'));
      expect(() => templateOutputFromReply(_recipe, '{"sections": []}'),
          throwsA(isA<ProviderException>()));
    });
  });

  group('settings', () {
    test('everything but clinical is on by default', () async {
      final s = await _load({});
      expect(s.clinical, isFalse);
      expect(s.enabledTemplates.map((t) => t.id),
          ['meeting', 'todo', 'recipe', 'grammar']);
    });

    test('clinical work carries over from the old settings', () async {
      expect((await _load({'useCase': 'clinical'})).clinical, isTrue);
      expect((await _load({'clinical': true})).clinical, isTrue);
      expect(
          (await _load({'clinical': true, 'useCase': 'general'})).clinical,
          isFalse);
    });

    test('switches and your own templates persist', () async {
      final s = await _load({});
      await s.setTemplateOn('grammar', false);
      await s.setTemplateOn(clinicalTemplateId, true);
      await s.saveTemplate(const NoteTemplate(
          id: 'custom_1', name: 'Sermon', instructions: 'Main points'));
      await s.saveTemplate(const NoteTemplate(
          id: 'custom_1', name: 'Sermon outline', instructions: 'Points'));

      final again = SettingsStore();
      await again.load();
      expect(again.clinical, isTrue);
      expect(again.enabledTemplates.map((t) => t.name), [
        'Meeting minutes',
        'To-do list',
        'Recipe',
        'Clinical note',
        'Sermon outline',
      ]);
      await again.deleteTemplate('custom_1');
      expect(again.template('custom_1'), isNull);
    });
  });

  group('on a note', () {
    late Directory tmp;
    late NotesDb db;
    late _Provider provider;
    late AppState state;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('templates_test');
      db = await NotesDb.open(
          path: p.join(tmp.path, 'notes.db'), factory: databaseFactoryFfi);
      provider = _Provider();
      state = AppState(_Settings(provider), db);
    });
    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<String> audio(String name) async {
      final f = File(p.join(tmp.path, name));
      await f.writeAsBytes([0, 1, 2]);
      return f.path;
    }

    test('is saved, rebuilt on regenerate and deleted', () async {
      final note = await state.addAudio(await audio('one.m4a'));
      await state.settled();
      expect(await state.applyTemplate(note.id!, _recipe), isNull);

      var n = state.byId(note.id!)!;
      expect(n.output('recipe')!.sections, hasLength(2));
      expect(n.isStale, isFalse);
      expect((await db.all()).single.output('recipe')!.name, 'Recipe');

      provider.text = 'then add salt';
      await state.addSegment(note.id!, await audio('two.m4a'));
      await state.settled();
      expect(state.byId(note.id!)!.isStale, isTrue);

      provider.prompts.clear();
      expect(await state.regenerate(note.id!), isNull);
      expect(provider.prompts.single, contains('then add salt'));
      expect(state.byId(note.id!)!.isStale, isFalse);

      await state.deleteOutput(note.id!, 'recipe');
      n = state.byId(note.id!)!;
      expect(n.outputs, isEmpty);
      expect((await db.all()).single.outputs, isEmpty);
    });

    test('find and replace reaches template outputs', () async {
      final note = await state.addAudio(await audio('one.m4a'));
      await state.settled();
      await state.applyTemplate(note.id!, _recipe);
      final r = replaceInNote(
          state.byId(note.id!)!, TextReplacer('toor', 'arhar'));
      expect(r!.note.output('recipe')!.text, contains('arhar dal'));
    });
  });
}
