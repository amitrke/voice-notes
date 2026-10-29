import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/find_replace.dart';
import '../models/note.dart';

/// Finds a word across all notes and replaces it, for fixing a name that was
/// misheard everywhere. Shows every affected note with a count first, and only
/// the ticked ones change.
class ReplacePage extends StatefulWidget {
  /// Start with this text in the "Find" box (e.g. the current search).
  final String initialFind;
  const ReplacePage({super.key, this.initialFind = ''});

  @override
  State<ReplacePage> createState() => _ReplacePageState();
}

class _ReplacePageState extends State<ReplacePage> {
  late final _find = TextEditingController(text: widget.initialFind);
  final _replace = TextEditingController();
  bool _matchCase = false;
  bool _working = false;

  /// Notes the user un-ticked.
  final _skipped = <int>{};

  @override
  void dispose() {
    _find.dispose();
    _replace.dispose();
    super.dispose();
  }

  TextReplacer get _replacer =>
      TextReplacer(_find.text.trim(), _replace.text, matchCase: _matchCase);

  Future<void> _apply(AppState state, List<({Note note, int count})> hits) async {
    final messenger = ScaffoldMessenger.of(context);
    final chosen = [
      for (final h in hits)
        if (!_skipped.contains(h.note.id)) h.note.id!,
    ];
    final total = hits
        .where((h) => !_skipped.contains(h.note.id))
        .fold<int>(0, (a, h) => a + h.count);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Replace in these notes?'),
        content: Text(
            'This changes $total ${total == 1 ? 'place' : 'places'} in '
            '${chosen.length} ${chosen.length == 1 ? 'note' : 'notes'}. '
            'It cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Replace')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _working = true);
    final changed = await state.replaceIn(chosen, _replacer);
    if (!mounted) return;
    setState(() {
      _working = false;
      _skipped.clear();
    });
    messenger.showSnackBar(SnackBar(
        content: Text('Updated $changed ${changed == 1 ? 'note' : 'notes'}')));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final find = _find.text.trim();
    final hits = find.isEmpty
        ? const <({Note note, int count})>[]
        : state.findMatches(_replacer);
    final picked = hits.where((h) => !_skipped.contains(h.note.id)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Find and replace')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _find,
            autofocus: widget.initialFind.isEmpty,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'Find'),
            onChanged: (_) => setState(_skipped.clear),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _replace,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'Replace with'),
            onChanged: (_) => setState(() {}),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Match upper and lower case'),
            value: _matchCase,
            onChanged: (v) => setState(() {
              _matchCase = v;
              _skipped.clear();
            }),
          ),
          if (find.isEmpty)
            Text('Type the word to find. Titles, summaries and transcripts '
                'are searched.',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant))
          else if (hits.isEmpty)
            Text('No notes contain "$find".',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant))
          else ...[
            Row(children: [
              Expanded(
                child: Text(
                  '${hits.length} ${hits.length == 1 ? 'note' : 'notes'} found',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  if (picked.length == hits.length) {
                    _skipped.addAll(hits.map((h) => h.note.id!));
                  } else {
                    _skipped.clear();
                  }
                }),
                child: Text(picked.length == hits.length
                    ? 'Clear all'
                    : 'Select all'),
              ),
            ]),
            Card(
              child: Column(
                children: [
                  for (final h in hits)
                    CheckboxListTile(
                      value: !_skipped.contains(h.note.id),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _skipped.remove(h.note.id);
                        } else {
                          _skipped.add(h.note.id!);
                        }
                      }),
                      title: Text(
                        h.note.title.isEmpty ? 'Untitled note' : h.note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                          matchSnippet(h.note, find) ??
                              '${h.count} ${h.count == 1 ? 'match' : 'matches'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      secondary: Text('${h.count}×',
                          style: theme.textTheme.labelLarge),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _working || picked.isEmpty
                  ? null
                  : () => _apply(state, hits),
              child: Text(_working
                  ? 'Replacing…'
                  : 'Replace in ${picked.length} '
                      '${picked.length == 1 ? 'note' : 'notes'}'),
            ),
          ],
        ],
      ),
    );
  }
}
