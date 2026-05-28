/// Sealed hierarchy of scroll-side events emitted by the chat viewport.
///
/// Subscribe via [ChatScrollController.addScrollListener] to react to user
/// drags / flings / programmatic jumps without conflating them — e.g. dismiss
/// the keyboard on a user drag but not on a `jumpTo`, debounce read-receipts
/// while a fling is in flight, or show a "↓ new messages" pill when the user
/// has scrolled away from the newest.
sealed class ChatScrollEvent {
  const ChatScrollEvent();
}

/// User touched the viewport and started dragging.
class ChatUserDragStart extends ChatScrollEvent {
  const ChatUserDragStart();
}

/// User lifted the finger; [velocity] is the terminal pixel/second velocity
/// (signed: positive = revealing older, negative = revealing newer).
class ChatUserDragEnd extends ChatScrollEvent {
  const ChatUserDragEnd(this.velocity);
  final double velocity;
}

/// A fling simulation just started after a drag end. [velocity] is the
/// initial velocity in pixel/second.
class ChatFlingStart extends ChatScrollEvent {
  const ChatFlingStart(this.velocity);
  final double velocity;
}

/// The fling simulation just terminated (either naturally or cancelled).
class ChatFlingEnd extends ChatScrollEvent {
  const ChatFlingEnd();
}

/// `controller.jumpTo` was called programmatically.
class ChatProgrammaticJump extends ChatScrollEvent {
  const ChatProgrammaticJump(this.targetId);
  final int targetId;
}

/// `controller.animateTo` started; carries the target id and the duration.
class ChatAnimateStart extends ChatScrollEvent {
  const ChatAnimateStart(this.targetId, this.duration);
  final int targetId;
  final Duration duration;
}

/// `controller.animateTo`'s animation finished.
class ChatAnimateEnd extends ChatScrollEvent {
  const ChatAnimateEnd(this.targetId);
  final int targetId;
}
