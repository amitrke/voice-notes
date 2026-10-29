import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/templates.dart';
import '../providers/ai_provider.dart';
import 'stale_banner.dart';
import 'theme.dart';

/// Tags offered when the user turns on the clinical template.
const clinicalTags = ['Patient', 'Follow-up'];

IconData templateIcon(String id) => switch (id) {
      'meeting' => Icons.groups_outlined,
      'todo' => Icons.checklist,
      'recipe' => Icons.restaurant_menu,
      'grammar' => Icons.spellcheck,
      clinicalTemplateId => Icons.medical_services_outlined,
      _ => Icons.description_outlined,
    };

/// What the user picked in [showTurnIntoSheet].
sealed class TurnIntoChoice {}

class UseTemplate extends TurnIntoChoice {
  final NoteTemplate template;
  UseTemplate(this.template);
}

class MakeTemplate extends TurnIntoChoice {}

/// Lists the templates turned on in Settings. Ones already used on the note
/// ([made]) are ticked.
Future<TurnIntoChoice?> showTurnIntoSheet(
    BuildContext context, AppState state, Set<String> made) {
  final s = state.settings;
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<TurnIntoChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Turn this note into',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final t in s.enabledTemplates)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: Icon(templateIcon(t.id)),
                title: Text(t.name),
                subtitle: Text(made.contains(t.id)
                    ? 'Already made · open or make again'
                    : t.blurb.isNotEmpty
                        ? t.blurb
                        : 'Your template'),
                trailing: made.contains(t.id)
                    ? Icon(Icons.check, color: scheme.primary)
                    : null,
                onTap: () => Navigator.pop(sheet, UseTemplate(t)),
              ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: Icon(Icons.add, color: scheme.primary),
              title: Text('Make your own',
                  style: TextStyle(color: scheme.primary)),
              onTap: () => Navigator.pop(sheet, MakeTemplate()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
              child: Text(
                s.textActive.canText
                    ? 'Written by ${s.textActive.label} · one request each'
                    : '${s.textActive.label} can\'t write text. Choose a '
                        'provider under Settings > Written by.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: s.textActive.canText
                        ? scheme.onSurfaceVariant
                        : scheme.error),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// What one template made from a note, section by section.
class TemplateOutputPage extends StatefulWidget {
  final int noteId;
  final String templateId;
  const TemplateOutputPage(
      {super.key, required this.noteId, required this.templateId});

  @override
  State<TemplateOutputPage> createState() => _TemplateOutputPageState();
}

class _TemplateOutputPageState extends State<TemplateOutputPage> {
  bool _busy = false;

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$what copied')));
  }

  Future<void> _makeAgain(AppState state, NoteTemplate t) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final err = await state.applyTemplate(widget.noteId, t);
    if (mounted) setState(() => _busy = false);
    if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _delete(AppState state, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete this $name?'),
        content: const Text('The note itself stays.'),
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
    if (ok != true || !mounted) return;
    Navigator.pop(context);
    await state.deleteOutput(widget.noteId, widget.templateId);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final note = state.byId(widget.noteId);
    final out = note?.output(widget.templateId);
    if (note == null || out == null) {
      return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
    }
    final template = state.settings.template(widget.templateId);
    return Scaffold(
      appBar: AppBar(
        title: Text(out.name),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy),
            onPressed: () => _copy(out.text, out.name),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'again' && template != null) _makeAgain(state, template);
              if (v == 'delete') _delete(state, out.name);
            },
            itemBuilder: (_) => [
              if (template != null)
                const PopupMenuItem(value: 'again', child: Text('Make again')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (note.isStale && template != null) ...[
            StaleBanner(
              message: 'This was made before the recordings changed, so it '
                  'may no longer match.',
              busy: _busy,
              onRegenerate: () => _makeAgain(state, template),
            ),
            const SizedBox(height: 12),
          ],
          for (final s in out.sections) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(s.heading,
                              style: Theme.of(context).textTheme.titleSmall),
                        ),
                        IconButton(
                          tooltip: 'Copy',
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () => _copy(s.body,
                              s.heading.isEmpty ? out.name : s.heading),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SelectableText(s.body,
                          style: const TextStyle(height: 1.5)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

/// Offers the settings that suit clinical work. Anything already in place is
/// not offered again.
Future<void> offerClinicalSetup(BuildContext context, AppState state) async {
  final s = state.settings;
  final canTell =
      s.active == ProviderId.gemini || s.active == ProviderId.onDevice;
  final have = state.approvedTags.map((t) => t.name.toLowerCase()).toSet();
  final missing =
      clinicalTags.where((t) => !have.contains(t.toLowerCase())).toList();
  final offerSpeakers = !s.identifySpeakers;
  if (!offerSpeakers && missing.isEmpty) return;
  var speakers = offerSpeakers;
  var tags = missing.isNotEmpty;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        title: const Text('Set up for clinical work?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Both are optional and can be changed later.'),
            if (offerSpeakers)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: speakers,
                onChanged: (v) => set(() => speakers = v ?? false),
                title: const Text('Identify speakers'),
                subtitle: Text(canTell
                    ? 'Tells clinician and patient apart.'
                    : 'Tells clinician and patient apart with Gemini or On '
                        'this device. ${s.active.label} will not label them.'),
              ),
            if (missing.isNotEmpty)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: tags,
                onChanged: (v) => set(() => tags = v ?? false),
                title: Text('Add tags: ${missing.join(', ')}'),
                subtitle:
                    const Text('Notes get them automatically when summarised.'),
              ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Apply')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  if (speakers) await s.setIdentifySpeakers(true);
  if (tags) {
    for (final t in missing) {
      await state.createTag(t);
    }
  }
  state.refresh();
}

/// Turns built-in templates on or off and lists the user's own.
class TemplatesPage extends StatelessWidget {
  const TemplatesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5);
    return Scaffold(
      appBar: AppBar(title: const Text('Templates')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          const SectionLabel('Built in',
              padding: EdgeInsets.fromLTRB(4, 16, 4, 8)),
          Card(
            child: Column(
              children: [
                for (final t in builtInTemplates) ...[
                  if (t != builtInTemplates.first) const Divider(),
                  SwitchListTile(
                    secondary: Icon(templateIcon(t.id)),
                    title: Text(t.name),
                    subtitle: Text(t.isClinical
                        ? 'AI draft for a clinician to review. Offers speaker '
                            'labels and Patient tags when turned on.'
                        : t.blurb),
                    value: s.templatesOn.contains(t.id),
                    onChanged: (v) async {
                      await s.setTemplateOn(t.id, v);
                      state.refresh();
                      if (v && t.isClinical && context.mounted) {
                        await offerClinicalSetup(context, state);
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
          if (s.clinical)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(
                'Clinical notes are sent to the provider under Written by. '
                'Do not use them where patient data may not leave your '
                'organisation.',
                style: muted,
              ),
            ),
          const SectionLabel('Yours', padding: EdgeInsets.fromLTRB(4, 24, 4, 8)),
          Card(
            child: Column(
              children: [
                for (final t in s.customTemplates) ...[
                  ListTile(
                    leading: Icon(templateIcon(t.id)),
                    title: Text(t.name),
                    subtitle: Text(t.instructions,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => editTemplate(context, state, t),
                  ),
                  const Divider(),
                ],
                ListTile(
                  leading: Icon(Icons.add,
                      color: Theme.of(context).colorScheme.primary),
                  title: Text('New template',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary)),
                  subtitle: const Text('Name it and say what you want'),
                  onTap: () => editTemplate(context, state, null),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the editor for [t], or for a new template when null. Returns the
/// saved template, or null if the user backed out or deleted it.
Future<NoteTemplate?> editTemplate(
        BuildContext context, AppState state, NoteTemplate? t) =>
    Navigator.push<NoteTemplate>(context,
        MaterialPageRoute(builder: (_) => _TemplateEditor(template: t)));

class _TemplateEditor extends StatefulWidget {
  final NoteTemplate? template;
  const _TemplateEditor({this.template});

  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  late final _name = TextEditingController(text: widget.template?.name);
  late final _instructions =
      TextEditingController(text: widget.template?.instructions);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _save(AppState state) async {
    final name = _name.text.trim();
    final instructions = _instructions.text.trim();
    if (name.isEmpty || instructions.isEmpty) {
      setState(() => _error = name.isEmpty
          ? 'Give the template a name.'
          : 'Say what the template should write.');
      return;
    }
    final t = NoteTemplate(
      id: widget.template?.id ??
          'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      instructions: instructions,
    );
    await state.settings.saveTemplate(t);
    state.refresh();
    if (mounted) Navigator.pop(context, t);
  }

  Future<void> _delete(AppState state) async {
    await state.settings.deleteTemplate(widget.template!.id);
    state.refresh();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.template == null ? 'New template' : 'Edit template'),
        actions: [
          if (widget.template != null)
            IconButton(
              tooltip: 'Delete template',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(state),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() => _error = null),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Name',
              hintText: 'Sermon outline',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _instructions,
            minLines: 4,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() => _error = null),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'What should it write?',
              alignLabelWithHint: true,
              hintText: 'List the main points, then every verse mentioned '
                  'with a one-line reason it was quoted.',
              helperText: 'Name the sections you want; each becomes a card.',
              helperMaxLines: 2,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => _save(state), child: const Text('Save')),
        ],
      ),
    );
  }
}
