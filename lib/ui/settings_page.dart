import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_state.dart';
import '../data/settings_store.dart';
import '../providers/ai_provider.dart';
import 'links.dart';
import 'text_size.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
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
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Header('Transcription provider'),
          RadioGroup<ProviderId>(
            groupValue: s.active,
            onChanged: (v) async {
              if (v == null) return;
              await s.setActive(v);
              setState(() {});
              state.refresh();
            },
            child: Column(
              children: [
                for (final id in ProviderId.values.where((p) => p.canTranscribe))
                  RadioListTile<ProviderId>(
                    value: id,
                    title: Text(id.label),
                    subtitle: Text(
                        '${id.blurb}${s.hasKey(id) ? '' : ' · no key yet'}'),
                  ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('How to get an API key'),
            subtitle: const Text(
                'Step-by-step guides for Sarvam, OpenAI and Gemini. '
                'As of October 2026, Gemini has a free tier.'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _openGuide(context),
          ),
          const Divider(),
          _KeyEditor(
            key: ValueKey('editor_${s.active.name}_${s.textActive == s.active}'),
            id: s.active,
            store: s,
            showText: s.textActive == s.active,
            onSaved: () {
              setState(() {});
              state.refresh();
            },
          ),
          const Divider(),
          const _Header('Enrichment'),
          SwitchListTile(
            title: const Text('Use a different provider for text'),
            subtitle: const Text(
                'Titles, summaries and clinical notes can use another '
                'provider, such as a free OpenRouter model, instead of the '
                'transcription provider.'),
            value: s.enrichment != null,
            onChanged: (v) async {
              await s.setEnrichment(v ? ProviderId.openrouter : null);
              setState(() {});
              state.refresh();
            },
          ),
          if (s.enrichment != null) ...[
            RadioGroup<ProviderId>(
              groupValue: s.enrichment,
              onChanged: (v) async {
                if (v == null) return;
                await s.setEnrichment(v);
                setState(() {});
                state.refresh();
              },
              child: Column(
                children: [
                  for (final id in ProviderId.values)
                    RadioListTile<ProviderId>(
                      value: id,
                      title: Text(id.label),
                      subtitle: Text(s.hasKey(id) ? 'Key saved' : 'No key yet'),
                    ),
                ],
              ),
            ),
            if (s.enrichment != s.active)
              _KeyEditor(
                key: ValueKey('editor_text_${s.enrichment!.name}'),
                id: s.enrichment!,
                store: s,
                showStt: false,
                onSaved: () {
                  setState(() {});
                  state.refresh();
                },
              ),
          ],
          const Divider(),
          const _Header('Text size'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextSizeControl(
              value: state.textScale,
              onChanged: state.setTextScale,
            ),
          ),
          const Divider(),
          const _Header('I use this for'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('General notes')),
                ButtonSegment(value: true, label: Text('Clinical work')),
              ],
              selected: {s.clinical},
              onSelectionChanged: (v) async {
                await s.setClinical(v.first);
                setState(() {});
                state.refresh();
              },
            ),
          ),
          if (s.clinical)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Adds a "Create clinical note" option to each transcript: an '
                'interpretation, a formatted note in English and the spoken '
                'language, and a list of items to verify. These are AI-generated '
                'drafts and must be reviewed by a clinician. The text is sent '
                'to your chosen provider; do not use it where patient data may '
                'not leave your organisation.',
              ),
            ),
          const Divider(),
          const _Header('Behaviour'),
          SwitchListTile(
            title: const Text('Translate to English'),
            subtitle: const Text(
                'Also produce an English version. Costs an extra request per recording.'),
            value: s.translate,
            onChanged: (v) async {
              await s.setTranslate(v);
              setState(() {});
            },
          ),
          SwitchListTile(
            title: const Text('Title and summary'),
            subtitle: const Text(
                'Uses your provider\'s text model to name each note.'),
            value: s.autoSummary,
            onChanged: (v) async {
              await s.setAutoSummary(v);
              setState(() {});
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Text(
              'Your API keys are stored in this device\'s secure storage and '
              'are only sent to the provider you choose. Audio is uploaded to '
              'that provider for transcription; nothing goes to any other server.',
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
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
