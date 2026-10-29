import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/dictionary.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/data/templates.dart';
import 'package:voice_notes/models/note.dart';

Future<SettingsStore> _settings([Map<String, Object> prefs = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
  final s = SettingsStore();
  await s.load();
  return s;
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('backup_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<NotesDb> db(String name) => NotesDb.open(
      path: p.join(tmp.path, '$name.db'), factory: databaseFactoryFfi);

  Note note(String text, DateTime at, {int? folderId}) => Note(
        title: 'Title of $text',
        transcript: text,
        provider: 'gemini',
        createdAt: at,
        status: NoteStatus.done,
        folderId: folderId,
        outputs: [
          TemplateOutput('recipe', 'Recipe', [OutputSection('Steps', text)]),
        ],
        segments: [
          Segment(
              audioPath: p.join(tmp.path, 'gone.m4a'),
              transcript: text,
              status: NoteStatus.done),
        ],
      );

  test('a backup carries notes to another phone, once', () async {
    final oldDb = await db('old');
    final old = AppState(await _settings(), oldDb);
    final folder = await oldDb.insertFolder('Work');
    final n = await oldDb.insert(
        note('wash the dal', DateTime(2026, 10, 1), folderId: folder.id));
    final tag = (await oldDb.tags()).firstWhere((t) => t.name == 'Ideas');
    await oldDb.setNoteTags(n.id!, [tag.id!]);
    await old.settings.setDictionary(Dictionary.fromLines(['Amoxicillin']));
    await old.settings.saveTemplate(const NoteTemplate(
        id: 'custom_1', name: 'Sermon outline', instructions: 'Points'));
    final file = jsonEncode(await old.backup());

    final newDb = await db('new');
    final fresh = AppState(await _settings(), newDb);
    await newDb.insert(note('already here', DateTime(2026, 10, 2)));
    await fresh.init();

    final b = Map<String, Object?>.from(jsonDecode(file) as Map);
    expect(await fresh.restore(b), 1);
    final restored =
        fresh.notes.firstWhere((x) => x.transcript == 'wash the dal');
    expect(restored.title, 'Title of wash the dal');
    expect(restored.output('recipe')!.text, contains('wash the dal'));
    expect(restored.segments.single.hasAudio, isFalse);
    expect(fresh.folders.single.name, 'Work');
    expect(restored.folderId, fresh.folders.single.id);
    expect(fresh.tags.where((t) => t.name == 'Ideas'), hasLength(1));
    expect(restored.tagIds, [fresh.tags.firstWhere((t) => t.name == 'Ideas').id]);
    expect(fresh.settings.dictionary.toLines(), contains('Amoxicillin'));
    expect(fresh.settings.template('custom_1')!.name, 'Sermon outline');
    expect(fresh.notes, hasLength(2));

    // Restoring the same file again adds nothing.
    expect(await fresh.restore(b), 0);
    expect(fresh.notes, hasLength(2));
    await oldDb.close();
    await newDb.close();
  });

  test('refuses files that are not a backup, or from a newer app', () async {
    final d = await db('x');
    final s = AppState(await _settings(), d);
    expect(() => s.restore({'format': 'something'}),
        throwsA(isA<FormatException>()));
    expect(
        () => s.restore({
              'format': backupFormat,
              'notes': {'version': NotesDb.version + 1},
            }),
        throwsA(isA<FormatException>()));
    await d.close();
  });

  test('notes whose recordings are gone keep their text', () async {
    final d = await db('y');
    await d.insert(note('text stays', DateTime(2026, 10, 3)));
    final s = AppState(await _settings(), d);
    await s.init();
    final n = s.notes.single;
    expect(n.transcript, 'text stays');
    expect(n.segments.single.hasAudio, isFalse);
    expect((await d.all()).single.segments.single.hasAudio, isFalse);
    await d.close();
  });

  test('the voiceprint moves out of the backed-up settings', () async {
    final s = await _settings({'voiceprint': '[0.5,0.25]'});
    expect(s.voiceprint, [0.5, 0.25]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('voiceprint'), isNull);
  });
}
