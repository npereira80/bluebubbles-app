import 'dart:async';
import 'dart:convert';
import 'dart:io' as dartio; // WebSocket (matches websocket_adapter.dart); SMS is Android-only

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/incoming_message_handler.dart';
import 'package:bluebubbles/services/backend/sms/chat_merge.dart';
import 'package:bluebubbles/services/backend/watch/watch_provisioner.dart';
import 'package:bluebubbles/services/backend/sms/sms_send_mode.dart';
import 'package:bluebubbles/services/backend/sms/sms_server_client.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dlibphonenumber/dlibphonenumber.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:objectbox/objectbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ignore: non_constant_identifier_names
SmsService get SmsSvc => GetIt.I<SmsService>();

enum SmsSyncState { idle, syncing, synced, failed }

/// TN Messages fork — local Android SMS + two-way sync with our self-hosted
/// SMS server. See `docs/SMS_INTEGRATION.md`.
class SmsService {
  static const String _kLastSync = 'tn_sms_last_sync_ms';
  static const String _kBackfillDone = 'tn_sms_backfill_done';
  static const String _kServerUrl = 'tn_sms_server_url';
  static const String _kServerSecret = 'tn_sms_server_secret';
  static const String _kServerToken = 'tn_sms_server_token';
  static const String _kServerCursor = 'tn_sms_server_cursor_ms'; // push cursor (provider date)
  static const String _kMmsPushCursor = 'tn_mms_server_cursor_ms'; // MMS push cursor (provider date)
  static const String _kMmsLastSync = 'tn_mms_last_sync_ms';       // MMS local-display backfill cursor
  static const String _kPullCursor = 'tn_sms_pull_cursor';        // pull cursor (server delta)
  static const String _kCanonMigration = 'tn_sms_canon_v1';       // one-time E.164 rebuild
  static const String _kNsMigration = 'tn_sms_ns_v1';             // one-time namespace isolation
  static const String _kPendingOps = 'tn_sms_pending_ops';        // offline delete/read retry queue

  // Baked defaults (personal build). Overridable in Settings → SMS Agent.
  static const String _bakedUrl = 'https://sms.tn-services.net';
  static const String _bakedSecret = '8c2f2eb8802ffbe58662f75590bbfd282733f767df704443';

  static const Duration _syncInterval = Duration(seconds: 60);

  /// Observable state for the SMS Agent settings panel.
  final RxBool isDefaultSmsApp = false.obs;
  final RxBool serverRegistered = false.obs;
  final RxnString simKey = RxnString();
  final RxnString simNumber = RxnString();
  final RxBool simPresent = false.obs;   // a SIM is physically present in this device
  final RxBool canSendSms = false.obs;   // SIM present AND radio on (not airplane) → can send natively
  final Rx<SmsSyncState> syncState = SmsSyncState.idle.obs;

  /// Live server reachability for the SMS Agent panel. null = unknown / not yet
  /// checked; true = ONLINE (green); false = OFFLINE (red). Refreshed by
  /// [pingServer] on view entry, tap, and pull-to-refresh.
  final Rxn<bool> serverOnline = Rxn<bool>();
  final RxBool serverPinging = false.obs;

  /// Set while applying deletions pulled from the server, so the chat/message
  /// delete hooks don't push those same deletions back (feedback loop).
  bool suppressServerDeletePush = false;

  String serverUrl = _bakedUrl;
  String serverSecret = _bakedSecret;
  bool get serverConfigured => serverUrl.isNotEmpty && serverSecret.isNotEmpty;

  SmsServerClient? _server;
  SharedPreferences? _prefs;
  Future<SharedPreferences> get _sp async => _prefs ??= await SharedPreferences.getInstance();

  Timer? _timer;
  bool _pushing = false;
  bool _pushingMms = false;
  bool _pulling = false;
  bool _flushing = false;

  // Realtime stream (server /stream WebSocket) — instant message/read/delete,
  // with the 60s timer kept as a reconciliation safety net.
  dartio.WebSocket? _ws;
  StreamSubscription? _wsSub;
  Timer? _wsReconnect;
  int _wsAttempt = 0;
  bool _wsConnecting = false;

  // ---- lifecycle ----

  Future<void> init() async {
    if (kIsWeb || kIsDesktop) return;
    try {
      await _loadConfig();
      await SmsSendMode.load();
      await refreshStatus();
      Logger.info('SmsService: default=${isDefaultSmsApp.value}, serverConfigured=$serverConfigured');

      // One-time recovery: pull our injected SMS out of BlueBubbles' server
      // chats (namespace collision) so they re-import into our own `SMS;-;tn:`
      // namespace and stop breaking those chats.
      final prefs = await _sp;
      if (!(prefs.getBool(_kNsMigration) ?? false)) {
        await prefs.setBool(_kNsMigration, true);
        await prefs.setBool(_kCanonMigration, true);
        await _purgeInjectedSmsMessages();
      }

      if (isDefaultSmsApp.value) {
        await backfill();
      }
      if (serverConfigured) {
        await _ensureServer();
        await pingServer();
        await _heartbeat();
        await _flushPendingOps();
        await pullFromServer();
        await syncToServer();
        _startTimer();
        unawaited(_ensureStream());
      }

      // Provision the paired TN Watch with both backends' credentials.
      unawaited(WatchProvisioner.push());
    } catch (e, s) {
      Logger.error('SmsService init failed: $e', trace: s);
    }
  }

  Future<void> _loadConfig() async {
    final prefs = await _sp;
    serverUrl = prefs.getString(_kServerUrl) ?? _bakedUrl;
    serverSecret = prefs.getString(_kServerSecret) ?? _bakedSecret;
  }

  void _startTimer() {
    _timer ??= Timer.periodic(_syncInterval, (_) async {
      await pingServer();
      await _heartbeat();
      await _flushPendingOps();
      await syncToServer();
      await pullFromServer();
      unawaited(_ensureStream()); // reconnect if the socket dropped
    });
  }

  Future<void> setServerConfig(String url, String secret) async {
    serverUrl = url.trim();
    serverSecret = secret.trim();
    final prefs = await _sp;
    await prefs.setString(_kServerUrl, serverUrl);
    await prefs.setString(_kServerSecret, serverSecret);
    await prefs.remove(_kServerToken);
    _disconnectStream();
    _server = null;
    serverRegistered.value = false;
    if (serverConfigured) {
      await syncNow();
      unawaited(_ensureStream());
    }
  }

  Future<bool> requestDefault() async {
    try {
      return (await MethodChannelSvc.invokeMethod('sms-request-default')) == true;
    } catch (e, s) {
      Logger.error('SmsService requestDefault failed: $e', trace: s);
      return false;
    }
  }

  Future<int> localCount() async => (await MethodChannelSvc.invokeMethod('sms-count')) ?? 0;

