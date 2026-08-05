import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/outgoing_message_handler.dart';
import 'package:bluebubbles/services/backend/sms/chat_merge.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/services.dart';

/// Keeps a small, ready-to-serve snapshot of recent conversations for the Garmin
/// watch app.
///
/// Why a snapshot instead of answering requests live: the watch talks to native
/// Kotlin over Bluetooth (Connect IQ Mobile SDK), and those requests can arrive
/// while this Flutter engine is backgrounded or gone. Kotlin therefore answers
/// from the last snapshot we handed it, and we refresh it as messages change —
/// the "first sync, then push what's new" shape.
///
/// Deliberately tiny: Connect IQ devices have very little memory and each
/// Bluetooth message carries only a couple of KB, so this is 20 conversations
/// with 15 messages each, bodies truncated.
class GarminSnapshot {
  static const _channel = MethodChannel('tnwatch/garmin');

  static const int maxChats = 20;
  static const int maxMessagesPerChat = 15;
  static const int bodyLimit = 140;

  static Timer? _debounce;
  static bool _handlerInstalled = false;

  /// Starts serving the Garmin watch: pushes the first snapshot and handles the
  /// replies it sends back (native receives them over BLE and forwards here).
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler(_onNativeCall);
    }
    await push();
  }

  static Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method != 'send') return null;
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    final chatKey = (args['chatKey'] as String?) ?? '';
    final service = (args['service'] as String?) ?? 'sms';
    final body = (args['body'] as String?) ?? '';
    if (chatKey.isEmpty || body.isEmpty) return null;
    await _sendReply(chatKey, service, body);
    return true;
  }

  /// Sends a preset reply the watch chose, reusing the app's normal send paths.
  static Future<void> _sendReply(String chatKey, String service, String body) async {
    try {
      final wantIMessage = service == 'imsg';
      Chat? target;
      for (final chat in ChatsSvc.allChats) {
        final isSms = ChatMerge.isOurSms(chat);
        final key = isSms
            ? (chat.chatIdentifier ?? chat.guid)
            : (ChatMerge.oneOnOneNumber(chat) ?? chat.guid);
        if (key != chatKey) continue;
        // Pick the side matching the requested service.
        if (wantIMessage && !isSms) { target = chat; break; }
        if (!wantIMessage && isSms) { target = chat; break; }
        final paired = ChatMerge.pairedChat(chat);
        if (paired != null) { target = paired; break; }
        target ??= chat;
      }
      if (target == null) {
        Logger.warn('Garmin reply: no chat for $chatKey');
        return;
      }
      // Same path the UI uses, so SMS goes over the SIM and iMessage over the
      // BlueBubbles server without duplicating any of that logic here.
      final message = Message(
        text: body,
        dateCreated: DateTime.now(),
        hasAttachments: false,
        isFromMe: true,
        handleId: 0,
      );
      OutgoingMsgHandler.queue(OutgoingMessage(chat: target, message: message));
      schedule();   // reflect the sent message in the next snapshot
    } catch (e) {
      Logger.warn('Garmin reply failed: $e');
    }
  }

  /// Rebuild and hand over, coalescing bursts (a sync can touch many chats).
  static void schedule() {
    if (!Platform.isAndroid) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => unawaited(push()));
  }

  /// Build the snapshot now and give it to the native Garmin bridge.
  static Future<void> push() async {
    if (!Platform.isAndroid) return;
    try {
      final payload = _build();
      await _channel.invokeMethod('snapshot', {'json': jsonEncode(payload)});
    } catch (e) {
      Logger.debug('GarminSnapshot.push failed: $e');
    }
  }

  /// Tell the watch something arrived, so it can re-request if it's open.
  static Future<void> notifyNew() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('notify');
    } catch (e) {
      // Watch not connected / app not running: nothing to do.
    }
  }

  // ---- building ----------------------------------------------------------

  static Map<String, dynamic> _build() {
    final chats = <Map<String, dynamic>>[];
    final messages = <String, List<Map<String, dynamic>>>{};

    final seen = <String>{};
    for (final chat in ChatsSvc.allChats) {
      if (chats.length >= maxChats) break;

      // A contact reachable on both services has two Chat rows here (ours in the
      // SMS;-;tn: namespace, BlueBubbles' own). Represent the pair once, with
      // both services flagged, so the watch shows one thread.
      final paired = ChatMerge.pairedChat(chat);
      final isSms = ChatMerge.isOurSms(chat);
      final key = isSms
          ? (chat.chatIdentifier ?? chat.guid)
          : (ChatMerge.oneOnOneNumber(chat) ?? chat.guid);
      if (!seen.add(key)) continue;

      final smsChat = isSms ? chat : paired;
      final bbChat = isSms ? paired : chat;

      chats.add({
        'k': key,
        'n': _title(chat),
        'a': smsChat?.chatIdentifier ?? ChatMerge.oneOnOneNumber(chat) ?? key,
        's': _trim(chat.latestMessage?.text ?? '', 48),
        't': chat.latestMessage?.dateCreated?.millisecondsSinceEpoch ?? 0,
        'u': (chat.hasUnreadMessage ?? false) ? 1 : 0,
        // Which services can answer this thread.
        'sms': smsChat != null ? 1 : 0,
        'im': (bbChat != null && bbChat.isIMessage) ? 1 : 0,
        if (bbChat != null) 'g': bbChat.guid,
      });

      messages[key] = _messagesFor(smsChat, bbChat);
    }

    return {'chats': chats, 'messages': messages};
  }

  /// Newest messages across both sides of a merged thread, oldest-first.
  static List<Map<String, dynamic>> _messagesFor(Chat? smsChat, Chat? bbChat) {
    final all = <Message>[];
    for (final chat in [smsChat, bbChat]) {
      if (chat == null) continue;
      try {
        all.addAll(Chat.getMessages(chat, limit: maxMessagesPerChat));
      } catch (_) {
        // Chat with no messages yet.
      }
    }
    all.sort((a, b) {
      final at = a.dateCreated?.millisecondsSinceEpoch ?? 0;
      final bt = b.dateCreated?.millisecondsSinceEpoch ?? 0;
      return at.compareTo(bt);
    });

    final recent = all.length > maxMessagesPerChat
        ? all.sublist(all.length - maxMessagesPerChat)
        : all;

    return recent.map((m) {
      final text = m.text ?? '';
      return <String, dynamic>{
        'd': m.isFromMe == true ? 1 : 0,
        'b': _trim(text, bodyLimit),
        't': m.dateCreated?.millisecondsSinceEpoch ?? 0,
        if (m.attachments.isNotEmpty && text.isEmpty) 'p': 1,
      };
    }).toList();
  }

  static String _title(Chat chat) {
    final title = chat.getTitle();
    if (title != null && title.trim().isNotEmpty) return title.trim();
    return chat.chatIdentifier ?? chat.guid;
  }

  static String _trim(String text, int limit) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= limit) return t;
    return '${t.substring(0, limit - 1)}…';
  }
}
