import 'dart:async';

import 'package:collection/collection.dart';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/backend/sms/sms_service.dart';
import 'package:bluebubbles/services/ui/chat/chats_service.dart';
import 'package:bluebubbles/services/ui/message/messages_service.dart';

/// TN fork — pairing between a contact's BlueBubbles chat (iMessage or iPhone
/// Text-Forwarding SMS) and our local Android SMS chat (`SMS;-;tn:<number>`).
///
/// This is the foundation for the UI merge: the chat list collapses a pair into
/// one row, and the conversation view interleaves both chats' messages. Neither
/// underlying chat record is modified, so BlueBubbles' server sync is untouched.
class ChatMerge {
  /// The canonical (E.164) number for a 1:1 phone chat, or null for groups,
  /// email/iMessage-only handles, and anything non-phone.
  static String? oneOnOneNumber(Chat chat) {
    if (chat.isGroup) return null;
    final hs = chat.handles;
    if (hs.length != 1) return null;
    final addr = hs.first.address;
    if (addr.isEmpty || addr.contains('@')) return null;
    final canon = SmsService.canonAddress(addr);
    // Only pair real phone numbers (canonAddress returns non-`+` for shortcodes).
    return canon.startsWith('+') ? canon : null;
  }

  /// True for our own local Android SMS chat namespace.
  static bool isOurSms(Chat chat) => chat.guid.startsWith('SMS;-;tn:');

  /// True for an SMS thread whose sender can't receive replies — an alphanumeric
  /// sender ID (banks, OTP codes, "MIN.SAUDE", "Google"). SMS can only be sent to
  /// phone numbers, so the composer is disabled (read-only) for these.
  static bool isReadOnlySms(Chat chat) {
    if (!isOurSms(chat)) return false;
    final addr = chat.chatIdentifier ?? '';
    if (addr.isEmpty) return true;
    return RegExp(r'[A-Za-z]').hasMatch(addr); // alphanumeric sender ID
  }

  /// The counterpart chat for [chat]: for our SMS chat → the contact's BB
  /// iMessage/TF chat; for a BB chat → our SMS chat. Null if there's no pair.
  static Chat? pairedChat(Chat chat) {
    final number = oneOnOneNumber(chat);
    if (number == null) return null;
    final wantOurs = !isOurSms(chat);
    for (final c in ChatsSvc.allChats) {
      if (c.guid == chat.guid) continue;
      if (isOurSms(c) != wantOurs) continue;
      if (oneOnOneNumber(c) == number) return c;
    }
    return null;
  }

  /// The chat an outgoing message should be sent through when the header toggle
  /// is set to SMS (green). Returns the existing local SMS chat if we already
  /// have one, otherwise a fresh `SMS;-;tn:<number>` chat that [Chat.addMessage]
  /// will persist on send. Returns null if [source] can't send SMS (no number).
  static Chat? smsSendChat(Chat source) {
    if (isOurSms(source)) return source;
    final number = oneOnOneNumber(source);
    if (number == null) return null;
    final existing = pairedChat(source);
    if (existing != null && isOurSms(existing)) return existing;
    return Chat(
      guid: 'SMS;-;tn:$number',
      chatIdentifier: number,
      participants: [Handle(address: number, service: 'SMS')],
    );
  }

