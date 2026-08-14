import 'dart:async';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/generated/objectbox.g.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// TN fork — fetch every attachment the app knows about but doesn't have on disk.
///
/// A sync brings back messages and attachment *metadata* only; the files
/// themselves arrive when a message scrolls into view. That's the right default
/// (raising the per-chat message count then costs sync time, not gigabytes), but
/// after restoring onto a new phone you may want the pictures there without
/// visiting every conversation.
///
/// Sequential on purpose: this can be thousands of files, and a burst of parallel
/// downloads competes with the foreground UI and with the server's own disk.
class AttachmentBackfill {
  /// How long to wait on a single file before counting it as failed and moving
  /// on. Generous because attachments include video.
  static const Duration _perFileTimeout = Duration(minutes: 5);

  static final RxBool running = false.obs;
  static final RxInt total = 0.obs;
  static final RxInt done = 0.obs;
  static final RxInt failed = 0.obs;

  static bool _cancelled = false;

  static void cancel() => _cancelled = true;

  /// Attachments with a server GUID and no local file.
  static List<Attachment> _missing() {
    if (kIsWeb) return [];
    final query = Database.attachments.query(Attachment_.guid.notNull()).build();
    try {
      return query.find().where((a) {
        final guid = a.guid;
        if (guid == null || guid.startsWith('temp')) return false;
        // Our own SMS/MMS media is written straight to disk and never lives on
        // the BlueBubbles server, so it can't be re-fetched from there.
        if (guid.startsWith('tn-mms-')) return false;
        return !a.existsOnDisk;
      }).toList();
    } finally {
      query.close();
    }
  }

  /// How many files a run would fetch, for the settings row.
  static int missingCount() => _missing().length;

  static Future<void> start() async {
    if (running.value) return;
    _cancelled = false;

    final pending = _missing();
    running.value = true;
    total.value = pending.length;
    done.value = 0;
    failed.value = 0;

    Logger.info('AttachmentBackfill: ${pending.length} attachment(s) to fetch');
    try {
      for (final attachment in pending) {
        if (_cancelled) {
          Logger.info('AttachmentBackfill: cancelled after ${done.value}');
          break;
        }
        final completer = Completer<void>();
        try {
          AttachmentDownloader.startDownload(
            attachment,
            onComplete: (_) {
              done.value++;
              if (!completer.isCompleted) completer.complete();
            },
            onError: () {
              failed.value++;
              if (!completer.isCompleted) completer.complete();
            },
          );
          // A stalled download shouldn't strand the whole run, but the limit has
          // to clear a large video on a slow connection — a timeout that gives up
          // on a real download is worse than waiting.
          await completer.future.timeout(_perFileTimeout, onTimeout: () {
            failed.value++;
          });
        } catch (e) {
          failed.value++;
          Logger.warn('AttachmentBackfill: ${attachment.guid} failed: $e');
        }
      }
    } finally {
      running.value = false;
      Logger.info('AttachmentBackfill: finished — ${done.value} fetched, ${failed.value} failed');
    }
  }
}
