import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../models/note.dart';
import 'audio_input.dart';
import 'format.dart';
import 'note_page.dart';
import 'settings_page.dart';
import 'theme.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _openSettings(BuildContext context) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const SettingsPage()),
  );

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
        toolbarHeight: 64,
        titleSpacing: 20,
        title: Text(
          'Notes',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Import audio',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: () => importAudio(context),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: const _RecordDock(),
      body: Column(
        children: [
          if (!state.hasActiveKey)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _KeyBanner(onOpen: () => _openSettings(context)),
            ),
          if (state.hasAnyNotes)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: SearchBar(
                hintText: 'Search notes',
                leading: const Icon(Icons.search),
                onChanged: (v) => state.query = v,
              ),
            ),
          Expanded(
            child: notes.isEmpty
                ? _Empty(searching: state.hasAnyNotes)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => switch (rows[i]) {
                      final Note n => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _NoteCard(
                          note: n,
                          showLanguage:
                              languageLabel(n.languageCode) != usualLanguage,
                        ),
                      ),
                      final String day => SectionLabel(day),
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

/// The big record button, docked at the bottom so it never covers a note.
class _RecordDock extends StatelessWidget {
  const _RecordDock();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filled(
                tooltip: 'Record a note',
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(72),
                  backgroundColor: recordColor,
                  foregroundColor: Colors.white,
                  elevation: 2,
                ),
                onPressed: () => recordAudio(context),
                icon: const Icon(Icons.mic_none_rounded, size: 32),
              ),
              const SizedBox(height: 6),
              ExcludeSemantics(
                child: Text(
                  'Tap to record',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyBanner extends StatelessWidget {
  final VoidCallback onOpen;
  const _KeyBanner({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.key_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add an API key to start transcribing. Your key stays on this device.',
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      height: 1.4,
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      textStyle: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    onPressed: onOpen,
                    child: const Text('Open settings →'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final bool searching;
  const _Empty({required this.searching});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching ? Icons.search_off : Icons.graphic_eq,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              searching ? 'No notes match your search.' : 'No notes yet',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (!searching) ...[
              const SizedBox(height: 6),
              Text(
                'Tap record below, or import an audio file.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final Note note;
  final bool showLanguage;
  const _NoteCard({required this.note, required this.showLanguage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lang = showLanguage ? languageLabel(note.languageCode) : null;
    final failed = note.status == NoteStatus.failed;
    final title = switch (note.status) {
      NoteStatus.processing => 'Transcribing…',
      NoteStatus.failed => 'Transcription failed',
      NoteStatus.done => note.title.isEmpty ? 'Untitled note' : note.title,
    };
    final body = failed
        ? (note.error ?? '')
        : (note.summary.isNotEmpty
              ? note.summary
              : (note.english.isNotEmpty ? note.english : note.transcript));
    final meta = [
      formatTime(note.createdAt),
      if (note.durationMs != null) formatDuration(note.durationMs!),
    ].join(' · ');
    final segments = note.segments;
    final done = segments
        .where((s) => s.status != NoteStatus.processing)
        .length;
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Card(
      shape: failed
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.error.withValues(alpha: 0.35)),
            )
          : null,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => NotePage(noteId: note.id!)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (failed) ...[
                    Icon(Icons.error_outline, color: scheme.error, size: 22),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                  if (note.status == NoteStatus.processing &&
                      segments.length > 1)
                    Text(
                      '$done of ${segments.length} parts',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
              ],
              if (note.status == NoteStatus.processing) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    value: segments.length > 1 ? done / segments.length : null,
                    backgroundColor: scheme.outlineVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metaStyle,
                    ),
                  ),
                  if (lang != null) _LanguageBadge(lang),
                  if (failed)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      onPressed: () => context.read<AppState>().retry(note.id!),
                      child: const Text('Retry'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageBadge extends StatelessWidget {
  final String text;
  const _LanguageBadge(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
