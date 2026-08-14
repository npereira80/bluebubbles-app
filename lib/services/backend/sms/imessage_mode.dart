import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/network/network_tasks.dart';
import 'package:bluebubbles/services/backend/sms/chat_merge.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';

/// TN fork — the master switch between "SMS + iMessage" and "SMS only".
///
/// Off means the BlueBubbles half of the app stops entirely: socket closed, no
/// incremental sync, no iMessage chats in the list, no server errors surfaced.
/// The app is then a plain Android SMS client.
///
/// Nothing is deleted. The local database and BlueBubbles' own sync cursor stay
/// exactly as they were, so turning it back on resumes from where it left off
/// instead of re-downloading the history.
class IMessageMode {
  /// Whether the iMessage half of the app is active.
  ///
  /// Also false when no server has been configured at all (the user skipped that
  /// step during setup), so callers don't have to test both conditions.
  static bool get enabled =>
      SettingsSvc.settings.iMessageEnabled.value && SettingsSvc.settings.serverAddress.value.isNotEmpty;

  /// Whether turning iMessage on needs the server to be configured first.
  ///
  /// True for an install that has only ever done SMS: there's nothing to connect
  /// to, so flipping the switch alone would do nothing at all.
  static bool get needsServerSetup => SettingsSvc.settings.serverAddress.value.isEmpty;

  /// Whether a chat belongs to the BlueBubbles side. Those disappear while off,
  /// including iPhone Text-Forwarding threads: everything the server provides
  /// comes down with the connection.
  static bool isServerChat(Chat chat) => !ChatMerge.isOurSms(chat);

  /// Apply a new value. Awaits the teardown/startup so the caller can hold the UI
  /// with a spinner and hand back a list that's already correct.
  static Future<void> set(bool value) async {
    if (SettingsSvc.settings.iMessageEnabled.value == value) return;

    SettingsSvc.settings.iMessageEnabled.value = value;
    await SettingsSvc.settings.saveOneAsync('iMessageEnabled');

    try {
      if (value) {
        await _turnOn();
      } else {
        await _turnOff();
      }
    } catch (e, s) {
      Logger.error('Failed to apply iMessage mode ($value): $e', trace: s);
    }

    // Rebuild the chat list against the new rules.
    ChatsSvc.chatListVersion.value++;
  }

  static Future<void> _turnOff() async {
    // Close the socket rather than just hiding the UI: an open socket keeps
    // delivering events, waking the app and draining battery for messages we've
    // been told not to show.
    try {
      SocketSvc.closeSocket();
    } catch (_) {
      // Already closed, or never opened because no server was configured.
    }
    // Deliberately NOT touching the sync cursor: that's what makes turning this
    // back on a resume rather than a full re-download.
  }

  static Future<void> _turnOn() async {
    if (SettingsSvc.settings.serverAddress.value.isEmpty) return;
    // init() rather than restartSocket(): startup skipped it entirely while this
    // was off, so the connectivity subscription was never set up either.
    SocketSvc.init();
    // Catch up from the saved point.
    unawaited(NetworkTasks.onConnect());
  }
}
