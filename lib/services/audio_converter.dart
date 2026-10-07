import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('com.subnext.voicenotes/audio');

/// Decodes [src] (m4a, mp3, ...) to a 16 kHz mono WAV in the temp directory
/// using the platform's own decoder. Returns null if the platform could not
/// convert it; the caller deletes the returned file when done.
Future<File?> convertToWav16kMono(File src) async {
  try {
    final dir = await getTemporaryDirectory();
    final dest = p.join(dir.path,
        'convert_${DateTime.now().microsecondsSinceEpoch}.wav');
    await _channel.invokeMethod<String>('toWav16kMono', {
      'src': src.path,
      'dest': dest,
    });
    return File(dest);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
