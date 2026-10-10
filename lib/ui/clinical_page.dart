import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/app_state.dart';
import '../data/clinical_export.dart';
import '../models/note.dart';
import 'format.dart';
import 'stale_banner.dart';
import 'theme.dart';

/// The clinical scribe output for one note: items to verify, the
/// interpretation and the clinical note in English and the spoken language.
class ClinicalPage extends StatefulWidget {
  final int noteId;
  const ClinicalPage({super.key, required this.noteId});

  @override
  State<ClinicalPage> createState() => _ClinicalPageState();
}

class _ClinicalPageState extends State<ClinicalPage> {
  bool _native = false;
  bool _regenerating = false;

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$what copied')));
  }

  Future<void> _exportTxt(Note note) async {
    final dir = await getTemporaryDirectory();
    final safe = note.title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
    final file = File(
      '${dir.path}/${safe.isEmpty ? 'clinical-note' : safe}.txt',
    );
    await file.writeAsString(clinicalReportText(note));
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  Future<void> _regenerate(AppState state, int id) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _regenerating = true);
    final err = await state.regenerate(id);
    if (mounted) setState(() => _regenerating = false);
    if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final note = state.byId(widget.noteId);
    final c = note?.clinical;
    if (note == null || c == null) {
      return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lang = languageLabel(note.languageCode) ?? 'Original';
    final hasBoth = c.noteEnglish.isNotEmpty && c.noteNative.isNotEmpty;
    final showNative = hasBoth ? _native : c.noteEnglish.isEmpty;
    final clinicalNote = showNative ? c.noteNative : c.noteEnglish;

    return Scaffold(
      appBar: AppBar(title: const Text('Clinical note')),
      bottomNavigationBar: _BottomBar(
        children: [
          FilledButton(
            onPressed: () => _exportTxt(note),
            child: const Text('Export TXT'),
          ),
          OutlinedButton(
            onPressed: () => _copy(clinicalReportText(note), 'Full report'),
            child: const Text('Copy all'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: scheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'AI-generated draft. A clinician must review it before use.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (note.isStale) ...[
            StaleBanner(
              message:
                  'This clinical note was written before the recordings '
                  'changed. Do not rely on it until it is regenerated.',
              busy: _regenerating,
              onRegenerate: () => _regenerate(state, note.id!),
            ),
            const SizedBox(height: 12),
          ],
          if (c.verify.isNotEmpty) ...[
            _VerifyCard(items: c.verify),
            const SizedBox(height: 12),
          ],
          if (c.interpretation.isNotEmpty) ...[
            _ClinicalCard(
              title: 'Interpretation',
              body: c.interpretation,
              onCopy: () => _copy(c.interpretation, 'Interpretation'),
            ),
            const SizedBox(height: 12),
          ],
          if (clinicalNote.isNotEmpty)
            _ClinicalCard(
              title: 'Clinical note',
              body: clinicalNote,
              onCopy: () => _copy(clinicalNote, 'Clinical note'),
              toggle: hasBoth
                  ? SegmentedButton<bool>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: [
                        const ButtonSegment(
                          value: false,
                          label: Text('English'),
                        ),
                        ButtonSegment(value: true, label: Text(lang)),
                      ],
                      selected: {_native},
                      onSelectionChanged: (s) =>
                          setState(() => _native = s.first),
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

/// Buttons pinned to the bottom of a screen, side by side.
class _BottomBar extends StatelessWidget {
  final List<Widget> children;
  const _BottomBar({required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              for (final (i, c) in children.indexed) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: c),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ClinicalCard extends StatelessWidget {
  final String title;
  final String body;
  final VoidCallback onCopy;
  final Widget? toggle;
  const _ClinicalCard({
    required this.title,
    required this.body,
    required this.onCopy,
    this.toggle,
  });

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: SectionLabel(title, padding: EdgeInsets.zero)),
              ?toggle,
              IconButton(
                tooltip: 'Copy',
                onPressed: onCopy,
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: SelectableText(
              body,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(height: 1.55),
            ),
          ),
        ],
      ),
    ),
  );
}

class _VerifyCard extends StatelessWidget {
  final List<String> items;
  const _VerifyCard({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.tertiary.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionLabel(
              'Verify before use · ${items.length}',
              padding: const EdgeInsets.only(bottom: 8),
              color: scheme.tertiary,
            ),
            for (final i in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 8),
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: scheme.tertiary,
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        i,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onTertiaryContainer,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
