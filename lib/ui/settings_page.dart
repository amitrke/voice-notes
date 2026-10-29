import 'dart:async';

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
import 'templates_ui.dart';
import 'text_size.dart';
import 'theme.dart';


/// The provider can label who is speaking.
bool _canTellSpeakers(SettingsStore s) =>
    s.active == ProviderId.gemini || s.active == ProviderId.onDevice;

/// Why "Identify speakers" cannot be turned on, or null when it can.
String? speakersBlocked(SettingsStore s) {
  if (!_canTellSpeakers(s)) {
    return '${s.active.label} can\'t tell speakers apart. Gemini and On this '
        'device can.';
  }
  if (s.active == ProviderId.onDevice &&
      !s.models.isInstalled(speakerModelsId)) {
    return 'Download the speaker models under Provider first (about 30 MB).';
  }
  return null;
}

/// What "Identify speakers" does with the transcription provider in use.
String _speakerHelp(SettingsStore s) => s.active == ProviderId.gemini
    ? 'Gemini labels who speaks each line. Timing is approximate.'
    : 'Tells voices apart on this device. Works best with a few people and '
        'little background noise.';

/// Why "Translate to English" cannot be turned on, or null when it can.
String? translateBlocked(SettingsStore s) {
  if (s.active != ProviderId.onDevice) return null;
  final id = s.offlineModel;
  final m = id == null ? null : s.models.byId(id);
  if (m == null || m.canTranslate) return null;
  return 'The ${m.label} model can\'t translate. Pick a Whisper model under '
      'Provider.';
}

/// One line saying how transcription is set up.
String transcriptionStatus(SettingsStore s) {
  if (s.active == ProviderId.onDevice) {
    final m = s.models.byId(s.offlineModel);
    return '${s.active.label} · ${m?.label ?? 'no model downloaded'}';
  }
  return '${s.active.label} · ${s.hasKey(s.active) ? 'key saved' : 'no key yet'}';
}

/// Who writes titles, summaries and clinical notes.
String writtenByStatus(SettingsStore s) {
  if (s.enrichment != null && s.enrichment != s.active) {
    return s.enrichment!.label;
  }
  return s.active.canText
      ? 'Same as transcription (${s.active.label})'
      : '${s.active.label} can\'t write text. Choose a provider.';
}

/// How many templates "Turn into…" offers.
String templatesStatus(SettingsStore s) {
  final n = s.enabledTemplates.length;
  return n == 0
      ? 'None turned on'
      : '$n ${n == 1 ? 'template' : 'templates'} under "Turn into…"';
}

/// Which providers have a key saved.
String keysStatus(SettingsStore s) {
  final saved = [
    for (final id in ProviderId.values)
      if (id.needsKey && s.hasKey(id)) id.label,
  ];
  if (saved.isEmpty) return 'No keys saved yet';
  if (saved.length == 1) return '${saved.first} saved';
  return '${saved.sublist(0, saved.length - 1).join(', ')} and '
      '${saved.last} saved';
}

/// Where the fix for a [setupProblem] is.
enum SetupFix { keys, provider, writtenBy }

/// The first thing stopping notes from being made, or null when set up.
({String message, SetupFix fix})? setupProblem(SettingsStore s) {
  if (!s.isReady(s.active)) {
    return s.active.needsKey
        ? (
            message: 'Add your ${s.active.label} key to start transcribing',
            fix: SetupFix.keys
          )
        : (
            message: 'Download an offline model to start transcribing',
            fix: SetupFix.provider
          );
  }
  if (s.autoSummary || s.clinical) {
    final t = s.textActive;
    if (!t.canText) {
      return (
        message: 'Choose who writes titles and summaries',
        fix: SetupFix.writtenBy
      );
    }
    if (!s.hasKey(t)) {
      return (
        message: 'Add your ${t.label} key for titles and summaries',
        fix: SetupFix.keys
      );
    }
  }
  return null;
}