  /// Delete the row from the Android Telephony provider (we own it as the default
  /// SMS app) so a re-backfill/full re-sync doesn't resurrect a message the user
  /// deleted in the UI. Matched by date+body. Only meaningful on the SIM device.
  Future<void> deleteFromProvider({required int dateMs, required String body}) async {
    if (kIsWeb || kIsDesktop) return;
    if (dateMs <= 0) return;
    try {
      await MethodChannelSvc.invokeMethod('sms-delete-match', {'date': dateMs, 'body': body});
    } catch (e) {
      Logger.warn('SMS provider delete failed: $e');
    }
  }

  /// Delete an entire conversation (SMS + MMS) from the Android Telephony
  /// provider. Deleting a chat used to leave every row in the system store, so
  /// the thread was still there in Google Messages and our own backfill could
  /// re-import it — messages coming back over and over.
  Future<void> deleteThreadFromProvider(String address) async {
    if (kIsWeb || kIsDesktop) return;
    if (address.trim().isEmpty) return;
    try {
      final removed = await MethodChannelSvc.invokeMethod('sms-delete-thread', {'address': address});
      Logger.info('SmsService: purged $removed provider row(s) for a deleted thread');
    } catch (e) {
      Logger.warn('SMS provider thread delete failed: $e');
    }
  }

  Future<void> refreshStatus() async {
    try {
      isDefaultSmsApp.value = (await MethodChannelSvc.invokeMethod('sms-is-default')) == true;
      final sim = ((await MethodChannelSvc.invokeMethod('sms-sim-info')) as Map?)?.cast<String, dynamic>() ?? {};
      simKey.value = sim['simKey'] as String?;
      simNumber.value = sim['number'] as String?;
      simPresent.value = (sim['present'] as bool?) ?? false;
      canSendSms.value = (sim['canSend'] as bool?) ?? false;
    } catch (_) {}
  }

  /// Full re-sync: reset all cursors and re-import everything from the phone
  /// provider AND the server (content-hash dedup means no duplicates). Use after
  /// clearing app data or if the server was unreachable at launch.
  Future<void> fullResyncFromServer() async {
    final prefs = await _sp;
    await prefs.setInt(_kPullCursor, 0);
    await prefs.setInt(_kServerCursor, 0);
    await prefs.setInt(_kLastSync, 0);
    await prefs.setBool(_kBackfillDone, false);
    await syncNow();
  }

  /// Manual full sync from the settings panel (with visible status).
  Future<void> syncNow() async {
    syncState.value = SmsSyncState.syncing;
    bool ok = true;
    try {
      await refreshStatus();
      if (isDefaultSmsApp.value) await backfill();
      if (isDefaultSmsApp.value) await backfillMms();
      if (serverConfigured) {
        await _ensureServer();
        await _heartbeat();
        await _flushPendingOps();
        final pushed = await syncToServer();
        final pushedMms = await syncMmsToServer();
        final pulled = await pullFromServer();
        ok = pushed && pushedMms && pulled;
      }
    } catch (e, s) {
      Logger.error('SMS syncNow failed: $e', trace: s);
      ok = false;
    }
    syncState.value = ok ? SmsSyncState.synced : SmsSyncState.failed;
  }

  // ---- local provider backfill (this phone's own SMS -> display) ----

  Future<void> backfill() async {
    final prefs = await _sp;
    final int since = prefs.getInt(_kLastSync) ?? 0;
    final bool firstRun = !(prefs.getBool(_kBackfillDone) ?? false);
    final List<dynamic> rows = (await MethodChannelSvc.invokeMethod('sms-query', {'since': since})) ?? const [];
    int maxDate = since;
    int imported = 0;
    for (final r in rows) {
      final map = (r as Map).cast<String, dynamic>();
      final int d = (map['date'] as num?)?.toInt() ?? 0;
      if (d > maxDate) maxDate = d;
      if (!firstRun && ((map['isFromMe'] as bool?) ?? false)) continue;
      await _insert(map);
      imported++;
    }
    await prefs.setInt(_kLastSync, maxDate);
    await prefs.setBool(_kBackfillDone, true);
    Logger.info('SmsService: backfilled $imported/${rows.length} local SMS (since $since, firstRun=$firstRun)');
  }

  /// Import provider MMS newer than the local-display cursor into the BlueBubbles
  /// store so they render in the thread (with their media). Separate from the
  /// server push cursor so the two never interfere.
  Future<void> backfillMms({bool live = false}) async {
    final prefs = await _sp;
    final int since = prefs.getInt(_kMmsLastSync) ?? 0;
    final List<dynamic> rows = (await MethodChannelSvc.invokeMethod('mms-query', {'since': since})) ?? const [];
    int maxDate = since;
    int imported = 0;
    for (final r in rows) {
      final map = (r as Map).cast<String, dynamic>();
      final int d = (map['date'] as num?)?.toInt() ?? 0;
      if (d > maxDate) maxDate = d;
      await _insertMms(map, live: live);
      imported++;
    }
    await prefs.setInt(_kMmsLastSync, maxDate);
    if (imported > 0) Logger.info('SmsService: backfilled $imported MMS (since $since)');
  }

  // ---- native -> dart (from method channel) ----

  Future<void> onSmsReceived(Map<String, dynamic> map) async {
    await _insert(map, live: true);
    unawaited(syncToServer());
  }

  /// Native told us an MMS finished downloading + persisted to the provider.
  /// Push it (and any others new since the cursor) up to the server. Local
  /// display in the Android thread is handled by the MMS backfill/insert path.
  Future<void> onMmsReceived(Map<String, dynamic> map) async {
    await backfillMms(live: true);   // show it in the local thread
    unawaited(syncMmsToServer());    // and push it to the server/other devices
  }

  /// Result of a native SMS/MMS send. The platform reports "sent"/"failed"
  /// asynchronously (well after the send call returns), so the optimistic bubble
  /// must be reconciled here: mark it delivered on success, or failed on failure
  /// so a send the radio rejected stops showing as "Delivered".
  Future<void> onSentStatus(Map<String, dynamic> map) async {
    final guid = map['messageId'] as String?;
    final status = map['status'] as String?;
    if (guid == null || guid.isEmpty) return;
    final message = Message.findOne(guid: guid);
    if (message == null) return;
    final chat = message.chat.target;
    if (status == 'failed') {
      message.error = MessageError.BAD_REQUEST.code;
      message.dateDelivered = null;
      message.save();
    } else if (status == 'sent') {
      if (message.error != 0 || message.dateDelivered != null) return;
      message.dateDelivered = DateTime.now();
      message.save();
    } else {
      return;
    }
    if (chat != null && Get.isRegistered<MessagesService>(tag: chat.guid)) {
      MessagesSvc(chat.guid).updateMessage(message);
    }
  }

  // ---- outbound (called by OutgoingMessageHandler for SMS chats) ----

  Future<void> nativeSend(String address, String body, String messageId) async {
    await MethodChannelSvc.invokeMethod('sms-send', {'address': address, 'body': body, 'messageId': messageId});
  }

