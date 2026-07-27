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

  /// Delta since a cursor (ms). Returns {messages, conversations, cursor}.
  Future<Map<String, dynamic>> delta(int since) async {
    final res = await _dio.get('/delta',
        queryParameters: {'since': since}, options: _authed);
    return (res.data as Map).cast<String, dynamic>();
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
}
