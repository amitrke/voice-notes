import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../models/note.dart';
import 'folders.dart';

/// The note's tags as chips, with a chip to change them. Changing them by
/// hand stops enrichment from retagging the note.
class NoteTags extends StatelessWidget {
  final Note note;
  const NoteTags({super.key, required this.note});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tags = state.tagsOf(note);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final t in tags)
          InputChip(
            label: Text(t.name),
            onDeleted: () => state.toggleNoteTag(note.id!, t.id!),
            deleteButtonTooltipMessage: 'Remove ${t.name}',
            onPressed: () => editNoteTags(context, note.id!),
          ),
        ActionChip(
          avatar: const Icon(Icons.sell_outlined, size: 18),
          label: Text(tags.isEmpty ? 'Add tags' : 'Edit'),
          onPressed: () => editNoteTags(context, note.id!),
        ),
      ],
    );
  }
}

/// Bottom sheet to pick the note's tags from the approved ones, or add one.
Future<void> editNoteTags(BuildContext context, int noteId) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) {
        final state = sheet.watch<AppState>();
        final note = state.byId(noteId);
        if (note == null) return const SizedBox.shrink();
        final mine = state.tagsOf(note).map((t) => t.id).toSet();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Tags',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  'Once you change a note\'s tags, regenerating the summary '
                  'leaves them as you set them.',
                  style: Theme.of(sheet).textTheme.bodySmall?.copyWith(
                      color: Theme.of(sheet).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final t in state.approvedTags)
                      FilterChip(
                        label: Text(t.name),
                        selected: mine.contains(t.id),
                        onSelected: (_) => state.toggleNoteTag(noteId, t.id!),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text('New tag'),
                      onPressed: () async {
                        final name = await askName(sheet,
                            title: 'New tag', action: 'Add');
                        if (name == null) return;
                        final t = await state.createTag(name);
                        final cur = state.byId(noteId);
                        if (t == null || cur == null) return;
                        await state.setNoteTags(noteId, [
                          ...state.tagsOf(cur).map((e) => e.id!),
                          t.id!,
                        ]);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

/// Settings screen for the tag list: add, rename and delete tags, and approve
/// or reject the ones the model suggested.
class TagsPage extends StatelessWidget {
  const TagsPage({super.key});

  Future<void> _rename(BuildContext context, AppState state, Tag t) async {
    final name =
        await askName(context, title: 'Rename tag', initial: t.name);
    if (name == null) return;
    final ok = await state.renameTag(t.id!, name);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('There is already a tag called "$name".')));
    }
  }

  Future<void> _delete(BuildContext context, AppState state, Tag t) async {
    final count = state.noteCountTagged(t.id!);
    if (count > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Delete "${t.name}"?'),
          content: Text('It is removed from $count '
              '${count == 1 ? 'note' : 'notes'}. The notes are kept.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Delete')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await state.deleteTag(t.id!);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final suggested = state.suggestedTags;
    final approved = state.approvedTags;
    return Scaffold(
      appBar: AppBar(title: const Text('Tags')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final name =
              await askName(context, title: 'New tag', action: 'Add');
          if (name != null) await state.createTag(name);
        },
        icon: const Icon(Icons.add),
        label: const Text('New tag'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(
            'When a note is summarised, your text provider picks tags from '
            'this list. If none fit it may suggest a new one, which waits '
            'here for you; once approved, it shows on the notes it was '
            'suggested for. On-device transcription has no text model, so '
            'tag those notes by hand.',
            style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.45),
          ),
          if (suggested.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Suggested', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  for (final (i, t) in suggested.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      title: Text(t.name),
                      subtitle: Text(_notesLabel(state.noteCountTagged(t.id!))),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Reject ${t.name}',
                            icon: const Icon(Icons.close),
                            onPressed: () => state.deleteTag(t.id!),
                          ),
                          IconButton(
                            tooltip: 'Approve ${t.name}',
                            icon: const Icon(Icons.check),
                            onPressed: () => state.approveTag(t.id!),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text('Your tags', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (approved.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('No tags yet.',
                    style: TextStyle(color: theme.colorScheme.outline)),
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  for (final (i, t) in approved.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      title: Text(t.name),
                      subtitle: Text(_notesLabel(state.noteCountTagged(t.id!))),
                      onTap: () => _rename(context, state, t),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Rename ${t.name}',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _rename(context, state, t),
                          ),
                          IconButton(
                            tooltip: 'Delete ${t.name}',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, state, t),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _notesLabel(int n) => n == 1 ? '1 note' : '$n notes';
}
