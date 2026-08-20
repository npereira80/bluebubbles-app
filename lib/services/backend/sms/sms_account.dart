import 'dart:async';

import 'package:bluebubbles/services/backend/sms/sms_server_client.dart';
import 'package:bluebubbles/services/backend/sms/sms_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TN fork — which family member this install belongs to.
///
/// The sync server keeps a separate database per person, so every request has to
/// carry a token that says who is asking. One account per install: SMS belongs
/// to the SIM in the phone and the default-SMS-app role is device-wide, so a
/// second account on the same phone would have no messages of its own.
class SmsAccount {
  static const String _kEmail = 'tn_sms_account_email';
  static const String _kToken = 'tn_sms_account_token';
  static const String _kUserId = 'tn_sms_account_user';

  /// Signed-in address, or null. Reactive so settings can show it live.
  static final RxnString email = RxnString();
  static final RxnString userId = RxnString();
  static String? _token;

  static String? get token => _token;
  static bool get signedIn => (_token ?? '').isNotEmpty;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    email.value = prefs.getString(_kEmail);
    userId.value = prefs.getString(_kUserId);
    _token = prefs.getString(_kToken);
  }

  static Future<void> _save({required String email_, required String token_, required String userId_}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEmail, email_);
    await prefs.setString(_kToken, token_);
    await prefs.setString(_kUserId, userId_);
    email.value = email_;
    userId.value = userId_;
    _token = token_;
  }

  static Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kEmail);
    await prefs.remove(_kToken);
    await prefs.remove(_kUserId);
    email.value = null;
    userId.value = null;
    _token = null;
  }

  /// How long to wait for our own SMS to come back before giving up. A local
  /// message is usually a few seconds; the carrier occasionally takes longer.
  static const Duration _codeTimeout = Duration(seconds: 90);

  static Completer<String>? _incoming;

  /// Called by [SmsService] for every received SMS while a sign-in is waiting.
  /// Returns true when the message was the verification code, so the caller can
  /// keep it out of the inbox — nobody wants "your code is 123456" from
  /// themselves sitting in their own thread.
  static bool offerIncoming(String body) {
    final waiting = _incoming;
    if (waiting == null || waiting.isCompleted) return false;
    final match = RegExp(r'\b(\d{6})\b').firstMatch(body);
    if (match == null) return false;
    waiting.complete(match.group(1)!);
    return true;
  }

  /// Sign in as [email], proving the SIM by texting this phone's own number.
  ///
  /// Returns null on success, or a short reason to show the user.
  static Future<String?> signIn({
    required String email_,
    required String serverUrl,
    required String secret,
  }) async {
    final phone = SmsSvc.effectiveSimNumber;
    if (phone == null || phone.trim().isEmpty) {
      return "Couldn't read this phone's number from the SIM. Some carriers "
          "don't store it — tap \"SIM number\" above and enter it.";
    }
    if (!SmsSvc.canSendSms.value) {
      return "No cellular service, so the verification text can't be sent yet.";
    }

    final client = SmsServerClient(baseUrl: serverUrl, secret: secret);
    try {
      final challenge = await client.startSignIn(email: email_, phone: phone);
      if (challenge == null) return "The server refused the sign-in request.";

      // Listen before sending, so a fast delivery can't arrive first.
      final waiter = _incoming = Completer<String>();
      await SmsSvc.nativeSend(phone, 'Bubbles verification code: ${challenge.code}', 'tn-signin');

      final String received;
      try {
        received = await waiter.future.timeout(_codeTimeout);
      } on TimeoutException {
        return "The verification text didn't arrive. Check that Bubbles is your "
            "default SMS app and that the SIM can send messages.";
      } finally {
        _incoming = null;
      }

      final result = await client.verifySignIn(
        challengeId: challenge.challengeId,
        code: received,
        label: 'Android',
      );
      if (result == null) return "The code didn't match. Try again.";

      await _save(email_: result.email.isEmpty ? email_ : result.email, token_: result.token, userId_: result.userId);
      Logger.info('SmsAccount: signed in as ${email.value}');
      return null;
    } catch (e, s) {
      Logger.error('SmsAccount: sign-in failed: $e', trace: s);
      return "Couldn't reach the server. Check the address in Settings ▸ SMS Agent.";
    } finally {
      _incoming = null;
    }
  }
}
