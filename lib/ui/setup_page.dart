import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_state.dart';
import '../providers/ai_provider.dart';
import '../services/model_store.dart';
import 'home_page.dart';
import 'links.dart';

/// The offline model offered on first run: the smallest and fastest.
const firstRunModel = 'base';

/// Show the first-run setup: nothing has been set up yet (no notes, and no
/// provider has a key or model) and it was never finished or skipped. People
/// updating from an earlier version have notes or a key, so never see it.
bool needsFirstRunSetup(AppState state) {
  final s = state.settings;
  return !s.setupDone &&
      !state.hasAnyNotes &&
      !ProviderId.values.any(s.isReady);
}

enum _Step { choose, offline, key }

/// Asks a new user how their recordings should be transcribed, and sets
/// that up: a free model on the phone, or their own AI key.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  var _step = _Step.choose;
  var _provider = ProviderId.gemini;
  final _key = TextEditingController();
  bool _hide = true;
  String? _downloadError;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final state = context.read<AppState>();
    final nav = Navigator.of(context);
    await state.settings.setSetupDone();
    state.refresh();
    nav.pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  Future<void> _chooseOffline() async {
    final state = context.read<AppState>();
    final models = context.read<ModelStore>();
    final s = state.settings;
    await s.setActive(ProviderId.onDevice);
    await s.setOfflineModel(firstRunModel);
    // Titles and summaries need an AI key; without one they would only
    // show a setup warning. They can be turned on later in Settings.
    await s.setAutoSummary(false);
    state.refresh();
    setState(() {
      _step = _Step.offline;
      _downloadError = null;
    });
    if (models.isInstalled(firstRunModel) || models.downloading != null) {
      return;
    }
    // Keeps going if the user moves on; ModelStore lives as long as the app.
    unawaited(models.download(firstRunModel).then((err) {
      if (err != null && mounted) setState(() => _downloadError = err);
      state.refresh();
    }));
  }

  Future<void> _saveKey() async {
    final s = context.read<AppState>().settings;
    await s.setApiKey(_provider, _key.text.trim());
    await s.setActive(_provider);
    await _finish();
  }

  Future<void> _openGuide() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await launchUrl(Uri.parse(apiKeyGuideUrl),
        mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not open the guide: $apiKeyGuideUrl')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _step == _Step.key
            ? BackButton(onPressed: () => setState(() => _step = _Step.choose))
            : null,
        automaticallyImplyLeading: false,
        actions: [
          if (_step != _Step.offline)
            TextButton(
              key: const ValueKey('setup_skip'),
              onPressed: _finish,
              child: const Text('Skip'),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          children: switch (_step) {
            _Step.choose => _choose(context),
            _Step.offline => _offline(context),
            _Step.key => _keyStep(context),
          },
        ),
      ),
    );
  }

  List<Widget> _choose(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final size = offlineModelById(firstRunModel)?.size ?? 0;
    return [
      Text('Welcome to Voice Notes', style: text.headlineSmall),
      const SizedBox(height: 8),
      Text('How should your recordings be turned into text? You can change '
          'this any time in Settings.'),
      const SizedBox(height: 24),
      _Choice(
        key: const ValueKey('setup_offline'),
        icon: Icons.phone_android,
        title: 'Free, on this phone',
        body: 'Download a model (${_mb(size)}). Audio never leaves your '
            'phone and it works without internet. Titles and summaries '
            'need an AI key.',
        onTap: _chooseOffline,
      ),
      const SizedBox(height: 12),
      _Choice(
        key: const ValueKey('setup_key'),
        icon: Icons.key_outlined,
        title: 'Use my own AI key',
        body: 'Sarvam, OpenAI or Google Gemini. More accurate, and adds '
            'titles, summaries and translation. Gemini has a free tier.',
        onTap: () => setState(() => _step = _Step.key),
      ),
    ];
  }

  List<Widget> _offline(BuildContext context) {
    final models = context.watch<ModelStore>();
    final text = Theme.of(context).textTheme;
    final ready = models.isInstalled(firstRunModel);
    final downloading = models.downloading == firstRunModel;
    return [
      Text(ready ? 'The model is ready' : 'Downloading the model',
          style: text.headlineSmall),
      const SizedBox(height: 16),
      if (ready)
        const Text('Recordings are transcribed on this phone.')
      else if (_downloadError != null) ...[
        Text(_downloadError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 8),
        OutlinedButton(
            onPressed: _chooseOffline, child: const Text('Try again')),
      ] else ...[
        LinearProgressIndicator(value: downloading ? models.progress : null),
        const SizedBox(height: 8),
        Text(downloading
            ? '${(models.progress * 100).round()}%'
            : 'Starting…'),
        const SizedBox(height: 16),
        const Text('You can start using the app now. The download carries on '
            'while Voice Notes is open, and recordings are transcribed once '
            'it finishes.'),
      ],
      const SizedBox(height: 32),
      FilledButton(
        key: const ValueKey('setup_done'),
        onPressed: _finish,
        child: const Text('Start using Voice Notes'),
      ),
    ];
  }

  List<Widget> _keyStep(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ids = ProviderId.values
        .where((p) => p.needsKey && p.canTranscribe)
        .toList();
    return [
      Text('Add your AI key', style: text.headlineSmall),
      const SizedBox(height: 8),
      const Text('Your key is stored in this phone\'s secure storage and is '
          'only sent to the provider you choose.'),
      const SizedBox(height: 16),
      RadioGroup<ProviderId>(
        groupValue: _provider,
        onChanged: (v) => setState(() => _provider = v ?? _provider),
        child: Column(
          children: [
            for (final id in ids)
              RadioListTile<ProviderId>(
                contentPadding: EdgeInsets.zero,
                value: id,
                title: Text(id.label),
                subtitle: Text(id.blurb),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('setup_key_field'),
        controller: _key,
        obscureText: _hide,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: '${_provider.label} API key',
          suffixIcon: IconButton(
            icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _hide = !_hide),
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          onPressed: _openGuide,
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('How to get a key'),
        ),
      ),
      const SizedBox(height: 24),
      FilledButton(
        key: const ValueKey('setup_save_key'),
        onPressed: _key.text.trim().isEmpty ? null : _saveKey,
        child: const Text('Save and start'),
      ),
    ];
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

class _Choice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;
  const _Choice({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: scheme.primary, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(body,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, height: 1.4)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
