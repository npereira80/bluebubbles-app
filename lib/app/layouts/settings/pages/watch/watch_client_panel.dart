import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/watch/watch_client.dart';
import 'package:bluebubbles/services/backend/watch/watch_provisioner.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// TN Messages fork — status panel for the Wear OS companion. Everything here is
/// read live from the watch over Bluetooth, so it only works while the watch is
/// nearby and the watch app is installed.
class WatchClientPanel extends StatefulWidget {
  const WatchClientPanel({super.key});

  @override
  State<WatchClientPanel> createState() => _WatchClientPanelState();
}

class _WatchClientPanelState extends State<WatchClientPanel> with ThemeHelpers {
  WatchStatus? _status;
  bool _loading = true;
  bool _resyncing = false;
  bool _pushingAvatars = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final status = await WatchClient.fetchStatus();
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  Future<void> _resync() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Re-sync watch?"),
        content: const Text(
          "This deletes the watch app's local message database and downloads "
          "everything again. It can take a while on the watch.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text("Re-sync")),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _resyncing = true);
    final status = await WatchClient.requestResync();
    if (!mounted) return;
    setState(() {
      _resyncing = false;
      _status = status ?? _status;
    });
    if (mounted) {
      showSnackbar(
        "Watch",
        status == null ? "Couldn't reach the watch" : "Re-sync started on the watch",
      );
    }
  }

  Future<void> _sendConfig() async {
    await WatchProvisioner.push();
    if (mounted) showSnackbar("Watch", "Settings sent to the watch");
    await _load();
  }

  Future<void> _pushAvatars() async {
    setState(() => _pushingAvatars = true);
    final sent = await WatchClient.pushAvatars();
    if (!mounted) return;
    setState(() => _pushingAvatars = false);
    showSnackbar(
      "Watch",
      sent == null ? "Couldn't send contact photos" : "Sent $sent contact photo(s)",
    );
    // Give the transfer a moment before re-reading the watch's count.
    await Future.delayed(const Duration(seconds: 2));
    await _load();
  }

