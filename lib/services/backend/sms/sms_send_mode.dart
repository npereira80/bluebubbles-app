import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/sms/chat_merge.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TN fork — per-conversation "send as SMS" toggle (green) vs iMessage (blue),
/// long-pressed on the send arrow. Persisted per chat guid (remembered per the
/// user's choice). Reactive via [inSmsMode] set so the arrow recolors instantly.
class SmsSendMode {
  static const String _key = 'tn_sms_send_mode_guids';
  static final RxSet<String> _guids = <String>{}.obs;
  static SharedPreferences? _prefs;

  static Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _guids.addAll(_prefs!.getStringList(_key) ?? const []);
  }

  /// True when this chat is set to send over SMS (green arrow).
  static bool isSms(String guid) => _guids.contains(guid);

  /// Reactive set for Obx to watch (recolor the arrow on toggle).
  static RxSet<String> get reactive => _guids;

  static Future<void> toggle(String guid) async {
    if (_guids.contains(guid)) {
      _guids.remove(guid);
    } else {
      _guids.add(guid);
    }
    await _prefs?.setStringList(_key, _guids.toList());
  }

  /// Whether the SMS/iMessage toggle should be offered for this chat. Only for
  /// iMessage-capable 1:1 chats — a pure SMS thread is always green, so there's
  /// nothing to toggle and the chip is hidden.
  static bool canToggle(Chat chat) =>
      !ChatMerge.isOurSms(chat) && ChatMerge.oneOnOneNumber(chat) != null;
}
