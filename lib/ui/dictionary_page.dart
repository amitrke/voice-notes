import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/dictionary.dart';

/// Names and terms the user wants spelled a certain way. Added words are sent
/// to providers as a hint, and a "sounds like" spelling is corrected in every
/// transcript afterwards.
class DictionaryPage extends StatefulWidget {
  const DictionaryPage({super.key});

  @override
  State<DictionaryPage> createState() => _DictionaryPageState();
}

class _DictionaryPageState extends State<DictionaryPage> {
  final _term = TextEditingController();
  final _heard = TextEditingController();

  @override
  void dispose() {
    _term.dispose();
    _heard.dispose();
    super.dispose();
  }

  Future<void> _save(AppState state, List<DictionaryEntry> entries) async {
    await state.settings.setDictionary(Dictionary(entries));
    state.refresh();
    if (mounted) setState(() {});
  }

  Future<void> _add(AppState state) async {
    final term = _term.text.trim();
    if (term.isEmpty) return;
    final heard = _heard.text
        .split(',')
        .map((h) => h.trim())
        .where((h) => h.isNotEmpty)
        .toList();
    final entries = [...state.settings.dictionary.entries];
    // Adding a term again replaces it, so the list never has duplicates.
    entries.removeWhere((e) => e.term.toLowerCase() == term.toLowerCase());
    entries.add(DictionaryEntry(term, heard));
    entries.sort((a, b) => a.term.toLowerCase().compareTo(b.term.toLowerCase()));
    _term.clear();
    _heard.clear();
    FocusScope.of(context).unfocus();
    await _save(state, entries);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final entries = state.settings.dictionary.entries;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Custom dictionary')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Add names, drug names, places and jargon. OpenAI and Gemini are '
            'told to listen for them. If a word still comes out wrong, add '
            'how it comes out under "Sounds like" and it is corrected in '
            'every new transcript, with any provider.',
            style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _term,
            textCapitalization: TextCapitalization.none,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Word or name',
              hintText: 'Amoxicillin',
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _heard,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Sounds like (optional)',
              helperText: 'Separate several spellings with commas',
              hintText: 'amoxicilin, amox a sill in',
            ),
            onSubmitted: (_) => _add(state),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _add(state),
              icon: const Icon(Icons.add),
              label: const Text('Add to dictionary'),
            ),
          ),
          const SizedBox(height: 16),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('No words yet.',
                    style: TextStyle(color: theme.colorScheme.outline)),
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  for (final (i, e) in entries.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      title: Text(e.term,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: e.heard.isEmpty
                          ? null
                          : Text('Sounds like: ${e.heard.join(', ')}'),
                      trailing: IconButton(
                        tooltip: 'Remove ${e.term}',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _save(state, [
                          for (final other in entries)
                            if (other != e) other,
                        ]),
                      ),
                      onTap: () {
                        _term.text = e.term;
                        _heard.text = e.heard.join(', ');
                      },
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
