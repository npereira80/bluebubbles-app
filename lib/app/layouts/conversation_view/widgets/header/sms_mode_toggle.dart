import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/sms/sms_send_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// TN fork — compact segmented control in the conversation header that toggles
/// whether outgoing messages go over iMessage (blue) or SMS (green). Only shown
/// for 1:1 chats that have a real phone number (so an SMS can be delivered).
class SmsModeToggle extends StatelessWidget {
  const SmsModeToggle({super.key, required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context) {
    if (!SmsSendMode.canToggle(chat)) return const SizedBox.shrink();

    final blue = context.theme.colorScheme.primary;
    final green = context.theme.colorScheme.bubble(context, false);

    return Obx(() {
      // Watch the reactive set so the pill flips instantly on toggle.
      final sms = SmsSendMode.reactive[chat.guid] ?? false;
      final active = sms ? green : blue;

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          SmsSendMode.toggle(chat.guid);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: active.withValues(alpha: 0.6), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: active, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                sms ? "SMS" : "iMessage",
                style: context.theme.textTheme.labelMedium!.copyWith(
                  color: active,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
