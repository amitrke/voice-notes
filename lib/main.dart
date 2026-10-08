import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/app_state.dart';
import 'data/notes_db.dart';
import 'data/settings_store.dart';
import 'ui/home_page.dart';

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
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const HomePage(),
    );
  }
}

ThemeData _theme(Brightness brightness) {
  final base = ThemeData(
    colorSchemeSeed: Colors.indigo,
    brightness: brightness,
    useMaterial3: true,
  );
  // Material 3's letter spacing is tuned for Roboto and looks loose in
  // Apple's system font.
  if (defaultTargetPlatform != TargetPlatform.iOS) return base;
  TextStyle? tight(TextStyle? s) => s?.copyWith(letterSpacing: 0);
  final t = base.textTheme;
  return base.copyWith(
    textTheme: t.copyWith(
      titleLarge: tight(t.titleLarge),
      titleMedium: tight(t.titleMedium),
      titleSmall: tight(t.titleSmall),
      bodyLarge: tight(t.bodyLarge),
      bodyMedium: tight(t.bodyMedium),
      bodySmall: tight(t.bodySmall),
      labelLarge: tight(t.labelLarge),
      labelMedium: tight(t.labelMedium),
      labelSmall: tight(t.labelSmall),
    ),
  );
}
