import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/ask.dart';
import '../models/note.dart';
import 'note_page.dart';
import 'settings_page.dart';

/// Questions about one note ([noteId]) or about all of the user's notes, or
/// those in a folder, with a tag or from a recent period. The conversation
/// lives only while the page is open.
class AskPage extends StatefulWidget {
  /// Ask about this note only; null to ask across notes.
  final int? noteId;
  const AskPage({super.key, this.noteId});

  @override
  State<AskPage> createState() => _AskPageState();
}

class _AskPageState extends State<AskPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <AskTurn>[];
  String? _pending;
  String? _error;

  /// `all`, `f` plus a folder id, or `t` plus a tag id.
  String _where = 'all';
  Duration? _within;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  AskScope get _scope => AskScope(
        folderId: _where.startsWith('f') ? int.parse(_where.substring(1)) : null,
        tagId: _where.startsWith('t') ? int.parse(_where.substring(1)) : null,
        within: _within,
      );

  void _scrollDown() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
        }
      });

  Future<void> _send([String? preset]) async {
    final q = (preset ?? _input.text).trim();
    if (q.isEmpty || _pending != null) return;
    final state = context.read<AppState>();
    final candidates =
        state.notesToAsk(scope: _scope, noteId: widget.noteId);
    setState(() {
      _pending = q;
      _error = null;
      _input.clear();
    });
    _scrollDown();
    final r = await state.ask(q, candidates, history: _turns);
    if (!mounted) return;
    setState(() {
      _pending = null;
      final a = r.answer;
      if (a == null) {
        _error = r.error;
        _input.text = q;
      } else {
        _turns.add(AskTurn(q, a.text, a.sourceIds));
      }
    });
    _scrollDown();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final single = widget.noteId != null;
    final blocker = state.askBlocker;
    final count = state
        .notesToAsk(scope: _scope, noteId: widget.noteId)
        .length;
    final provider = state.settings.textActive.label;
    return Scaffold(
      appBar: AppBar(
        title: Text(single ? 'Ask about this note' : 'Ask your notes'),
        actions: [
          if (_turns.isNotEmpty)
            IconButton(
              tooltip: 'Clear the conversation',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => setState(() {
                _turns.clear();
                _error = null;
              }),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!single && blocker == null) _scopeBar(state),
          if (blocker == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                single
                    ? 'This note is sent to $provider with each question.'
                    : count == 0
                        ? 'No notes match.'
                        : 'Each question sends up to '
                            '${count < askMaxNotes ? count : askMaxNotes} of '
                            '$count ${count == 1 ? 'note' : 'notes'} to '
                            '$provider.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          Expanded(
            child: blocker != null
                ? _blocked(blocker)
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      if (_turns.isEmpty && _pending == null) _hint(single),
                      for (final t in _turns) ..._turn(state, t),
                      if (_pending != null) ...[
                        _bubble(_pending!),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Row(children: [
                            SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                            SizedBox(width: 12),
                            Text('Reading your notes…'),
                          ]),
                        ),
                      ],
                      if (_error != null)
                        Card(
                          color: theme.colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        theme.colorScheme.onErrorContainer)),
                          ),
                        ),
                    ],
                  ),
          ),
          if (blocker == null) _inputBar(single),
        ],
      ),
    );
  }

  Widget _scopeBar(AppState state) {
    final folders = state.folders;
    final tags = state.approvedTags;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _where,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Look in',
                  border: OutlineInputBorder(),
                  isDense: true),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All notes')),
                for (final f in folders)
                  DropdownMenuItem(
                      value: 'f${f.id}',
                      child: Text('Folder: ${f.name}',
                          overflow: TextOverflow.ellipsis)),
                for (final t in tags)
                  DropdownMenuItem(
                      value: 't${t.id}',
                      child: Text('Tag: ${t.name}',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _where = v ?? 'all'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<Duration?>(
              initialValue: _within,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'When',
                  border: OutlineInputBorder(),
                  isDense: true),
              items: const [
                DropdownMenuItem(value: null, child: Text('Any time')),
                DropdownMenuItem(
                    value: Duration(days: 7), child: Text('Past week')),
                DropdownMenuItem(
                    value: Duration(days: 30), child: Text('Past month')),
                DropdownMenuItem(
                    value: Duration(days: 365), child: Text('Past year')),
              ],
              onChanged: (v) => setState(() => _within = v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _blocked(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.key_outlined, size: 40),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SettingsPage())),
                child: const Text('Open settings'),
              ),
            ],
          ),
        ),
      );

  Widget _hint(bool single) {
    final examples = single
        ? ['What are the action items?', 'Summarise the key points']
        : ['What did I decide recently?', 'Where did I mention a deadline?'];
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            single
                ? 'Ask anything about this note.'
                : 'Ask anything about your notes. Answers name the notes '
                    'they come from.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in examples)
                ActionChip(label: Text(e), onPressed: () => _send(e)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bubble(String text) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: 12, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(text),
        ),
      );

  List<Widget> _turn(AppState state, AskTurn t) {
    final sources = [
      for (final id in t.sourceIds)
        if (state.byId(id) != null) state.byId(id)!,
    ];
    return [
      _bubble(t.question),
      Card(
        margin: const EdgeInsets.only(top: 8, right: 24),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(t.answer),
              if (sources.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [for (final n in sources) _source(n)],
                ),
              ],
            ],
          ),
        ),
      ),
    ];
  }

  Widget _source(Note n) => ActionChip(
        avatar: const Icon(Icons.description_outlined, size: 18),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(n.title.isEmpty ? 'Untitled' : n.title,
              overflow: TextOverflow.ellipsis),
        ),
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => NotePage(noteId: n.id!))),
      );

  Widget _inputBar(bool single) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: single ? 'Ask about this note' : 'Ask your notes',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                tooltip: 'Send',
                onPressed: _pending == null ? _send : null,
                icon: const Icon(Icons.arrow_upward),
              ),
            ],
          ),
        ),
      );
}
