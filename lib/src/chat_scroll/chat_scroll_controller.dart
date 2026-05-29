import 'dart:async';

import 'package:chatscrollview/src/chat_scroll/chat_scroll_events.dart';
import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

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

  /// `LinkedHashSet` (literal `<...>{}` is a `LinkedHashSet`) so a duplicate
  /// `addJumpListener` is a no-op — otherwise the symmetric `remove` only
  /// strips one of multiple registrations and the listener silently leaks.
  final _jumpListeners = <ValueChanged<int>>{};

  /// Subscribe to jump events. Callback receives the target message ID.
  /// Adding the same callback twice is a no-op.
  void addJumpListener(ValueChanged<int> callback) =>
      _jumpListeners.add(callback);

  /// Unsubscribe from jump events.
  void removeJumpListener(ValueChanged<int> callback) =>
      _jumpListeners.remove(callback);

  /// Jump to a specific message, resetting the anchor.
  void jumpTo(int messageId) {
    if (_disposed) return;
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

  // --- Scroll-by: typed listener -------------------------------------------

  /// `LinkedHashSet` — same dedup rationale as [_jumpListeners].
  final _scrollByListeners = <ValueChanged<double>>{};

  /// Subscribe to programmatic `scrollBy` events. Callback receives the
  /// pixel delta. Used by the viewport to cancel any in-flight fling and
  /// relayout in response; consumers can listen too if they need to react.
  /// Adding the same callback twice is a no-op.
  void addScrollByListener(ValueChanged<double> callback) =>
      _scrollByListeners.add(callback);

  /// Unsubscribe from `scrollBy` events.
  void removeScrollByListener(ValueChanged<double> callback) =>
      _scrollByListeners.remove(callback);

  /// Shift the viewport's anchor by [pixels]. Positive values reveal older
  /// messages (content moves down); negative values reveal newer (content
  /// moves up). Use for keyboard scroll, mouse-wheel forwarding, or any
  /// programmatic "scroll by N pixels" affordance — the underlying physics
  /// (clamping, follow-tail, fetch poll) all settle on the next frame.
  ///
  /// **Sign convention is anchor-relative**, the opposite of a Flutter
  /// `ScrollController.position.pixels` delta. When porting code from a
  /// `ListView` scroll listener, negate the value.
  ///
  /// **`scrollBy(0.0)` is a silent no-op** — listeners are not notified
  /// and `ChatProgrammaticScroll` is not emitted. If a consumer counts
  /// notifications, account for the zero short-circuit. Non-finite values
  /// (NaN / ±∞) are also dropped silently — they would otherwise poison
  /// the anchor for the rest of the controller's lifetime.
  ///
  /// To navigate to a specific message id use [jumpTo] or [animateTo]
  /// instead. To know "what's N viewport-heights away" the consumer needs
  /// the current viewport size, which the controller does not own — fold
  /// that into [pixels] at the call site.
  void scrollBy(double pixels) {
    if (_disposed) return;
    if (pixels == 0.0 || !pixels.isFinite) return;
    _anchorPixelOffset += pixels;
    for (final cb in List<ValueChanged<double>>.of(
      _scrollByListeners,
      growable: false,
    )) {
      cb(pixels);
    }
    _emitScroll(ChatProgrammaticScroll(pixels));
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
    if (_disposed) return;
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

  final _DeferredValueNotifier<ChatVisibleRange?> _visibleRange =
      _DeferredValueNotifier<ChatVisibleRange?>(null);

  /// Inclusive id range of currently-on-screen messages plus the active
  /// anchor id. `null` before the first layout has run (or when no message
  /// intersects the paint area). Push as the viewport scrolls / re-fans.
  ///
  /// **Listener safety**: pushes from `RenderChatScrollView` happen inside
  /// `performLayout`, where calling `setState` is illegal. The notifier
  /// auto-defers `notifyListeners()` to the end of the frame when the push
  /// lands during the `persistentCallbacks` phase — listeners that call
  /// `setState` (or `markNeedsLayout` on a parent) Just Work without having
  /// to wrap the callback in a `addPostFrameCallback` themselves.
  ValueListenable<ChatVisibleRange?> get visibleRange => _visibleRange;

  /// Viewport-only setter — `RenderChatScrollView` pushes the latest range
  /// after every layout / Tier-1 reposition. Safe to call from inside
  /// `performLayout`: the notification is deferred past the frame.
  @internal
  set visibleRange(ChatVisibleRange? value) {
    if (_disposed) return;
    _visibleRange.value = value;
  }

  // --- Tail tracking -------------------------------------------------------

  final _DeferredValueNotifier<bool> _isAtTail =
      _DeferredValueNotifier<bool>(false);

  /// Whether the *newest* known message is currently in the paint area and
  /// the data source has reported [ChatDataSource.reachedNewest]. `false`
  /// when the conversation has no boundary yet, the viewport is in overlay
  /// mode, or the user has scrolled away from the bottom.
  ///
  /// **Initial value is `false`.** The first push happens at the end of
  /// the first `performLayout`, so listeners attached in `initState` will
  /// observe a `false → true` transition on the next frame when the
  /// viewport is at the tail. UI built off the initial synchronous value
  /// (e.g. a new-messages pill in `initState`) will briefly show as if
  /// the user were *not* at the tail until the first layout runs.
  ///
  /// **Listener safety**: same contract as [visibleRange] — pushes from
  /// inside `performLayout` are deferred past the frame so listeners may
  /// call `setState` without an explicit post-frame trampoline.
  ///
  /// Drives the canonical "follow tail" UI patterns: hide a
  /// new-messages-pill when the user is already pinned to the newest, show
  /// it when they've scrolled away. A separate "messages since I left the
  /// tail" counter is the consumer's responsibility — derive it from this
  /// flag plus `dataSource.newestKnownId` so the controller stays
  /// decoupled from the data source.
  ValueListenable<bool> get isAtTail => _isAtTail;

  /// Viewport-only setter — `RenderChatScrollView` pushes after every
  /// layout / Tier-1 reposition. Safe to call from inside `performLayout`.
  @internal
  set isAtTail(bool value) {
    if (_disposed) return;
    _isAtTail.value = value;
  }

  // --- Scroll events -------------------------------------------------------

  /// `LinkedHashSet` — same dedup rationale as [_jumpListeners].
  final _scrollListeners = <ValueChanged<ChatScrollEvent>>{};

  /// Subscribe to typed scroll events ([ChatUserDragStart], [ChatFlingStart],
  /// [ChatProgrammaticJump], …). Adding the same callback twice is a no-op.
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
    if (_disposed) return;
    _anchorPixelOffset += delta;
  }

  /// Silently reassign anchor (no notification).
  /// Called by the viewport during anchor renormalization inside performLayout.
  @internal
  void reassignAnchor(int messageId, double pixelOffset) {
    if (_disposed) return;
    _anchorMessageId = messageId;
    _anchorPixelOffset = pixelOffset;
  }

  /// Whether [dispose] has been called. Exposed so callers that share a
  /// controller across short-lived widgets can guard against double-dispose.
  bool get isDisposed => _disposed;
  bool _disposed = false;

  /// Drop all listeners. Call from the owning widget's `dispose` so a stray
  /// late notification cannot reach a torn-down listener. Idempotent — safe
  /// to call twice.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _jumpListeners.clear();
    _scrollListeners.clear();
    _scrollByListeners.clear();
    // Drop the animator binding — a pending `await animator.animate(...)`
    // from a previous `animateTo` returning after dispose must not mutate
    // anchor state through a stale reference.
    _animator = null;
    _visibleRange.dispose();
    _isAtTail.dispose();
  }
}

