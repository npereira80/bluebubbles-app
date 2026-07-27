import 'dart:async';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/incoming_message_handler.dart';
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
  static const String _kPullCursor = 'tn_sms_pull_cursor';        // pull cursor (server delta)
  static const String _kCanonMigration = 'tn_sms_canon_v1';       // one-time E.164 rebuild
  static const String _kNsMigration = 'tn_sms_ns_v1';             // one-time namespace isolation

  // Baked defaults (personal build). Overridable in Settings → SMS Agent.
  static const String _bakedUrl = 'https://sms.tn-services.net';
  static const String _bakedSecret = '8c2f2eb8802ffbe58662f75590bbfd282733f767df704443';

  static const Duration _syncInterval = Duration(seconds: 60);

  /// Observable state for the SMS Agent settings panel.
  final RxBool isDefaultSmsApp = false.obs;
  final RxBool serverRegistered = false.obs;
  final RxnString simKey = RxnString();
  final RxnString simNumber = RxnString();
  final Rx<SmsSyncState> syncState = SmsSyncState.idle.obs;

  String serverUrl = _bakedUrl;
  String serverSecret = _bakedSecret;
  bool get serverConfigured => serverUrl.isNotEmpty && serverSecret.isNotEmpty;

  SmsServerClient? _server;
  SharedPreferences? _prefs;
  Future<SharedPreferences> get _sp async => _prefs ??= await SharedPreferences.getInstance();

  Timer? _timer;
  bool _pushing = false;
  bool _pulling = false;

  // ---- lifecycle ----

  Future<void> init() async {
    if (kIsWeb || kIsDesktop) return;
    try {
      await _loadConfig();
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
        await _heartbeat();
        await pullFromServer();
        await syncToServer();
        _startTimer();
      }
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
      await _heartbeat();
      await syncToServer();
      await pullFromServer();
    });
  }

  Future<void> setServerConfig(String url, String secret) async {
    serverUrl = url.trim();
    serverSecret = secret.trim();
    final prefs = await _sp;
    await prefs.setString(_kServerUrl, serverUrl);
    await prefs.setString(_kServerSecret, serverSecret);
    await prefs.remove(_kServerToken);
    _server = null;
    serverRegistered.value = false;
    if (serverConfigured) await syncNow();
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

  Future<void> refreshStatus() async {
    try {
      isDefaultSmsApp.value = (await MethodChannelSvc.invokeMethod('sms-is-default')) == true;
      final sim = ((await MethodChannelSvc.invokeMethod('sms-sim-info')) as Map?)?.cast<String, dynamic>() ?? {};
      simKey.value = sim['simKey'] as String?;
      simNumber.value = sim['number'] as String?;
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
      if (serverConfigured) {
        await _ensureServer();
        await _heartbeat();
        final pushed = await syncToServer();
        final pulled = await pullFromServer();
        ok = pushed && pulled;
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

  // ---- native -> dart (from method channel) ----

  Future<void> onSmsReceived(Map<String, dynamic> map) async {
    await _insert(map);
    unawaited(syncToServer());
  }

  Future<void> onSentStatus(Map<String, dynamic> map) async {
    Logger.debug('SmsService: sent-status ${map['messageId']} = ${map['status']}');
  }

  // ---- outbound (called by OutgoingMessageHandler for SMS chats) ----

  Future<void> nativeSend(String address, String body, String messageId) async {
    await MethodChannelSvc.invokeMethod('sms-send', {'address': address, 'body': body, 'messageId': messageId});
  }

  Future<void> recordOutgoing(String address, String body, int ts) async {
    unawaited(Future.delayed(const Duration(seconds: 4), syncToServer));
  }

  // ---- server sync ----

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
      await _server!.heartbeat((sim['present'] as bool?) ?? false, sim['simKey'] as String?);
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
        batch.add(_toServerMsg(map));
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

  Future<void> _insert(Map<String, dynamic> map) async {
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
  }
}
