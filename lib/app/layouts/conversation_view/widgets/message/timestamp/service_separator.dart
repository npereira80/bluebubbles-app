import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/sms/chat_merge.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Which route a message travelled, for the divider between them.
enum MessageChannel { iMessage, sms }

/// TN fork — the "iMessage" / "SMS" divider iOS shows when a thread switches
/// between the two, so a merged conversation doesn't leave you guessing which
/// route a given message took (and, for replies, which one it will cost you).
///
/// Only appears at the switch. A thread that never changes channel shows nothing.
class ServiceSeparator extends StatelessWidget {
  const ServiceSeparator({super.key, required this.olderMessage});

  final Message? olderMessage;

  /// Anything the BlueBubbles server gave us counts as iMessage, including SMS
  /// forwarded from an iPhone — from here they arrive by the same route and are
  /// sent back the same way.
  ///
  /// SMS means our own: received by this device's radio, or synced from our SMS
  /// server. Those carry an `sms-` GUID or live in the `SMS;-;tn:` namespace.
  static MessageChannel channelOf(Message message) {
    if (message.guid?.startsWith('sms-') ?? false) return MessageChannel.sms;
    final chat = message.chat.target;
    if (chat != null && ChatMerge.isOurSms(chat)) return MessageChannel.sms;
    return MessageChannel.iMessage;
  }

  @override
  Widget build(BuildContext context) {
    final message = MessageStateScope.messageOf(context);
    final older = olderMessage;
    // Nothing to compare against at the top of a loaded page: a label there would
    // be a claim about a change we can't see.
    if (older == null) return const SizedBox.shrink();

    final channel = channelOf(message);
    if (channel == channelOf(older)) return const SizedBox.shrink();

    final hasBackground = ChatStateScope.maybeOf(context)?.customBackgroundPath.value?.isNotEmpty == true;
    final textColor = hasBackground ? context.theme.colorScheme.onSurfaceVariant : context.theme.colorScheme.outline;

    final label = Text(
      channel == MessageChannel.iMessage ? "iMessage" : "SMS",
      style: context.theme.textTheme.labelSmall!.copyWith(color: textColor, fontWeight: FontWeight.w600),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Center(
        child: hasBackground
            ? Container(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
                decoration: BoxDecoration(
                  color: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: label,
              )
            : label,
      ),
    );
  }
}
