import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.subnext.voicenotes/recording');

/// Keeps a recording going with the screen off or another app in front. On
/// Android this runs a service with a "Recording" notification; iOS needs
/// only the audio background mode in Info.plist, so it does nothing there.
/// Never throws: without it, recording still works in the foreground.
Future<void> keepRecordingInBackground(bool on) async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod(on ? 'start' : 'stop');
  } catch (_) {}
}
