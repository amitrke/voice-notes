import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/ask.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/data/templates.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/ui/ask_page.dart';
import 'package:voice_notes/ui/theme.dart';

Note _note(int id, String title, String text,
        {String summary = '', DateTime? at, int? folder, List<int>? tags}) =>
    Note(
      id: id,
      title: title,
      summary: summary,
      provider: 'gemini',
      createdAt: at ?? DateTime(2026, 11, id),
      status: NoteStatus.done,
      transcript: text,
      folderId: folder,
      tagIds: tags ?? const [],
      segments: [
        Segment(audioPath: '', transcript: text, status: NoteStatus.done),
      ],
    );

class _Provider implements AiProvider {
  final prompts = <String>[];
  String reply = '{"answer": "On Friday.", "sources": ["N1"]}';

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;
  @override
  Future<Transcription> transcribe(File audio,
          {required bool translate,
          List<String> vocabulary = const [],
          bool speakers = false}) async =>
      const Transcription(text: '');
  @override
  Future<NoteSummary> summarize(String text,
          {List<String> tags = const []}) async =>
      const NoteSummary('', '');
  @override
  Future<String> completeJson(String prompt) async {
    prompts.add(prompt);
    return reply;
  }
}

class _Settings extends SettingsStore {
  final AiProvider provider;
  final bool ready;
  _Settings(this.provider, {this.ready = true});

  @override
  AiProvider? build(ProviderId id) => provider;
  @override
  bool isReady(ProviderId id) => ready;
}

