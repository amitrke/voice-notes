import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../services/recorder_service.dart';
import 'record_screen.dart';

/// Records audio and adds it as a new note, or, when [noteId] is given, as
/// another recording on that note.
Future<void> recordAudio(BuildContext context, {int? noteId}) async {
  final state = context.read<AppState>();
  final result = await Navigator.push<RecordingResult>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          RecordScreen(format: state.settings.active.recordingFormat),
    ),
  );
  if (result == null) return;
  if (noteId == null) {
    await state.addAudio(result.path, durationMs: result.durationMs);
  } else {
    await state.addSegment(noteId, result.path, durationMs: result.durationMs);
  }
}

/// Imports an audio file as a new note, or, when [noteId] is given, as
/// another recording on that note.
Future<void> importAudio(BuildContext context, {int? noteId}) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final picked = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const [
      'm4a', 'mp3', 'wav', 'aac', 'ogg', 'opus', 'flac', 'mp4', 'amr', 'webm'
    ],
  );
  final path = picked?.path;
  if (path == null) return;
  try {
    final stored = await state.importFile(path);
    if (noteId == null) {
      await state.addAudio(stored);
    } else {
      await state.addSegment(noteId, stored);
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not import: $e')));
  }
}
