import 'package:bluebubbles/helpers/types/helpers/misc_helpers.dart';
import 'package:bluebubbles/services/backend/sms/imessage_mode.dart';
import 'package:bluebubbles/services/backend/sms/sms_service.dart';
import 'package:bluebubbles/services/backend/sync/sync_service.dart';
import 'package:bluebubbles/services/network/socket_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Pull down on the chat list to sync SMS now instead of waiting for the next
/// scheduled pass (60s). Handy after a period offline, or when another device
/// sent something and you don't want to wait for it to land.
///
/// The sync itself is cursor-based, so pulling repeatedly is cheap.
class ChatListRefresh {
  /// Push and pull SMS, and reconcile with the BlueBubbles server too, so one
  /// gesture refreshes everything the list shows rather than only half of it.
  static Future<void> sync() async {
    if (kIsWeb || kIsDesktop) return;

    // A scheduled pass (or a second pull) is already mid-flight. Wait for it
    // instead of starting a competing sync — and wait rather than returning, so
    // the spinner reflects real work instead of vanishing instantly.
    if (SmsSvc.syncState.value == SmsSyncState.syncing) {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (SmsSvc.syncState.value == SmsSyncState.syncing && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      return;
    }

    final futures = <Future>[SmsSvc.syncNow()];

    if (IMessageMode.enabled) {
      // Actually pull from the BlueBubbles server, rather than only nudging the
      // socket. Restarting a dead socket recovers *future* messages; anything
      // that arrived while it was down still needs fetching, which is what the
      // incremental sync does.
      if (SocketSvc.state.value != SocketState.connected) {
        futures.add(Future(() => SocketSvc.restartSocket()));
      }
      futures.add(SyncSvc.startIncrementalSync());
    }

    try {
      await Future.wait(futures);
    } catch (e, s) {
      Logger.error('Chat list refresh failed: $e', trace: s);
    }
  }
}

/// Material/Samsung wrapper: a normal [RefreshIndicator] around the list.
class ChatListRefreshWrapper extends StatelessWidget {
  const ChatListRefreshWrapper({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || kIsDesktop) return child;
    return RefreshIndicator(
      onRefresh: ChatListRefresh.sync,
      color: context.theme.colorScheme.primary,
      backgroundColor: context.theme.colorScheme.surface,
      child: child,
    );
  }
}

/// iOS-skin equivalent, added as the first sliver of the list's scroll view so
/// the pull feels native rather than showing a Material spinner.
class ChatListCupertinoRefresh extends StatelessWidget {
  const ChatListCupertinoRefresh({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || kIsDesktop) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return CupertinoSliverRefreshControl(onRefresh: ChatListRefresh.sync);
  }
}
