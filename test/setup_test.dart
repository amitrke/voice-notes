import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/services/model_store.dart';
import 'package:voice_notes/ui/home_page.dart';
import 'package:voice_notes/ui/setup_page.dart';
import 'package:voice_notes/ui/theme.dart';

/// Counts transcriptions; every one succeeds.
class _Provider implements AiProvider {
  int calls = 0;

  @override
  ProviderId get id => ProviderId.gemini;
  @override
  RecordingFormat get recordingFormat => RecordingFormat.m4a;

  @override
  Future<Transcription> transcribe(File audio,
      {required bool translate,
      List<String> vocabulary = const [],
      bool speakers = false}) async {
    calls++;
    return const Transcription(text: 'hello there', languageCode: 'en');
  }

  @override
  Future<NoteSummary> summarize(String text,
          {List<String> tags = const []}) async =>
      NoteSummary('Title', 'Summary');

  @override
  Future<String> completeJson(String prompt) async => '{}';
}

/// Not set up until [ready] is turned on.
class _Unready extends SettingsStore {
  final _Provider provider;
  bool ready = false;
  _Unready(this.provider);

  @override
  bool isReady(ProviderId id) => ready;
  @override
  AiProvider? build(ProviderId id) => ready ? provider : null;
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late NotesDb db;
  late AppState state;

  /// A new install: no notes, no keys, no models. Downloads fail, so no
  /// test reaches the network.
  Future<void> fresh({Map<String, Object> prefs = const {}}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(prefs);
    tmp = await Directory.systemTemp.createTemp('setup_test');
    final models = ModelStore(
      baseDir: () async => tmp,
      client: () => MockClient((_) async => http.Response('offline', 503)),
    );
    final s = SettingsStore(models: models);
    await s.load();
    await models.load();
    db = await NotesDb.open(
        path: p.join(tmp.path, 'n.db'), factory: databaseFactoryFfi);
    state = AppState(s, db);
    await state.init();
  }

  Future<void> cleanUp() async {
    await db.close();
    await tmp.delete(recursive: true);
  }

  group('needsFirstRunSetup', () {
    tearDown(cleanUp);

    test('a new install sees it', () async {
      await fresh();
      expect(needsFirstRunSetup(state), isTrue);
    });

    test('not once finished or skipped', () async {
      await fresh(prefs: {'setupDone': true});
      expect(needsFirstRunSetup(state), isFalse);
    });

    test('not for someone updating with notes', () async {
      await fresh();
      await db.insert(Note(
          title: 'Old',
          provider: 'sarvam',
          createdAt: DateTime(2026),
          status: NoteStatus.done));
      await state.init();
      expect(needsFirstRunSetup(state), isFalse);
    });

    test('not for someone updating with a key for any provider', () async {
      await fresh();
      // Sarvam transcribes by default; a Gemini key still counts.
      await state.settings.setApiKey(ProviderId.gemini, 'k');
      expect(needsFirstRunSetup(state), isFalse);
    });
  });

  group('recordings made before setup', () {
    late Directory dir;
    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('unready');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('are transcribed once a key or model is ready, others are not',
        () async {
      final provider = _Provider();
      final settings = _Unready(provider);
      await settings.load();
      settings.autoSummary = false;
      final notesDb = await NotesDb.open(
          path: p.join(dir.path, 'u.db'), factory: databaseFactoryFfi);
      addTearDown(notesDb.close);
      final s = AppState(settings, notesDb);
      await s.init();
      final audio = File(p.join(dir.path, 'early.m4a'))..writeAsStringSync('x');

      final early = await s.addAudio(audio.path);
      await s.settled();
      final failed = s.byId(early.id!)!.segments.single;
      expect(failed.status, NoteStatus.failed);
      expect(failed.error, contains('API key in Settings'));

      // Still nothing set up: nothing to retry with.
      await s.retryNotReady();
      await s.settled();
      expect(provider.calls, 0);

      settings.ready = true;
      // Failed for another reason: left for the user to retry.
      final other = await s.addAudio(audio.path);
      await s.settled();
      await notesDb.saveSegment(s
          .byId(other.id!)!
          .segments
          .single
          .copyWith(status: NoteStatus.failed, error: 'No luck.'));
      await s.init();
      provider.calls = 0;

      await s.retryNotReady();
      await s.settled();
      expect(provider.calls, 1);
      expect(s.byId(early.id!)!.segments.single.status, NoteStatus.done);
      expect(s.byId(early.id!)!.segments.single.transcript, 'hello there');
      expect(s.byId(other.id!)!.segments.single.status, NoteStatus.failed);
    });
  });

  group('SetupPage', () {
    Future<void> open(WidgetTester tester) async {
      await tester.runAsync(fresh);
      addTearDown(() => tester.runAsync(cleanUp));
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: state),
          ChangeNotifierProvider.value(value: state.settings.models),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const SetupPage(),
        ),
      ));
    }

    testWidgets('an AI key is saved and used to transcribe', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('setup_key')));
      await tester.pumpAndSettle();

      final save = find.byKey(const ValueKey('setup_save_key'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull,
          reason: 'nothing to save yet');
      await tester.tap(find.text('OpenAI'));
      await tester.enterText(
          find.byKey(const ValueKey('setup_key_field')), '  sk-test  ');
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(save);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      final s = state.settings;
      expect(s.apiKey(ProviderId.openai), 'sk-test');
      expect(s.active, ProviderId.openai);
      expect(s.setupDone, isTrue);
      expect(find.byType(HomePage), findsOneWidget);
    });

    testWidgets('Android back on the key step returns to the question',
        (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('setup_key')));
      await tester.pumpAndSettle();
      expect(find.text('Add your AI key'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Voice Notes'), findsOneWidget);
      expect(find.byType(SetupPage), findsOneWidget);
    });

    testWidgets('skipping goes to the notes and does not ask again',
        (tester) async {
      await open(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('setup_skip')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(state.settings.setupDone, isTrue);
      expect(find.byType(HomePage), findsOneWidget);
      expect(needsFirstRunSetup(state), isFalse);
    });

    testWidgets('the free choice uses the phone and starts the download',
        (tester) async {
      await open(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('setup_offline')));
        // Long enough for the (failing) download to finish.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      final s = state.settings;
      expect(s.active, ProviderId.onDevice);
      expect(s.autoSummary, isFalse,
          reason: 'titles need a key, so they would only warn');
      expect(find.text('Try again'), findsOneWidget,
          reason: 'the download failed, and says so');

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('setup_done')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(s.setupDone, isTrue);
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.textContaining('The offline model did not download'),
          findsOneWidget,
          reason: 'the failure is still shown after leaving setup');
    });
  });
}