  /// The local SMS chat for a canonical [number] — the existing one if there is
  /// history, otherwise a fresh unpersisted `SMS;-;tn:` chat that
  /// [Chat.addMessage] will save on send.
  ///
  /// Unlike [smsSendChat] this is keyed by number rather than an existing chat,
  /// for starting a conversation with someone we've never texted. It deliberately
  /// touches no network: an SMS thread exists only on this phone, so there is
  /// nothing for the BlueBubbles server to look up or create.
  static Chat localSmsChatFor(String number) {
    final guid = 'SMS;-;tn:$number';
    for (final c in ChatsSvc.allChats) {
      if (isOurSms(c) && oneOnOneNumber(c) == number) return c;
    }
    // Not in the in-memory list yet, but it may still be in the database — a
    // thread whose messages were all deleted, say.
    final stored = Chat.findOne(guid: guid);
    if (stored != null) return stored;

    final chat = Chat(
      guid: guid,
      chatIdentifier: number,
      participants: [Handle(address: number, service: 'SMS')],
    );

    // Persist immediately, and not as a convenience: an ObjectBox ToOne is only
    // attached to the store once its entity has been put. Chat.toMap() reads
    // dbLatestMessage.targetId, so the first save of a hand-built Chat throws
    // "ToOne relation field not initialized" — which is what happened when the
    // outgoing handler called addMessage on a brand-new SMS conversation, and
    // the send died there with nothing shown to the user.
    //
    // The incoming path gets away with a bare Chat because IncomingMsgHandler
    // puts it before anything reads the relation.
    Database.chats.put(chat);

    // Hand back the stored row, not the object that was just put.
    //
    // Everything downstream keys off chat.id — Chat.getMessagesAsync returns an
    // empty list outright when it's null — so the caller must end up with a
    // fully persisted, hydrated instance rather than the one built in memory.
    // Re-reading it also means the relations are attached, which is the same
    // trap that made the first save of a hand-built Chat throw.
    return Chat.findOne(guid: guid) ?? chat;
  }

  /// The chat to open for a compose request aimed at [number] — tapping Message
  /// on a contact, or a number in the dialer.
  ///
  /// Prefers the contact's iMessage/Text-Forwarding thread when they have one,
  /// because that's the merged conversation the person recognises and it can
  /// still send as SMS via the header toggle. Falls back to the local SMS
  /// thread, and returns null when there's no history at all, so the caller can
  /// open the new-message screen instead.
  static Chat? chatForCompose(String number) {
    final localSms =
        ChatsSvc.allChats.firstWhereOrNull((c) => isOurSms(c) && oneOnOneNumber(c) == number);

    // The iMessage condition is read from settings rather than through
    // IMessageMode, which imports this file — going the other way too would
    // make the two libraries circular.
    final iMessageOn = SettingsSvc.settings.iMessageEnabled.value &&
        SettingsSvc.settings.serverAddress.value.isNotEmpty;
    if (!iMessageOn) return localSms;

    return bbChatForNumber(number) ?? localSms;
  }

  /// The contact's BB (iMessage/TF) chat for a canonical phone [number], or null
  /// if they only have our local SMS thread. Resolved from the DB chat list, so
  /// it works even when called with a freshly-built (un-persisted) SMS chat.
  static Chat? bbChatForNumber(String number) {
    if (!number.startsWith('+')) return null;
    for (final c in ChatsSvc.allChats) {
      if (isOurSms(c)) continue;
      if (oneOnOneNumber(c) == number) return c;
    }
    return null;
  }

  /// Reflect a local SMS into the contact's paired iMessage chat so the merged
  /// UI stays correct: (1) live-insert into the open thread, (2) update the chat
  /// list preview + re-sort to top, and (3) optionally mark it unread. No-op when
  /// the contact has no iMessage chat (a pure SMS thread manages itself).
  static void reflectSmsIntoPairedChat(String number, Message message, {required bool markUnread}) {
    final bb = bbChatForNumber(number);
    if (bb == null) return;
    // (1) live insert if the merged thread is open (dedup handled internally)
    final svc = maybeFindMessagesSvc(bb.guid);
    if (svc != null) unawaited(svc.addNewMessage(message));
    // (2) preview + re-sort (updateChatLatestMessage ignores older messages)
    ChatsSvc.updateChatLatestMessage(bb.guid, message);
    // (3) unread badge (only for a live incoming SMS not currently on screen)
    if (markUnread && !ChatsSvc.isChatActive(bb.guid)) {
      unawaited(ChatsSvc.setChatHasUnread(bb, true));
    }
  }

  /// Both chats for a contact number, primary first (BB iMessage/TF preferred as
  /// the "home" chat so sending defaults to iMessage). Returns 1 or 2 chats.
  static List<Chat> chatsForContact(Chat chat) {
    final pair = pairedChat(chat);
    if (pair == null) return [chat];
    final bb = isOurSms(chat) ? pair : chat;
    final sms = isOurSms(chat) ? chat : pair;
    return [bb, sms];
  }
}
