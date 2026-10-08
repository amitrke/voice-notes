import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voice_notes/data/clinical_export.dart';
import 'package:voice_notes/models/note.dart';
import 'package:voice_notes/providers/ai_provider.dart';
import 'package:voice_notes/providers/openai_provider.dart';

void main() {
  const reply = '''
{"interpretation": "Complaint: fever",
 "note_english": "Fever for 3 days.",
 "note_native": "3 రోజులుగా జ్వరం.",
 "verify": ["Brotin injection", "SOS"]}''';

  test('buildClinicalReport parses the model reply', () async {
    String? sent;
    final client = MockClient((req) async {
      sent = jsonDecode(req.body)['messages'][0]['content'] as String;
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'choices': [
              {
                'message': {'content': reply},
              },
            ],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final r = await buildClinicalReport(
      OpenAiProvider(apiKey: 'k', client: client),
      transcript: 'జ్వరం',
      english: 'fever',
      language: 'Telugu',
    );
    expect(r.noteEnglish, 'Fever for 3 days.');
    expect(r.noteNative, contains('జ్వరం'));
    expect(r.verify, ['Brotin injection', 'SOS']);
    expect(sent, contains('Telugu'));
    expect(sent, contains('Never invent'));
  });

  test('report survives a database round trip and exports as text', () {
    final report = ClinicalReport.fromJson(extractJsonObject(reply));
    final note = Note(
      segments: const [Segment(audioPath: '/a/pranav_audio.m4a')],
      provider: 'gemini',
      createdAt: DateTime(2026, 10, 7),
      languageCode: 'te-IN',
      transcript: 'జ్వరం',
      english: 'fever',
      clinical: report,
    );
    final back = Note.fromMap({...note.toMap(), 'id': 1}, note.segments);
    expect(back.clinical!.verify, hasLength(2));

    final text = clinicalReportText(back);
    expect(text, contains('CLINICAL SCRIBE'));
    expect(text, contains('pranav_audio.m4a'));
    expect(text, contains('CLINICAL NOTE — TELUGU'));
    expect(text, contains('⚠ Brotin injection'));
    expect(text, contains('6. VERIFICATION REQUIRED'));
  });
}
