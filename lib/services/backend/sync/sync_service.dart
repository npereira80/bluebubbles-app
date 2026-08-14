import 'dart:async';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/sms/imessage_mode.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/services/backend/interfaces/contact_v2_interface.dart';
import 'package:bluebubbles/services/backend/interfaces/sync_interface.dart';
import 'package:bluebubbles/services/isolates/incremental_sync_isolate.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:dio/dio.dart' show DioException, DioExceptionType;
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';
import 'package:universal_io/universal_io.dart';

// ignore: non_constant_identifier_names
SyncService get SyncSvc => GetIt.I<SyncService>();

class SyncService {
  int numberOfMessagesPerPage = 25;
  bool skipEmptyChats = true;
  bool saveToDownloads = false;
  bool syncGroupChatIcons = false;
  int? syncTimeFilter;
  final RxBool isIncrementalSyncing = false.obs;

  static const Duration _incrementalSyncCooldown = Duration(seconds: 30);
  DateTime? _lastIncrementalSyncTimestamp;

  FullSyncManager? _manager;
  FullSyncManager? get fullSyncManager => _manager;

  void initFullSync() {
    _manager = FullSyncManager(
        messageCount: numberOfMessagesPerPage.toInt(),
        skipEmptyChats: skipEmptyChats,
        saveLogs: saveToDownloads,
        syncGroupChatIcons: syncGroupChatIcons,
        syncTimeFilter: syncTimeFilter);
  }

  Future<void> startFullSync() async {
    if (_manager == null) {
      initFullSync();
    }

    // Set the last sync date (for incremental, even though this isn't incremental)
    // We won't try an incremental sync until the last (full) sync date is set
    SettingsSvc.settings.lastIncrementalSync.value = DateTime.now().millisecondsSinceEpoch;
    await SettingsSvc.settings.saveOneAsync('lastIncrementalSync');
    await _manager!.start();
  }

