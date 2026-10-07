import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../models/note.dart';
import '../services/recorder_service.dart';
import 'format.dart';
import 'note_page.dart';
import 'record_sheet.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _record(BuildContext context) async {
    final state = context.read<AppState>();
    final result = await showModalBottomSheet<RecordingResult>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (_) =>
          RecordSheet(format: state.settings.active.recordingFormat),
    );
    if (result != null) {
      await state.addAudio(result.path, durationMs: result.durationMs);
    }
  }

  Future<void> _import(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const [
        'm4a', 'mp3', 'wav', 'aac', 'ogg', 'opus', 'flac', 'mp4', 'amr', 'webm'
      ],
    );
    final path = picked?.path;
    if (path == null) return;
    try {
      final stored = await state.importFile(path);
      await state.addAudio(stored);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not import: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final notes = state.notes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Notes'),
        actions: [
          IconButton(
            tooltip: 'Import audio',
            icon: const Icon(Icons.upload_file),
            onPressed: () => _import(context),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _record(context),
        icon: const Icon(Icons.mic),
        label: const Text('Record'),
      ),
      body: Column(
        children: [
          if (!state.hasActiveKey) const _KeyBanner(),
          if (state.hasAnyNotes)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SearchBar(
                hintText: 'Search notes',
                leading: const Icon(Icons.search),
                elevation: const WidgetStatePropertyAll(0),
                onChanged: (v) => state.query = v,
              ),
            ),
          Expanded(
            child: notes.isEmpty
                ? _Empty(searching: state.hasAnyNotes)
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: notes.length,
                    itemBuilder: (_, i) => _NoteTile(note: notes[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _KeyBanner extends StatelessWidget {
  const _KeyBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MaterialBanner(
      backgroundColor: scheme.secondaryContainer,
      content: const Text(
          'Add an API key to transcribe your recordings. Your key stays on this device.'),
      leading: const Icon(Icons.key),
      actions: [
        TextButton(
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsPage())),
          child: const Text('Open settings'),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final bool searching;
  const _Empty({required this.searching});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            searching
                ? 'No notes match your search.'
                : 'No notes yet.\nTap Record, or import an audio file.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
}

class _NoteTile extends StatelessWidget {
  final Note note;
  const _NoteTile({required this.note});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lang = languageLabel(note.languageCode);
    final title = switch (note.status) {
      NoteStatus.processing => 'Transcribing…',
      NoteStatus.failed => 'Transcription failed',
      NoteStatus.done => note.title.isEmpty ? 'Untitled note' : note.title,
    };
    final body = note.status == NoteStatus.failed
        ? (note.error ?? '')
        : (note.summary.isNotEmpty
            ? note.summary
            : (note.english.isNotEmpty ? note.english : note.transcript));
    return ListTile(
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => NotePage(noteId: note.id!))),
      leading: switch (note.status) {
        NoteStatus.processing => const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5)),
        NoteStatus.failed => Icon(Icons.error_outline, color: scheme.error),
        NoteStatus.done => const Icon(Icons.graphic_eq),
      },
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (body.isNotEmpty)
            Text(body, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(
            [
              formatDate(note.createdAt),
              ?lang,
              if (note.durationMs != null) formatDuration(note.durationMs!),
            ].join(' · '),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.outline),
          ),
        ],
      ),
      isThreeLine: body.isNotEmpty,
    );
  }
}
