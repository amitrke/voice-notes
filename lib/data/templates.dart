import 'dart:convert';

import '../providers/ai_provider.dart';

/// Id of the clinical template, which has its own report and screen.
const clinicalTemplateId = 'clinical';

/// Something a note can be turned into: a recipe, meeting minutes and so on.
/// [instructions] tell the text model what to write.
class NoteTemplate {
  final String id;
  final String name;
  final String blurb;
  final String instructions;
  final bool builtIn;
  const NoteTemplate({
    required this.id,
    required this.name,
    this.blurb = '',
    this.instructions = '',
    this.builtIn = false,
  });

  bool get isClinical => id == clinicalTemplateId;

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'instructions': instructions};

  factory NoteTemplate.fromJson(Map<String, dynamic> j) => NoteTemplate(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        instructions: (j['instructions'] ?? '').toString(),
      );
}

const builtInTemplates = [
  NoteTemplate(
    id: 'meeting',
    name: 'Meeting minutes',
    blurb: 'Decisions, actions and owners',
    builtIn: true,
    instructions: 'Write meeting minutes: an "Overview" of what was '
        'discussed, the "Decisions" made, and "Action items" with the owner '
        'and due date where they were mentioned. List items one per line '
        'starting with "- ". Add "Attendees" only if people were named.',
  ),
  NoteTemplate(
    id: 'todo',
    name: 'To-do list',
    blurb: 'Every task mentioned',
    builtIn: true,
    instructions: 'List every task, errand or reminder mentioned, one per '
        'line starting with "- ", short and starting with a verb. Include a '
        'date or time when one was said. Group them under headings only if '
        'they fall into clear groups.',
  ),
  NoteTemplate(
    id: 'recipe',
    name: 'Recipe',
    blurb: 'Ingredients and steps',
    builtIn: true,
    instructions: 'Write it as a recipe: "Ingredients" with quantities, one '
        'per line starting with "- ", then "Steps" as numbered lines. Add '
        '"Tips" only if any were mentioned.',
  ),
  NoteTemplate(
    id: 'grammar',
    name: 'Grammar review',
    blurb: 'Corrections with reasons',
    builtIn: true,
    instructions: 'Review the speaker\'s English. Give a "Corrected version" '
        'of what was said, then "Changes" listing each correction, one per '
        'line starting with "- ", as: original → corrected (short reason). '
        'Ignore filler words and false starts.',
  ),
  NoteTemplate(
    id: clinicalTemplateId,
    name: 'Clinical note',
    blurb: 'AI draft, a clinician must review it',
    builtIn: true,
  ),
];

/// One headed part of a [TemplateOutput].
class OutputSection {
  final String heading;
  final String body;
  const OutputSection(this.heading, this.body);
}

/// What a template wrote for a note. Keeps the template's [name] so it still
/// reads well if the template is later deleted.
class TemplateOutput {
  final String templateId;
  final String name;
  final List<OutputSection> sections;
  const TemplateOutput(this.templateId, this.name, this.sections);

  /// The whole output as plain text, for copying.
  String get text => sections
      .map((s) => s.heading.isEmpty ? s.body : '${s.heading}\n${s.body}')
      .join('\n\n');

  Map<String, Object?> toJson() => {
        'template': templateId,
        'name': name,
        'sections': [
          for (final s in sections) {'heading': s.heading, 'body': s.body}
        ],
      };

  factory TemplateOutput.fromJson(Map<String, dynamic> j) {
    final raw = j['sections'];
    return TemplateOutput(
      (j['template'] ?? '').toString(),
      (j['name'] ?? '').toString(),
      [
        if (raw is List)
          for (final s in raw.whereType<Map>())
            OutputSection((s['heading'] ?? '').toString().trim(),
                (s['body'] ?? '').toString().trim()),
      ],
    );
  }

  static List<TemplateOutput> listFrom(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          TemplateOutput.fromJson(j as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }
}

String templatePrompt(
  NoteTemplate t, {
  required String transcript,
  required String english,
}) =>
    'You turn voice notes into a "${t.name}". ${t.instructions}\n'
    'Reply with JSON only, in the form {"sections": [{"heading": "...", '
    '"body": "..."}]}, one section per part, in order. Write in English '
    'unless the instructions say otherwise. Use only what was said; never '
    'invent names, numbers or details. If the note has nothing for a part, '
    'leave that part out. If it has nothing at all for this, reply with one '
    'section whose body says so.\n\n'
    'Voice note:\n$transcript'
    '${english.isEmpty ? '' : '\n\nEnglish translation:\n$english'}';

/// Parses the reply to [templatePrompt].
TemplateOutput templateOutputFromReply(NoteTemplate t, String reply) {
  final j = extractJsonObject(reply);
  final out = TemplateOutput.fromJson(
      {'template': t.id, 'name': t.name, 'sections': j['sections']});
  final sections = out.sections
      .where((s) => s.heading.isNotEmpty || s.body.isNotEmpty)
      .toList();
  if (sections.isEmpty) {
    throw const ProviderException('The model returned nothing for this.');
  }
  return TemplateOutput(t.id, t.name, sections);
}

Future<TemplateOutput> buildTemplateOutput(
  AiProvider provider,
  NoteTemplate t, {
  required String transcript,
  required String english,
}) async =>
    templateOutputFromReply(
        t,
        await provider.completeJson(
            templatePrompt(t, transcript: transcript, english: english)));
