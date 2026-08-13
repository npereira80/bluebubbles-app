import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/sms/imessage_mode.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// TN Messages fork — the switch between "SMS + iMessage" and "SMS only".
class IMessagePanel extends StatefulWidget {
  const IMessagePanel({super.key});

  @override
  State<IMessagePanel> createState() => _IMessagePanelState();
}

class _IMessagePanelState extends State<IMessagePanel> with ThemeHelpers {
  bool _applying = false;

  Future<void> _toggle(bool value) async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      // Closing the socket, reloading the list and (on re-enable) kicking off a
      // catch-up sync all take a moment. Block the UI rather than letting the
      // user watch chats appear and disappear underneath them.
      await IMessageMode.set(value);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasServer = SettingsSvc.settings.serverAddress.value.isNotEmpty;

    return Stack(
      children: [
        SettingsScaffold(
          title: "iMessage",
          initialHeader: "iMessage Support",
          iosSubtitle: iosSubtitle,
          materialSubtitle: materialSubtitle,
          tileColor: tileColor,
          headerColor: headerColor,
          bodySlivers: [
            SliverList(
              delegate: SliverChildListDelegate([
                SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    Obx(() => SettingsSwitch(
                          initialVal: SettingsSvc.settings.iMessageEnabled.value,
                          onChanged: _toggle,
                          title: "Enable iMessage",
                          subtitle: SettingsSvc.settings.iMessageEnabled.value
                              ? "Your iMessage conversations sync from the Bubbles server."
                              : "SMS only. Your messages, chats and sync position are kept, "
                                  "so turning this back on picks up where you left off.",
                          isThreeLine: true,
                          backgroundColor: tileColor,
                          leading: SettingsLeadingIcon(
                            iosIcon: CupertinoIcons.chat_bubble_2_fill,
                            materialIcon: Icons.forum_outlined,
                            containerColor: SettingsSvc.settings.iMessageEnabled.value ? Colors.blue : Colors.grey,
                          ),
                        )),
                  ],
                ),
                SettingsHeader(
                  iosSubtitle: iosSubtitle,
                  materialSubtitle: materialSubtitle,
                  text: "What changes",
                ),
                SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                      child: Text(
                        "With iMessage off, Bubbles is a plain Android SMS client. "
                        "iMessage conversations are hidden, contacts you reach both ways show "
                        "only their SMS thread, and nothing connects to the Bubbles server, "
                        "so no iMessage errors or offline warnings appear.\n\n"
                        "Nothing is deleted. Everything comes back exactly as it was.",
                        style: context.theme.textTheme.bodyMedium
                            ?.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                if (!hasServer)
                  SettingsSection(
                    backgroundColor: tileColor,
                    children: [
                      SettingsTile(
                        backgroundColor: tileColor,
                        title: "No server configured",
                        subtitle: "Add your Bubbles server in Settings ▸ Connection to use iMessage.",
                        isThreeLine: true,
                        leading: const SettingsLeadingIcon(
                          iosIcon: CupertinoIcons.info,
                          materialIcon: Icons.info_outline,
                          containerColor: Colors.orange,
                        ),
                      ),
                    ],
                  ),
              ]),
            ),
          ],
        ),
        if (_applying)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: context.theme.colorScheme.surface.withValues(alpha: 0.7),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      buildProgressIndicator(context),
                      const SizedBox(height: 14),
                      Text(
                        SettingsSvc.settings.iMessageEnabled.value ? "Turning iMessage on…" : "Turning iMessage off…",
                        style: context.theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
