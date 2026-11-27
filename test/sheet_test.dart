import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voice_notes/data/app_state.dart';
import 'package:voice_notes/data/notes_db.dart';
import 'package:voice_notes/data/settings_store.dart';
import 'package:voice_notes/data/templates.dart';
import 'package:voice_notes/ui/sheet.dart';
import 'package:voice_notes/ui/templates_ui.dart';
import 'package:voice_notes/ui/theme.dart';

/// Issue #36: on an iPhone, "Turn into…" with many templates filled the
/// screen and could not be left without choosing one.
void main() {
  sqfliteFfiInit();

  testWidgets('"Turn into" on a full iPhone screen can be closed',
      (tester) async {
    // An iPhone 15: 393 x 852 points, with the Dynamic Island's inset.
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.reset);

    late AppState state;
    late NotesDb db;
    late Directory tmp;
    await tester.runAsync(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        // Every built-in template on: the longest list.
        'templatesOn': [for (final t in builtInTemplates) t.id],
      });
      tmp = await Directory.systemTemp.createTemp('sheet_test');
      final s = SettingsStore();
      await s.load();
      db = await NotesDb.open(
          path: p.join(tmp.path, 's.db'), factory: databaseFactoryFfi);
      state = AppState(s, db);
    });
    addTearDown(() => tester.runAsync(() async {
          await db.close();
          await tmp.delete(recursive: true);
        }));

    var result = 'not closed';
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                final c = await showTurnIntoSheet(context, state, {});
                result = c == null ? 'closed' : 'picked';
              },
              child: const Text('Turn into…'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Turn into…'));
    await tester.pumpAndSettle();
    expect(find.text('Turn this note into'), findsOneWidget);

    // The sheet leaves the top of the screen, below the status bar, free,
    // so tapping above it also closes it.
    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.top, greaterThanOrEqualTo(852 * (1 - maxSheetHeight) - 1));

    await tester.tap(find.byKey(const ValueKey('sheet_close')));
    await tester.pumpAndSettle();
    expect(find.text('Turn this note into'), findsNothing);
    expect(result, 'closed');

    // Tapping the dimmed area above it closes it too.
    await tester.tap(find.text('Turn into…'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(196, 80));
    await tester.pumpAndSettle();
    expect(find.text('Turn this note into'), findsNothing);
  });
}
