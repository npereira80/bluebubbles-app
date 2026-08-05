import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/services.dart';

/// Live status of the TN Watch app, fetched over the Wear Data Layer (Bluetooth).
class WatchStatus {
  WatchStatus(this.raw);

  final Map<String, dynamic> raw;

  bool get online => raw['online'] == true;
  bool get smsConfigured => raw['smsConfigured'] == true;
  bool get smsOk => raw['smsOk'] == true;
  bool get bbConfigured => raw['bbConfigured'] == true;
  bool get bbOk => raw['bbOk'] == true;
  bool get syncing => raw['syncing'] == true;
  bool get firstSyncDone => raw['firstSyncDone'] == true;
  int get chats => (raw['chats'] as num?)?.toInt() ?? 0;
  int get messages => (raw['messages'] as num?)?.toInt() ?? 0;
  int get queued => (raw['queued'] as num?)?.toInt() ?? 0;

  /// Storage the watch app occupies on the watch (APK + all app data).
  int get storageBytes => (raw['storageBytes'] as num?)?.toInt() ?? 0;

  /// Contact photos cached on the watch.
  int get avatars => (raw['avatars'] as num?)?.toInt() ?? 0;

  /// Human-readable storage figure, e.g. "1.46 GB".
  String get storageLabel {
    final bytes = storageBytes;
    if (bytes <= 0) return "Unknown";
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return "${(bytes / gb).toStringAsFixed(2)} GB";
    if (bytes >= mb) return "${(bytes / mb).toStringAsFixed(1)} MB";
    if (bytes >= kb) return "${(bytes / kb).toStringAsFixed(0)} KB";
    return "$bytes B";
  }
  String get syncUrl => (raw['syncUrl'] as String?) ?? '';
  String get bbUrl => (raw['bbUrl'] as String?) ?? '';
  String get appVersion => (raw['appVersion'] as String?) ?? '';

  bool get configured => smsConfigured || bbConfigured;
}

/// Talks to the watch app for the "Watch App Client" settings screen. Returns
/// null whenever the watch can't be reached (not paired, out of range, or the
/// watch app isn't installed).
class WatchClient {
  static const _channel = MethodChannel('tnwatch/provision');

  static Future<WatchStatus?> fetchStatus() => _invoke('status');

  /// Asks the watch to wipe its local database and sync everything again.
  static Future<WatchStatus?> requestResync() => _invoke('resync');

  /// Pushes every contact photo we have to the watch. Returns how many were
  /// sent, or null if the push couldn't run.
  static Future<int?> pushAvatars() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('pushAvatars');
    } catch (e) {
      Logger.debug('WatchClient.pushAvatars failed: $e');
      return null;
    }
  }

  static Future<WatchStatus?> _invoke(String method) async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<String>(method);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) return WatchStatus(decoded.cast<String, dynamic>());
      return null;
    } catch (e) {
      Logger.debug('WatchClient.$method failed: $e');
      return null;
    }
  }
}
