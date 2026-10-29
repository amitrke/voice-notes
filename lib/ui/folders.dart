import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../models/note.dart';

/// Asks for a name; null when cancelled or left empty.
Future<String?> askName(BuildContext context,
    {required String title, String initial = '', String action = 'Save'}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => Navigator.pop(dialog, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: Text(action)),
      ],
    ),
  ).then((v) => v == null || v.isEmpty ? null : v);
}

/// Bottom sheet that files [note] in a folder (or none), or in a new one.
Future<void> moveNoteToFolder(BuildContext context, Note note) async {
  final state = context.read<AppState>();
  final folders = state.folders;
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.7),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Move to folder',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: Icon(note.folderId == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text('No folder'),
              onTap: () => Navigator.pop(sheet, 0),
            ),
            for (final f in folders)
              ListTile(
                leading: Icon(note.folderId == f.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(f.name),
                onTap: () => Navigator.pop(sheet, f.id!),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder…'),
              onTap: () => Navigator.pop(sheet, 'new'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return;
  if (choice == 'new') {
    if (!context.mounted) return;
    final name = await askName(context, title: 'New folder', action: 'Create');
    if (name == null) return;
    final folder = await state.createFolder(name);
    if (folder != null) await state.moveToFolder(note.id!, folder.id);
    return;
  }
  await state.moveToFolder(note.id!, choice == 0 ? null : choice as int);
}

/// Rename or delete [folder].
Future<void> showFolderActions(BuildContext context, Folder folder) async {
  final state = context.read<AppState>();
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename folder'),
            onTap: () => Navigator.pop(sheet, 'rename'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete folder'),
            subtitle: const Text('Its notes are kept.'),
            onTap: () => Navigator.pop(sheet, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  if (action == 'rename') {
    final name = await askName(context,
        title: 'Rename folder', initial: folder.name);
    if (name != null) await state.renameFolder(folder.id!, name);
  } else {
    await state.deleteFolder(folder.id!);
  }
}
