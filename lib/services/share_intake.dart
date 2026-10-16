import 'dart:io';

import 'package:flutter/services.dart';

/// Turns audio and video shared from other apps (the Android share sheet)
/// into notes. The platform copies what was shared into the cache folder;
/// [onFile] imports each copy, after which it is deleted.
class ShareIntake {
  final Future<void> Function(String path) onFile;
  final MethodChannel _channel;

  ShareIntake({required this.onFile, MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('com.subnext.voicenotes/share');

  /// Starts listening, then imports anything shared before the app was ready
  /// (for example the file that launched it).
  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') await drain();
    });
    await drain();
  }

  Future<void> drain() async {
    final List<Object?>? paths;
    try {
      paths = await _channel.invokeListMethod<Object?>('take');
    } on MissingPluginException {
      return; // This platform has no share sheet integration.
    } on PlatformException {
      return;
    }
    for (final path in paths ?? const <Object?>[]) {
      if (path is! String) continue;
      try {
        await onFile(path);
      } catch (_) {
        // One bad file should not stop the rest.
      } finally {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }
}
