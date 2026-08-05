import 'dart:io';

import 'package:bluebubbles/services/backend/sms/sms_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/services.dart';

/// Pushes both backends' credentials to the paired TN Watch app over the Wear
/// Data Layer (handled natively in MainActivity → WatchProvisioner.kt). The
/// watch registers itself with the sync server using the secret, so we don't
/// hand it a token. Called at startup; the watch can also request a re-push.
class WatchProvisioner {
  static const _channel = MethodChannel('tnwatch/provision');

  static Future<void> push() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('provision', <String, String>{
        'syncUrl': SmsSvc.serverUrl,
        'syncSecret': SmsSvc.serverSecret,
        'syncToken': '',
        'bbUrl': SettingsSvc.settings.serverAddress.value,
        'bbPassword': SettingsSvc.settings.guidAuthKey.value,
      });
    } catch (e) {
      Logger.debug('WatchProvisioner.push failed: $e');
    }
  }
}
