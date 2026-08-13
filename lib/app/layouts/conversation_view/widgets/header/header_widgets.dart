import 'dart:typed_data';

import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

class ManualMark extends StatefulWidget {
  const ManualMark({super.key, required this.controller});

  final ConversationViewController controller;

  @override
  State<StatefulWidget> createState() => ManualMarkState();
}

class ManualMarkState extends State<ManualMark> with ThemeHelpers {
  bool marked = false;
  bool marking = false;

  Chat get chat => widget.controller.chat;

  @override
  Widget build(BuildContext context) {
    final manualMark = SettingsSvc.settings.enablePrivateAPI.value &&
        SettingsSvc.settings.privateManualMarkAsRead.value &&
        !(chat.autoSendReadReceipts ?? false);
    return Obx(() {
      if (!manualMark && !widget.controller.inSelectMode.value) return const SizedBox.shrink();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              widget.controller.inSelectMode.value
                  ? (iOS ? CupertinoIcons.trash : Icons.delete_outlined)
                  : marking
                      ? (iOS ? CupertinoIcons.arrow_2_circlepath : Icons.sync)
                      : marked
                          ? (iOS ? CupertinoIcons.app : Icons.mark_chat_read_outlined)
                          : (iOS ? CupertinoIcons.app_badge : Icons.mark_chat_unread_outlined),
              color: !iOS
                  ? context.theme.colorScheme.onSurface
                  : (!marked && !marking || widget.controller.inSelectMode.value)
                      ? context.theme.colorScheme.primary
                      : context.theme.colorScheme.outline,
            ),
            tooltip: widget.controller.inSelectMode.value
                ? "Delete"
                : marking
                    ? null
                    : marked
                        ? "Mark Unread"
                        : "Mark Read",
            onPressed: () async {
              if (widget.controller.inSelectMode.value) {
                for (Message m in widget.controller.selected) {
                  await MessagesSvc(chat.guid).softDeleteMessage(m);
                }
                widget.controller.inSelectMode.value = false;
                widget.controller.selected.clear();
                return;
              }
              if (marking) return;
              setState(() {
                marking = true;
              });
              if (!marked) {
                await HttpSvc.chat.markRead(chat.guid);
              } else {
                await HttpSvc.chat.markUnread(chat.guid);
              }
              setState(() {
                marking = false;
                marked = !marked;
              });
            },
          ),
          if (widget.controller.inSelectMode.value)
            IconButton(
              icon: Icon(
                iOS ? CupertinoIcons.arrow_right : Icons.forward_outlined,
                color: !iOS ? context.theme.colorScheme.onSurface : context.theme.colorScheme.primary,
              ),
              onPressed: () async {
                List<PlatformFile> attachments = [];
                String text = "";
                widget.controller.selected.sort((a, b) => Message.sort(a, b, descending: false));
                for (Message m in widget.controller.selected) {
                  final _attachments = m.dbAttachments
                      .where((e) => AttachmentsSvc.getContent(e, autoDownload: false) is PlatformFile)
                      .map((e) => AttachmentsSvc.getContent(e, autoDownload: false) as PlatformFile);
                  for (PlatformFile a in _attachments) {
                    Uint8List? bytes = a.bytes;
                    bytes ??= await File(a.path!).readAsBytes();
                    attachments.add(PlatformFile(
                      name: a.name,
                      path: a.path,
                      size: bytes.length,
                      bytes: bytes,
                    ));
                  }
                  if (!isNullOrEmpty(m.text)) {
                    if (text.isEmpty) {
                      text = m.text!;
                    } else {
                      text = "$text\n\n${m.text}";
                    }
                  }
                }
                widget.controller.inSelectMode.value = false;
                widget.controller.selected.clear();
                NavigationSvc.pushAndRemoveUntil(
                  context,
                  NewChatCreator(
                    initialText: text,
                    initialAttachments: attachments,
                  ),
                  (route) => route.isFirst,
                );
              },
            ),
        ],
      );
    });
  }
}

/// A send-progress [LinearProgressIndicator] shared by both header skins.
///
/// Reads [Chat.sendProgress] from [ChatStateScope] so it never needs a
/// [Chat] constructor parameter.  Place it in a [Positioned] at the bottom
/// of the header stack.
class HeaderProgressIndicator extends StatelessWidget {
  const HeaderProgressIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = ChatStateScope.chatOf(context);
    return Obx(() => TweenAnimationBuilder<double>(
          duration: chat.sendProgress.value == 0
              ? Duration.zero
              : chat.sendProgress.value == 1
                  ? const Duration(milliseconds: 250)
                  : const Duration(seconds: 10),
          curve: chat.sendProgress.value == 1 ? Curves.easeInOut : Curves.easeOutExpo,
          tween: Tween<double>(
            begin: 0,
            end: chat.sendProgress.value,
          ),
          builder: (context, value, _) => AnimatedOpacity(
            opacity: value == 1 ? 0 : 1,
            duration: const Duration(milliseconds: 250),
            child: LinearProgressIndicator(
              value: value,
              backgroundColor: Colors.transparent,
              minHeight: 3,
            ),
          ),
        ));
  }
}
