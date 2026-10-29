import 'dart:convert';

import '../models/note.dart';
import '../providers/ai_provider.dart';
import '../providers/voice_match.dart';

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
        'and due date where they were mentioned. When a speaker takes on a '
        'task ("I will…"), they own it; name them as the transcript labels '
        'them. List items one per line starting with "- ". Add "Attendees" '
        'only for people who spoke and whose names are known; someone who '
        'is only mentioned did not attend.',
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
    id: speakingTemplateId,
    name: 'Speaking feedback',
    blurb: 'Clarity, pace and filler words',
    builtIn: true,
    instructions: 'Coach the speaker marked "You" on how clearly they spoke; '
        'other speakers are there only for context. Give "Unclear moments": '
        'phrases of theirs that came out garbled, cut off or hard to follow, '
        'quoted, each with a short reason and a clearer way to say it, one '
        'per line starting with "- ". Garbled or nonsensical words in a '
        'transcript usually mean mumbling or speaking too fast. Then '
        '"Habits": filler words, rambling sentences or hedging that keep '
        'coming back, with what to do instead. Then "What went well", '
        'briefly. Be specific and kind.',
  ),
  NoteTemplate(
    id: clinicalTemplateId,
    name: 'Clinical note',
    blurb: 'AI draft, a clinician must review it',
    builtIn: true,
  ),
];

/// Id of the speaking feedback template, which reads only the owner's lines
/// and adds numbers worked out on the phone.
const speakingTemplateId = 'speaking';

/// Words and phrases counted as fillers in speaking feedback.
const fillerWords = [
  'um', 'uh', 'er', 'erm', 'hmm', 'you know', 'basically', 'actually',
  'literally', 'i mean', 'kind of', 'sort of',
];

/// What speaking feedback reads from [n]: the transcript with the owner's
/// lines marked "You", how long they spoke and how many words they used.
/// A note without speaker labels counts as one person, the owner, talking.
/// Null when the note has several speakers and none is recognised as the
/// owner.
({String text, String mine, int ms})? speakingSample(Note n) {
  final lines = [for (final s in n.segments) ...s.lines];
  final labelled = lines.any((l) => l.speaker != null);
  if (!labelled) {
    final text = n.transcript.trim();
    final ms = lines.isEmpty
        ? (n.durationMs ?? 0)
        : lines.fold<int>(0, (a, l) => a + l.endMs - l.startMs);
    return (text: text, mine: text, ms: ms);
  }
  // Recognised by voice, or renamed "You" or "Me" on the note.
  bool isYou(String? id) =>
      id == youSpeakerId ||
      const {'you', 'me'}
          .contains(n.speakerNames[id]?.trim().toLowerCase());
  final mine = lines.where((l) => isYou(l.speaker)).toList();
  if (mine.isEmpty) return null;
  return (
    text: [
      for (final l in lines)
        '${isYou(l.speaker) ? 'You' : 'Other'}: ${l.text.trim()}',
    ].join('\n'),
    mine: mine.map((l) => l.text.trim()).join(' '),
    ms: mine.fold<int>(0, (a, l) => a + l.endMs - l.startMs),
  );
}

/// How often each of [fillerWords] appears in [text], most frequent first,
/// leaving out the ones that never do.
Map<String, int> countFillers(String text) {
  final lower = text.toLowerCase();
  final counts = {
    for (final f in fillerWords)
      f: RegExp('(?<![\\p{L}\'])${RegExp.escape(f)}(?![\\p{L}\'])',
              unicode: true)
          .allMatches(lower)
          .length,
  }..removeWhere((_, n) => n == 0);
  return Map.fromEntries(
      counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
}

/// Pace, speaking time and filler words, worked out on the phone rather
/// than by the model.
OutputSection speakingNumbers(({String text, String mine, int ms}) s) {
  final words =
      s.mine.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  final minutes = s.ms / 60000;
  final fillers = countFillers(s.mine);
  final total = fillers.values.fold<int>(0, (a, b) => a + b);
  return OutputSection('At a glance', [
    if (s.ms >= 30000) '- Pace: ${(words / minutes).round()} words a minute',
    if (s.ms >= 60000)
      '- You spoke for ${minutes.round()} min'
    else if (s.ms > 0)
      '- You spoke for ${(s.ms / 1000).round()} s',
    total == 0
        ? '- No filler words counted'
        : '- Filler words: $total (${fillers.entries.map((e) => '"${e.key}" ${e.value}').join(', ')})',
  ].join('\n'));
}

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

/// Asks for [t]'s notes, [current] so far, brought up to date with [newText]
/// from a recording that is still going. The reply has the same form as for
/// [templatePrompt].
String liveNotesPrompt(
  NoteTemplate t, {
  required String current,
  required String newText,
}) =>
    'You keep a "${t.name}" up to date while a recording goes on. '
    '${t.instructions}\n'
    'Below are the notes so far and what was said since. Reply with the '
    'complete updated notes as JSON only, in the form {"sections": '
    '[{"heading": "...", "body": "..."}]}: keep what still holds, add what is '
    'new, and correct anything the new part changes. Write in English unless '
    'the instructions say otherwise. Use only what was said; never invent '
    'names, numbers or details.\n\n'
    'Notes so far:\n${current.isEmpty ? '(none yet)' : current}\n\n'
    'Said since:\n$newText';

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

/// [n]'s text with each line led by who said it ("You", a name the user
/// gave, or "Speaker 2"), so templates can tell who said what. Plain text
/// when the note has no speaker labels. [english] picks the translation.
String labelledText(Note n, {bool english = false}) {
  final lines = [for (final s in n.segments) ...s.lines];
  if (!lines.any((l) => l.speaker != null)) {
    return english ? n.english : n.transcript;
  }
  return [
    for (final l in lines)
      if ((english && l.english.isNotEmpty ? l.english : l.text)
          .trim()
          .isNotEmpty)
        '${l.speaker == null ? '' : '${n.speakerLabel(l.speaker!)}: '}'
            '${(english && l.english.isNotEmpty ? l.english : l.text).trim()}',
  ].join('\n');
}

/// Runs template [t] on note [n].
Future<TemplateOutput> buildTemplateOutput(
    AiProvider provider, NoteTemplate t, Note n) async {
  if (t.id != speakingTemplateId) {
    return templateOutputFromReply(
        t,
        await provider.completeJson(templatePrompt(t,
            transcript: labelledText(n),
            english: n.english.isEmpty ? '' : labelledText(n, english: true))));
  }
  final s = speakingSample(n);
  if (s == null) {
    throw const ProviderException(
        'Speaking feedback needs to know which voice is yours. Rename your '
        'speaker "You" on this note, or set up Your voice in Settings for '
        'future recordings.');
  }
  if (s.mine.trim().isEmpty) {
    throw const ProviderException('There is no speech to give feedback on.');
  }
  final numbers = speakingNumbers(s);
  final out = templateOutputFromReply(
      t,
      await provider.completeJson(templatePrompt(t,
          transcript: '${s.text}\n\nMeasured on the phone:\n${numbers.body}',
          english: '')));
  return TemplateOutput(t.id, t.name, [numbers, ...out.sections]);
}