  static const Widget _spinner =
      SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));

  Widget _dot(Color color) => Icon(Icons.circle, size: 14, color: color);

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final reachable = s != null;

    return SettingsScaffold(
      title: "Watch App Client",
      initialHeader: "Watch",
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      tileColor: tileColor,
      headerColor: headerColor,
      bodySlivers: [
        CupertinoSliverRefreshControl(onRefresh: _load),
        SliverList(
          delegate: SliverChildListDelegate(<Widget>[
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                SettingsTile(
                  backgroundColor: tileColor,
                  title: "Watch",
                  subtitle: _loading
                      ? "Looking for your watch…"
                      : reachable
                          ? "Connected${s.appVersion.isNotEmpty ? " · v${s.appVersion}" : ""}"
                          : "Not available — bring your watch nearby and open the app",
                  onTap: _loading ? null : _load,
                  trailing: _loading ? _spinner : _dot(reachable ? Colors.green : Colors.red),
                  leading: SettingsLeadingIcon(
                    iosIcon: CupertinoIcons.device_laptop,
                    materialIcon: Icons.watch_outlined,
                    containerColor: reachable ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),
            if (reachable) ...[
              SettingsHeader(
                iosSubtitle: iosSubtitle,
                materialSubtitle: materialSubtitle,
                text: "Connectivity",
              ),
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "Watch network",
                    subtitle: s.online ? "Online" : "Offline — no Wi-Fi on the watch",
                    trailing: _dot(s.online ? Colors.green : Colors.red),
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.wifi,
                      materialIcon: Icons.wifi,
                      containerColor: s.online ? Colors.green : Colors.red,
                    ),
                  ),
                  const SettingsDivider(),
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "SMS server",
                    subtitle: !s.smsConfigured
                        ? "Not configured on the watch"
                        : s.smsOk
                            ? "Reachable · ${s.syncUrl}"
                            : "Offline / unreachable from the watch",
                    trailing: _dot(!s.smsConfigured
                        ? Colors.grey
                        : s.smsOk
                            ? Colors.green
                            : Colors.red),
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.chat_bubble_2_fill,
                      materialIcon: Icons.sms_outlined,
                      containerColor: s.smsOk && s.smsConfigured ? Colors.green : Colors.grey,
                    ),
                  ),
                  const SettingsDivider(),
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "iMessage server",
                    subtitle: !s.bbConfigured
                        ? "Not configured on the watch"
                        : s.bbOk
                            ? "Reachable · ${s.bbUrl}"
                            : "Offline / unreachable from the watch",
                    trailing: _dot(!s.bbConfigured
                        ? Colors.grey
                        : s.bbOk
                            ? Colors.green
                            : Colors.red),
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.bubble_left_bubble_right_fill,
                      materialIcon: Icons.message_outlined,
                      containerColor: s.bbOk && s.bbConfigured ? Colors.blue : Colors.grey,
                    ),
                  ),
                ],
              ),
              SettingsHeader(
                iosSubtitle: iosSubtitle,
                materialSubtitle: materialSubtitle,
                text: "Local database",
              ),
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "Cached on watch",
                    subtitle: "${s.chats} chats · ${s.messages} messages",
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.tray_full,
                      materialIcon: Icons.storage_outlined,
                      containerColor: Colors.blueGrey,
                    ),
                  ),
                  const SettingsDivider(),
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "Memory",
                    subtitle: s.storageLabel,
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.chart_pie,
                      materialIcon: Icons.sd_storage_outlined,
                      containerColor: Colors.deepPurple,
                    ),
                  ),
                  const SettingsDivider(),
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "Sync state",
                    subtitle: s.syncing
                        ? "Syncing now…"
                        : s.firstSyncDone
                            ? "Up to date (incremental)"
                            : "First sync not finished yet",
                    trailing: s.syncing ? _spinner : null,
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.arrow_2_circlepath,
                      materialIcon: Icons.sync,
                      containerColor: s.firstSyncDone ? Colors.green : Colors.orange,
                    ),
                  ),
                  if (s.queued > 0) ...[
                    const SettingsDivider(),
                    SettingsTile(
                      backgroundColor: tileColor,
                      title: "Waiting to send",
                      subtitle: "${s.queued} message(s) queued on the watch",
                      leading: const SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.clock,
                        materialIcon: Icons.schedule,
                        containerColor: Colors.orange,
                      ),
                    ),
                  ],
                ],
              ),
              SettingsHeader(
                iosSubtitle: iosSubtitle,
                materialSubtitle: materialSubtitle,
                text: "Actions",
              ),
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "Send settings to watch",
                    subtitle: "Push the SMS + iMessage server settings again",
                    onTap: _sendConfig,
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.arrow_up_circle,
                      materialIcon: Icons.upload_outlined,
                      containerColor: Colors.blue,
                    ),
                  ),
                  const SettingsDivider(),
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "Update contact photos",
                    subtitle: "${s.avatars} cached on watch · tap to push them all again",
                    onTap: _pushingAvatars ? null : _pushAvatars,
                    trailing: _pushingAvatars ? _spinner : null,
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.person_crop_circle,
                      materialIcon: Icons.account_circle_outlined,
                      containerColor: Colors.teal,
                    ),
                  ),
                  const SettingsDivider(),
                  SettingsTile(
                    backgroundColor: tileColor,
                    title: "Full re-sync",
                    subtitle: "Delete the watch database and download everything again",
                    onTap: _resyncing ? null : _resync,
                    trailing: _resyncing ? _spinner : null,
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.arrow_clockwise,
                      materialIcon: Icons.restart_alt,
                      containerColor: Colors.red,
                    ),
                  ),
                ],
              ),
            ],
          ]),
        ),
      ],
    );
  }
}
