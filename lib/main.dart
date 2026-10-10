import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/app_state.dart';
import 'data/notes_db.dart';
import 'data/settings_store.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsStore();
  await settings.load();
  final state = AppState(settings, await NotesDb.open());
  await state.init();
  runApp(
    ChangeNotifierProvider.value(value: state, child: const VoiceNotesApp()),
  );
}

class VoiceNotesApp extends StatelessWidget {
  const VoiceNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    final userScale = context.select<AppState, double>((s) => s.textScale);
    return MaterialApp(
      title: 'Voice Notes',
      debugShowCheckedModeBanner: false,
      // The user's choice stacks on the system font size, with an upper bound
      // so layouts stay usable.
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final system = media.textScaler.scale(1.0);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear((system * userScale).clamp(0.5, 3.0)),
          ),
          child: child!,
        );
      },
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const HomePage(),
    );
  }
}
