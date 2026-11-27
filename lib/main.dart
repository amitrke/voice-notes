import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/app_state.dart';
import 'data/backup_sync.dart';
import 'data/notes_db.dart';
import 'data/settings_store.dart';
import 'services/backup_folder.dart';
import 'services/drive_backup_folder.dart';
import 'services/share_intake.dart';
import 'ui/home_page.dart';
import 'ui/setup_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final SettingsStore settings;
  final AppState state;
  try {
    settings = SettingsStore();
    await settings.load();
    await settings.models.load();
    state = AppState(settings, await NotesDb.open(audioRoot: (await audioDir()).path));
    await state.init();
  } catch (e) {
    // Without this the app would sit on its launch screen for ever.
    runApp(_StartupError('$e'));
    return;
  }
  // Decided before shared audio can add a note, so opening the app for the
  // first time by sharing a file into it still shows the setup.
  final showSetup = needsFirstRunSetup(state);
  // Audio shared from other apps becomes a new note.
  unawaited(ShareIntake(
    onFile: (path) async => state.addAudio(await state.importFile(path)),
  ).start());
  // Keeps this phone's backup in the backup folder (or Google Drive) up to
  // date.
  final native = NativeBackupFolder();
  final auth = GoogleDriveAuth();
  final backup = BackupSync(
    state,
    BackupDestinations(
      native,
      DriveBackupFolder(auth, GoogleDriveFiles(auth), phone: native.device),
    ),
  );
  unawaited(backup.start());
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        ChangeNotifierProvider.value(value: settings.models),
        ChangeNotifierProvider.value(value: backup),
      ],
      child: VoiceNotesApp(showSetup: showSetup),
    ),
  );
}

/// Shown when the notes or settings could not be opened.
class _StartupError extends StatelessWidget {
  final String detail;
  const _StartupError(this.detail);

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 16),
                    const Text(
                      'Voice Notes could not open your notes.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your notes have not been changed. Try again; if this '
                      'keeps happening, restart the phone.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    SelectableText(detail, textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    const FilledButton(
                        onPressed: main, child: Text('Try again')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class VoiceNotesApp extends StatelessWidget {
  /// Start with the first-run setup ([needsFirstRunSetup]). Decided once at
  /// launch, so saving a key during setup does not swap the page under it.
  final bool showSetup;
  const VoiceNotesApp({super.key, this.showSetup = false});

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
      home: showSetup ? const SetupPage() : const HomePage(),
    );
  }
}