  /// Send an MMS (text + media) over the local SIM. [parts] = list of
  /// {bytes: Uint8List, mime: String, name: String}. klinker41 persists it to
  /// the provider Sent box; the next backfillMms surfaces + syncs it.
  Future<void> nativeSendMms(List<String> addresses, String text, List<Map<String, dynamic>> parts,
      {String? messageId}) async {
    await MethodChannelSvc.invokeMethod('mms-send', {
      'addresses': addresses,
      'text': text,
      'parts': parts,
      if (messageId != null) 'messageId': messageId,
    });
  }

  /// Send a text SMS via the server relay (this device has no SIM). The server
  /// dispatches it to the primary phone, which sends it over its radio.
  Future<void> sendTextViaServer(String address, String body) async {
    if (!await _ensureServer()) throw StateError('SMS server not available');
    await _server!.send(to: address, body: body);
  }

  /// Send an MMS via the server relay (this device has no SIM). Uploads each
  /// media part to the server, then asks the primary phone to send it.
  Future<void> sendMmsViaServer(String address, String text, List<Map<String, dynamic>> parts) async {
    if (!await _ensureServer()) throw StateError('SMS server not available');
    final List<Map<String, dynamic>> attachments = [];
    for (final p in parts) {
      final bytes = p['bytes'];
      final mime = (p['mime'] as String?) ?? 'application/octet-stream';
      if (bytes is! Uint8List || bytes.isEmpty) continue;
      final sha = await _server!.uploadMedia(bytes, mime);
      if (sha == null) throw StateError('media upload failed');
      attachments.add({'sha256': sha, 'mime': mime, 'size': bytes.length, if (p['name'] != null) 'name': p['name']});
    }
    await _server!.send(to: address, body: text, attachments: attachments);
  }

  /// Called after this device transmits an SMS over the radio.
  ///
  /// Ingests the message immediately so the Mac/watch see it, then schedules the
  /// provider push. Waiting only on the provider round-trip (SmsSentReceiver
  /// writes the Sent box → next syncToServer) left the message visible on this
  /// phone alone whenever that write was late or missing.
  Future<void> recordOutgoing(String address, String body, int ts) async {
    await _ingestOutgoing(address, body, ts);
    unawaited(Future.delayed(const Duration(seconds: 4), syncToServer));
  }

  /// After a native MMS send, give klinker41 a moment to persist to the provider
  /// Sent box, then backfill it locally (dedups the optimistic bubble) and push
  /// it to the server so the Mac/other devices get it.
  Future<void> recordOutgoingMms() async {
    unawaited(Future.delayed(const Duration(seconds: 4), () async {
      await backfillMms();
      await syncMmsToServer();
    }));
  }

  // ---- server sync ----

  /// Ping the SMS server's `/health` endpoint and publish ONLINE/OFFLINE to
  /// [serverOnline]. Works even before registration (uses a transient client),
  /// so the panel can show reachability independent of the sync/auth state.
  Future<bool> pingServer() async {
    if (!serverConfigured) {
      serverOnline.value = null;
      return false;
    }
    serverPinging.value = true;
    try {
      final client = _server ?? SmsServerClient(baseUrl: serverUrl, secret: serverSecret);
      final ok = await client.ping();
      serverOnline.value = ok;
      return ok;
    } catch (_) {
      serverOnline.value = false;
      return false;
    } finally {
      serverPinging.value = false;
    }
  }

  /// Push a conversation's read-state to the server (keyed by canonical number)
  /// so the Mac and other Android devices reflect it. Queued so a change made
  /// offline still propagates once connectivity returns.
  Future<void> reportReadState(String canonNumber, bool unread) async {
    if (!serverConfigured) return;
    await _enqueueOp({'op': 'read', 'address': canonNumber, 'unread': unread}, dedupReadAddress: canonNumber);
    await _flushPendingOps();
  }

  // ---- offline retry queue (delete + read pushes) ----

