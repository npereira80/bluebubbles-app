import 'package:bluebubbles/database/models.dart' hide Entity;
import 'package:flutter/foundation.dart';

class ReactionTypes {
  // ignore: non_constant_identifier_names
  static const String LOVE = "love";
  // ignore: non_constant_identifier_names
  static const String LIKE = "like";
  // ignore: non_constant_identifier_names
  static const String DISLIKE = "dislike";
  // ignore: non_constant_identifier_names
  static const String LAUGH = "laugh";
  // ignore: non_constant_identifier_names
  static const String EMPHASIZE = "emphasize";
  // ignore: non_constant_identifier_names
  static const String QUESTION = "question";

  /// TN fork — a tapback made with an arbitrary emoji (macOS Sequoia and later).
  ///
  /// The server only translates the six classic reaction IDs into names and
  /// passes anything else through as a raw number, so these arrived as "2006"
  /// and matched nothing: no verb in the chat list ("Tuxa null …") and, because
  /// they weren't recognised as reactions at all, an empty bubble in the thread.
  // ignore: non_constant_identifier_names
  static const String EMOJI = "emoji";

  static List<String> toList() {
    return [
      LOVE,
      LIKE,
      DISLIKE,
      LAUGH,
      EMPHASIZE,
      QUESTION,
      EMOJI,
    ];
  }

  /// Raw `associated_message_type` values, for the ones the server leaves as
  /// numbers. 2000-2005 and 3000-3005 already arrive named.
  static const int _emojiReactionId = 2006;
  static const int _emojiRemovalId = 3006;

  /// Canonical name for whatever the server sent, or null if it isn't a
  /// reaction at all.
  ///
  /// Unrecognised IDs in the reaction ranges are treated as emoji tapbacks
  /// rather than discarded: Apple has added to this list before and will again,
  /// and showing a reaction we can't name beats showing a blank message.
  static String? normalize(String? type) {
    if (type == null || type.isEmpty) return null;
    if (toList().contains(type.replaceAll("-", ""))) return type;

    final id = int.tryParse(type);
    if (id == null) return null;
    if (id == _emojiReactionId || (id > 2005 && id < 3000)) return EMOJI;
    if (id == _emojiRemovalId || (id > 3005 && id < 4000)) return "-$EMOJI";
    return null;
  }

  static final Map<String, String> reactionToVerb = {
    LOVE: "loved",
    LIKE: "liked",
    DISLIKE: "disliked",
    LAUGH: "laughed at",
    EMPHASIZE: "emphasized",
    QUESTION: "questioned",
    EMOJI: "reacted to",
    "-$EMOJI": "removed a reaction from",
    "-$LOVE": "removed a heart from",
    "-$LIKE": "removed a like from",
    "-$DISLIKE": "removed a dislike from",
    "-$LAUGH": "removed a laugh from",
    "-$EMPHASIZE": "removed an exclamation from",
    "-$QUESTION": "removed a question mark from",
  };

  static final Map<String, String> reactionToEmoji = {
    LOVE: "❤️",
    LIKE: "👍",
    DISLIKE: "👎",
    LAUGH: "😂",
    EMPHASIZE: "❗",
    QUESTION: "❓",
  };

  /// Whether an SVG icon ships for this reaction. False for emoji tapbacks,
  /// which have no fixed icon by definition.
  static bool hasAsset(String? type) => reactionToEmoji.containsKey(type?.replaceAll("-", ""));

  /// The emoji to draw on the reaction bubble.
  ///
  /// For an emoji tapback the server doesn't send which emoji it was, but
  /// iMessage writes it into the message text ("Reacted ❤️ to …"), so pull it
  /// back out of there. Falls back to a neutral marker rather than guessing.
  static String emojiFor(String? type, {String? text}) {
    final known = reactionToEmoji[type?.replaceAll("-", "")];
    if (known != null) return known;
    final extracted = _firstEmoji(text);
    return extracted ?? "❕";
  }

  static final RegExp _emojiPattern = RegExp(
    r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}\u{FE0F}\u{2764}]+',
    unicode: true,
  );

  static String? _firstEmoji(String? text) {
    if (text == null || text.isEmpty) return null;
    final match = _emojiPattern.firstMatch(text);
    final value = match?.group(0)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static final Map<String, String> emojiToReaction = {
    "❤️": LOVE,
    "👍": LIKE,
    "👎": DISLIKE,
    "😂": LAUGH,
    "❗": EMPHASIZE,
    "❓": QUESTION,
  };
}

List<Message> getUniqueReactionMessages(List<Message> messages) {
  List<int> handleCache = [];
  List<Message> output = [];
  // Sort the messages, putting the latest at the top
  final ids = messages.map((e) => e.guid).toSet();
  messages.retainWhere((element) => ids.remove(element.guid));
  messages.sort(Message.sort);
  // Iterate over the messages and insert the latest reaction for each user
  for (Message msg in messages) {
    int cache = msg.isFromMe! ? 0 : msg.handleId ?? 0;
    if (!handleCache.contains(cache) && !kIsWeb) {
      handleCache.add(cache);
      // Only add the reaction if it's not a "negative"
      if (!msg.associatedMessageType!.startsWith("-")) {
        output.add(msg);
      }
    } else if (kIsWeb && !msg.associatedMessageType!.startsWith("-")) {
      output.add(msg);
    }
  }

  return output;
}
