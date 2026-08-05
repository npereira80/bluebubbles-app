import 'dart:typed_data';

import 'package:dio/dio.dart';

/// REST client for the self-hosted SMS Sync server (the Node/TS server from the
/// v3 platform). This is the cross-device backup/source-of-truth for Android
/// SMS — the phone ingests here, and the Mac app reads from the same server.
/// iMessage is never touched by this (that stays on the BlueBubbles server).
class SmsServerClient {
  SmsServerClient({required this.baseUrl, required this.secret, this.token})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 30),
        ));

  final String baseUrl;
  final String secret;
  String? token;
  final Dio _dio;

  Options get _authed => Options(headers: {'Authorization': 'Bearer $token'});

  /// Lightweight reachability check against the server's unauthenticated
  /// `/health` endpoint. Returns true only for a 2xx `{ok:true}` response.
  /// Uses its own short timeouts so a dead host fails fast for the UI.
  Future<bool> ping() async {
    try {
      // Own short-timeout Dio so an unreachable host reports OFFLINE fast,
      // rather than waiting on the shared client's longer connect timeout.
      final pingDio = Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 6),
        sendTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 6),
      ));
      final res = await pingDio.get(
        '/health',
        options: Options(
          // Don't throw on non-2xx — we inspect the code ourselves.
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode == null || res.statusCode! < 200 || res.statusCode! >= 300) {
        return false;
      }
      final data = res.data;
      if (data is Map) return data['ok'] == true;
      return true; // 2xx with a non-JSON body still means the server answered
    } catch (_) {
      return false;
    }
  }

  /// Register this device and capture the bearer token. Returns the token.
  Future<String?> register(String label) async {
    final res = await _dio.post('/devices/register', data: {
      'secret': secret,
      'label': label,
      'platform': 'android',
    });
    token = (res.data as Map)['token'] as String?;
    return token;
  }

  /// Batch upsert messages. Each map: {direction, address, body, ts, type, providerId?}.
  Future<void> ingest(List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty || token == null) return;
    await _dio.post('/ingest', data: {'messages': messages}, options: _authed);
  }

  /// Upload a media blob (MMS attachment). Content-addressed on the server;
  /// returns its sha256, which the caller references from an ingest attachment.
  Future<String?> uploadMedia(Uint8List bytes, String mime) async {
    if (token == null || bytes.isEmpty) return null;
    final res = await _dio.post(
      '/media',
      data: Stream.fromIterable([bytes]),
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': mime,
        Headers.contentLengthHeader: bytes.length,
      }),
    );
    return (res.data as Map?)?['sha256'] as String?;
  }

  /// Download a media blob by its server content hash.
  Future<Uint8List?> downloadMedia(String sha256) async {
    if (token == null) return null;
    final res = await _dio.get<List<int>>(
      '/media/$sha256',
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        responseType: ResponseType.bytes,
      ),
    );
    final data = res.data;
    return data == null ? null : Uint8List.fromList(data);
  }

  /// Delta since a cursor (ms). Returns {messages, conversations, cursor}.
  Future<Map<String, dynamic>> delta(int since) async {
    final res = await _dio.get('/delta',
        queryParameters: {'since': since}, options: _authed);
    return (res.data as Map).cast<String, dynamic>();
  }

  /// Ask the server to send an SMS/MMS via the primary (SIM) device. Used by
  /// non-SIM devices (Mac, second phone) to relay through the primary phone.
  Future<void> send({required String to, String body = '', List<Map<String, dynamic>> attachments = const []}) async {
    if (token == null) return;
    await _dio.post('/send', data: {
      'to': to,
      'body': body,
      if (attachments.isNotEmpty) 'attachments': attachments,
    }, options: _authed);
  }

  /// Report SIM state so the server elects the primary device (SIM-swap).
  Future<Map<String, dynamic>?> heartbeat(bool simPresent, String? simKey) async {
    if (token == null) return null;
    final res = await _dio.post('/devices/heartbeat',
        data: {'simPresent': simPresent, 'simKey': simKey}, options: _authed);
    return (res.data as Map?)?.cast<String, dynamic>();
  }

  /// Report read-state changes (address -> unread) so other devices reflect it.
  Future<void> read(List<Map<String, dynamic>> updates) async {
    if (updates.isEmpty || token == null) return;
    await _dio.post('/read', data: {'updates': updates}, options: _authed);
  }

  /// Delete on the server (propagates to all devices via delta tombstones + WS).
  /// - [messageHashes]: cross-device content identities (used by this fork, which
  ///   doesn't store the server's message ids).
  /// - [conversationId]: normalized-address key to drop a whole thread.
  /// - [messageIds]: server nanoid ids (used by clients that hold them).
  Future<void> delete({
    List<String>? messageHashes,
    List<String>? messageIds,
    String? conversationId,
  }) async {
    if (token == null) return;
    final bool hasHashes = messageHashes != null && messageHashes.isNotEmpty;
    final bool hasIds = messageIds != null && messageIds.isNotEmpty;
    if (!hasHashes && !hasIds && conversationId == null) return;
    await _dio.post('/delete', data: {
      if (hasHashes) 'messageHashes': messageHashes,
      if (hasIds) 'messageIds': messageIds,
      if (conversationId != null) 'conversationId': conversationId,
    }, options: _authed);
  }
}
