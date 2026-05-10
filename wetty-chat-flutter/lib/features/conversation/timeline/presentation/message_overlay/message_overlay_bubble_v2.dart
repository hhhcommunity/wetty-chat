import 'package:chahua/features/conversation/message_bubble/presentation/message_item.dart';
import 'package:chahua/features/conversation/timeline/model/message_long_press_details_v2.dart';
import 'package:chahua/features/shared/model/message/message.dart'
    hide MessageItem;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea;

class MessageOverlayBubbleV2 extends StatelessWidget {
  const MessageOverlayBubbleV2({super.key, required this.details});

  final MessageLongPressDetailsV2 details;

  @override
  Widget build(BuildContext context) {
    final isTextSelectable = switch (details.message.content) {
      TextMessageContent(:final text) when text.trim().isNotEmpty => true,
      _ => false,
    };
    final bubble = Align(
      alignment: details.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: MessageItem(
        message: details.message,
        isMe: details.isMe,
        isInteractive: false,
        isTextSelectable: isTextSelectable,
        showSenderName: details.sourceShowsSenderName,
      ),
    );
    if (isTextSelectable) {
      return SelectionArea(child: bubble);
    }
    return IgnorePointer(child: bubble);
  }
}
