import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/sms/sms_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// TN Messages fork — control panel for the local Android SMS engine + our
/// self-hosted backup server. Reached from Settings → "SMS Agent".
class SmsAgentPanel extends StatefulWidget {
  const SmsAgentPanel({super.key});

  @override
  State<SmsAgentPanel> createState() => _SmsAgentPanelState();
}

class _SmsAgentPanelState extends State<SmsAgentPanel> with ThemeHelpers {
  late final TextEditingController _url = TextEditingController(text: SmsSvc.serverUrl);
  late final TextEditingController _secret = TextEditingController(text: SmsSvc.serverSecret);

  @override
  void initState() {
    super.initState();
    SmsSvc.refreshStatus();
  }

  @override
  void dispose() {
    _url.dispose();
    _secret.dispose();
    super.dispose();
  }

  static const Widget _spinner =
      SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));

  String _syncLabel(SmsSyncState s) {
    switch (s) {
      case SmsSyncState.syncing:
        return "Syncing…";
      case SmsSyncState.synced:
        return "Synced";
      case SmsSyncState.failed:
        return "Sync failed";
      case SmsSyncState.idle:
        return "Idle";
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: "SMS Agent",
      initialHeader: "Status",
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      tileColor: tileColor,
      headerColor: headerColor,
      bodySlivers: [
        SliverList(
          delegate: SliverChildListDelegate(<Widget>[
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Obx(() => SettingsTile(
                      backgroundColor: tileColor,
                      title: "Default SMS app",
                      subtitle: SmsSvc.isDefaultSmsApp.value
                          ? "Yes — Android SMS is handled here"
                          : "No — tap to set BlueBubbles as your SMS app",
                      onTap: () async {
                        await SmsSvc.requestDefault();
                        await Future.delayed(const Duration(seconds: 1));
                        await SmsSvc.refreshStatus();
                      },
                      leading: SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.chat_bubble_2_fill,
                        materialIcon: Icons.sms_outlined,
                        containerColor: SmsSvc.isDefaultSmsApp.value ? Colors.green : Colors.grey,
                      ),
                    )),
                const SettingsDivider(),
                Obx(() => SettingsTile(
                      backgroundColor: tileColor,
                      title: "SIM number",
                      subtitle: SmsSvc.simNumber.value ??
                          (SmsSvc.simKey.value != null
                              ? "No number from SIM • ID ${SmsSvc.simKey.value}"
                              : "Unknown (no SIM / not readable)"),
                      leading: const SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.antenna_radiowaves_left_right,
                        materialIcon: Icons.sim_card_outlined,
                        containerColor: Colors.teal,
                      ),
                    )),
                const SettingsDivider(),
                Obx(() {
                  final syncing = SmsSvc.syncState.value == SmsSyncState.syncing;
                  return SettingsTile(
                    backgroundColor: tileColor,
                    title: "Backup server",
                    subtitle: SmsSvc.serverRegistered.value
                        ? "Registered • ${_syncLabel(SmsSvc.syncState.value)}"
                        : (SmsSvc.serverConfigured ? "Connecting…" : "Not configured"),
                    trailing: syncing ? _spinner : null,
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.cloud,
                      materialIcon: Icons.cloud_outlined,
                      containerColor: SmsSvc.serverRegistered.value ? Colors.blue : Colors.grey,
                    ),
                  );
                }),
              ],
            ),
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Backup Server"),
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: "Server URL", border: OutlineInputBorder()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: TextField(
                    controller: _secret,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: "Registration secret", border: OutlineInputBorder()),
                  ),
                ),
                SettingsTile(
                  backgroundColor: tileColor,
                  title: "Save & connect",
                  subtitle: "Register this device with your SMS server",
                  onTap: () async {
                    await SmsSvc.setServerConfig(_url.text, _secret.text);
                    if (mounted) setState(() {});
                  },
                  leading: const SettingsLeadingIcon(
                    iosIcon: CupertinoIcons.cloud_upload,
                    materialIcon: Icons.cloud_sync_outlined,
                    containerColor: Colors.blue,
                  ),
                ),
              ],
            ),
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Actions"),
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Obx(() {
                  final syncing = SmsSvc.syncState.value == SmsSyncState.syncing;
                  return SettingsTile(
                    backgroundColor: tileColor,
                    title: "Sync now",
                    subtitle: syncing
                        ? "Syncing…"
                        : "${_syncLabel(SmsSvc.syncState.value)} • backfill + push/pull server",
                    onTap: syncing ? null : () => SmsSvc.syncNow(),
                    trailing: syncing ? _spinner : null,
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.arrow_2_circlepath,
                      materialIcon: Icons.sync,
                      containerColor: Colors.orange,
                    ),
                  );
                }),
                const SettingsDivider(),
                Obx(() {
                  final syncing = SmsSvc.syncState.value == SmsSyncState.syncing;
                  return SettingsTile(
                    backgroundColor: tileColor,
                    title: "Full re-sync from server",
                    subtitle: syncing
                        ? "Syncing…"
                        : "Pull ALL messages from the server again and merge with local",
                    onTap: syncing ? null : () => SmsSvc.fullResyncFromServer(),
                    trailing: syncing ? _spinner : null,
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.cloud_download,
                      materialIcon: Icons.cloud_download_outlined,
                      containerColor: Colors.indigo,
                    ),
                  );
                }),
                const SettingsDivider(),
                SettingsTile(
                  backgroundColor: tileColor,
                  title: "Rebuild SMS chats",
                  subtitle: "Fix duplicate threads (re-import with normalized numbers)",
                  onTap: () => SmsSvc.rebuildSmsChats(),
                  leading: const SettingsLeadingIcon(
                    iosIcon: CupertinoIcons.arrow_3_trianglepath,
                    materialIcon: Icons.merge_type,
                    containerColor: Colors.purple,
                  ),
                ),
              ],
            ),
          ]),
        ),
      ],
    );
  }
}
