import 'package:bluebubbles/app/layouts/chat_creator/chat_creator_controller.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_service_type.dart';
// For the ColorScheme bubble()/onBubble() extensions.
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/sms/imessage_mode.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// A CupertinoSegmentedControl that lets the user choose between visible
/// [ChatServiceType] values (e.g. iMessage and SMS). RCS is defined in the
/// enum but hidden until ready.
class ServiceTypePicker extends StatelessWidget {
  const ServiceTypePicker({super.key, required this.controller});

  final ChatCreatorController controller;

  @override
  Widget build(BuildContext context) {
    // TN fork: with no Bubbles server there is only one way to send, so offering
    // a choice would be a choice between working and not working.
    if (!IMessageMode.enabled) return const SizedBox.shrink();

    final visibleTypes = ChatServiceType.values.where((t) => t.isVisible).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Obx(() {
        final selected = controller.selectedService.value;

        // Colour the control by the selected service, using the same blue and
        // green as the message bubbles rather than the theme's primary. Blue
        // means iMessage everywhere else in the app, so a blue "SMS" segment
        // contradicts the bubble the message is about to be sent as.
        final isIMsg = selected == ChatServiceType.iMessage;
        final accent = context.theme.colorScheme.bubble(context, isIMsg);
        final onAccent = context.theme.colorScheme.onBubble(context, isIMsg);

        return CupertinoSegmentedControl<ChatServiceType>(
          groupValue: selected,
          onValueChanged: controller.onServiceChanged,
          borderColor: accent,
          selectedColor: accent,
          unselectedColor: Colors.transparent,
          pressedColor: accent.withValues(alpha: 0.1),
          children: {
            for (final type in visibleTypes)
              type: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                child: Text(
                  type.label,
                  style: context.theme.textTheme.bodyMedium?.copyWith(
                    color: selected == type ? onAccent : accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          },
        );
      }),
    );
  }
}
