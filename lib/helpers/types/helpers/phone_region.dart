import 'package:get/get.dart';

/// The region national phone numbers are parsed against.
///
/// Everything that turns a typed-in number into E.164 needs a region: "916309004"
/// is only meaningful once you know which country's numbering plan it belongs to.
/// That used to be read from `Get.deviceLocale`, which is the wrong source and
/// fails silently in the common case — a Portuguese SIM in a phone set to English
/// reports "en_US", so the number parses as country code 1 and becomes
/// +1916309004, which will never connect.
///
/// The SIM knows whose line it is, so [set] is called with its ISO country as
/// soon as [SmsService] reads it, and everything else asks [current].
class PhoneRegion {
  PhoneRegion._();

  static String? _fromSim;

  /// Called by [SmsService] whenever it refreshes SIM info.
  static void set(String? isoCountryCode) {
    final trimmed = isoCountryCode?.trim();
    if (trimmed == null || trimmed.length != 2) return;
    _fromSim = trimmed.toUpperCase();
  }

  /// SIM country, else the device locale's, else US.
  ///
  /// The locale fallback is for a phone with no SIM at all (a tablet, or the
  /// second device that relays sends) where nothing better is available. 'US' is
  /// last because it has to be something, not because it's a good guess.
  static String get current => _fromSim ?? Get.deviceLocale?.countryCode ?? 'US';

  /// Whether the region came from the SIM rather than a fallback. Callers that
  /// would rather leave a number as typed than reformat it wrongly can check
  /// this — see `formatPhoneNumber`.
  static bool get isFromSim => _fromSim != null;
}
