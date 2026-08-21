import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:dlibphonenumber/dlibphonenumber.dart';
// Not for `Get.` itself but for the String extensions below (isEmail,
// numericOnly) — removing this import compiles as an unrelated failure.
import 'package:get/get.dart';

String formatPhoneNumber(dynamic item) {
  String cc = PhoneRegion.current;
  String? address;

  // Set the address/country accordingly
  if (item is String?) {
    address = item;
  } else if (item is Handle?) {
    address = item?.address;
    cc = item?.country ?? cc;
  } else {
    return item.toString();
  }

  // If we don't have a valid address, or it's an email, return it
  if (isNullOrEmpty(address) || address!.isEmail || address.contains("urn:biz")) return address ?? "Unknown";
  address = address.trim();

  String? formatted;
  try {
    final parsed = PhoneNumberUtil.instance.parse(address, address.startsWith("+") ? null : cc);
    // Only reformat when the number really is valid for that region. Formatting
    // unconditionally is how a Portuguese "916309004" came out as "+1 916309004":
    // parse() happily attaches the region's country code to digits that could
    // never be a number there, and the display then asserts a number the user
    // never typed. Showing it exactly as entered is always safe.
    if (PhoneNumberUtil.instance.isValidNumber(parsed)) {
      formatted = PhoneNumberUtil.instance.format(parsed, PhoneNumberFormat.international);
    }
  } catch (_) {}

  return formatted ?? address;
}

List<String> getUniqueNumbers(Iterable<String> numbers) {
  List<String> phones = [];
  for (String phone in numbers) {
    bool exists = false;
    for (String current in phones) {
      if (phone.numericOnly() == current.numericOnly()) {
        exists = true;
        break;
      }
    }

    if (!exists) {
      phones.add(phone);
    }
  }

  return phones;
}

List<String> getUniqueEmails(Iterable<String> list) {
  List<String> emails = [];
  for (String email in list) {
    bool exists = false;
    for (String current in emails) {
      if (email.trim() == current.trim()) {
        exists = true;
        break;
      }
    }

    if (!exists) {
      emails.add(email);
    }
  }

  return emails;
}

String getDisplayName(String? displayName, String? firstName, String? lastName) {
  String? _displayName = (displayName?.isEmpty ?? false) ? null : displayName;
  return _displayName ?? [firstName, lastName].where((e) => e?.isNotEmpty ?? false).toList().join(" ");
}
