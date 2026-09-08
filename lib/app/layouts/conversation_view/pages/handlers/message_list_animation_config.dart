import 'package:flutter/material.dart';

/// Centralizes all animation configuration for the message list.
/// This makes animation timing and curves easy to tune without touching the orchestrator logic.
class MessageListAnimationConfig {
  /// Duration for new message insertion animations (slide + size + fade).
  ///
  /// The send animation flies for exactly this long (SendAnimation reads it),
  /// so the row has finished opening its space and settling at the instant the
  /// bubble lands on it. The two used to differ by 25ms, with the row's fade
  /// pushed into the last 10% to keep the overlap from showing; the row is now
  /// hidden outright for the flight, so neither trick is needed.
  static const Duration insertionDuration = Duration(milliseconds: 450);

  /// Curve for insertion slide animation
  static const Curve insertionSlideCurve = Curves.easeOut;

  /// Curve for insertion size animation
  static const Curve insertionSizeCurve = Curves.easeOut;

  /// Curve for insertion fade animation (only for sent messages)
  static const Curve insertionFadeCurve = Curves.easeOut;

  /// Fade interval for sent messages. Front-loaded now that it no longer has
  /// to hide an overlap: an outgoing message that arrives from another device
  /// (no send animation to hand off from) fades in as it slides, rather than
  /// snapping in at the very end.
  static const Interval fadeInterval = Interval(0.0, 0.6, curve: Curves.easeOut);

  /// Size transition start ratio (messages start at 30% height)
  static const double sizeTransitionStartRatio = 0.3;

  /// Slide transition start offset (messages slide up from bottom)
  static const Offset slideStartOffset = Offset(0.0, 1.0);

  /// Size transition axis alignment (-1.0 = top aligned, 1.0 = bottom aligned)
  static const double sizeTransitionAxisAlignment = -1.0;
}
