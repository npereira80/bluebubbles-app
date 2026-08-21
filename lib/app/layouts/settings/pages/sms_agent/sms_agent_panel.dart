import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/backend/sms/sms_account.dart';
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
  bool _signingIn = false;
  late final TextEditingController _url = TextEditingController(text: SmsSvc.serverUrl);
  late final TextEditingController _secret = TextEditingController(text: SmsSvc.serverSecret);

  @override
  void initState() {
    super.initState();
    SmsSvc.refreshStatus();
    // Check server reachability as soon as the view opens.
    SmsSvc.pingServer();
  }

  Future<void> _refresh() async {
    await SmsSvc.refreshStatus();
    await SmsSvc.pingServer();
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

  /// Let the number be typed in when the SIM won't report it. Signing in texts
  /// this phone its own code, so without a number there's no way to join an
  /// account at all — and plenty of carriers, prepaid especially, never write
  /// the MSISDN to the SIM.
  Future<void> _editSimNumber() async {
    final controller = TextEditingController(
      text: SmsSvc.simNumberManual.value ?? SmsSvc.simNumber.value ?? '',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("SIM number", style: context.theme.textTheme.titleLarge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "This phone's own number, in full international form. Used to text "
              "itself when signing in, and to tell your messages apart from "
              "everyone else's on the server.",
              style: context.theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(hintText: "+351912345678"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text("Cancel")),
          // Clearing it falls back to whatever the SIM reports, which is the
          // right answer on a phone where that worked all along.
          TextButton(onPressed: () => Navigator.of(ctx).pop(''), child: const Text("Use SIM")),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text("Save"),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    await SmsSvc.setSimNumberManual(result.isEmpty ? null : result);
    if (mounted) setState(() {});
  }

  /// Ask for an email, then prove the SIM by texting this phone its own code.
  Future<void> _signInFlow() async {
    if (SmsAccount.signedIn) {
      final out = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
          title: Text("Signed in as ${SmsAccount.email.value}", style: context.theme.textTheme.titleLarge),
          content: Text(
            "Signing out stops this phone syncing to your account. Messages already "
            "on the phone stay where they are.",
            style: context.theme.textTheme.bodyLarge,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text("Cancel")),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text("Sign out")),
          ],
        ),
      );
      if (out == true) await SmsAccount.signOut();
      return;
    }

    final controller = TextEditingController();
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("Sign in", style: context.theme.textTheme.titleLarge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Your email identifies your account on the family server. "
              "This phone will text itself a code to confirm the SIM.",
              style: context.theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(hintText: "you@example.com"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text("Continue"),
          ),
        ],
      ),
    );
    if (email == null || email.isEmpty || !mounted) return;

    // No number to text, or no cellular to text it with: the self-text can't
    // work, so go straight to the other route rather than making the person
    // wait out a 90-second timeout to be told so.
    if (SmsSvc.effectiveSimNumber == null || !SmsSvc.canSendSms.value) {
      await _remoteSignIn(email);
      return;
    }

    setState(() => _signingIn = true);
    final error = await SmsAccount.signIn(
      email_: email,
      serverUrl: SmsSvc.serverUrl,
      secret: SmsSvc.serverSecret,
    );
    if (mounted) setState(() => _signingIn = false);

    if (error != null) {
      // The self-text is the only part that failed. Offer the other route
      // instead of dead-ending on an error message.
      if (mounted) await _offerRemoteFallback(email, error);
      return;
    }
    showSnackbar('Signed in', 'Syncing as $email');
    await SmsSvc.syncNow();
  }

  /// The self-text didn't work. Explain, and offer the code-from-another-device
  /// route rather than leaving the person stuck.
  Future<void> _offerRemoteFallback(String email, String reason) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("Couldn't verify by text", style: context.theme.textTheme.titleLarge),
        content: Text(
          "$reason\n\nIf another device is already signed in to this account, "
          "the code can be sent there instead.",
          style: context.theme.textTheme.bodyLarge,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Use another device"),
          ),
        ],
      ),
    );
    if (go == true && mounted) await _remoteSignIn(email);
  }

  /// Sign in using a code the server pushes to a device already on the account.
  Future<void> _remoteSignIn(String email) async {
    setState(() => _signingIn = true);
    final challenge = await SmsAccount.startRemote(
      email_: email,
      serverUrl: SmsSvc.serverUrl,
      secret: SmsSvc.serverSecret,
    );
    if (mounted) setState(() => _signingIn = false);
    if (!mounted) return;

    if (challenge == null) {
      showSnackbar('Sign in',
          "The server didn't recognise $email. Check the spelling — a new address "
          "would create a separate account.");
      return;
    }

    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("Enter the code", style: context.theme.textTheme.titleLarge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Always shown, never made conditional on another device having
            // rendered it. "Delivered" only ever meant a socket was open, which
            // left this screen waiting on a code nobody had displayed.
            Text(
              challenge.code != null
                  ? "Your code is ${challenge.code}."
                      "${challenge.delivered ? ' It was also sent to your other signed-in devices.' : ''}"
                  : "Check your other signed-in devices for a 6-digit code.",
              style: context.theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(hintText: "000000"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text("Sign in"),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty || !mounted) return;

    setState(() => _signingIn = true);
    final error = await SmsAccount.completeRemote(
      email_: email,
      challengeId: challenge.challengeId,
      code: code,
      serverUrl: SmsSvc.serverUrl,
      secret: SmsSvc.serverSecret,
    );
    if (mounted) setState(() => _signingIn = false);

    if (error != null) {
      showSnackbar('Sign in', error);
      return;
    }
    showSnackbar('Signed in', 'Syncing as $email');
    await SmsSvc.syncNow();
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
        CupertinoSliverRefreshControl(onRefresh: _refresh),
        SliverList(
          delegate: SliverChildListDelegate(<Widget>[
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Obx(() {
                  final online = SmsSvc.serverOnline.value;
                  final pinging = SmsSvc.serverPinging.value;
                  final String label;
                  final Color color;
                  if (pinging && online == null) {
                    label = "Checking…";
                    color = Colors.grey;
                  } else if (online == true) {
                    label = "ONLINE";
                    color = Colors.green;
                  } else if (online == false) {
                    label = "OFFLINE";
                    color = Colors.red;
                  } else {
                    label = "Unknown — tap to check";
                    color = Colors.grey;
                  }
                  return SettingsTile(
                    backgroundColor: tileColor,
                    title: "Server status",
                    subtitle: label,
                    onTap: pinging ? null : () => SmsSvc.pingServer(),
                    trailing: pinging
                        ? _spinner
                        : Icon(Icons.circle, size: 14, color: color),
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.dot_radiowaves_left_right,
                      materialIcon: Icons.dns_outlined,
                      containerColor: color,
                    ),
                  );
                }),
                const SettingsDivider(),
                // The server keeps a separate database per family member, so
                // nothing syncs until this install says who it belongs to.
                Obx(() {
                  final account = SmsAccount.email.value;
                  return SettingsTile(
                    backgroundColor: tileColor,
                    title: account == null ? "Sign in" : "Signed in",
                    subtitle: account ??
                        "Your messages sync to your own account on the server. "
                            "Verified by a text this phone sends to itself.",
                    isThreeLine: account == null,
                    onTap: _signingIn ? null : _signInFlow,
                    // The wait here is real: it sends a text and waits for it to
                    // come back, so say so rather than looking frozen.
                    trailing: _signingIn ? _spinner : null,
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.person_crop_circle,
                      materialIcon: Icons.account_circle_outlined,
                      containerColor: account == null ? Colors.orange : Colors.green,
                    ),
                  );
                }),
                const SettingsDivider(),
                Obx(() {
                  final isDefault = SmsSvc.isDefaultSmsApp.value;
                  // Reading the store rather than receiving directly is a real
                  // difference in behaviour, so say so plainly. Left unexplained
                  // it reads as "No" next to an app that is nonetheless working,
                  // which looks like a bug.
                  final observing = SmsSvc.observerMode;
                  return SettingsTile(
                    backgroundColor: tileColor,
                    title: "Default SMS app",
                    subtitle: isDefault
                        ? "Yes — Android SMS is handled here"
                        : observing
                            ? SmsSvc.radioSendBlocked.value
                                ? "No — reading Android's message store, and this "
                                    "phone's radio won't send for us, so messages go "
                                    "out through your sync server."
                                : "No — reading Android's message store instead. "
                                    "Messages still arrive and sending works. Your "
                                    "replies won't show in the built-in app."
                            : "No — tap to set Bubbles as your SMS app",
                    isThreeLine: observing,
                    onTap: () async {
                      await SmsSvc.requestDefault();
                      await Future.delayed(const Duration(seconds: 1));
                      await SmsSvc.refreshStatus();
                    },
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.chat_bubble_2_fill,
                      materialIcon: Icons.sms_outlined,
                      containerColor: isDefault
                          ? Colors.green
                          : observing
                              ? Colors.orange
                              : Colors.grey,
                    ),
                  );
                }),
                const SettingsDivider(),
                // Being the default SMS app isn't enough on its own: if the SMS
                // permissions didn't come with the role, Android drops incoming
                // messages before they reach us and everything looks fine.
                Obx(() {
                  final ok = SmsSvc.hasSmsPermissions.value;
                  final missing = SmsSvc.missingSmsPermissions;
                  return SettingsTile(
                    backgroundColor: tileColor,
                    title: "SMS & MMS permissions",
                    subtitle: ok
                        ? "Granted — messages can reach the app"
                        : "Missing ${missing.join(', ')} — tap to grant. "
                            "Without these you won't receive anything.",
                    onTap: () async {
                      await SmsSvc.requestPermissions();
                      await Future.delayed(const Duration(seconds: 1));
                      await SmsSvc.refreshPermissions();
                    },
                    leading: SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.lock_shield_fill,
                      materialIcon: Icons.verified_user_outlined,
                      containerColor: ok ? Colors.green : Colors.red,
                    ),
                  );
                }),
                const SettingsDivider(),
                Obx(() {
                  final manual = SmsSvc.simNumberManual.value;
                  final fromSim = SmsSvc.simNumber.value;
                  final String subtitle;
                  if (manual != null && manual.isNotEmpty) {
                    subtitle = "$manual • entered manually";
                  } else if (fromSim != null && fromSim.isNotEmpty) {
                    subtitle = fromSim;
                  } else if (SmsSvc.simPresent.value) {
                    // Presence and readability are different questions, and this
                    // row used to conflate them: carriers frequently don't store
                    // the MSISDN, and ICCID is system-apps-only on Android 11+, so
                    // a perfectly working SIM reads as "no SIM".
                    subtitle = "SIM detected, but it won't report its number • tap to enter it";
                  } else {
                    subtitle = "No SIM detected • tap to enter the number anyway";
                  }
                  return SettingsTile(
                    backgroundColor: tileColor,
                    title: "SIM number",
                    subtitle: subtitle,
                    // Editable because signing in has to text this phone, and a
                    // fair number of carriers never write the number to the SIM.
                    onTap: _editSimNumber,
                    leading: const SettingsLeadingIcon(
                      iosIcon: CupertinoIcons.antenna_radiowaves_left_right,
                      materialIcon: Icons.sim_card_outlined,
                      containerColor: Colors.teal,
                    ),
                  );
                }),
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
