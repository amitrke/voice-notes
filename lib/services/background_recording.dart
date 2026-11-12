import 'dart:io';

import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _channel = MethodChannel('com.subnext.voicenotes/recording');

/// Keeps the screen on while recording, so the phone does not lock itself
/// and cut the recording short. On Android it also runs a service with a
/// "Recording" notification, so recording survives the user pressing the power
/// button or switching apps. iOS has no such mode here (the app does not
/// declare the audio background mode), so a locked or backgrounded app stops
/// recording; the wakelock is what protects a long recording there.
/// Never throws: without it, recording still works in the foreground.
Future<void> keepRecordingInBackground(bool on) async {
  try {
    await (on ? WakelockPlus.enable() : WakelockPlus.disable());
  } catch (_) {}
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod(on ? 'start' : 'stop');
  } catch (_) {}
}
