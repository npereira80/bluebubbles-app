import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// TN fork — shown when the user skips the Bubbles server during setup.
///
/// Without a server there's no iMessage, so the one thing that still has to
/// happen is Android handing us SMS: the app needs to be the default SMS app or
/// it can't receive anything at all. Asking here, rather than letting them
/// discover an empty inbox later, is the whole point of the dialog.
class SmsOnlyDialog extends StatefulWidget {
  const SmsOnlyDialog({super.key});

  @override
  State<SmsOnlyDialog> createState() => _SmsOnlyDialogState();
}

class _SmsOnlyDialogState extends State<SmsOnlyDialog> {
  bool _working = false;

  Future<void> _finish() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await setup.finishSetupWithoutServer();
    } catch (e, s) {
      Logger.error('Failed to finish SMS-only setup: $e', trace: s);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    Get.offAll(
      () => ConversationList(showArchivedChats: false, showUnknownSenders: false),
      routeName: "",
      duration: Duration.zero,
      transition: Transition.noTransition,
    );
    // Registered as permanent, so it survives offAll unless forced out.
    Get.delete<SetupViewController>(force: true);
  }

  Future<void> _setDefaultThenFinish() async {
    try {
      await SmsSvc.requestDefault();
      // The system dialog runs in its own activity; give it a beat to settle
      // before we read the result back.
      await Future.delayed(const Duration(seconds: 1));
      await SmsSvc.refreshStatus();
    } catch (e, s) {
      Logger.error('Default SMS app request failed: $e', trace: s);
    }
    await _finish();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      title: Text("Use Bubbles for SMS only", style: context.theme.textTheme.titleLarge),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Without a Bubbles server there's no iMessage, so Bubbles will work as "
            "your SMS app using the SIM in this phone.\n\n"
            "For that, Android needs to make Bubbles your default SMS app. "
            "You can connect a server later in Settings.",
            style: context.theme.textTheme.bodyLarge,
          ),
          if (_working) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: Text("Go back", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
        ),
        TextButton(
          onPressed: _working ? null : _finish,
          child: Text("Not now",
              style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.outline)),
        ),
        TextButton(
          onPressed: _working ? null : _setDefaultThenFinish,
          child: Text("Set as default",
              style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
        ),
      ],
    );
  }
}
