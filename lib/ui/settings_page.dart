import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_state.dart';
import '../data/settings_store.dart';
import '../providers/ai_provider.dart';
import '../services/model_store.dart';
import 'dictionary_page.dart';
import 'links.dart';
import 'tags.dart';
import 'text_size.dart';
import 'theme.dart';

/// Tags offered when the user switches to clinical work.
const clinicalTags = ['Patient', 'Follow-up'];

/// The provider can label who is speaking.
bool _canTellSpeakers(SettingsStore s) =>
    s.active == ProviderId.gemini || s.active == ProviderId.onDevice;

/// What "Identify speakers" does with the transcription provider in use.
String _speakerHelp(SettingsStore s) {
  switch (s.active) {
    case ProviderId.gemini:
      return 'Gemini labels who speaks each line. Timing is approximate, so '
          'following along may drift a little.';
    case ProviderId.onDevice:
      return s.models.isInstalled(speakerModelsId)
          ? 'Tells voices apart on this device. Works best with a few '
              'people and little background noise.'
          : 'Needs the speaker models below (about 30 MB).';
    default:
      return 'Only Gemini and On this device can tell speakers apart. '
          '${s.active.label} will not label them.';
  }
}

/// One line saying how transcription is set up.
String transcriptionStatus(SettingsStore s) {
  if (s.active == ProviderId.onDevice) {
    final m = s.models.byId(s.offlineModel);
    return '${s.active.label} · ${m?.label ?? 'no model downloaded'}';
  }
  return '${s.active.label} · ${s.hasKey(s.active) ? 'key saved' : 'no key yet'}';
}

/// One line summing up the transcription options.
String optionsStatus(SettingsStore s) {
  final n = s.dictionary.entries.length;
  return [
    s.translate ? 'Translate on' : 'Translate off',
    s.identifySpeakers ? 'Speakers on' : 'Speakers off',
    if (n > 0) '$n ${n == 1 ? 'word' : 'words'}',
  ].join(' · ');
}