  Future<List<Map<String, dynamic>>> _loadOps(SharedPreferences prefs) async {
    final raw = prefs.getString(_kPendingOps);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveOps(SharedPreferences prefs, List<Map<String, dynamic>> ops) async {
    if (ops.isEmpty) {
      await prefs.remove(_kPendingOps);
    } else {
      await prefs.setString(_kPendingOps, jsonEncode(ops));
    }
  }

  /// Append a pending server op. For read ops, [dedupReadAddress] collapses any
  /// earlier read op for the same conversation so the queue can't grow unbounded.
  Future<void> _enqueueOp(Map<String, dynamic> op, {String? dedupReadAddress}) async {
    final prefs = await _sp;
    final ops = await _loadOps(prefs);
    if (dedupReadAddress != null) {
      ops.removeWhere((o) => o['op'] == 'read' && o['address'] == dedupReadAddress);
    }
    ops.add(op);
    await _saveOps(prefs, ops);
  }

  Future<void> _executeOp(Map<String, dynamic> op) async {
    switch (op['op']) {
      case 'delete':
        await _server!.delete(
          messageHashes: (op['messageHashes'] as List?)?.cast<String>(),
          conversationId: op['conversationId'] as String?,
        );
        break;
      case 'read':
        await _server!.read([
          {'address': op['address'], 'unread': op['unread']}
        ]);
        break;
    }
  }

  /// Drain the pending-ops queue in order. Successful ops are removed; a op the
  /// server rejects (4xx) is dropped as unfixable; the first network/5xx failure
  /// stops the drain and keeps the rest for the next sync.
  Future<void> _flushPendingOps() async {
    if (_flushing) return;
    if (!serverConfigured) return;
    if (!await _ensureServer()) return;
    _flushing = true;
    try {
      final prefs = await _sp;
      final ops = await _loadOps(prefs);
      if (ops.isEmpty) return;
      final remaining = <Map<String, dynamic>>[];
      bool stop = false;
      for (final op in ops) {
        if (stop) {
          remaining.add(op);
          continue;
        }
        try {
          await _executeOp(op);
          // success — drop it
        } on DioException catch (e) {
          final code = e.response?.statusCode;
          if (code != null && code >= 400 && code < 500) {
            Logger.warn('Dropping server-rejected SMS op ($code): $op');
            // drop unfixable op
          } else {
            // no response (offline) or 5xx — keep this and the rest, stop
            remaining.add(op);
            stop = true;
          }
        } catch (e) {
          remaining.add(op);
          stop = true;
        }
      }
      await _saveOps(prefs, remaining);
      if (remaining.isNotEmpty) {
        Logger.info('SMS: ${remaining.length} pending op(s) still queued (offline)');
      }
    } finally {
      _flushing = false;
    }
  }

  // ---- realtime stream (/stream WebSocket) ----

  String? _streamUrl() {
    final token = _server?.token;
    if (token == null) return null;
    var base = serverUrl.trim();
    if (base.startsWith('https')) {
      base = base.replaceFirst('https', 'wss');
    } else if (base.startsWith('http')) {
      base = base.replaceFirst('http', 'ws');
    }
    base = base.replaceAll(RegExp(r'/+$'), '');
    return '$base/stream?token=$token';
  }

  /// Open the realtime stream if not already connected. Safe to call repeatedly
  /// (the 60s timer does, so a dropped socket recovers even if the backoff timer
  /// was cleared). On connect we pull the delta once to catch up on anything
  /// missed while disconnected.
  Future<void> _ensureStream() async {
    if (kIsWeb || kIsDesktop) return;
    if (_ws != null || _wsConnecting) return;
    if (!serverConfigured) return;
    if (!await _ensureServer()) return;
    final url = _streamUrl();
    if (url == null) return;
    _wsConnecting = true;
    try {
      final ws = await dartio.WebSocket.connect(url).timeout(const Duration(seconds: 15));
      _ws = ws;
      _wsAttempt = 0;
      Logger.info('SMS stream connected');
      _wsSub = ws.listen(
        (data) => _handleStreamEvent(data),
        onDone: () => _onStreamClosed('done'),
        onError: (e) => _onStreamClosed('error: $e'),
        cancelOnError: true,
      );
      unawaited(pullFromServer());
      unawaited(_flushPendingOps());
    } catch (e) {
      Logger.warn('SMS stream connect failed: $e');
      _onStreamClosed('connect failed');
    } finally {
      _wsConnecting = false;
    }
  }

  void _onStreamClosed(String reason) {
    Logger.info('SMS stream closed ($reason)');
    _wsSub?.cancel();
    _wsSub = null;
    _ws = null;
    _scheduleStreamReconnect();
  }

  void _disconnectStream() {
    _wsReconnect?.cancel();
    _wsReconnect = null;
    _wsSub?.cancel();
    _wsSub = null;
    _ws?.close();
    _ws = null;
    _wsAttempt = 0;
  }

  void _scheduleStreamReconnect() {
    if (_wsReconnect?.isActive ?? false) return;
    const delays = [2, 5, 10, 20, 30];
    final secs = delays[_wsAttempt.clamp(0, delays.length - 1)];
    _wsAttempt++;
    _wsReconnect = Timer(Duration(seconds: secs), () {
      _wsReconnect = null;
      unawaited(_ensureStream());
    });
  }

  Future<void> _handleStreamEvent(dynamic raw) async {
    Map<String, dynamic> data;
    try {
      data = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    try {
      switch (data['type']) {
        case 'message':
          await _handleStreamMessage(data['message']);
          break;
        case 'conversation_read':
          await _applyReadStateLocal(data['conversationId'] as String?, (data['unread'] as bool?) ?? false);
          break;
        case 'message_deleted':
          final h = data['contentHash'] as String?;
          if (h != null && h.isNotEmpty) {
            await _applyServerDeletions([
              {'content_hash': h, 'conversation_id': data['conversationId']}
            ]);
          }
          break;
        case 'conversation_deleted':
          await _applyConversationDeletedLocal(data['conversationId'] as String?);
          break;
        case 'send':
          await _handleStreamSend(data);
          break;
        // welcome / primary_changed / send_status: no action needed here.
      }
    } catch (e, s) {
      Logger.warn('SMS stream event handling failed: $e', trace: s);
    }
  }

  Future<void> _handleStreamMessage(dynamic rawMsg) async {
    if (rawMsg is! Map) return;
    final m = rawMsg.cast<String, dynamic>();
    final address = (m['address'] as String?) ?? '';
    final body = (m['body'] as String?) ?? '';
    final ts = (m['ts'] as num?)?.toInt() ?? 0;
    final isFromMe = m['direction'] == 'out';
    if (address.isEmpty) return;
    // Dedup against our own copy (the SIM phone echoes its own captured SMS back
    // via the stream). Skipping here also avoids re-marking a read chat unread.
    final guid = smsGuid(isFromMe: isFromMe, address: canonAddress(address), body: body, dateMs: ts);
    if (Message.findOne(guid: guid) != null) return;
    await _insert({'address': address, 'body': body, 'date': ts, 'isFromMe': isFromMe}, live: true);
  }

  /// Set a chat's unread flag locally only — no BlueBubbles-server read receipt
  /// and no re-push to our SMS server (avoids a read-state loop).
  Future<void> _setChatUnreadLocal(Chat chat, bool unread) async {
    if ((chat.hasUnreadMessage ?? false) == unread) return;
    await chat.toggleHasUnreadAsync(unread, force: true, clearLocalNotifications: false, privateMark: false);
    ChatsSvc.getChatState(chat.guid)?.hasUnreadMessage.value = unread;
    ChatsSvc.updateChat(chat);
  }

  Future<void> _applyReadStateLocal(String? convId, bool unread) async {
    if (convId == null) return;
    for (final chat in ChatsSvc.allChats.where((c) => c.guid.startsWith('SMS;-;tn:')).toList()) {
      if (serverConvId(chat.chatIdentifier ?? '') != convId) continue;
      await _setChatUnreadLocal(chat, unread);
      final bb = ChatMerge.bbChatForNumber(canonAddress(chat.chatIdentifier ?? ''));
      if (bb != null) await _setChatUnreadLocal(bb, unread);
      break;
    }
  }

  Future<void> _applyConversationDeletedLocal(String? convId) async {
    if (convId == null) return;
    suppressServerDeletePush = true;
    try {
      for (final chat in ChatsSvc.allChats.where((c) => c.guid.startsWith('SMS;-;tn:')).toList()) {
        if (serverConvId(chat.chatIdentifier ?? '') != convId) continue;
        final paired = ChatMerge.pairedChat(chat);
        // One provider purge for the whole thread: the previous per-message
        // date+body deletes only covered SMS rows (MMS survived) and were slow
        // on long threads.
        await deleteThreadFromProvider(chat.chatIdentifier ?? '');
        for (final m in Chat.getMessages(chat, limit: 100000)) {
          final g = m.guid;
          if (g == null) continue;
          await Message.delete(g);
          if (Get.isRegistered<MessagesService>(tag: chat.guid)) MessagesSvc(chat.guid).removeMessage(m);
          if (paired != null && Get.isRegistered<MessagesService>(tag: paired.guid)) {
            MessagesSvc(paired.guid).removeMessage(m);
          }
        }
        try {
          await ChatsSvc.deleteChat(chat);
        } catch (_) {}
        break;
      }
    } finally {
      suppressServerDeletePush = false;
    }
  }

  /// The server dispatches Mac/iPad/second-device sends to the primary (SIM)
  /// device over the stream. Send it via the SIM and report status back. If the
  /// event carries attachments it's a relayed MMS: download each media blob from
  /// the server, then send as MMS.
  Future<void> _handleStreamSend(Map<String, dynamic> data) async {
    final to = (data['to'] as String?) ?? '';
    final body = (data['body'] as String?) ?? '';
    final requestId = (data['requestId'] as String?) ?? '';
    final List<dynamic> atts = (data['attachments'] as List?) ?? const [];
    if (to.isEmpty) {
      _sendStreamStatus(requestId, 'failed');
      return;
    }
    try {
      if (atts.isNotEmpty) {
        // Relayed MMS: fetch the media the requesting device uploaded, then send.
        if (!await _ensureServer()) { _sendStreamStatus(requestId, 'failed'); return; }
        final List<Map<String, dynamic>> parts = [];
        for (final a in atts) {
          final m = (a as Map).cast<String, dynamic>();
          final sha = m['sha256'] as String?;
          if (sha == null) continue;
          final bytes = await _server!.downloadMedia(sha);
          if (bytes == null || bytes.isEmpty) { _sendStreamStatus(requestId, 'failed'); return; }
          parts.add({
            'bytes': bytes,
            'mime': (m['mime'] as String?) ?? 'application/octet-stream',
            if (m['name'] != null) 'name': m['name'],
          });
        }
        await nativeSendMms([to], body, parts);
        recordOutgoingMms();
        _sendStreamStatus(requestId, 'sent');
      } else {
        await nativeSend(to, body, 'ws-$requestId');
        final ts = DateTime.now().millisecondsSinceEpoch;
        await _insert({'address': to, 'body': body, 'date': ts, 'isFromMe': true}, live: false);
        // Awaited: recordOutgoing ingests the message, so the watch/Mac that
        // requested this send has it before we report success.
        await recordOutgoing(to, body, ts);
        _sendStreamStatus(requestId, 'sent');
      }
    } catch (e) {
      Logger.warn('SMS stream send failed: $e');
      _sendStreamStatus(requestId, 'failed');
    }
  }

  /// Outgoing messages ingested directly (address|body|ts), so the provider copy
  /// of the same message isn't pushed a second time. The server dedups by content
  /// hash, but that hash buckets the timestamp in 10s windows, and our timestamp
  /// and the provider's can straddle a boundary — which would create a duplicate.
  final List<({String address, String body, int ts})> _directIngests = [];

  /// Ingest an outgoing SMS we just transmitted, so other devices see it without
  /// waiting for the provider → push round-trip.
  Future<void> _ingestOutgoing(String to, String body, int ts) async {
    try {
      if (!await _ensureServer()) return;
      final address = canonAddress(to);
      await _server!.ingest([
        {
          'direction': 'out',
          'address': address,
          'body': body,
          'ts': ts,
          'type': 'sms',
        }
      ]);
      final cutoff = DateTime.now().millisecondsSinceEpoch - 300000; // keep 5 min
      _directIngests.removeWhere((e) => e.ts < cutoff);
      _directIngests.add((address: address, body: body, ts: ts));
    } catch (e) {
      // Non-fatal: the provider copy still gets pushed by the next sync.
      Logger.warn('SmsService: direct ingest of outgoing SMS failed: $e');
    }
  }

  /// True when this provider row is the echo of a message we already ingested.
  bool _alreadyIngested(Map<String, dynamic> serverMsg) {
    if (serverMsg['direction'] != 'out') return false;
    final address = (serverMsg['address'] as String?) ?? '';
    final body = (serverMsg['body'] as String?) ?? '';
    final ts = (serverMsg['ts'] as num?)?.toInt() ?? 0;
    return _directIngests.any((e) =>
        e.address == address && e.body == body && (e.ts - ts).abs() <= 15000);
  }

  void _sendStreamStatus(String requestId, String status) {
    try {
      _ws?.add(jsonEncode({'type': 'send_status', 'requestId': requestId, 'status': status}));
    } catch (_) {}
  }

  /// Propagate a deletion to the server so other devices remove it too. Delete a
  /// single message by cross-device content hash, or a whole thread by
  /// conversation id (canonical number key). Queued so a delete made offline
  /// still propagates once connectivity returns.
  Future<void> deleteOnServer({List<String>? messageHashes, String? conversationId}) async {
    if (!serverConfigured) return;
    final op = <String, dynamic>{'op': 'delete'};
    if (messageHashes != null && messageHashes.isNotEmpty) op['messageHashes'] = messageHashes;
    if (conversationId != null) op['conversationId'] = conversationId;
    if (op.length == 1) return; // nothing to delete
    await _enqueueOp(op);
    await _flushPendingOps();
  }

  Future<bool> _ensureServer() async {
    if (!serverConfigured) return false;
    final prefs = await _sp;
    _server ??= SmsServerClient(baseUrl: serverUrl, secret: serverSecret, token: prefs.getString(_kServerToken));
    if (_server!.token == null) {
      try {
        final token = await _server!.register('BlueBubbles Android SMS');
        if (token != null) await prefs.setString(_kServerToken, token);
      } catch (e) {
        Logger.warn('SMS server register deferred: $e');
        serverRegistered.value = false;
        return false;
      }
    }
    serverRegistered.value = _server!.token != null;
    return serverRegistered.value;
  }

  Future<void> _heartbeat() async {
    if (!await _ensureServer()) return;
    try {
      final sim = ((await MethodChannelSvc.invokeMethod('sms-sim-info')) as Map?)?.cast<String, dynamic>() ?? {};
      simKey.value = sim['simKey'] as String?;
      simNumber.value = sim['number'] as String?;
      simPresent.value = (sim['present'] as bool?) ?? false;
      canSendSms.value = (sim['canSend'] as bool?) ?? false;
      // Report canSend (not mere SIM presence) so the server won't elect a
      // device that can't currently transmit (e.g. airplane mode) as primary.
      await _server!.heartbeat((sim['canSend'] as bool?) ?? false, sim['simKey'] as String?);
    } catch (e) {
      Logger.warn('SMS heartbeat deferred: $e');
    }
  }

  /// Push provider SMS newer than the push cursor. Cursor only advances on
  /// success (offline recovery). Returns true if the server op succeeded.
  Future<bool> syncToServer() async {
    if (_pushing) return true;
    if (!await _ensureServer()) return false;
    _pushing = true;
    try {
      final prefs = await _sp;
      final int cursor = prefs.getInt(_kServerCursor) ?? 0;
      final List<dynamic> rows = (await MethodChannelSvc.invokeMethod('sms-query', {'since': cursor})) ?? const [];
      if (rows.isEmpty) return true;
      int maxDate = cursor;
      final List<Map<String, dynamic>> batch = [];
      for (final r in rows) {
        final map = (r as Map).cast<String, dynamic>();
        final int d = (map['date'] as num?)?.toInt() ?? 0;
        if (d > maxDate) maxDate = d;
        final serverMsg = _toServerMsg(map);
        // Skip the provider echo of a message we already ingested at send time.
        if (_alreadyIngested(serverMsg)) continue;
        batch.add(serverMsg);
      }
      for (var i = 0; i < batch.length; i += 200) {
        await _server!.ingest(batch.sublist(i, (i + 200) > batch.length ? batch.length : i + 200));
      }
      await prefs.setInt(_kServerCursor, maxDate);
      Logger.info('SmsService: pushed ${batch.length} SMS (cursor $cursor -> $maxDate)');
      return true;
    } catch (e) {
      Logger.warn('SmsService: push deferred (will retry): $e');
      return false;
    } finally {
      _pushing = false;
    }
  }

  /// Push provider MMS newer than the MMS push cursor: upload each media part to
  /// the server's content-addressed store, then ingest the message with its
  /// attachment metadata. Cursor only advances on full success (offline retry).
  Future<bool> syncMmsToServer() async {
    if (_pushingMms) return true;
    if (!await _ensureServer()) return false;
    _pushingMms = true;
    try {
      final prefs = await _sp;
      final int cursor = prefs.getInt(_kMmsPushCursor) ?? 0;
      final List<dynamic> rows = (await MethodChannelSvc.invokeMethod('mms-query', {'since': cursor})) ?? const [];
      if (rows.isEmpty) return true;
      int maxDate = cursor;
      final List<Map<String, dynamic>> batch = [];
      for (final r in rows) {
        final map = (r as Map).cast<String, dynamic>();
        final int d = (map['date'] as num?)?.toInt() ?? 0;

        // Upload each media part; abort this cycle if any upload fails so we
        // don't ingest a message referencing media the server doesn't have.
        final List<dynamic> parts = (map['parts'] as List?) ?? const [];
        final List<Map<String, dynamic>> attachments = [];
        bool uploadsOk = true;
        for (final p in parts) {
          final part = (p as Map).cast<String, dynamic>();
          final int partId = (part['partId'] as num?)?.toInt() ?? -1;
          final String mime = (part['contentType'] as String?) ?? 'application/octet-stream';
          if (partId < 0) continue;
          final bytes = await MethodChannelSvc.invokeMethod('mms-part-bytes', {'partId': partId});
          if (bytes is! Uint8List || bytes.isEmpty) continue;
          final sha = await _server!.uploadMedia(bytes, mime);
          if (sha == null) { uploadsOk = false; break; }
          attachments.add({
            'sha256': sha, 'mime': mime, 'size': bytes.length,
            if (part['name'] != null) 'name': part['name'],
          });
        }
        if (!uploadsOk) {
          Logger.warn('SmsService: MMS media upload failed; will retry (cursor stays $cursor)');
          return false;
        }

        if (d > maxDate) maxDate = d;
        batch.add({
          'direction': ((map['isFromMe'] as bool?) ?? false) ? 'out' : 'in',
          'address': canonAddress((map['address'] as String?) ?? ''),
          'body': (map['body'] as String?) ?? '',
          'ts': d,
          'type': 'mms',
          if (map['providerId'] != null) 'providerId': map['providerId'].toString(),
          'attachments': attachments,
        });
      }
      if (batch.isNotEmpty) await _server!.ingest(batch);
      await prefs.setInt(_kMmsPushCursor, maxDate);
      Logger.info('SmsService: pushed ${batch.length} MMS (cursor $cursor -> $maxDate)');
      return true;
    } catch (e) {
      Logger.warn('SmsService: MMS push deferred (will retry): $e');
      return false;
    } finally {
      _pushingMms = false;
    }
  }

  /// Pull server messages newer than the pull cursor into the local store —
  /// gives a new / SIM-swapped phone the full aggregated history.
  Future<bool> pullFromServer() async {
    if (_pulling) return true;
    if (!await _ensureServer()) return false;
    _pulling = true;
    try {
      final prefs = await _sp;
      final int since = prefs.getInt(_kPullCursor) ?? 0;
      final data = await _server!.delta(since);
      final msgs = (data['messages'] as List?) ?? const [];
      for (final m in msgs) {
        final sm = (m as Map).cast<String, dynamic>();
        await _insert({
          'address': sm['address'],
          'body': sm['body'],
          'date': (sm['ts'] as num?)?.toInt() ?? 0,
          'isFromMe': sm['direction'] == 'out',
          'providerId': null,
        });
      }
      await _applyServerDeletions((data['deletions'] as List?) ?? const []);
      await _applyServerReadState((data['conversations'] as List?) ?? const []);
      final int cursor = (data['cursor'] as num?)?.toInt() ?? since;
      await prefs.setInt(_kPullCursor, cursor);
      if (msgs.isNotEmpty) Logger.info('SmsService: pulled ${msgs.length} SMS (cursor $since -> $cursor)');
      return true;
    } catch (e) {
      Logger.warn('SmsService: pull deferred (will retry): $e');
      return false;
    } finally {
      _pulling = false;
    }
  }

  /// Apply deletion tombstones from the server: remove local SMS messages whose
  /// cross-device content hash matches a tombstone (deleted on another device).
  /// Empty SMS chats left behind are removed. Mirrored copies in an open paired
  /// iMessage thread are pulled out too.
  Future<void> _applyServerDeletions(List<dynamic> deletions) async {
    if (deletions.isEmpty) return;
    suppressServerDeletePush = true;
    try {
      await _applyServerDeletionsInner(deletions);
    } finally {
      suppressServerDeletePush = false;
    }
  }

  Future<void> _applyServerDeletionsInner(List<dynamic> deletions) async {
    final Set<String> hashes = {};
    final Set<String> convIds = {};
    for (final d in deletions) {
      final m = (d as Map).cast<String, dynamic>();
      final h = m['content_hash'] as String?;
      if (h != null && h.isNotEmpty) hashes.add(h);
      final c = m['conversation_id'] as String?;
      if (c != null && c.isNotEmpty) convIds.add(c);
    }
    if (hashes.isEmpty) return;

    final smsChats = ChatsSvc.allChats.where((c) => c.guid.startsWith('SMS;-;tn:')).toList();
    // Prefer scanning only affected conversations; fall back to all if a
    // tombstone carried no conversation id.
    final candidates = convIds.isEmpty
        ? smsChats
        : smsChats.where((c) => convIds.contains(serverConvId(c.chatIdentifier ?? ''))).toList();

    for (final chat in candidates) {
      final number = chat.chatIdentifier ?? '';
      final msgs = Chat.getMessages(chat, limit: 100000);
      final paired = ChatMerge.pairedChat(chat);
      bool removedAny = false;
      for (final msg in msgs) {
        final h = serverContentHash(
          isFromMe: msg.isFromMe ?? false,
          address: number,
          body: msg.text ?? '',
          dateMs: msg.dateCreated?.millisecondsSinceEpoch ?? 0,
        );
        if (!hashes.contains(h)) continue;
        final guid = msg.guid;
        if (guid == null) continue;
        await Message.delete(guid);
        // Also remove it from the Android Telephony provider. Without this, a
        // delete that originated elsewhere (e.g. the Mac) leaves the SMS in the
        // SIM phone's provider, and the next syncToServer re-ingests it — which
        // the server now rejects via tombstone, but deleting the provider row
        // keeps the phone itself consistent and stops the pointless re-push.
        await deleteFromProvider(
          dateMs: msg.dateCreated?.millisecondsSinceEpoch ?? 0,
          body: msg.text ?? '',
        );
        // Pull it out of any open thread (the SMS chat and/or its paired
        // iMessage thread where it was mirrored under the same guid).
        if (Get.isRegistered<MessagesService>(tag: chat.guid)) {
          MessagesSvc(chat.guid).removeMessage(msg);
        }
        if (paired != null && Get.isRegistered<MessagesService>(tag: paired.guid)) {
          MessagesSvc(paired.guid).removeMessage(msg);
        }
        removedAny = true;
      }
      if (removedAny) {
        // If the thread is now empty, drop the local SMS chat too.
        final remaining = Chat.getMessages(chat, limit: 1);
        if (remaining.isEmpty) {
          try {
            await ChatsSvc.deleteChat(chat);
          } catch (_) {}
        } else {
          ChatsSvc.updateChat(chat);
        }
      }
    }
  }

  /// Apply the server's per-conversation unread snapshot to our local SMS chats
  /// so read-state set on another device shows here. Sets the local flag only —
  /// never marks on the BlueBubbles server (these are our own SMS;-;tn: chats),
  /// and does not re-push (avoids a read-state loop).
  Future<void> _applyServerReadState(List<dynamic> conversations) async {
    if (conversations.isEmpty) return;
    final Map<String, bool> unreadByConv = {};
    for (final c in conversations) {
      final m = (c as Map).cast<String, dynamic>();
      final id = m['id'] as String?;
      if (id == null) continue;
      unreadByConv[id] = ((m['unread'] as num?)?.toInt() ?? 0) != 0;
    }
    if (unreadByConv.isEmpty) return;
    for (final chat in ChatsSvc.allChats.where((c) => c.guid.startsWith('SMS;-;tn:')).toList()) {
      final unread = unreadByConv[serverConvId(chat.chatIdentifier ?? '')];
      if (unread == null) continue;
      await _setChatUnreadLocal(chat, unread);
      // For a merged contact the visible row is the iMessage chat, not the
      // hidden SMS chat — reflect the read-state there too so it actually shows.
      final bb = ChatMerge.bbChatForNumber(canonAddress(chat.chatIdentifier ?? ''));
      if (bb != null) await _setChatUnreadLocal(bb, unread);
    }
  }

  Map<String, dynamic> _toServerMsg(Map<String, dynamic> map) => {
        'direction': ((map['isFromMe'] as bool?) ?? false) ? 'out' : 'in',
        'address': canonAddress((map['address'] as String?) ?? ''),
        'body': (map['body'] as String?) ?? '',
        'ts': (map['date'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        'type': 'sms',
        if (map['providerId'] != null) 'providerId': map['providerId'].toString(),
      };

  // ---- content-based dedup GUID ----

  static String smsGuid({
    required bool isFromMe,
    required String address,
    required String body,
    required int dateMs,
  }) {
    final addr = canonAddress(address);
    final dir = isFromMe ? 'out' : 'in';
    final key = isFromMe ? '$addr|$body|${dateMs ~/ 120000}' : '$addr|$body|$dateMs';
    return 'sms-$dir-${_fnv1a(key)}';
  }

  /// Server-side conversation key for [address] — mirrors the Node server's
  /// `normalizeAddress`. Alphanumeric sender IDs (OTP/banks like "Google") are
  /// kept verbatim so they don't all collapse to an empty id; otherwise it's a
  /// leading `+` (if present) plus digits only. Used to address /read and
  /// whole-thread /delete calls.
  static String serverConvId(String address) {
    final canon = canonAddress(address);
    if (RegExp(r'[A-Za-z]').hasMatch(canon)) return canon;
    final plus = canon.startsWith('+') ? '+' : '';
    return plus + canon.replaceAll(RegExp(r'[^0-9]'), '');
  }

  /// Server-side content hash for a single SMS — mirrors the Node server's
  /// `contentHash` (sha256 over normalized address, type, direction, trimmed
  /// body and a 10s time bucket). Lets us delete one message by content identity
  /// without knowing the server's generated message id.
  /// Server content hash for [message] addressed by [number]. For an MMS it
  /// reads the attachment bytes and folds in their sha256s (matching how the
  /// server built the identity), so a delete actually matches. Must be called
  /// BEFORE the message/attachments are removed from disk.
  static Future<String> deleteContentHashFor(Message message, String number) async {
    final dateMs = message.dateCreated?.millisecondsSinceEpoch ?? 0;
    final body = message.text ?? '';
    final atts = message.dbAttachments;
    if (atts.isEmpty) {
      return serverContentHash(isFromMe: message.isFromMe ?? false, address: number, body: body, dateMs: dateMs);
    }
    final List<String> shas = [];
    for (final a in atts) {
      try {
        final bytes = await dartio.File(a.path).readAsBytes();
        shas.add(sha256.convert(bytes).toString());
      } catch (_) {}
    }
    return serverContentHash(
      isFromMe: message.isFromMe ?? false, address: number, body: body, dateMs: dateMs,
      type: 'mms', attachmentSha256: shas);
  }

  static String serverContentHash({
    required bool isFromMe,
    required String address,
    required String body,
    required int dateMs,
    String type = 'sms',
    List<String> attachmentSha256 = const [],
  }) {
    final bucket = (dateMs / 10000).round();
    final parts = <String>[
      serverConvId(address),
      type,
      isFromMe ? 'out' : 'in',
      body.trim(),
      bucket.toString(),
    ];
    // MMS: the server folds the sorted media content hashes into the identity,
    // so a delete must too or it won't match (matches Server util.contentHash).
    if (attachmentSha256.isNotEmpty) {
      final sorted = [...attachmentSha256]..sort();
      parts.add(sorted.join(','));
    }
    return sha256.convert(utf8.encode(parts.join('|'))).toString();
  }

  /// Canonicalize a phone number to E.164 (`+CC…`) so every format of the same
  /// number maps to one chat. Non-phone senders (short codes, alphanumeric
  /// sender IDs, emails) are returned unchanged.
  static String canonAddress(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return s;
    if (s.contains('@')) return s; // email
    if (RegExp(r'[A-Za-z]').hasMatch(s)) return s; // alphanumeric sender ID
    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 6) return s; // short code — keep distinct
    final util = PhoneNumberUtil.instance;
    final cc = Get.deviceLocale?.countryCode ?? 'US';
    // 1) parse as national for the device region; 2) parse as already-international.
    for (final cand in <String>[s, '+$digits']) {
      try {
        final parsed = util.parse(cand, cand.startsWith('+') ? null : cc);
        if (util.isValidNumber(parsed)) return util.format(parsed, PhoneNumberFormat.e164);
      } catch (_) {}
    }
    return s;
  }

  /// Delete existing (mixed-format) SMS chats and reset import cursors so they
  /// re-import with canonical E.164 addresses (duplicates for one contact
  /// collapse into a single thread).
  /// Insert an MMS (from the provider) into the BlueBubbles store with its media
  /// materialised on disk as already-downloaded attachments, so the thread shows
  /// the image/video/etc. Mirrors [_insert] but carries attachments.
  Future<void> _insertMms(Map<String, dynamic> map, {bool live = false}) async {
    await Database.waitForInit();
    if (!GetIt.I.isRegistered<IncomingMessageHandler>()) return;

    final String address = canonAddress(((map['address'] as String?) ?? '').trim());
    if (address.isEmpty) return;
    final String body = (map['body'] as String?) ?? '';
    final int dateMs = (map['date'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final bool isFromMe = (map['isFromMe'] as bool?) ?? false;
    final handle = Handle(address: address, service: 'SMS');
    final chat = Chat(guid: 'SMS;-;tn:$address', chatIdentifier: address, participants: [handle]);

    final List<dynamic> parts = (map['parts'] as List?) ?? const [];
    final List<Attachment> attachments = [];
    for (final p in parts) {
      final part = (p as Map).cast<String, dynamic>();
      final int partId = (part['partId'] as num?)?.toInt() ?? -1;
      final String mime = (part['contentType'] as String?) ?? 'application/octet-stream';
      if (partId < 0) continue;
      final bytes = await MethodChannelSvc.invokeMethod('mms-part-bytes', {'partId': partId});
      if (bytes is! Uint8List || bytes.isEmpty) continue;
      final String name = ((part['name'] as String?)?.trim().isNotEmpty ?? false)
          ? (part['name'] as String)
          : 'mms_$partId';
      final att = Attachment(
        guid: 'tn-mms-${_fnv1a("$address|$dateMs|$partId")}',
        mimeType: mime,
        transferName: name,
        totalBytes: bytes.length,
        isOutgoing: isFromMe,
        isDownloaded: true,
      );
      try {
        final dir = dartio.Directory(att.directory);
        if (!dir.existsSync()) dir.createSync(recursive: true);
        dartio.File(att.path).writeAsBytesSync(bytes);
        attachments.add(att);
      } catch (e) {
        Logger.warn('SmsService: failed writing MMS part $partId to disk: $e');
      }
    }

    final message = Message(
      guid: smsGuid(isFromMe: isFromMe, address: address, body: body, dateMs: dateMs),
      text: body,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(dateMs),
      isFromMe: isFromMe,
      handle: isFromMe ? null : handle,
      hasAttachments: attachments.isNotEmpty,
    );

    await IncomingMsgHandler.handle(IncomingPayload(
      type: MessageEventType.newMessage,
      source: MessageSource.methodChannel,
      chat: chat,
      message: message,
      attachments: attachments,
    ));

    final hydrated = Message.findOne(guid: message.guid) ?? message;
    ChatMerge.reflectSmsIntoPairedChat(address, hydrated, markUnread: live && !isFromMe);
  }

  Future<void> _purgeSmsChats() async {
    try {
      // ONLY our own namespace — never BlueBubbles' server SMS/iMessage chats.
      final smsChats = ChatsSvc.allChats.where((c) => c.guid.startsWith('SMS;-;tn:')).toList();
      for (final c in smsChats) {
        try {
          await ChatsSvc.deleteChat(c);
        } catch (_) {}
      }
      await _resetSyncCursors();
      Logger.info('SmsService: purged ${smsChats.length} local SMS chats for rebuild');
    } catch (e, s) {
      Logger.error('SmsService purge failed: $e', trace: s);
    }
  }

  /// Recovery: remove any of our injected `sms-` messages that leaked into
  /// BlueBubbles' server chats (from the earlier namespace collision), without
  /// deleting any chats. They re-import cleanly into the `SMS;-;tn:` namespace.
  Future<void> _purgeInjectedSmsMessages() async {
    try {
      final q = Database.messages.query(Message_.guid.startsWith('sms-')).build();
      final ids = q.findIds();
      q.close();
      if (ids.isNotEmpty) Database.messages.removeMany(ids);
      Logger.info('SmsService: purged ${ids.length} injected SMS messages');
    } catch (e, s) {
      Logger.error('SmsService injected-message purge failed: $e', trace: s);
    }
    await _resetSyncCursors();
  }

  Future<void> _resetSyncCursors() async {
    final prefs = await _sp;
    await prefs.setInt(_kLastSync, 0);
    await prefs.setBool(_kBackfillDone, false);
    await prefs.setInt(_kPullCursor, 0);
    await prefs.setInt(_kMmsLastSync, 0);
    await prefs.setInt(_kMmsPushCursor, 0);
  }

  /// Manual "Rebuild SMS chats" action (settings panel): purge + full re-sync.
  Future<void> rebuildSmsChats() async {
    await _purgeSmsChats();
    await syncNow();
  }

  static String _fnv1a(String s) {
    int hash = 0x811c9dc5;
    for (final c in s.codeUnits) {
      hash ^= c;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  // ---- core: SMS map -> BlueBubbles pipeline ----

  Future<void> _insert(Map<String, dynamic> map, {bool live = false}) async {
    await Database.waitForInit();
    if (!GetIt.I.isRegistered<IncomingMessageHandler>()) return;

    final String address = canonAddress(((map['address'] as String?) ?? '').trim());
    if (address.isEmpty) return;
    final String body = (map['body'] as String?) ?? '';
    final int dateMs = (map['date'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final bool isFromMe = (map['isFromMe'] as bool?) ?? false;

    final handle = Handle(address: address, service: 'SMS');
    // Our Android SMS live in their OWN namespace ("SMS;-;tn:<number>") so they
    // never collide with BlueBubbles' server iMessage/Text-Forwarding chats
    // (which would break those chats' pagination). Still SMS-service => green.
    final chat = Chat(guid: 'SMS;-;tn:$address', chatIdentifier: address, participants: [handle]);
    final message = Message(
      guid: smsGuid(isFromMe: isFromMe, address: address, body: body, dateMs: dateMs),
      text: body,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(dateMs),
      isFromMe: isFromMe,
      handle: isFromMe ? null : handle,
      hasAttachments: false,
    );

    await IncomingMsgHandler.handle(IncomingPayload(
      type: MessageEventType.newMessage,
      source: MessageSource.methodChannel,
      chat: chat,
      message: message,
    ));

    // Reflect into the contact's paired iMessage chat (if any) so the merged UI
    // updates: live-insert into an open thread, refresh the list preview + sort,
    // and mark unread for a live incoming SMS.
    final hydrated = Message.findOne(guid: message.guid) ?? message;
    ChatMerge.reflectSmsIntoPairedChat(address, hydrated, markUnread: live && !isFromMe);
  }
}