  Future<void> startIncrementalSync({bool useGlobalIsolate = false}) async {
    if (isIncrementalSyncing.value) return;

    // TN fork: with the iMessage half switched off there is nothing to sync from
    // the server, and the cursor is left untouched so re-enabling resumes rather
    // than re-downloading. The contact pass below still runs: it reads the
    // phone's own contacts and is what gives every chat its name and avatar,
    // including in SMS-only mode.
    final syncFromServer = IMessageMode.enabled;

    final now = DateTime.now();
    if (_lastIncrementalSyncTimestamp != null &&
        now.difference(_lastIncrementalSyncTimestamp!) < _incrementalSyncCooldown) {
      Logger.debug(
        'Skipping incremental sync... Last ran ${now.difference(_lastIncrementalSyncTimestamp!).inSeconds}s ago '
        '(cooldown: ${_incrementalSyncCooldown.inSeconds}s)',
        tag: 'Incremental Chat Sync',
      );
      return;
    }

    _lastIncrementalSyncTimestamp = now;
    isIncrementalSyncing.value = true;
    int errors = 0;
    // An unreachable server isn't a sync failure worth shouting about — it's the
    // expected outcome of the server being off, which the offline bar already
    // says. Tracked separately so a real failure still surfaces.
    bool unreachable = false;

    // Per-page tracking: record message IDs and chat subtitle message IDs that were
    // already applied by per-page events so the final return can skip redundant work.
    final processedMessageIds = <int>{};
    final processedSubtitleByChat = <String, int>{}; // chatGuid → message DB ID

    Future<void> onPageComplete(dynamic data) async {
      if (data is! Map<String, dynamic>) return;
      final messageIds = (data['messageIds'] as List).cast<int>();
      final latestPerChat = Map<String, int>.from(data['latestMessageIdPerChat'] as Map);

      // Hydrate the page's messages and dispatch to any open chat view immediately.
      final messages = Database.messages.getMany(messageIds).whereType<Message>().toList();
      for (final message in messages) {
        if (message.id != null) processedMessageIds.add(message.id!);
        final chatGuid = message.chat.target?.guid;
        if (chatGuid == null || message.guid == null) continue;
        if (Get.isRegistered<MessagesService>(tag: chatGuid)) {
          unawaited(Get.find<MessagesService>(tag: chatGuid).addNewMessage(message));
        }
      }

      // Update chat subtitles for the per-page latest message per chat.
      for (final entry in latestPerChat.entries) {
        final msg = Database.messages.get(entry.value);
        if (msg == null) continue;
        // If this chat was created for the first time during this sync,
        // ChatState doesn't exist yet — register it so updateChatLatestMessage
        // isn't a silent no-op.
        if (ChatsSvc.getChatState(entry.key) == null) {
          final chat = msg.chat.target;
          if (chat != null) await ChatsSvc.addChat(chat, immediate: true);
        }
        ChatsSvc.updateChatLatestMessage(entry.key, msg);
        processedSubtitleByChat[entry.key] = entry.value;
      }
    }

    final syncIsolate = GetIt.I<IncrementalSyncIsolate>();
    if (syncFromServer) {
      syncIsolate.addEventListener(IsolateEvent.incrementalSyncPageComplete, onPageComplete);
    }

    try {
      // Server-side sync. Skipped entirely in SMS-only mode; the contact
      // pass after this block still runs.
      if (syncFromServer) {
        Logger.info('Starting incremental chat sync...', tag: 'Incremental Chat Sync');
        final chatStopwatch = Stopwatch()..start();
        final syncedMessages = await SyncInterface.performIncrementalSync(useGlobalIsolate: useGlobalIsolate);
        if (syncedMessages.isNotEmpty) {
          // latestMessageIdPerChat is keyed by chat GUID, so syncedMessages already contains
          // at most one message per chat. Deduplicate defensively by keeping the latest
          // message per chat GUID in case the data ever changes.
          final Map<String, Message> latestPerChat = {};
          for (final message in syncedMessages) {
            final chatGuid = message.chat.target?.guid;
            if (chatGuid == null) continue;
            final existing = latestPerChat[chatGuid];
            if (existing == null ||
                (message.dateCreated != null &&
                    (existing.dateCreated == null || message.dateCreated!.isAfter(existing.dateCreated!)))) {
              latestPerChat[chatGuid] = message;
            }
          }

          // IncrementalSyncManager.complete() already called ChatsSvc.updateChat() for every
          // synced chat. Here we only need to push the subtitle update into ChatState.
          // Skip chats where the per-page event already applied the same (or newer) message.
          for (final entry in latestPerChat.entries) {
            final message = entry.value;
            if (message.id != null && processedSubtitleByChat[entry.key] == message.id) continue;
            ChatsSvc.updateChatLatestMessage(entry.key, message);
          }

          // Dispatch newly synced messages to any currently active chat view.
          // Skip messages already dispatched by a per-page event.
          // MessagesService.addNewMessage() is a no-op if the message is already present,
          // so this is safe even without the skip, but avoiding the call reduces churn.
          for (final message in syncedMessages) {
            if (message.id != null && processedMessageIds.contains(message.id)) continue;
            final chatGuid = message.chat.target?.guid;
            if (chatGuid == null || message.guid == null) continue;
            if (Get.isRegistered<MessagesService>(tag: chatGuid)) {
              unawaited(Get.find<MessagesService>(tag: chatGuid).addNewMessage(message));
            }
          }
        }

        chatStopwatch.stop();
        Logger.info(
            'Incremental chat sync completed! Synced ${syncedMessages.length} messages across '
            '${syncedMessages.map((m) => m.chat.target?.guid).toSet().length} chats '
            'in ${chatStopwatch.elapsedMilliseconds}ms',
            tag: 'Incremental Chat Sync');
      }
    } catch (e, stack) {
      if (isServerUnreachable(e)) {
        unreachable = true;
        Logger.info('Incremental chat sync skipped — server unreachable', tag: 'Incremental Chat Sync');
      } else {
        Logger.error('Incremental chat sync failed!', error: e, trace: stack, tag: 'Incremental Chat Sync');
        errors += 1;
      }
    } finally {
      syncIsolate.removeEventListener(IsolateEvent.incrementalSyncPageComplete, onPageComplete);
    }

    // Matching the phone's contacts to handles is local work and the only thing
    // that gives a chat a name and a photo, so it runs regardless of whether the
    // server was reachable — or configured at all.
    final contactSyncResult = await performContactSyncToHandles();
    if (!contactSyncResult) {
      errors += 1;
    }

    // Uploading them is the server's business: pointless when it isn't answering,
    // and meaningless when there's no server.
    if (syncFromServer && !unreachable) {
      final contactUploadResult = await performContactSyncToServer();
      if (!contactUploadResult) {
        errors += 1;
      }
    }

    if (errors > 0) {
      await showToast('Incremental sync completed with $errors errors', isError: true);
    } else if (unreachable) {
      // Silent: the "iMessage server offline" bar is already on screen, and this
      // runs on every resume and every reconnect attempt.
    } else if (SettingsSvc.settings.showIncrementalSync.value) {
      await showToast('Incremental sync complete');
    }

    isIncrementalSyncing.value = false;
  }

