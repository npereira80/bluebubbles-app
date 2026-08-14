import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/sms/chat_merge.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TN fork — per-conversation "send as SMS" (green) vs iMessage (blue), shown as
/// the pill in the header and the colour of the send arrow.
///
/// The stored value is the route last *used* in that chat, not only what the user
/// last tapped. Sending records the route it actually went out on, including when
/// the SMS fallback took over because iMessage was unreachable — so the pill
/// always reflects what would happen if you hit send again, which is the only
/// thing it's useful for.
///
/// Chats with no stored value fall back to the route of the last outgoing message
/// in the thread, so existing conversations start out right rather than all
/// claiming iMessage.
class SmsSendMode {
  /// Legacy storage: a plain list of chat GUIDs in SMS mode. Migrated on load.
  static const String _legacyKey = 'tn_sms_send_mode_guids';
  static const String _key = 'tn_sms_send_mode';

  /// guid -> true when SMS. Absent means "not decided yet", which is different
  /// from "iMessage": only the former consults the thread's history.
  static final RxMap<String, bool> _modes = <String, bool>{}.obs;
  static SharedPreferences? _prefs;

  static Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();

    final raw = _prefs!.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        _modes.addAll((jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, v == true)));
      } catch (_) {
        // Corrupt value: start clean rather than losing the ability to send.
      }
    }

    // One-time migration from the old set-of-GUIDs format.
    final legacy = _prefs!.getStringList(_legacyKey);
    if (legacy != null) {
      for (final guid in legacy) {
        _modes.putIfAbsent(guid, () => true);
      }
      await _prefs!.remove(_legacyKey);
      await _save();
    }
  }

  static Future<void> _save() async {
    await _prefs?.setString(_key, jsonEncode(_modes));
  }

  /// True when this chat is set to send over SMS (green arrow).
  static bool isSms(String guid) => _modes[guid] ?? false;

  /// Reactive map for Obx to watch (recolour the arrow and pill on change).
  static RxMap<String, bool> get reactive => _modes;

  static Future<void> toggle(String guid) async {
    _modes[guid] = !(_modes[guid] ?? false);
    await _save();
  }

  /// Record the route a message actually went out on.
  ///
  /// Called after every send, so an automatic fallback to SMS is remembered the
  /// same as a deliberate tap — from the user's side both mean "the last message
  /// here was an SMS".
  static Future<void> remember(String guid, {required bool sms}) async {
    if (_modes[guid] == sms) return;
    _modes[guid] = sms;
    await _save();
  }

  /// Seed the mode for a chat that has never been set, from the last message you
  /// sent in it. No-op once the chat has a stored value, so it can never override
  /// a deliberate choice.
  static Future<void> seedFromHistory(Chat chat) async {
    if (_modes.containsKey(chat.guid)) return;
    if (!canToggle(chat)) return;

    Message? lastSent;
    for (final candidate in ChatMerge.chatsForContact(chat)) {
      try {
        final messages = Chat.getMessages(candidate, limit: 25);
        for (final message in messages) {
          if (!(message.isFromMe ?? false)) continue;
          final date = message.dateCreated;
          if (date == null) continue;
          if (lastSent?.dateCreated == null || date.isAfter(lastSent!.dateCreated!)) {
            lastSent = message;
          }
        }
      } catch (_) {
        // Chat with no messages yet.
      }
    }
    if (lastSent == null) return;

    final wasSms = (lastSent.guid?.startsWith('sms-') ?? false) ||
        (lastSent.chat.target != null && ChatMerge.isOurSms(lastSent.chat.target!));
    _modes[chat.guid] = wasSms;
    await _save();
  }

  /// Whether the SMS/iMessage toggle should be offered for this chat. Only for
  /// iMessage-capable 1:1 chats — a pure SMS thread is always green, so there's
  /// nothing to toggle and the chip is hidden.
  static bool canToggle(Chat chat) =>
      !ChatMerge.isOurSms(chat) && ChatMerge.oneOnOneNumber(chat) != null;
}
