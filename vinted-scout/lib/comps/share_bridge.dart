import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Text shared into the app from the Android share sheet ("Mojo Comps").
/// The native side lives in MainActivity.kt. On other platforms this is a
/// no-op.
class ShareBridge {
  static const _ch = MethodChannel('mojo/share');
  static final _ctl = StreamController<String>.broadcast();
  static bool _ready = false;

  static Stream<String> get shares => _ctl.stream;

  static void init() {
    if (_ready || !Platform.isAndroid) return;
    _ready = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shared' && call.arguments is String) {
        _ctl.add(call.arguments as String);
      }
      return null;
    });
  }

  /// The text the app was launched with, if it was opened from a share.
  static Future<String?> takeInitial() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<String>('takeInitial');
    } catch (_) {
      return null;
    }
  }
}