/// One line summing up titles, summaries and tags.
String textStatus(SettingsStore s, AppState state) {
  final waiting = state.suggestedTags.length;
  final tags = state.approvedTags.length;
  return [
    if (!s.autoSummary)
      'Off'
    else if (!s.textActive.canText)
      'Needs a text provider'
    else
      'On · ${s.textActive.label}',
    waiting > 0
        ? '$waiting ${waiting == 1 ? 'tag' : 'tags'} to approve'
        : '$tags ${tags == 1 ? 'tag' : 'tags'}',
  ].join(' · ');
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<void> _setUseCase(AppState state, UseCase u) async {
    await state.settings.setUseCase(u);
    state.refresh();
    if (u == UseCase.clinical && mounted) await _offerClinicalSetup(state);
  }

  /// Offers, once per switch, the settings that suit clinical work. Anything
  /// already in place is not offered again.
  Future<void> _offerClinicalSetup(AppState state) async {
    final s = state.settings;
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
                  subtitle: Text(_canTellSpeakers(s)
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
                  subtitle: const Text(
                      'Notes get them automatically when summarised.'),
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

  Widget _row(BuildContext context, IconData icon, String title, String status,
          Widget page) =>
      ListTile(
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(status),
        trailing: const Icon(Icons.chevron_right),
        onTap: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => page)),
      );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    context.watch<ModelStore>();
    final s = state.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          const _Header('I use this for'),
          SegmentedButton<UseCase>(
            showSelectedIcon: false,
            segments: [
              for (final u in UseCase.values)
                ButtonSegment(value: u, label: Text(u.label)),
            ],
            selected: {s.useCase},
            onSelectionChanged: (v) => _setUseCase(state, v.first),
          ),
          if (s.clinical)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(
                'Adds a "Create clinical note" option to each transcript: an '
                'interpretation, a formatted note in English and the spoken '
                'language, and a list of items to verify. These are AI-generated '
                'drafts and must be reviewed by a clinician. The text is sent '
                'to your chosen provider; do not use it where patient data may '
                'not leave your organisation.',
              ),
            ),
          const _Header('Setup'),
          Card(
            child: Column(
              children: [
                _row(context, Icons.mic_none, 'Transcription',
                    transcriptionStatus(s), const _TranscriptionPage()),
                const Divider(),
                _row(context, Icons.tune, 'Transcription options',
                    optionsStatus(s), const _OptionsPage()),
                const Divider(),
                _row(context, Icons.auto_awesome_outlined,
                    'Titles, summaries and tags', textStatus(s, state),
                    const _TextPage()),
              ],
            ),
          ),
          const _Header('Recordings'),
          Card(
            child: SwitchListTile(
              title: const Text('Delete audio after transcribing'),
              subtitle: const Text(
                  'Keeps the text and removes the recording once it has '
                  'been transcribed. Saves space; you can no longer play '
                  'it back or transcribe it again.'),
              value: s.deleteAudioAfter,
              onChanged: (v) async {
                await s.setDeleteAudioAfter(v);
                state.refresh();
              },
            ),
          ),
          const _Header('Text size'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextSizeControl(
                value: state.textScale,
                onChanged: state.setTextScale,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Your API keys are stored in this device\'s secure storage and '
                    'are only sent to the provider you choose. Audio is uploaded to '
                    'that provider for transcription; nothing goes to any other server. '
                    'With "On this device", audio never leaves your phone.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A settings sub-page: a title and a list of cards.
class _SubPage extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SubPage({required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: children,
        ),
      );
}

/// Which provider transcribes, with its key or the offline models.
class _TranscriptionPage extends StatelessWidget {
  const _TranscriptionPage();

  Future<void> _openGuide(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await launchUrl(Uri.parse(apiKeyGuideUrl),
        mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not open the guide: $apiKeyGuideUrl')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    return _SubPage(
      title: 'Transcription',
      children: [
        Card(
          child: Column(
            children: [
              RadioGroup<ProviderId>(
                groupValue: s.active,
                onChanged: (v) async {
                  if (v == null) return;
                  await s.setActive(v);
                  state.refresh();
                },
                child: Column(
                  children: [
                    for (final id
                        in ProviderId.values.where((p) => p.canTranscribe))
                      RadioListTile<ProviderId>(
                        value: id,
                        title: Text(id.label,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(id.blurb),
                        secondary: id.needsKey
                            ? _KeyStatus(saved: s.hasKey(id))
                            : _KeyStatus(
                                saved: s.isReady(id),
                                yes: 'Model ready',
                                no: 'No model'),
                      ),
                  ],
                ),
              ),
              const Divider(),
              if (s.active == ProviderId.onDevice)
                _OfflineModels(store: s, onChanged: state.refresh)
              else
                _KeyEditor(
                  key: ValueKey(
                      'editor_${s.active.name}_${s.textActive == s.active}'),
                  id: s.active,
                  store: s,
                  showText: s.textActive == s.active,
                  onSaved: state.refresh,
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.help_outline),
                title: const Text('How to get an API key'),
                subtitle: const Text(
                    'Step-by-step guides for Sarvam, OpenAI and Gemini. '
                    'As of October 2026, Gemini has a free tier.'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _openGuide(context),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Translation, speaker labels and the custom dictionary.
class _OptionsPage extends StatelessWidget {
  const _OptionsPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final models = context.watch<ModelStore>();
    final s = state.settings;
    return _SubPage(
      title: 'Transcription options',
      children: [
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Translate to English'),
                subtitle: const Text(
                    'Also produce an English version. Costs an extra request per recording.'),
                value: s.translate,
                onChanged: (v) async {
                  await s.setTranslate(v);
                  state.refresh();
                },
              ),
              const Divider(),
              SwitchListTile(
                title: const Text('Identify speakers'),
                subtitle: Text(_speakerHelp(s)),
                value: s.identifySpeakers,
                onChanged: (v) async {
                  await s.setIdentifySpeakers(v);
                  state.refresh();
                },
              ),
              if (s.active == ProviderId.onDevice)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _SpeakerModelsRow(
                    installed: models.isInstalled(speakerModelsId),
                    downloading: models.downloading == speakerModelsId,
                    busy: models.downloading != null,
                    progress: models.progress,
                    onDownload: () => _downloadModel(
                        context, s, models, speakerModelsId, state.refresh),
                    onCancel: models.cancel,
                    onDelete: () async {
                      await models.delete(speakerModelsId);
                      state.refresh();
                    },
                  ),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.spellcheck),
                title: const Text('Custom dictionary'),
                subtitle: Text(s.dictionary.isEmpty
                    ? 'Names and terms to get right'
                    : '${s.dictionary.entries.length} '
                        '${s.dictionary.entries.length == 1 ? 'word' : 'words'}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const DictionaryPage()));
                  state.refresh();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Titles, summaries and tags, and the provider that writes them.
class _TextPage extends StatelessWidget {
  const _TextPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    return _SubPage(
      title: 'Titles, summaries and tags',
      children: [
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Title and summary'),
                subtitle: Text(s.textActive.canText
                    ? 'Uses your provider\'s text model to name each note.'
                    : 'On-device transcription has no text model. Turn on '
                        '"Use a different provider for text" below to get '
                        'titles and summaries when you are online.'),
                value: s.autoSummary,
                onChanged: (v) async {
                  await s.setAutoSummary(v);
                  state.refresh();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.sell_outlined),
                title: const Text('Tags'),
                subtitle: Text(state.suggestedTags.isNotEmpty
                    ? '${state.suggestedTags.length} suggested, waiting for '
                        'your approval'
                    : '${state.approvedTags.length} '
                        '${state.approvedTags.length == 1 ? 'tag' : 'tags'}'
                        ', picked automatically when a note is summarised'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const TagsPage())),
              ),
            ],
          ),
        ),
        const _Header('Text provider'),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Use a different provider for text'),
                subtitle: const Text(
                    'Titles, summaries and clinical notes can use another '
                    'provider, such as a free OpenRouter model, instead of the '
                    'transcription provider.'),
                value: s.enrichment != null,
                onChanged: (v) async {
                  await s.setEnrichment(v ? ProviderId.openrouter : null);
                  state.refresh();
                },
              ),
              if (s.enrichment != null) ...[
                const Divider(),
                RadioGroup<ProviderId>(
                  groupValue: s.enrichment,
                  onChanged: (v) async {
                    if (v == null) return;
                    await s.setEnrichment(v);
                    state.refresh();
                  },
                  child: Column(
                    children: [
                      for (final id
                          in ProviderId.values.where((p) => p.canText))
                        RadioListTile<ProviderId>(
                          value: id,
                          title: Text(id.label),
                          secondary: _KeyStatus(saved: s.hasKey(id)),
                        ),
                    ],
                  ),
                ),
                if (s.enrichment != s.active) ...[
                  const Divider(),
                  _KeyEditor(
                    key: ValueKey('editor_text_${s.enrichment!.name}'),
                    id: s.enrichment!,
                    store: s,
                    showStt: false,
                    onSaved: state.refresh,
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// "Key saved" or "No key" beside a provider.
class _KeyStatus extends StatelessWidget {
  final bool saved;
  final String yes;
  final String no;
  const _KeyStatus(
      {required this.saved, this.yes = 'Key saved', this.no = 'No key'});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      saved ? yes : no,
      style: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: saved
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) =>
      SectionLabel(text, padding: const EdgeInsets.fromLTRB(4, 24, 4, 8));
}

class _KeyEditor extends StatefulWidget {
  final ProviderId id;
  final SettingsStore store;
  final VoidCallback onSaved;
  final bool showStt;
  final bool showText;
  const _KeyEditor({
    super.key,
    required this.id,
    required this.store,
    required this.onSaved,
    this.showStt = true,
    this.showText = true,
  });

  @override
  State<_KeyEditor> createState() => _KeyEditorState();
}

class _KeyEditorState extends State<_KeyEditor> {
  late final _key = TextEditingController(text: widget.store.apiKey(widget.id));
  late final _stt = TextEditingController(text: widget.store.sttModel(widget.id));
  late final _text = TextEditingController(text: widget.store.textModel(widget.id));
  bool _hide = true;

  @override
  void dispose() {
    _key.dispose();
    _stt.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.store.setApiKey(widget.id, _key.text);
    await widget.store.setModels(
      widget.id,
      stt: widget.showStt && widget.id.canTranscribe ? _stt.text : null,
      text: widget.showText ? _text.text : null,
    );
    widget.onSaved();
    if (mounted) {
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.id.label} settings saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = modelDefaults[widget.id]!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.id.label} API key',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: _hide,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'API key',
              suffixIcon: IconButton(
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
          ),
          if (widget.showStt && widget.id.canTranscribe) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _stt,
              autocorrect: false,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Transcription model',
                helperText: 'Default: ${d.stt}',
              ),
            ),
          ],
          if (widget.showText) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              autocorrect: false,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Text model (summary, clinical note)',
                helperText: 'Default: ${d.text}',
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}

String _size(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb >= 1000 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '${mb.round()} MB';
}

/// Downloads [id], reporting a failure in a snack bar.
Future<void> _downloadModel(BuildContext context, SettingsStore store,
    ModelStore models, String id, VoidCallback onChanged) async {
  final messenger = ScaffoldMessenger.of(context);
  final err = await models.download(id);
  if (err != null) {
    messenger.showSnackBar(SnackBar(content: Text(err)));
    return;
  }
  if (!models.isInstalled(id)) return; // Cancelled.
  // The first model downloaded is the one used.
  if (store.offlineModel == id) await store.setOfflineModel(id);
  onChanged();
}

/// Downloads, picks and deletes the models used offline.
class _OfflineModels extends StatelessWidget {
  final SettingsStore store;
  final VoidCallback onChanged;
  const _OfflineModels({required this.store, required this.onChanged});

  Future<void> _delete(
      BuildContext context, ModelStore models, OfflineModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete the ${m.label} model?'),
        content: Text(
            'This frees ${_size(m.size)}. You can download it again later.'),
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
    await models.delete(m.id);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final models = context.watch<ModelStore>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4);
    final selected = store.offlineModel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Offline model', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Download a model once. After that, transcription works without '
            'internet and audio stays on your phone. Wi-Fi is recommended. '
            'Larger models are more accurate but slower. For Indian languages, '
            'the models below the Whisper ones may do better than Whisper, '
            'but Sarvam is still the one built for them.',
            style: muted,
          ),
          const SizedBox(height: 8),
          for (final m in models.catalog.where((m) => m.kind == ModelKind.whisper))
            _modelRow(context, models, m, selected),
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 2),
            child: Text('Indian languages',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: theme.colorScheme.primary)),
          ),
          Text(
            'Each model below listens in one way: the language-specific ones '
            'transcribe only their language, and Omnilingual covers many '
            'without naming which one it heard. None of them translate to '
            'English. Try one on a short recording before relying on it.',
            style: muted,
          ),
          for (final m in models.catalog.where((m) => m.kind != ModelKind.whisper))
            _modelRow(context, models, m, selected),
          if (store.translate &&
              models.byId(selected)?.canTranslate == false)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The selected model cannot translate to English, so notes '
                'transcribed with it have only the original language.',
                style: muted,
              ),
            ),
        ],
      ),
    );
  }

  Widget _modelRow(BuildContext context, ModelStore models, OfflineModel m,
          String? selected) =>
      _ModelRow(
        model: m,
        installed: models.isInstalled(m.id),
        selected: selected == m.id,
        downloading: models.downloading == m.id,
        busy: models.downloading != null,
        progress: models.progress,
        onSelect: () async {
          await store.setOfflineModel(m.id);
          onChanged();
        },
        onDownload: () =>
            _downloadModel(context, store, models, m.id, onChanged),
        onCancel: models.cancel,
        onDelete: () => _delete(context, models, m),
      );
}

