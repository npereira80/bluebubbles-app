abstract class MethodChannelInboundMethods {
  static const String newServerUrl = 'NewServerUrl';
  static const String newMessage = 'new-message';
  static const String updatedMessage = 'updated-message';
  static const String groupNameChange = 'group-name-change';
  static const String participantRemoved = 'participant-removed';
  static const String participantAdded = 'participant-added';
  static const String participantLeft = 'participant-left';
  static const String groupIconChanged = 'group-icon-changed';
  static const String scheduledMessageError = 'scheduled-message-error';
  static const String replyChat = 'ReplyChat';
  static const String markChatRead = 'MarkChatRead';
  static const String chatReadStatusChanged = 'chat-read-status-changed';
  static const String mediaColors = 'MediaColors';
  static const String incomingFacetime = 'incoming-facetime';
  static const String ftCallStatusChanged = 'ft-call-status-changed';
  static const String answerFacetime = 'answer-facetime';
  static const String iMessageAliasesRemoved = 'imessage-aliases-removed';
  static const String socketEvent = 'socket-event';
  static const String unifiedpushSettings = 'unifiedpush-settings';
  // TN Messages fork — local Android SMS
  static const String smsReceived = 'sms-received';
  /// The system SMS/MMS store changed. Sent by the ContentObserver, for phones
  /// where an OEM ROM keeps the SMS role and we only get to read the provider.
  static const String smsProviderChanged = 'sms-provider-changed';
  static const String smsSentStatus = 'sms-sent-status';
  static const String mmsReceived = 'mms-received';
}
