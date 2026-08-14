import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/backend/sms/sms_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// TN fork — shown when the user skips the Bubbles server during setup.
///
/// Without a server there's no iMessage, so the one thing that still has to
/// happen is Android handing us SMS. Being the default SMS app isn't optional
/// here: without the role the app can't receive anything, can't read the
/// messages already on the phone, and can't write restored history back into the
/// system store. So setup doesn't finish until the role is held.
class SmsOnlyDialog extends StatefulWidget {
  const SmsOnlyDialog({super.key});

  @override
  State<SmsOnlyDialog> createState() => _SmsOnlyDialogState();
}

class _SmsOnlyDialogState extends State<SmsOnlyDialog> with WidgetsBindingObserver {
  bool _working = false;
  bool _askedOnce = false;
  bool _isDefault = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The role is granted in a system activity, so the answer only arrives when
    // we come back. Polling on a timer would be guessing at how long they take.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      await SmsSvc.refreshStatus();
    } catch (_) {}
    if (mounted) setState(() => _isDefault = SmsSvc.isDefaultSmsApp.value);
  }

  Future<void> _requestRole() async {
    setState(() => _askedOnce = true);
    try {
      await SmsSvc.requestDefault();
    } catch (e, s) {
      Logger.error('Default SMS app request failed: $e', trace: s);
    }
    // didChangeAppLifecycleState picks up the result on return.
  }

  Future<void> _finish() async {
    if (_working || !_isDefault) return;
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
            _isDefault
                ? "Bubbles is your default SMS app. Your messages will be imported "
                    "next, along with anything backed up to your SMS server.\n\n"
                    "You can connect a Bubbles server later in Settings to add iMessage."
                : "Without a Bubbles server there's no iMessage, so Bubbles will work as "
                    "your SMS app using the SIM in this phone.\n\n"
                    "For that, Android has to make Bubbles your default SMS app. Without it "
                    "Bubbles can't receive messages or read the ones already on this phone.",
            style: context.theme.textTheme.bodyLarge,
          ),
          if (_askedOnce && !_isDefault) ...[
            const SizedBox(height: 14),
            Text(
              "Bubbles still isn't the default SMS app. Tap 'Set as default' and choose "
              "Bubbles in the Android dialog.",
              style: context.theme.textTheme.bodyMedium?.copyWith(color: context.theme.colorScheme.error),
            ),
          ],
          if (_working) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            Center(child: Text("Importing your messages…", style: context.theme.textTheme.bodyMedium)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: Text("Go back",
              style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.outline)),
        ),
        if (!_isDefault)
          TextButton(
            onPressed: _working ? null : _requestRole,
            child: Text("Set as default",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
          ),
        if (_isDefault)
          TextButton(
            onPressed: _working ? null : _finish,
            child: Text("Continue",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
          ),
      ],
    );
  }
}