void main() {
  sqfliteFfiInit();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('picking notes', () {
    test('words of the question that carry meaning', () {
      expect(askTerms('What did I say about the Roadmap deadline?'),
          ['roadmap', 'deadline']);
    });

    test('few short notes are all sent, newest first', () {
      final notes = [
        _note(1, 'Old', 'a'),
        _note(5, 'New', 'b'),
      ];
      expect(pickNotes(notes, 'anything').map((n) => n.id), [5, 1]);
    });

    test('a title or summary hit beats a mention in the text', () {
      final long = 'filler ' * 400;
      final notes = [
        for (var i = 1; i <= 12; i++) _note(i, 'Note $i', long),
        _note(20, 'Plumber visit', '$long plumber', summary: 'The plumber'),
        _note(21, 'Other', '$long plumber once'),
      ];
      final picked = pickNotes(notes, 'when is the plumber coming');
      expect(picked.first.id, 20);
      expect(picked.map((n) => n.id), contains(21));
      expect(picked.length, lessThanOrEqualTo(askMaxNotes));
    });

    test('a question that matches nothing still gets the newest notes', () {
      final long = 'filler ' * 1000;
      final notes = [for (var i = 1; i <= 12; i++) _note(i, 'Note', long)];
      final picked = pickNotes(notes, 'zzzz qqqq');
      expect(picked.map((n) => n.id), [12, 11, 10]);
    });

    test('a long note is cut around the words asked about', () {
      final text = '${'a ' * 3000}the budget is 40k${' b' * 3000}';
      final cut = excerpt(text, ['budget'], 1200);
      expect(cut.length, lessThan(1300));
      expect(cut, contains('the budget is 40k'));
      expect(excerpt('short', ['x'], 100), 'short');
    });
  });

  group('prompt and reply', () {
    test('the prompt labels each note and carries the question', () {
      final notes = [
        _note(1, 'Trip', 'leave on Friday', summary: 'Coorg trip'),
        _note(2, '', 'buy milk'),
      ];
      final prompt = askPrompt('When do we leave?', notes, history: const [
        AskTurn('Where?', 'Coorg.'),
      ]);
      expect(prompt, contains('[N1] "Trip" · 1 Nov 2026'));
      expect(prompt, contains('[N2] "Untitled"'));
      expect(prompt, contains('Summary: Coorg trip'));
      expect(prompt, contains('Q: Where?\nA: Coorg.'));
      expect(prompt, contains('Use only the notes below'));
      expect(prompt, endsWith('Question: When do we leave?'));
    });

    test('sources map back to note ids; bad labels are ignored', () {
      final notes = [_note(7, 'A', 'x'), _note(9, 'B', 'y')];
      final a = parseAskReply(
          '{"answer": "Both.", "sources": ["N2", "n1", "N2", "N9", "x"]}',
          notes);
      expect(a.text, 'Both.');
      expect(a.sourceIds, [9, 7]);
    });

    test('a reply that is not JSON is the answer; an empty one is an error',
        () {
      final notes = [_note(1, 'A', 'x')];
      expect(parseAskReply('Just text.', notes).text, 'Just text.');
      expect(parseAskReply('Just text.', notes).sourceIds, isEmpty);
      expect(() => parseAskReply('{"answer": ""}', notes),
          throwsA(isA<ProviderException>()));
      expect(() => parseAskReply('  ', notes),
          throwsA(isA<ProviderException>()));
    });
  });

  group('scope', () {
    final now = DateTime(2026, 11, 15);
    test('folder, tag and period narrow the notes', () {
      final n = _note(10, 'A', 'x', folder: 3, tags: [4]);
      expect(const AskScope().matches(n, now), isTrue);
      expect(const AskScope(folderId: 3).matches(n, now), isTrue);
      expect(const AskScope(folderId: 2).matches(n, now), isFalse);
      expect(const AskScope(tagId: 4).matches(n, now), isTrue);
      expect(const AskScope(tagId: 5).matches(n, now), isFalse);
      expect(const AskScope(within: Duration(days: 7)).matches(n, now), isTrue);
      expect(const AskScope(within: Duration(days: 2)).matches(n, now), isFalse);
    });
  });

  group('AppState.ask', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ask_test'));

    Future<AppState> state(_Settings s) async {
      SharedPreferences.setMockInitialValues({});
      final db = await NotesDb.open(
          path: p.join(tmp.path, 'a.db'), factory: databaseFactoryFfi);
      await db.insert(_note(1, 'Trip', 'leave on Friday'));
      final a = AppState(s, db, audioDirectory: () async => tmp);
      await a.init();
      return a;
    }

    test('answers from the notes with the text provider', () async {
      final provider = _Provider();
      final a = await state(_Settings(provider));
      final r = await a.ask('When do we leave?', a.notesToAsk());
      expect(r.error, isNull);
      expect(r.answer!.text, 'On Friday.');
      expect(r.answer!.sourceIds, [a.allNotes.single.id]);
      expect(provider.prompts.single, contains('leave on Friday'));
    });

    test('one note only, or the notes of a scope', () async {
      final a = await state(_Settings(_Provider()));
      final id = a.allNotes.single.id!;
      expect(a.notesToAsk(noteId: id), hasLength(1));
      expect(a.notesToAsk(noteId: 999), isEmpty);
      expect(a.notesToAsk(scope: const AskScope(folderId: 5)), isEmpty);
    });

    test('says what is missing when there is no text provider ready',
        () async {
      final provider = _Provider();
      final a = await state(_Settings(provider, ready: false));
      expect(a.askBlocker, isNotNull);
      final r = await a.ask('Hi?', a.notesToAsk());
      expect(r.answer, isNull);
      expect(r.error, contains('API key'));
      expect(provider.prompts, isEmpty);
    });
  });

  group('screen', () {
    for (final (name, size, scale, single) in [
      ('across notes on a small phone at 200% text', const Size(360, 640), 2.0, false),
      ('one note on a phone on its side', const Size(640, 360), 1.0, true),
    ]) {
      testWidgets(name, (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late AppState state;
        await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp('askscreen');
          final db = await NotesDb.open(
              path: p.join(dir.path, 's.db'), factory: databaseFactoryFfi);
          await db.insert(_note(1, 'Trip', 'leave on Friday'));
          state = AppState(_Settings(_Provider()), db);
          await state.init();
          await state.createFolder('Work');
        });
        final id = state.allNotes.single.id;
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: AskPage(noteId: single ? id : null),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byType(TextField), 'When do we leave?');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('On Friday.'), findsOneWidget);
        expect(find.text('Trip'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('without a ready provider it explains what to do',
        (tester) async {
      late AppState state;
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('askscreen2');
        final db = await NotesDb.open(
            path: p.join(dir.path, 's.db'), factory: databaseFactoryFfi);
        state = AppState(_Settings(_Provider(), ready: false), db);
        await state.init();
      });
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
            theme: buildTheme(Brightness.light), home: const AskPage()),
      ));
      await tester.pump();
      expect(find.textContaining('API key'), findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('study templates', () {
    test('are built in and ask for the right shapes', () {
      final byId = {for (final t in builtInTemplates) t.id: t};
      expect(byId['study']!.instructions, contains('Key points'));
      expect(byId['flashcards']!.instructions, contains('one section per card'));
      expect(byId['quiz']!.instructions, contains('Answer key'));
      for (final id in ['study', 'flashcards', 'quiz']) {
        expect(byId[id]!.builtIn, isTrue);
        final prompt = templatePrompt(byId[id]!, transcript: 't', english: '');
        expect(prompt, contains('Reply with JSON only'));
      }
    });
  });
}
