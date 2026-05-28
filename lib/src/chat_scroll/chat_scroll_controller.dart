import 'dart:async';

import 'package:chatscrollview/src/chat_scroll/chat_scroll_events.dart';
import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/foundation.dart';

/// Visible-range snapshot exposed by [ChatScrollController.visibleRange].
///
/// `firstId`/`lastId` are the inclusive id bounds of children whose rect
/// intersects the viewport's logical paint area (top inset to bottom inset).
/// `anchorId` is the message id currently used as the layout origin.
typedef ChatVisibleRange = ({int firstId, int lastId, int anchorId});

/// Delegate that performs actual scroll animations on behalf of
/// [ChatScrollController.animateTo]. Implemented by `RenderChatScrollView`
/// and bound automatically when the widget mounts; consumers do not interact
/// with this directly.
abstract class ChatScrollAnimator {
  Future<void> animate(
    int targetId, {
    required Duration duration,
    required Curve curve,
  });
}

/// Scroll controller for [ChatScrollView].
///
/// Owns anchor state and navigation: which message is the layout origin, its
/// pixel offset, the jump / animate entry points, and the typed event
/// stream (drag, fling, jump). Conversation boundaries (`oldestKnownId`,
/// `reachedOldest`, …) live on [ChatDataSource] — they describe the *data*,
/// not the navigation.
///
/// Uses typed listeners instead of [ChangeNotifier] — subscribers know
/// exactly what event occurred.
class ChatScrollController {
  // --- Jump: typed listener with payload ---

  final _jumpListeners = <ValueChanged<int>>[];

  /// Subscribe to jump events. Callback receives the target message ID.
  void addJumpListener(ValueChanged<int> callback) =>
      _jumpListeners.add(callback);

  /// Unsubscribe from jump events.
  void removeJumpListener(ValueChanged<int> callback) =>
      _jumpListeners.remove(callback);

  /// Jump to a specific message, resetting the anchor.
  void jumpTo(int messageId) {
    _anchorMessageId = messageId;
    _anchorPixelOffset = 0.0;
    // Iterate a snapshot — a listener may add or remove listeners (including
    // itself) while reacting to the jump.
    for (final cb in List<ValueChanged<int>>.of(
      _jumpListeners,
      growable: false,
    )) {
      cb(messageId);
    }
    _emitScroll(ChatProgrammaticJump(messageId));
  }

  /// Smoothly move the anchor onto [messageId] over [duration].
  ///
  /// Returns a Future that completes when the animation settles (or
  /// immediately if no viewport is bound yet). When the target is far outside
  /// the currently-built range, the viewport crossfades — instant jumpTo
  /// under a brief opacity blink — rather than animating through messages it
  /// would need to build on the fly.
  Future<void> animateTo(
    int messageId, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeInOutCubic,
  }) async {
    final animator = _animator;
    if (animator == null) {
      jumpTo(messageId);
      return;
    }
    _emitScroll(ChatAnimateStart(messageId, duration));
    try {
      await animator.animate(messageId, duration: duration, curve: curve);
    } finally {
      _emitScroll(ChatAnimateEnd(messageId));
    }
  }

  // --- Scroll-animator binding (viewport-only) -----------------------------

  ChatScrollAnimator? _animator;

  /// Bound by `RenderChatScrollView` on attach. Detach passes `null`.
  @internal
  set animator(ChatScrollAnimator? value) => _animator = value;

  // --- Visible range -------------------------------------------------------

  final ValueNotifier<ChatVisibleRange?> _visibleRange =
      ValueNotifier<ChatVisibleRange?>(null);

  /// Inclusive id range of currently-on-screen messages plus the active
  /// anchor id. `null` before the first layout has run (or when no message
  /// intersects the paint area). Push as the viewport scrolls / re-fans.
  ValueListenable<ChatVisibleRange?> get visibleRange => _visibleRange;

  /// Viewport-only setter — `RenderChatScrollView` pushes the latest range
  /// after every layout / Tier-1 reposition.
  @internal
  set visibleRange(ChatVisibleRange? value) => _visibleRange.value = value;

  // --- Scroll events -------------------------------------------------------

  final _scrollListeners = <ValueChanged<ChatScrollEvent>>[];

  /// Subscribe to typed scroll events ([ChatUserDragStart], [ChatFlingStart],
  /// [ChatProgrammaticJump], …).
  void addScrollListener(ValueChanged<ChatScrollEvent> callback) =>
      _scrollListeners.add(callback);

  void removeScrollListener(ValueChanged<ChatScrollEvent> callback) =>
      _scrollListeners.remove(callback);

  /// Viewport-only emitter. Iterates a snapshot — a listener removing itself
  /// or another listener during dispatch is safe.
  @internal
  void notifyScrollEvent(ChatScrollEvent event) => _emitScroll(event);

  void _emitScroll(ChatScrollEvent event) {
    if (_scrollListeners.isEmpty) return;
    for (final cb in List<ValueChanged<ChatScrollEvent>>.of(
      _scrollListeners,
      growable: false,
    )) {
      cb(event);
    }
  }

  // --- Anchor state (read-only for public, writable for viewport) ---

  /// The message ID used as layout origin.
  int get anchorMessageId => _anchorMessageId;
  int _anchorMessageId = 0;

  /// Pixel offset of the anchor message's top edge from the viewport top.
  double get anchorPixelOffset => _anchorPixelOffset;
  double _anchorPixelOffset = 0.0;

  // --- Viewport-only: silent mutation without notifications ---

  /// Apply a scroll delta without notification.
  /// Called by the viewport from the Ticker callback.
  @internal
  void applyScrollDelta(double delta) {
    _anchorPixelOffset += delta;
  }

  /// Silently reassign anchor (no notification).
  /// Called by the viewport during anchor renormalization inside performLayout.
  @internal
  void reassignAnchor(int messageId, double pixelOffset) {
    _anchorMessageId = messageId;
    _anchorPixelOffset = pixelOffset;
  }

  /// Drop all listeners. Call from the owning widget's `dispose` so a stray
  /// late notification cannot reach a torn-down listener.
  void dispose() {
    _jumpListeners.clear();
    _scrollListeners.clear();
    _visibleRange.dispose();
  }
}
