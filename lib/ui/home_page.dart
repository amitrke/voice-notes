import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../models/note.dart';
import 'audio_input.dart';
import 'format.dart';
import 'note_page.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final notes = state.notes;
    final usualLanguage = _usualLanguage(notes);
    // Notes arrive newest first; a heading goes before each new day.
    final rows = <Object>[];
    String? lastDay;
    for (final n in notes) {
      final day = dayLabel(n.createdAt);
      if (day != lastDay) rows.add(lastDay = day);
      rows.add(n);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Notes'),
        actions: [
          IconButton(
            tooltip: 'Import audio',
            icon: const Icon(Icons.upload_file),
            onPressed: () => importAudio(context),
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
        onPressed: () => recordAudio(context),
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
                    itemCount: rows.length,
                    itemBuilder: (_, i) => switch (rows[i]) {
                      final Note n => _NoteTile(
                          note: n,
                          showLanguage: languageLabel(n.languageCode) !=
                              usualLanguage),
                      final String day => _DayHeader(day),
                      _ => const SizedBox.shrink(),
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// The language most notes are in, so the list only calls out the others.
String? _usualLanguage(List<Note> notes) {
  final counts = <String, int>{};
  for (final n in notes) {
    final l = languageLabel(n.languageCode);
    if (l != null) counts[l] = (counts[l] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

class _DayHeader extends StatelessWidget {
  final String text;
  const _DayHeader(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text,
          style: theme.textTheme.labelLarge
              ?.copyWith(color: theme.colorScheme.primary)),
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
  final bool showLanguage;
  const _NoteTile({required this.note, required this.showLanguage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lang = showLanguage ? languageLabel(note.languageCode) : null;
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
      // Status sits at the end so titles line up whether or not it shows.
      trailing: switch (note.status) {
        NoteStatus.processing => const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5)),
        NoteStatus.failed => Icon(Icons.error_outline, color: scheme.error),
        NoteStatus.done => null,
      },
      title: Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (body.isNotEmpty)
            Text(body, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(
            [
              formatTime(note.createdAt),
              if (note.durationMs != null) formatDuration(note.durationMs!),
              ?lang,
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ],
      ),
      isThreeLine: body.isNotEmpty,
    );
  }
}