void _open(BuildContext context, Widget page) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Widget _row(BuildContext context, IconData icon, String title,
          String status, Widget page) =>
      ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(status),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _open(context, page),
      );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    context.watch<ModelStore>();
    final s = state.settings;
    final problem = setupProblem(s);
    final speakersOff = speakersBlocked(s);
    final translateOff = translateBlocked(s);
    final waiting = state.suggestedTags.length;
    final tags = state.approvedTags.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (problem != null)
            _SetupBanner(
              message: problem.message,
              onTap: () => _open(
                  context,
                  switch (problem.fix) {
                    SetupFix.keys => const _ApiKeysPage(),
                    SetupFix.provider => const _ProviderPage(),
                    SetupFix.writtenBy => const _WrittenByPage(),
                  }),
            ),
          const _Header('Transcribe'),
          Card(
            child: Column(
              children: [
                _row(context, Icons.mic_none, 'Provider',
                    transcriptionStatus(s), const _ProviderPage()),
                const Divider(),
                SwitchListTile(
                  secondary: const Icon(Icons.translate),
                  title: const Text('Translate to English'),
                  subtitle: Text(translateOff ??
                      'Also produce an English version. One extra request '
                          'per recording.'),
                  value: translateOff == null && s.translate,
                  onChanged: translateOff != null
                      ? null
                      : (v) async {
                          await s.setTranslate(v);
                          state.refresh();
                        },
                ),
                const Divider(),
                SwitchListTile(
                  secondary: const Icon(Icons.record_voice_over_outlined),
                  title: const Text('Identify speakers'),
                  subtitle: Text(speakersOff ?? _speakerHelp(s)),
                  value: speakersOff == null && s.identifySpeakers,
                  onChanged: speakersOff != null
                      ? null
                      : (v) async {
                          await s.setIdentifySpeakers(v);
                          state.refresh();
                        },
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
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const DictionaryPage()));
                    state.refresh();
                  },
                ),
              ],
            ),
          ),
          const _Header('Write-up'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('Titles and summaries'),
                  subtitle: const Text('Names and summarises each note.'),
                  value: s.autoSummary,
                  onChanged: (v) async {
                    await s.setAutoSummary(v);
                    state.refresh();
                  },
                ),
                const Divider(),
                _row(context, Icons.edit_note, 'Written by', writtenByStatus(s),
                    const _WrittenByPage()),
                const Divider(),
                _row(
                    context,
                    Icons.sell_outlined,
                    'Tags',
                    waiting > 0
                        ? '$waiting waiting for approval'
                        : '$tags ${tags == 1 ? 'tag' : 'tags'}, picked '
                            'automatically when a note is summarised',
                    const TagsPage()),
                const Divider(),
                _row(context, Icons.auto_fix_high, 'Templates',
                    templatesStatus(s), const TemplatesPage()),
              ],
            ),
          ),
          const _Header('Recordings and display'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.delete_outline),
                  title: const Text('Delete audio after transcribing'),
                  subtitle: const Text(
                      'Keeps the text and removes the recording. Saves space; '
                      'you can no longer play it back or transcribe it again.'),
                  value: s.deleteAudioAfter,
                  onChanged: (v) async {
                    await s.setDeleteAudioAfter(v);
                    state.refresh();
                  },
                ),
                const Divider(),
                const ListTile(
                  leading: Icon(Icons.format_size),
                  title: Text('Text size'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: TextSizeControl(
                    value: state.textScale,
                    onChanged: state.setTextScale,
                  ),
                ),
              ],
            ),
          ),
          const _Header('Accounts'),
          Card(
            child: _row(context, Icons.key_outlined, 'API keys', keysStatus(s),
                const _ApiKeysPage()),
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

/// Says what is missing before notes can be made, and opens the fix.
class _SetupBanner extends StatelessWidget {
  final String message;
  final VoidCallback onTap;
  const _SetupBanner({required this.message, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: ListTile(
        leading: Icon(Icons.warning_amber_rounded,
            color: scheme.onTertiaryContainer),
        title: Text(message,
            style: TextStyle(color: scheme.onTertiaryContainer)),
        trailing:
            Icon(Icons.chevron_right, color: scheme.onTertiaryContainer),
        onTap: onTap,
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

/// Which provider transcribes, with the offline models for "On this device".
class _ProviderPage extends StatelessWidget {
  const _ProviderPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final models = context.watch<ModelStore>();
    final s = state.settings;
    return _SubPage(
      title: 'Provider',
      children: [
        Card(
          child: RadioGroup<ProviderId>(
            groupValue: s.active,
            onChanged: (v) async {
              if (v == null) return;
              await s.setActive(v);
              state.refresh();
            },
            child: Column(
              children: [
                for (final id in ProviderId.values.where((p) => p.canTranscribe))
                  RadioListTile<ProviderId>(
                    value: id,
                    title: Text(id.label,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
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
        ),
        const SizedBox(height: 12),
        if (s.active == ProviderId.onDevice) ...[
          Card(child: _OfflineModels(store: s, onChanged: state.refresh)),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
          ),
        ] else
          Card(
            child: ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text('${s.active.label} API key'),
              subtitle: Text(s.hasKey(s.active) ? 'Saved' : 'Not added yet'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(context, const _ApiKeysPage()),
            ),
          ),
      ],
    );
  }
}

/// Who writes titles, summaries and clinical notes.
class _WrittenByPage extends StatelessWidget {
  const _WrittenByPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    String status(ProviderId id) =>
        s.hasKey(id) ? 'Key saved' : 'Needs a key · add it in API keys';
    return _SubPage(
      title: 'Written by',
      children: [
        Card(
          child: RadioGroup<ProviderId?>(
            // The transcription provider is offered only as "Same as
            // transcription", so picking it by name counts as that.
            groupValue: s.enrichment == s.active ? null : s.enrichment,
            onChanged: (v) async {
              await s.setEnrichment(v);
              state.refresh();
            },
            child: Column(
              children: [
                RadioListTile<ProviderId?>(
                  value: null,
                  enabled: s.active.canText,
                  title: const Text('Same as transcription'),
                  subtitle: Text(s.active.canText
                      ? '${s.active.label} · ${status(s.active)}'
                      : '${s.active.label} has no text model. Choose another '
                          'provider; it is used when you are online.'),
                ),
                for (final id in ProviderId.values
                    .where((p) => p.canText && p != s.active))
                  RadioListTile<ProviderId?>(
                    value: id,
                    title: Text(id.label),
                    subtitle: Text(id == ProviderId.openrouter
                        ? 'Free models available · ${status(id)}'
                        : status(id)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('API keys'),
            subtitle: Text(keysStatus(s)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(context, const _ApiKeysPage()),
          ),
        ),
      ],
    );
  }
}

/// Every provider's API key in one place, with its model names.
class _ApiKeysPage extends StatelessWidget {
  const _ApiKeysPage();

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
    final ids = ProviderId.values.where((p) => p.needsKey).toList();
    return _SubPage(
      title: 'API keys',
      children: [
        Card(
          child: Column(
            children: [
              for (final id in ids) ...[
                if (id != ids.first) const Divider(),
                _KeyTile(
                  key: ValueKey('key_${id.name}'),
                  id: id,
                  store: s,
                  onSaved: state.refresh,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('How to get an API key'),
            subtitle: const Text(
                'Step-by-step guides for Sarvam, OpenAI and Gemini. '
                'As of October 2026, Gemini has a free tier.'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _openGuide(context),
          ),
        ),
      ],
    );
  }
}

/// One provider's key and model names. Changes save as you type.
class _KeyTile extends StatefulWidget {
  final ProviderId id;
  final SettingsStore store;
  final VoidCallback onSaved;
  const _KeyTile({
    super.key,
    required this.id,
    required this.store,
    required this.onSaved,
  });

  @override
  State<_KeyTile> createState() => _KeyTileState();
}

class _KeyTileState extends State<_KeyTile> {
  late final _key = TextEditingController(text: widget.store.apiKey(widget.id));
  late final _stt = TextEditingController(text: widget.store.sttModel(widget.id));
  late final _text = TextEditingController(text: widget.store.textModel(widget.id));
  bool _hide = true;
  Timer? _pending;

  /// Open at first when the provider is in use but has no key.
  late bool _expanded = !widget.store.hasKey(widget.id) &&
      (widget.store.active == widget.id ||
          widget.store.textActive == widget.id);

  @override
  void dispose() {
    if (_pending?.isActive ?? false) {
      _pending!.cancel();
      _save();
    }
    _key.dispose();
    _stt.dispose();
    _text.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _pending?.cancel();
    _pending = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() async {
    final id = widget.id;
    final key = _key.text, stt = _stt.text, text = _text.text;
    await widget.store.setApiKey(id, key);
    await widget.store.setModels(id,
        stt: id.canTranscribe ? stt : null, text: id.canText ? text : null);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final id = widget.id;
    final d = modelDefaults[id]!;
    final uses = [
      if (s.active == id) 'transcribes',
      if (s.textActive == id) 'writes titles',
    ];
    return ExpansionTile(
      shape: const Border(),
      initiallyExpanded: _expanded,
      onExpansionChanged: (v) => setState(() => _expanded = v),
      title: Text(id.label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(uses.isEmpty
          ? id.blurb
          : 'In use: ${uses.join(' and ')}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _KeyStatus(saved: s.hasKey(id)),
          const SizedBox(width: 8),
          Icon(_expanded ? Icons.expand_less : Icons.expand_more),
        ],
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      children: [
        TextField(
          controller: _key,
          obscureText: _hide,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: _changed,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: '${id.label} API key',
            helperText: 'Saved as you type',
            suffixIcon: IconButton(
              icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _hide = !_hide),
            ),
          ),
        ),
        ExpansionTile(
          shape: const Border(),
          tilePadding: EdgeInsets.zero,
          title: Text('Advanced: model names',
              style: Theme.of(context).textTheme.bodyMedium),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            if (id.canTranscribe)
              TextField(
                controller: _stt,
                autocorrect: false,
                onChanged: _changed,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Transcription model',
                  helperText: 'Default: ${d.stt}',
                ),
              ),
            if (id.canTranscribe && id.canText) const SizedBox(height: 12),
            if (id.canText)
              TextField(
                controller: _text,
                autocorrect: false,
                onChanged: _changed,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Text model (summary, clinical note)',
                  helperText: 'Default: ${d.text}',
                ),
              ),
          ],
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
                  Text('Tell voices apart. Needed for "Identify speakers".',
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