/// `ValueNotifier` subclass that defers `notifyListeners()` to the end of the
/// current frame when its setter fires during the `persistentCallbacks`
/// scheduler phase (layout / paint). Outside that phase it behaves exactly
/// like a plain `ValueNotifier`.
///
/// Used for [ChatScrollController.isAtTail] and
/// [ChatScrollController.visibleRange]: `RenderChatScrollView` pushes both
/// from inside `performLayout`, where a synchronous `notifyListeners()` would
/// invite listeners to call `setState` mid-layout — illegal. Deferring the
/// notification lets listeners be naive consumers without each one having to
/// install a `addPostFrameCallback` trampoline.
///
/// Reads (`value` getter) are *not* deferred — they always return the latest
/// pushed value, including a write still pending notification. This keeps the
/// notifier consistent with the underlying viewport state: a render-side
/// equality short-circuit on `_controller.isAtTail.value == newValue` will
/// see the freshly-set value and skip the redundant deferred dispatch.
class _DeferredValueNotifier<T> extends ValueNotifier<T> {
  _DeferredValueNotifier(super.value);

  // Pending-write bookkeeping. `_pending` distinguishes "no pending write"
  // from "pending write whose new value is a typed null" — `_pendingValue`
  // alone cannot tell those apart when `T` itself is nullable
  // (e.g. `ChatVisibleRange?`).
  bool _pending = false;
  late T _pendingValue;
  bool _disposed = false;

  @override
  T get value => _pending ? _pendingValue : super.value;

  @override
  set value(T newValue) {
    if (_disposed) return;
    // Equality short-circuit against the *effective* value (pending or
    // committed). Otherwise a setter that lands inside performLayout
    // would schedule a post-frame even when the value hasn't moved.
    if (value == newValue) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      // First pending write of this frame: schedule the post-frame trampoline
      // that commits + notifies. Subsequent writes just overwrite the pending
      // value — only the final value of the frame is dispatched, matching how
      // a synchronous setter would behave without coalescing.
      final firstPending = !_pending;
      _pendingValue = newValue;
      _pending = true;
      if (firstPending) {
        SchedulerBinding.instance.addPostFrameCallback(_commitPending);
      }
    } else {
      _pending = false;
      super.value = newValue;
    }
  }

  void _commitPending(Duration _) {
    if (_disposed || !_pending) return;
    final committed = _pendingValue;
    _pending = false;
    // Drive notification through the base setter so [ValueNotifier]'s own
    // equality short-circuit and listener iteration apply unchanged.
    super.value = committed;
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = false;
    super.dispose();
  }
}