class _ModelRow extends StatelessWidget {
  final OfflineModel model;
  final bool installed;
  final bool selected;
  final bool downloading;

  /// Some download is running; only one runs at a time.
  final bool busy;
  final double progress;
  final VoidCallback onSelect;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  const _ModelRow({
    required this.model,
    required this.installed,
    required this.selected,
    required this.downloading,
    required this.busy,
    required this.progress,
    required this.onSelect,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget action = downloading
        ? TextButton(onPressed: onCancel, child: const Text('Cancel'))
        : installed
            ? IconButton(
                tooltip: 'Delete ${model.label}',
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              )
            : OutlinedButton(
                onPressed: busy ? null : onDownload,
                child: const Text('Download'),
              );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (installed)
                IconButton(
                  tooltip: selected ? 'In use' : 'Use ${model.label}',
                  onPressed: onSelect,
                  icon: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected ? scheme.primary : null,
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(Icons.download_for_offline_outlined,
                      color: scheme.onSurfaceVariant),
                ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${model.label} · ${_size(model.size)}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(model.blurb, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              action,
            ],
          ),
          if (downloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(child: LinearProgressIndicator(value: progress)),
                  const SizedBox(width: 12),
                  Text('${(progress * 100).floor()}%',
                      style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Download, cancel or delete the small models that tell voices apart.
class _SpeakerModelsRow extends StatelessWidget {
  final bool installed;
  final bool downloading;
  final bool busy;
  final double progress;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  const _SpeakerModelsRow({
    required this.installed,
    required this.downloading,
    required this.busy,
    required this.progress,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget action = downloading
        ? TextButton(onPressed: onCancel, child: const Text('Cancel'))
        : installed
            ? IconButton(
                tooltip: 'Delete speaker models',
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              )
            : OutlinedButton(
                onPressed: busy ? null : onDownload,
                child: const Text('Download'),
              );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.record_voice_over_outlined,
                color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Speaker models · ${_size(speakerSegmentationFile.size + speakerEmbeddingFile.size)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('Tell voices apart. Used when "Identify speakers" is on.',
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            action,
          ],
        ),
        if (downloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 8, 8, 0),
            child: LinearProgressIndicator(value: progress),
          ),
      ],
    );
  }
}