  /// Whether a failure means "the server isn't answering" rather than "something
  /// went wrong". Covers a dead socket, DNS failure, refused connection, timeouts,
  /// a tunnel that's gone, and our own "no server configured" guard.
  static bool isServerUnreachable(Object error) {
    if (error is SocketException) return true;
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return true;
        case DioExceptionType.badResponse:
          // 502/503/504 mean the tunnel is up but nothing is behind it.
          final status = error.response?.statusCode ?? 0;
          return status >= 502 && status <= 504;
        default:
          break;
      }
      if (error.error is SocketException) return true;
    }
    final text = error.toString();
    return text.contains('No server URL!') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection refused') ||
        text.contains('Connection closed') ||
        text.contains('Network is unreachable');
  }

  Future<bool> performContactSyncToHandles() async {
    try {
      Logger.info('Starting contact refresh', tag: 'Incremental Contact Sync');
      final contactStopwatch = Stopwatch()..start();
      final refreshedHandleIds = await ContactsSvcV2.syncContactsToHandles();
      contactStopwatch.stop();
      Logger.info(
          'Finished contact refresh, refreshed ${refreshedHandleIds.length} handles in ${contactStopwatch.elapsedMilliseconds}ms',
          tag: 'Incremental Contact Sync');

      if (refreshedHandleIds.isNotEmpty) {
        ContactsSvcV2.notifyHandlesUpdated(refreshedHandleIds);
      }

      return true;
    } catch (ex, stack) {
      Logger.error('Contacts refresh failed!', error: ex, trace: stack, tag: 'Incremental Contact Sync');
      return false;
    }
  }

  Future<bool> performContactSyncToServer() async {
    try {
      // Auto upload contacts if requested
      if (Platform.isAndroid && SettingsSvc.settings.syncContactsAutomatically.value) {
        Logger.debug("Starting contact upload to server...", tag: "Contact Upload");
        final contactUploadStopwatch = Stopwatch()..start();
        // Get all contacts from ContactServiceV2
        final contactsV2 = await ContactsSvcV2.getAllContacts();
        final _contacts = <Map<String, dynamic>>[];
        for (final c in contactsV2) {
          _contacts.add(c.toServerMap());
        }

        await ContactV2Interface.uploadContacts(_contacts);
        contactUploadStopwatch.stop();
        Logger.debug("Contact upload complete in ${contactUploadStopwatch.elapsedMilliseconds}ms",
            tag: "Contact Upload");
      }

      return true;
    } catch (e, stack) {
      Logger.error("Failed to upload contacts!", error: e, trace: stack, tag: "Contact Upload");
      return false;
    }
  }
}
