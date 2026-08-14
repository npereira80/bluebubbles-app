import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/network/network_tasks.dart';
import 'package:get_it/get_it.dart';
import 'package:bluebubbles/services/backend/sms/sms_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';

SetupService setup = Get.isRegistered<SetupService>() ? Get.find<SetupService>() : Get.put(SetupService());

class SetupService extends GetxService {
  Future<void> startSetup(int numberOfMessagesPerPage, bool skipEmptyChats, bool saveToDownloads,
      bool syncGroupChatIcons, int? syncTimeFilter) async {
    SyncSvc.numberOfMessagesPerPage = numberOfMessagesPerPage;
    SyncSvc.skipEmptyChats = skipEmptyChats;
    SyncSvc.saveToDownloads = saveToDownloads;
    SyncSvc.syncGroupChatIcons = syncGroupChatIcons;
    SyncSvc.syncTimeFilter = syncTimeFilter;

    // Reaching a full sync means a server answered, so the iMessage half is live
    // again. An install that had been running SMS-only left this off, and
    // syncing without turning it back on would download everything and then hide
    // it.
    if (!SettingsSvc.settings.iMessageEnabled.value) {
      SettingsSvc.settings.iMessageEnabled.value = true;
      await SettingsSvc.settings.saveOneAsync('iMessageEnabled');
    }

    SyncSvc.initFullSync();

    // Pre-fetch server details before the full sync so sync managers can
    // read SettingsSvc.serverDetails.value synchronously during the sync.
    await SettingsSvc.fetchServerDetails();
    await SyncSvc.startFullSync();
    await _finishSetup();
  }

  /// TN fork — finish setup without a Bubbles server: SMS only, over the Android
  /// SIM. iMessage is switched off rather than left on and broken, so nothing
  /// tries to reach a server that was never configured.
  ///
  /// Deliberately skips the sync pages: there is nothing to full-sync, and
  /// SyncProgress asserts on a sync manager that would never have been created.
  Future<void> finishSetupWithoutServer() async {
    SettingsSvc.settings.iMessageEnabled.value = false;
    await SettingsSvc.settings.saveOneAsync('iMessageEnabled');
    await _finishSetup();
  }

  Future<void> _finishSetup() async {
    // Re-entering setup to add a server to an install that's already running
    // must not rewind the SMS cursors: those messages are already imported, and
    // re-pulling them all would be work for nothing.
    final firstRun = !SettingsSvc.settings.finishedSetup.value;
    SettingsSvc.settings.finishedSetup.value = true;
    await SettingsSvc.settings.saveOneAsync('finishedSetup');
    await StartupTasks.onStartup();
    await NetworkTasks.onConnect();

    // TN fork: SmsService registers (and gives up early) before setup is
    // finished, so nothing has imported the phone's own SMS or pulled the backup
    // yet. Do it now that the chat service is up and inserts have somewhere to
    // land — otherwise an SMS-only install opens to an empty list.
    if (!kIsWeb && !kIsDesktop && GetIt.I.isRegistered<SmsService>()) {
      await SmsSvc.init();
      if (firstRun) {
        // Reset the cursors first: an early pull may have advanced them past
        // messages whose inserts went nowhere, and those never come back on
        // their own. Cheap, and content hashes mean no duplicates.
        await SmsSvc.fullResyncFromServer();
      }
    }
  }
}
