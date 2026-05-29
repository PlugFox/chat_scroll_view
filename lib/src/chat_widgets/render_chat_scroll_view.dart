import 'dart:async';
import 'dart:collection';

import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_chunk.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_events.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scrollbar.dart';
import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:meta/meta.dart' show internal;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show ClampingScrollSimulation;

/// Parent data for a viewport child.
///
/// For a message: its [id], the [offset] of its top edge within the viewport
/// (viewport-local Y, may be negative), whether it [startsDay] (carries an
/// inline date divider), its [dayBucket] (day-grouping key, `null` until the
/// message loads), and the [dividerOpacity] of its inline date separator. The
/// floating day header reuses this type — only [offset] is meaningful for it.
class ChatMessageParentData extends ParentData {
  int id = 0;
  double offset = 0.0;
  bool startsDay = false;

  /// Group key (`DateTime`, record, string, anything equatable) — produced by
  /// the viewport's `groupBy` callback. `null` when the message has not loaded
  /// or grouping is disabled.
  Object? dayBucket;

  /// Fade opacity (0..1) for this message's inline date separator — set by
  /// `RenderChatScrollView` from [offset] so the separator fades out as it
  /// rises into the floating day header's zone. Only meaningful when
  /// [startsDay] is `true`; read by `RenderDatedMessage`.
  double dividerOpacity = 1.0;
}

/// Kind of full-viewport overlay the element is asked to build. Internal
/// contract between `RenderChatScrollView` and `ChatScrollElement`.
///
/// * `loading` — the data source has nothing yet ([ChatDataSource.isInitialLoading]).
/// * `empty` — the data source confirmed the conversation has no messages
///   ([ChatDataSource.isEmpty]).
/// * `none` — no overlay, the viewport is in normal fan-out mode (used to ask
///   the element to drop a previously-built overlay).
@internal
enum ChatOverlayKind { none, loading, empty }

/// Contract the render object uses to lazily inflate / dispose children.
///
/// Implemented by `ChatScrollElement` only. The render object calls the
/// build methods during `performLayout` (wrapped in `invokeLayoutCallback`)
/// and the remove methods to garbage-collect children outside the build
/// range. Public API consumers should never implement or call this directly.
@internal
abstract interface class ChatChildManager {
  /// Inflate or update the widget for message [id]; returns its render box.
  /// [startsNewDay] asks the element to prepend an inline date separator.
  RenderBox? buildChild(int id, {required bool startsNewDay});

  /// Deactivate the elements for [ids] that are no longer needed.
  void removeChildren(List<int> ids);

  /// Inflate / update / remove the floating day header for [date] (`null`
  /// removes it). Called during layout, the same channel as [buildChild].
  RenderBox? buildFloatingHeader(DateTime? date);

  /// Inflate or update the chunk-error tile for [chunkIndex]. Called when
  /// the chunk is in error state *and* a `chunkErrorBuilder` was supplied.
  RenderBox? buildChunkError(int chunkIndex, int firstId, int lastId);

  /// Deactivate chunk-error tiles for [chunkIndices] no longer in range.
  void removeChunkErrors(List<int> chunkIndices);

  /// Inflate / update / remove the full-viewport overlay (loading or empty).
  /// Pass [ChatOverlayKind.none] to drop the currently-built overlay.
  RenderBox? buildOverlay(ChatOverlayKind kind);
}

/// Widget-based endless chat viewport render object.
///
/// Children are real [RenderBox]es (each a `RepaintBoundary`), keyed by
/// message id in a sparse [SplayTreeMap]. Layout is anchor-based — children
/// are positioned around [ChatScrollController.anchorMessageId], never against
/// a global content height. Scrolling repositions children and calls
/// [markNeedsPaint] (no layout, no rebuild — Tier 1); the framework moves the
/// cached child layers.
class RenderChatScrollView extends RenderBox implements ChatScrollAnimator {
  RenderChatScrollView({
    required ChatDataSource dataSource,
    required ChatScrollController controller,
    required double cacheExtent,
    double extraBuildExtent = 0.0,
    bool ticking = true,
    bool reverse = false,
    ValueListenable<double>? bottomPadding,
    ValueListenable<double>? topPadding,
    Object Function(IChatMessage)? groupBy,
    bool hasErrorBuilder = false,
    bool hasEmptyBuilder = false,
    bool hasLoadingBuilder = false,
  }) : _dataSource = dataSource,
       _controller = controller,
       _cacheExtent = cacheExtent,
       _extraBuildExtent = extraBuildExtent,
       _ticking = ticking,
       _reverse = reverse,
       _bottomPadding = bottomPadding,
       _topPadding = topPadding,
       _groupBy = groupBy,
       _hasErrorBuilder = hasErrorBuilder,
       _hasEmptyBuilder = hasEmptyBuilder,
       _hasLoadingBuilder = hasLoadingBuilder;

  /// Set by `ChatScrollElement` in `mount`. Drives lazy child inflation.
  ChatChildManager? childManager;

  /// messageId -> message render box, sorted ascending (top-to-bottom).
  final SplayTreeMap<int, RenderBox> _children = SplayTreeMap<int, RenderBox>();

  /// chunkIndex -> chunk-error render box, sorted ascending. One tile per
  /// failed chunk in the build range. Kept separate from [_children] so a
  /// message at the chunk's first id (when the chunk just transitioned out
  /// of error) does not collide with the lingering chunk-error tile —
  /// distinct slot namespaces avoid silent overwrites in the render layer.
  final SplayTreeMap<int, RenderBox> _chunkErrors =
      SplayTreeMap<int, RenderBox>();

  // --- Configurable inputs ---------------------------------------------------

  ChatDataSource _dataSource;
  set dataSource(ChatDataSource value) {
    if (identical(_dataSource, value)) return;
    if (attached) {
      _dataSource
        ..removeDataListener(_onDataChanged)
        ..removeBoundaryListener(_onBoundaryChanged);
    }
    // The old data source's in-flight fetch (and any pending retry) refers to
    // chunks we no longer read — let it stop instead of resolving into an
    // orphan, and avoid a dangling Timer on detach.
    _dataSource.cancelFetch();
    _dataSource = value;
    if (attached) {
      _dataSource
        ..addDataListener(_onDataChanged)
        ..addBoundaryListener(_onBoundaryChanged);
    }
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  ChatScrollController _controller;
  set controller(ChatScrollController value) {
    if (identical(_controller, value)) return;
    if (attached) {
      _cancelAnimate();
      _controller
        ..removeJumpListener(_onJump)
        ..animator = null;
      _controller.visibleRange = null;
    }
    _controller = value;
    if (attached) {
      _controller
        ..addJumpListener(_onJump)
        ..animator = this;
    }
    markNeedsLayout();
  }

  double _cacheExtent;
  set cacheExtent(double value) {
    if (_cacheExtent == value) return;
    _cacheExtent = value;
    markNeedsLayout();
  }

  /// Extra pixels beyond [cacheExtent] that are still built — off-screen and
  /// paint-culled, but their elements (and any `State`) survive. Distance-based
  /// only; unrelated to the `KeepAlive` widget.
  double _extraBuildExtent;
  set extraBuildExtent(double value) {
    if (_extraBuildExtent == value) return;
    _extraBuildExtent = value;
    markNeedsLayout();
  }

  /// Whether the scroll [Ticker] is allowed to tick. Driven by `TickerMode`,
  /// so a viewport on an inactive route does not animate a fling off-screen.
  bool _ticking;
  set ticking(bool value) {
    if (_ticking == value) return;
    _ticking = value;
    _ticker?.muted = !value;
    if (!value) _cancelFling();
  }

  /// Whether to prefer pinning the *newest* message to the bottom edge when
  /// the conversation is short enough to fit in the viewport (`reverse:
  /// true`, chat-style). The default `false` is list-style: short content
  /// stacks at the top.
  bool _reverse;
  set reverse(bool value) {
    if (_reverse == value) return;
    _reverse = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  /// Empty space reserved after the newest message — compensation for bottom
  /// chrome stacked over the viewport (the composer, attachment previews,
  /// status strips). Reactive: when its value changes the viewport relayouts
  /// so the newest message keeps clearing whatever sits on top of it.
  ValueListenable<double>? _bottomPadding;
  set bottomPadding(ValueListenable<double>? value) {
    if (identical(_bottomPadding, value)) return;
    final oldValue = _bottomPad;
    if (attached) _bottomPadding?.removeListener(_onBottomPaddingChanged);
    _bottomPadding = value;
    if (attached) _bottomPadding?.addListener(_onBottomPaddingChanged);
    // Swapping the listenable is itself a value change when the new current
    // differs from the old one — re-pin the newest message so it follows the
    // inset, the same as `_onBottomPaddingChanged` would have done.
    if (oldValue != _bottomPad) _bottomPaddingDirty = true;
    markNeedsLayout();
  }

  double get _bottomPad => _bottomPadding?.value ?? 0.0;

  /// Set when [bottomPadding] changed; consumed by the next [performLayout]
  /// to re-pin the newest message when the viewport was sitting at the bottom.
  bool _bottomPaddingDirty = false;

  /// Empty space reserved at the *top* of the viewport — compensation for top
  /// chrome (an app bar). The floating day header rests just below it.
  ValueListenable<double>? _topPadding;
  set topPadding(ValueListenable<double>? value) {
    if (identical(_topPadding, value)) return;
    if (attached) _topPadding?.removeListener(_onTopPaddingChanged);
    _topPadding = value;
    if (attached) _topPadding?.addListener(_onTopPaddingChanged);
    markNeedsLayout();
  }

  double get _topPad => _topPadding?.value ?? 0.0;

  /// Groups messages into sections for the date separators / floating header.
  /// `null` turns the feature off entirely.
  Object Function(IChatMessage)? _groupBy;
  set groupBy(Object Function(IChatMessage)? value) {
    // `==` instead of `identical`: an instance-method tear-off
    // (`widget.someMethod`) is not necessarily identical across accesses but
    // *is* equal — so `identical` would force a relayout every parent rebuild
    // while `==` correctly recognises the unchanged callback.
    if (_groupBy == value) return;
    _groupBy = value;
    markNeedsLayout();
  }

  /// Whether the host widget exposes a chunk-error builder — drives the
  /// fan-out's "skip ids in errored chunks, build one error tile instead"
  /// branch. The builder itself lives on the widget; the element looks it
  /// up when [ChatChildManager.buildChunkError] is called.
  bool _hasErrorBuilder;
  set hasErrorBuilder(bool value) {
    if (_hasErrorBuilder == value) return;
    _hasErrorBuilder = value;
    markNeedsLayout();
  }

  /// Whether the host exposes an empty-state builder — drives the empty-mode
  /// overlay path in [performLayout].
  bool _hasEmptyBuilder;
  set hasEmptyBuilder(bool value) {
    if (_hasEmptyBuilder == value) return;
    _hasEmptyBuilder = value;
    markNeedsLayout();
  }

  /// Whether the host exposes an initial-loading builder — drives the
  /// loading-mode overlay path in [performLayout].
  bool _hasLoadingBuilder;
  set hasLoadingBuilder(bool value) {
    if (_hasLoadingBuilder == value) return;
    _hasLoadingBuilder = value;
    markNeedsLayout();
  }

  // --- Layout state ----------------------------------------------------------

  int _accessTick = 0;
  int _layoutMinChunk = 0;
  int _layoutMaxChunk = -1;

  /// Exponential moving average of the per-frame scroll delta (px/frame,
  /// signed). Positive = anchor moving down = revealing older messages.
  /// Drives the directional build-ahead lead.
  double _scrollVelocity = 0.0;
  static const double _leadFrames = 4.0;

  /// Floating-header height assumed for the inline-divider fade before the
  /// real header has been laid out (first frame only).
  static const double _kHeaderFallbackHeight = 32.0;

  /// Travel distance over which an inline date separator fades in / out near
  /// the floating header — short, so it reaches full opacity almost as soon as
  /// it clears the header.
  static const double _kDividerFadeBand = 20.0;

  // --- Ticker / scroll physics ----------------------------------------------

  Ticker? _ticker;
  double _pendingScrollDelta = 0.0;
  ClampingScrollSimulation? _simulation;

  /// Ticker `elapsed` at the first tick of the current fling, or `null`
  /// between flings. Nullable on purpose — a [Ticker]'s very first `elapsed`
  /// is exactly [Duration.zero], so zero cannot double as "unset".
  Duration? _flingStartTime;
  double _lastFlingValue = 0.0;

  VerticalDragGestureRecognizer? _drag;

  // --- animateTo state ------------------------------------------------------

  /// Active `animateTo`'s completer, or `null` when no animation is running.
  Completer<void>? _animateCompleter;

  /// Target id for the in-flight animation; for the close-target branch the
  /// anchor has already been reassigned to this id at the start.
  int _animateTargetId = 0;

  /// Anchor pixel offset at animation start (close path) or the fade window
  /// progress driver (far path).
  double _animateStartOffset = 0.0;
  double _animateEndOffset = 0.0;
  Duration? _animateStartTime;
  Duration _animateDuration = Duration.zero;
  Curve _animateCurve = Curves.linear;

  /// `true` while the far-target crossfade is active. Drives [paint]'s
  /// opacity wrap and the jumpTo at the fade midpoint.
  bool _farAnimateActive = false;
  bool _farAnimateJumped = false;

  /// Current fade opacity for far-target crossfade (1.0 → 0.0 → 1.0 across
  /// the animation duration). 1.0 when no far animation is in flight.
  double _fadeOpacity = 1.0;
  final LayerHandle<OpacityLayer> _fadeLayer = LayerHandle<OpacityLayer>();

  // --- Fetch poll ------------------------------------------------------------

  static const Duration _pollInterval = Duration(milliseconds: 150);
  Timer? _pollTimer;
  int _lastScrollTs = 0;

  // --- Scrollbar -------------------------------------------------------------

  final ChatScrollbar _scrollbar = ChatScrollbar();

  /// Retained clip layer — reused across repaints via `oldLayer`.
  final LayerHandle<ClipRectLayer> _clipLayer = LayerHandle<ClipRectLayer>();

  // --- Day separators --------------------------------------------------------

  /// The floating day header, pinned to the top — one extra child render box
  /// beyond the id-keyed messages. Built lazily during layout (like a message)
  /// by `ChatScrollElement`. `null` when day separators are off, or no day is
  /// known yet.
  RenderBox? _floatingHeader;
  set floatingHeader(RenderBox? value) {
    if (identical(_floatingHeader, value)) return;
    if (_floatingHeader != null) dropChild(_floatingHeader!);
    _floatingHeader = value;
    if (value != null) adoptChild(value);
  }

  // --- Full-viewport overlay (loading / empty) ------------------------------

  /// The single full-viewport overlay child (loading skeleton or empty state)
  /// or `null` when the viewport is in normal fan-out mode.
  RenderBox? _overlay;

  /// The kind of overlay currently built (matches [_overlay]'s identity); used
  /// to skip a redundant rebuild when the mode doesn't change.
  ChatOverlayKind _overlayKind = ChatOverlayKind.none;

  set overlay(RenderBox? value) {
    if (identical(_overlay, value)) return;
    if (_overlay != null) dropChild(_overlay!);
    _overlay = value;
    if (value != null) adoptChild(value);
  }

  /// Group bucket the floating header was last built for; `null` = none.
  /// The header is rebuilt only when the topmost visible group changes.
  Object? _headerBucket;

  /// Date the header currently shows — for debugging / introspection.
  DateTime? _headerDate;

  /// Set when the header must rebuild regardless of the day (its builder
  /// reference changed). Consumed by the next [performLayout].
  bool _headerDirty = false;

  /// Force the floating header to rebuild on the next layout — used when its
  /// builder reference changes, which the day-bucket gate cannot detect.
  void invalidateFloatingHeader() {
    _headerDirty = true;
    markNeedsLayout();
  }

  // --- Scroll semantics state -----------------------------------------------

  bool _canRevealOlder = false;
  bool _canRevealNewer = false;

  // --- Debug instrumentation (zero-cost in release via assert) --------------

  final Stopwatch _debugSw = Stopwatch();
  Duration debugLastLayoutDuration = Duration.zero;
  Duration debugLastPaintDuration = Duration.zero;
  int debugLayoutFrameId = 0;
  int debugPaintFrameId = 0;

  int get debugChildCount => _children.length;
  int get debugChunkErrorCount => _chunkErrors.length;
  int get debugChunkCount => _dataSource.chunks.length;
  int get debugLayoutMinChunk => _layoutMinChunk;
  int get debugLayoutMaxChunk => _layoutMaxChunk;
  int? get debugFirstId => _children.isEmpty ? null : _children.firstKey();
  int? get debugLastId => _children.isEmpty ? null : _children.lastKey();
  bool get debugHasFloatingHeader => _floatingHeader != null;
  double? get debugFloatingHeaderOffset =>
      _floatingHeader == null ? null : _parentData(_floatingHeader!).offset;
  DateTime? get debugHeaderDate => _headerDate;

  /// Inline-divider fade opacity (0..1) of the built child [id], or `null`
  /// when [id] is not currently built.
  double? debugDividerOpacity(int id) {
    final child = _children[id];
    return child == null ? null : _parentData(child).dividerOpacity;
  }

  // --- RenderBox configuration ----------------------------------------------

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ChatMessageParentData) {
      child.parentData = ChatMessageParentData();
    }
  }

  ChatMessageParentData _parentData(RenderBox child) =>
      child.parentData! as ChatMessageParentData;

  // --- Child management (called by ChatScrollElement) -----------------------

  /// Adopt [child] for message [id]. Called via `insertRenderObjectChild`.
  void insertChild(RenderBox child, int id) {
    _children[id] = child;
    adoptChild(child);
    _parentData(child).id = id;
  }

  /// Drop the child for message [id]. Called via `removeRenderObjectChild`.
  void removeChild(int id) {
    final child = _children.remove(id);
    if (child == null) return;
    dropChild(child);
  }

  /// Adopt a chunk-error tile for [chunkIndex]. Kept in a separate map from
  /// message tiles so a frame that flips a chunk from errored → valid (or
  /// vice versa) can coexist a chunk-error tile and a message at the same
  /// position id without overwriting either side's render box.
  void insertChunkError(RenderBox child, int chunkIndex) {
    _chunkErrors[chunkIndex] = child;
    adoptChild(child);
    _parentData(child).id = ChatScrollChunk.firstIdOf(chunkIndex);
  }

  /// Drop the chunk-error tile for [chunkIndex].
  void removeChunkError(int chunkIndex) {
    final child = _chunkErrors.remove(chunkIndex);
    if (child == null) return;
    dropChild(child);
  }

  // --- RenderObject lifecycle -----------------------------------------------

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    for (final child in _children.values) {
      child.attach(owner);
    }
    for (final child in _chunkErrors.values) {
      child.attach(owner);
    }
    _floatingHeader?.attach(owner);
    _overlay?.attach(owner);
    _ticker = Ticker(_onTick)..muted = !_ticking;
    _dataSource
      ..addDataListener(_onDataChanged)
      ..addBoundaryListener(_onBoundaryChanged);
    _controller
      ..addJumpListener(_onJump)
      ..animator = this;
    _bottomPadding?.addListener(_onBottomPaddingChanged);
    _topPadding?.addListener(_onTopPaddingChanged);
    _drag = VerticalDragGestureRecognizer()
      ..onStart = _onDragStart
      ..onUpdate = _onDragUpdate
      ..onEnd = _onDragEnd;
  }

  @override
  void detach() {
    _cancelFling();
    _ticker?.dispose();
    _ticker = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    // Drop our listener first — cancelFetch notifies, and a `markNeedsLayout`
    // on a detaching render object is brittle even if currently harmless.
    _dataSource
      ..removeDataListener(_onDataChanged)
      ..removeBoundaryListener(_onBoundaryChanged);
    _dataSource.cancelFetch();
    _controller
      ..removeJumpListener(_onJump)
      ..animator = null
      // Mirror the controller-swap path: once no viewport is bound, the
      // last-published range no longer reflects anything observable.
      ..visibleRange = null;
    _cancelAnimate();
    _bottomPadding?.removeListener(_onBottomPaddingChanged);
    _topPadding?.removeListener(_onTopPaddingChanged);
    _drag?.dispose();
    _drag = null;
    super.detach();
    // Detach children after super: `this` is now detached, so each child's
    // `attached == parent.attached` invariant holds during child.detach().
    for (final child in _children.values) {
      child.detach();
    }
    for (final child in _chunkErrors.values) {
      child.detach();
    }
    _floatingHeader?.detach();
    _overlay?.detach();
  }

  @override
  void redepthChildren() {
    for (final child in _children.values) {
      redepthChild(child);
    }
    for (final child in _chunkErrors.values) {
      redepthChild(child);
    }
    final header = _floatingHeader;
    if (header != null) redepthChild(header);
    final overlay = _overlay;
    if (overlay != null) redepthChild(overlay);
  }

  @override
  void visitChildren(RenderObjectVisitor visitor) {
    for (final child in _children.values) {
      visitor(child);
    }
    for (final child in _chunkErrors.values) {
      visitor(child);
    }
    final header = _floatingHeader;
    if (header != null) visitor(header);
    final overlay = _overlay;
    if (overlay != null) visitor(overlay);
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    final pd = child.parentData! as ChatMessageParentData;
    transform.translateByDouble(0, pd.offset, 0, 1);
  }

  // --- Typed listeners -------------------------------------------------------

  void _onDataChanged() => markNeedsLayout();

  void _onBottomPaddingChanged() {
    _bottomPaddingDirty = true;
    markNeedsLayout();
  }

  void _onTopPaddingChanged() => markNeedsLayout();

  void _onJump(int messageId) {
    _cancelFling();
    markNeedsLayout();
  }

  void _onBoundaryChanged() {
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  // --- Layout ----------------------------------------------------------------

  @override
  void performLayout() {
    assert(() {
      _debugSw
        ..reset()
        ..start();
      return true;
    }());
    assert(childManager != null, 'childManager not wired by ChatScrollElement');
    assert(
      constraints.hasBoundedHeight && constraints.hasBoundedWidth,
      'RenderChatScrollView needs bounded constraints; got $constraints. '
      'Give it a finite size — wrap it in an Expanded, a sized SizedBox, or '
      'Positioned.fill.',
    );

    // Mode selection.
    //
    // * Empty wins over loading: a confirmed-empty conversation is terminal,
    //   while initial-loading is unknown — if both flip true simultaneously
    //   (a fetch resolves with `[]` and seeds the empty boundary), we want
    //   the empty UI immediately, not a skeleton.
    // * An empty conversation always skips the message fan-out, even when
    //   no `emptyBuilder` is wired: there are no ids to build, so shimmer
    //   placeholders for negative / large ids would be wrong.
    final ChatOverlayKind overlayKind;
    if (_dataSource.isEmpty) {
      overlayKind = _hasEmptyBuilder
          ? ChatOverlayKind.empty
          : ChatOverlayKind.none;
    } else if (_hasLoadingBuilder && _dataSource.isInitialLoading) {
      overlayKind = ChatOverlayKind.loading;
    } else {
      overlayKind = ChatOverlayKind.none;
    }

    if (_dataSource.isEmpty || overlayKind != ChatOverlayKind.none) {
      _layoutOverlayMode(overlayKind);
      assert(() {
        debugLastLayoutDuration = _debugSw.elapsed;
        _debugSw.stop();
        debugLayoutFrameId++;
        return true;
      }());
      return;
    }

    // Normal mode: drop a previously-built overlay before fanning out.
    if (_overlayKind != ChatOverlayKind.none || _overlay != null) {
      invokeLayoutCallback<BoxConstraints>((_) {
        childManager!.buildOverlay(ChatOverlayKind.none);
      });
      _overlayKind = ChatOverlayKind.none;
    }

    // Children span the full viewport width; each message widget centers its
    // own content column. A full-width child lets selection chrome tint the
    // whole row without bleeding past a narrower content box.
    final childConstraints = BoxConstraints.tightFor(width: size.width);

    final built = <int>{};
    final builtChunks = <int>{};
    _layoutFromAnchor(childConstraints, built, builtChunks);

    final anchorBefore = _controller.anchorMessageId;
    _renormalizeAnchor();
    // When the bottom inset changed while the viewport was pinned at the
    // newest message, let the clamp carry the content along with the inset.
    final repinBottom =
        _bottomPaddingDirty && _dataSource.reachedNewest && !_canRevealNewer;
    _bottomPaddingDirty = false;
    final clamped = _clampBoundaries(repinBottom: repinBottom);
    if (clamped) _cancelFling();

    // Re-fan from the corrected anchor. When pass 1 ran with the anchor far
    // off-screen it builds every message between the anchor and the viewport;
    // re-fanning from the renormalized (visible) anchor yields the tight set,
    // so the off-screen extras fall outside `built` and are collected below.
    if (clamped || _controller.anchorMessageId != anchorBefore) {
      built.clear();
      builtChunks.clear();
      _layoutFromAnchor(childConstraints, built, builtChunks);
    }

    // Garbage-collect children outside the build range. Messages and chunk-
    // error tiles travel through separate element-side channels.
    final staleMessages = <int>[
      for (final id in _children.keys)
        if (!built.contains(id)) id,
    ];
    final staleErrorChunks = <int>[
      for (final ci in _chunkErrors.keys)
        if (!builtChunks.contains(ci)) ci,
    ];
    if (staleMessages.isNotEmpty || staleErrorChunks.isNotEmpty) {
      invokeLayoutCallback<BoxConstraints>((_) {
        if (staleMessages.isNotEmpty) {
          childManager!.removeChildren(staleMessages);
        }
        if (staleErrorChunks.isNotEmpty) {
          childManager!.removeChunkErrors(staleErrorChunks);
        }
      });
    }

    // Track the laid-out chunk range (for fetch + eviction). Messages and
    // chunk-error tiles together span the visible chunks — collapse both
    // through `chunkOf` to find the inclusive range.
    if (_children.isEmpty && _chunkErrors.isEmpty) {
      _layoutMinChunk = 0;
      _layoutMaxChunk = -1;
    } else {
      var minChunk = _children.isEmpty
          ? _chunkErrors.firstKey()!
          : ChatScrollChunk.chunkOf(_children.firstKey()!);
      var maxChunk = _children.isEmpty
          ? _chunkErrors.lastKey()!
          : ChatScrollChunk.chunkOf(_children.lastKey()!);
      if (_chunkErrors.isNotEmpty) {
        final eMin = _chunkErrors.firstKey()!;
        final eMax = _chunkErrors.lastKey()!;
        if (eMin < minChunk) minChunk = eMin;
        if (eMax > maxChunk) maxChunk = eMax;
      }
      _layoutMinChunk = minChunk;
      _layoutMaxChunk = maxChunk;
    }
    _evictChunks();
    _updateScrollSemantics();
    _publishVisibleRange();
    _scheduleFetchPoll();
    _updateFloatingHeader();

    assert(() {
      debugLastLayoutDuration = _debugSw.elapsed;
      _debugSw.stop();
      debugLayoutFrameId++;
      return true;
    }());
  }

  /// Run a layout pass in overlay mode: drop the message fan-out, build a
  /// single full-viewport child, place it at (0,0). Message tiles, chunk-
  /// error tiles, and the floating day header are all GC'd.
  void _layoutOverlayMode(ChatOverlayKind kind) {
    final staleMessages = _children.keys.toList();
    final staleErrorChunks = _chunkErrors.keys.toList();

    invokeLayoutCallback<BoxConstraints>((_) {
      if (staleMessages.isNotEmpty) {
        childManager!.removeChildren(staleMessages);
      }
      if (staleErrorChunks.isNotEmpty) {
        childManager!.removeChunkErrors(staleErrorChunks);
      }
      if (_floatingHeader != null) {
        childManager!.buildFloatingHeader(null);
      }
      if (_overlayKind != kind) {
        childManager!.buildOverlay(kind);
      }
    });
    _overlayKind = kind;

    final overlay = _overlay;
    if (overlay != null) {
      overlay.layout(BoxConstraints.tight(size), parentUsesSize: false);
      _parentData(overlay).offset = 0.0;
    }

    _layoutMinChunk = 0;
    _layoutMaxChunk = -1;
    _headerBucket = null;
    _headerDate = null;
    _headerDirty = false;
    _scrollVelocity = 0.0;
    _bottomPaddingDirty = false;
    _pendingScrollDelta = 0.0;
    _cancelFling();
    _cancelAnimate();
    // An active drag survives a hit-test entry if the gesture arena already
    // assigned the pointer to our recognizer. handleEvent's overlay-mode
    // guard only blocks *new* pointers — the recognizer will keep dispatching
    // onUpdate for the already-tracked pointer, mutating the anchor while
    // the overlay paints. Re-creating the recognizer drops the active
    // tracking without affecting future drag setup in normal mode.
    if (_drag != null) {
      _drag!.dispose();
      _drag = VerticalDragGestureRecognizer()
        ..onStart = _onDragStart
        ..onUpdate = _onDragUpdate
        ..onEnd = _onDragEnd;
    }
    _ticker?.stop();
    _evictChunks();
    _updateScrollSemantics();
    _publishVisibleRange();
    _scheduleFetchPoll();
  }

  /// Build + lay out + position children fanning out from the anchor, in a
  /// single `invokeLayoutCallback` (lazy inflation is legal during layout
  /// only inside such a callback).
  void _layoutFromAnchor(
    BoxConstraints cc,
    Set<int> built,
    Set<int> builtChunks,
  ) {
    invokeLayoutCallback<BoxConstraints>(
      (_) => _fanOutFromAnchor(cc, built, builtChunks),
    );
  }

  void _fanOutFromAnchor(
    BoxConstraints cc,
    Set<int> built,
    Set<int> builtChunks,
  ) {
    final anchorId = _controller.anchorMessageId;
    final oldest = _dataSource.oldestKnownId;
    final newest = _dataSource.newestKnownId;

    // Build zone = cacheExtent + keep-alive band, plus a directional lead
    // biased toward travel so a fast fling does not outrun the built range.
    final base = _cacheExtent + _extraBuildExtent;
    final lead = (_scrollVelocity.abs() * _leadFrames).clamp(0.0, size.height);
    final topExtent = base + (_scrollVelocity > 0 ? lead : 0.0);
    final bottomExtent = base + (_scrollVelocity < 0 ? lead : 0.0);
    final lowerBound = size.height + bottomExtent;
    final topBound = -topExtent;

    // Anchor: chunk-error tile when the anchor's chunk failed and a builder
    // was supplied; the actual message otherwise. The anchor's "size" then
    // determines where downward fan-out begins.
    //
    // No fallback to `_buildMessage` on a null chunk-error build: the chunk
    // is errored, so 64 per-message slots would surface `status.isError`
    // through `messageBuilder` — a one-frame flash of the very UI the
    // chunk-error builder was wired to replace. Bail and let the next layout
    // (after the builder swap settles) place the right tile.
    final anchorChunkIndex = ChatScrollChunk.chunkOf(anchorId);
    final RenderBox? anchor;
    final bool anchorIsError;
    if (_isChunkErrored(anchorChunkIndex)) {
      anchor = _buildChunkError(anchorChunkIndex, cc);
      anchorIsError = anchor != null;
      if (anchor == null) return;
    } else {
      anchor = _buildMessage(anchorId, cc);
      anchorIsError = false;
      if (anchor == null) return;
    }
    final anchorTop = _controller.anchorPixelOffset;
    _setOffset(anchor, anchorTop);
    if (anchorIsError) {
      builtChunks.add(anchorChunkIndex);
    } else {
      built.add(anchorId);
    }

    // Fan downward (newer messages).
    var y = anchorTop + anchor.size.height;
    var id = anchorIsError
        ? ChatScrollChunk.firstIdOf(anchorChunkIndex + 1)
        : anchorId + 1;
    while (y < lowerBound && (newest == null || id <= newest)) {
      final chunkIndex = ChatScrollChunk.chunkOf(id);
      if (_isChunkErrored(chunkIndex)) {
        final tile = _buildChunkError(chunkIndex, cc);
        if (tile == null) break;
        _setOffset(tile, y);
        builtChunks.add(chunkIndex);
        y += tile.size.height;
        id = ChatScrollChunk.firstIdOf(chunkIndex + 1);
        continue;
      }
      final child = _buildMessage(id, cc);
      if (child == null) break;
      _setOffset(child, y);
      built.add(id);
      y += child.size.height;
      id++;
    }

    // Fan upward (older messages).
    y = anchorTop;
    id = anchorIsError
        ? ChatScrollChunk.firstIdOf(anchorChunkIndex) - 1
        : anchorId - 1;
    while (y > topBound && (oldest == null || id >= oldest)) {
      final chunkIndex = ChatScrollChunk.chunkOf(id);
      if (_isChunkErrored(chunkIndex)) {
        final tile = _buildChunkError(chunkIndex, cc);
        if (tile == null) break;
        y -= tile.size.height;
        _setOffset(tile, y);
        builtChunks.add(chunkIndex);
        id = ChatScrollChunk.firstIdOf(chunkIndex) - 1;
        continue;
      }
      final child = _buildMessage(id, cc);
      if (child == null) break;
      y -= child.size.height;
      _setOffset(child, y);
      built.add(id);
      id--;
    }
  }

  /// Build, lay out, and tag one message child. Stores its day-grouping info
  /// (`startsDay` / `dayBucket`) in parent data so the per-frame header walk is
  /// a pure field read. The caller sets [ChatMessageParentData.offset].
  RenderBox? _buildMessage(int id, BoxConstraints cc) {
    final bucket = _bucketOf(id);
    final startsDay = _startsDay(id, bucket);
    final child = childManager!.buildChild(id, startsNewDay: startsDay);
    if (child == null) return null;
    child.layout(cc, parentUsesSize: true);
    _touchChunk(id);
    _parentData(child)
      ..startsDay = startsDay
      ..dayBucket = bucket;
    return child;
  }

  /// Build and lay out a chunk-error tile — one widget standing in for the
  /// entire chunk. Stored in `_chunkErrors` keyed by chunk index. Returns
  /// `null` when the element declines to build it (e.g. host removed the
  /// errorBuilder mid-flight).
  RenderBox? _buildChunkError(int chunkIndex, BoxConstraints cc) {
    final firstId = ChatScrollChunk.firstIdOf(chunkIndex);
    final lastId = firstId + ChatScrollChunk.kSize - 1;
    final tile = childManager!.buildChunkError(chunkIndex, firstId, lastId);
    if (tile == null) return null;
    tile.layout(cc, parentUsesSize: true);
    _touchChunk(firstId);
    _parentData(tile)
      ..startsDay = false
      ..dayBucket = null;
    return tile;
  }

  /// Whether [chunkIndex] is in error state *and* an error builder is wired
  /// — i.e., the chunk should be represented by a single chunk-error tile
  /// instead of 64 per-message slots.
  bool _isChunkErrored(int chunkIndex) {
    if (!_hasErrorBuilder) return false;
    final chunk = _dataSource.chunks[chunkIndex];
    return chunk != null && chunk.status.isError;
  }

  /// Resolve the render box currently positioned at `anchorMessageId`: the
  /// message tile if its chunk is normal, the chunk-error tile if its chunk
  /// failed. Returns `null` when neither is built yet (first frame, between
  /// fetches, …).
  ({RenderBox box, bool isChunkError})? _resolveAnchorBox() {
    final anchorId = _controller.anchorMessageId;
    // Fast path for the dominant valid-data-only case: skip the
    // chunk-error map lookup entirely when no chunk has errored.
    if (_chunkErrors.isEmpty) {
      final msg = _children[anchorId];
      return msg == null ? null : (box: msg, isChunkError: false);
    }
    final anchorChunkIndex = ChatScrollChunk.chunkOf(anchorId);
    final errorTile = _chunkErrors[anchorChunkIndex];
    if (errorTile != null) {
      return (box: errorTile, isChunkError: true);
    }
    final msg = _children[anchorId];
    if (msg != null) return (box: msg, isChunkError: false);
    return null;
  }

  /// Group key for [id], or `null` when its message is not loaded (or
  /// grouping is disabled).
  Object? _bucketOf(int id) {
    final groupBy = _groupBy;
    if (groupBy == null) return null;
    final message = _dataSource.getMessage(id);
    return message == null ? null : groupBy(message);
  }

  /// Whether message [id] is the first of its group — and so carries an
  /// inline date separator. Needs [id] and its predecessor loaded; until then
  /// returns `false`, so the separator appears once the data arrives.
  bool _startsDay(int id, Object? bucket) {
    if (bucket == null) return false;
    final oldest = _dataSource.oldestKnownId;
    if (_dataSource.reachedOldest && oldest != null && id <= oldest) {
      return true; // the very first message of the conversation
    }
    final prevBucket = _bucketOf(id - 1);
    if (prevBucket == null) return false;
    return prevBucket != bucket;
  }

  void _touchChunk(int id) {
    final chunk = _dataSource.chunks[ChatScrollChunk.chunkOf(id)];
    if (chunk != null) chunk.lastAccessTick = ++_accessTick;
  }

  /// If the anchor message drifted beyond the cache extent, silently re-base
  /// the anchor onto the first visible child (no visual change). The anchor
  /// may already be a chunk-error tile — picked up via [_resolveAnchorBox].
  void _renormalizeAnchor() {
    final resolved = _resolveAnchorBox();
    if (resolved == null) return;
    final anchor = resolved.box;
    final pd = _parentData(anchor);
    final top = pd.offset;
    final bottom = top + anchor.size.height;
    if (bottom >= -_cacheExtent && top <= size.height + _cacheExtent) return;

    // Find the topmost visible child — messages and chunk-error tiles share
    // viewport space, walk both and pick the smallest-offset candidate whose
    // bottom is still on screen.
    int? bestId;
    double bestOffset = double.infinity;
    for (final entry in _children.entries) {
      final cpd = _parentData(entry.value);
      if (cpd.offset + entry.value.size.height > 0 &&
          cpd.offset < bestOffset) {
        bestId = entry.key;
        bestOffset = cpd.offset;
      }
    }
    for (final entry in _chunkErrors.entries) {
      final cpd = _parentData(entry.value);
      if (cpd.offset + entry.value.size.height > 0 &&
          cpd.offset < bestOffset) {
        // Reassign to the chunk's first id — the next fan-out will detect
        // the chunk-error tile via `_isChunkErrored`.
        bestId = ChatScrollChunk.firstIdOf(entry.key);
        bestOffset = cpd.offset;
      }
    }
    if (bestId != null) {
      _controller.reassignAnchor(bestId, bestOffset);
    }
  }

  /// Pin content to the viewport edges at conversation boundaries.
  /// Returns `true` if a boundary was hit (fling should cancel).
  ///
  /// [repinBottom] also pulls the newest message *up* onto the bottom edge —
  /// used when the reserved bottom inset grew while the viewport was pinned
  /// there, so the message follows the inset instead of being covered.
  ///
  /// The two pins (newest-to-bottom, oldest-to-top) compete when the entire
  /// conversation fits in the viewport — whichever runs last "wins". In
  /// `reverse: false` (list-style) the oldest-pin runs last so short content
  /// stacks at the top; in `reverse: true` (chat-style) the newest-pin runs
  /// last so short content stacks at the bottom.
  /// Find the render box for a boundary id (oldest / newest). When the id's
  /// chunk is in error mode, the boundary visually lives at the chunk-error
  /// tile rather than at a (missing) message slot, so pinning anchors there.
  RenderBox? _boundaryBox(int id) {
    final tile = _chunkErrors[ChatScrollChunk.chunkOf(id)];
    if (tile != null) return tile;
    return _children[id];
  }

  bool _clampBoundaries({bool repinBottom = false}) {
    var cancelFling = false;
    bool pinNewest() {
      final newest = _dataSource.newestKnownId;
      if (!_dataSource.reachedNewest || newest == null) return false;
      final last = _boundaryBox(newest);
      if (last == null) return false;
      final bottom = _parentData(last).offset + last.size.height;
      // Pin the newest message above the reserved bottom inset (composer,
      // attachment previews, …) instead of against the viewport edge.
      final bottomEdge = size.height - _bottomPad;
      if (bottom < bottomEdge || (repinBottom && bottom > bottomEdge)) {
        _controller.applyScrollDelta(bottomEdge - bottom);
        _repositionFromAnchor();
        return true;
      }
      return false;
    }

    bool pinOldest() {
      final oldest = _dataSource.oldestKnownId;
      if (!_dataSource.reachedOldest || oldest == null) return false;
      final first = _boundaryBox(oldest);
      if (first == null) return false;
      final topY = _parentData(first).offset;
      if (topY > 0) {
        _controller.applyScrollDelta(-topY);
        _repositionFromAnchor();
        return true;
      }
      return false;
    }

    if (_reverse) {
      cancelFling = pinOldest() || cancelFling;
      cancelFling = pinNewest() || cancelFling;
    } else {
      cancelFling = pinNewest() || cancelFling;
      cancelFling = pinOldest() || cancelFling;
    }
    return cancelFling;
  }

  /// Recompute every child's [ChatMessageParentData.offset] from the anchor
  /// without rebuilding or re-laying-out. O(visible children).
  ///
  /// Walks message tiles id by id and jumps over a whole chunk whenever a
  /// chunk-error tile is encountered — chunk-error tiles live at
  /// `firstIdOf(chunkIndex)` with their entire chunk's ids unrepresented.
  void _repositionFromAnchor() {
    final resolved = _resolveAnchorBox();
    if (resolved == null) return;
    final anchor = resolved.box;
    // Tier-1 hot path: when no chunk errored, drop every per-id chunk-error
    // probe and walk the message map alone (the original O(visible) loop).
    if (_chunkErrors.isEmpty) {
      _repositionMessagesOnly(anchor);
      return;
    }

    final anchorIsError = resolved.isChunkError;
    final anchorChunkIndex = ChatScrollChunk.chunkOf(
      _controller.anchorMessageId,
    );

    var y = _controller.anchorPixelOffset;
    _setOffset(anchor, y);

    // Walk downward (toward newer ids).
    y += anchor.size.height;
    var id = anchorIsError
        ? ChatScrollChunk.firstIdOf(anchorChunkIndex + 1)
        : _controller.anchorMessageId + 1;
    while (true) {
      final ci = ChatScrollChunk.chunkOf(id);
      // At a chunk boundary, a chunk-error tile pre-empts message slots.
      if (id == ChatScrollChunk.firstIdOf(ci)) {
        final tile = _chunkErrors[ci];
        if (tile != null) {
          _setOffset(tile, y);
          y += tile.size.height;
          id = ChatScrollChunk.firstIdOf(ci + 1);
          continue;
        }
      }
      final child = _children[id];
      if (child == null) break;
      _setOffset(child, y);
      y += child.size.height;
      id++;
    }

    // Walk upward (toward older ids).
    y = _controller.anchorPixelOffset;
    id = anchorIsError
        ? ChatScrollChunk.firstIdOf(anchorChunkIndex) - 1
        : _controller.anchorMessageId - 1;
    while (true) {
      final ci = ChatScrollChunk.chunkOf(id);
      final lastIdOfChunk = ChatScrollChunk.firstIdOf(ci + 1) - 1;
      if (id == lastIdOfChunk) {
        final tile = _chunkErrors[ci];
        if (tile != null) {
          y -= tile.size.height;
          _setOffset(tile, y);
          id = ChatScrollChunk.firstIdOf(ci) - 1;
          continue;
        }
      }
      final child = _children[id];
      if (child == null) break;
      y -= child.size.height;
      _setOffset(child, y);
      id--;
    }
  }

  /// Tier-1 fast path: only message tiles. Avoids the per-id chunk-error
  /// boundary probe and tree lookup that the general path performs.
  void _repositionMessagesOnly(RenderBox anchor) {
    final anchorId = _controller.anchorMessageId;
    var y = _controller.anchorPixelOffset;
    _setOffset(anchor, y);
    y += anchor.size.height;
    for (var id = anchorId + 1; ; id++) {
      final child = _children[id];
      if (child == null) break;
      _setOffset(child, y);
      y += child.size.height;
    }
    y = _controller.anchorPixelOffset;
    for (var id = anchorId - 1; ; id--) {
      final child = _children[id];
      if (child == null) break;
      y -= child.size.height;
      _setOffset(child, y);
    }
  }

  /// LRU-evict data chunks outside the laid-out range.
  void _evictChunks() {
    final chunks = _dataSource.chunks;
    final maxChunks = _dataSource.maxChunks;
    while (chunks.length > maxChunks) {
      ChatScrollChunk? oldest;
      for (final chunk in chunks.values) {
        if (chunk.index >= _layoutMinChunk && chunk.index <= _layoutMaxChunk) {
          continue;
        }
        if (oldest == null || chunk.lastAccessTick < oldest.lastAccessTick) {
          oldest = chunk;
        }
      }
      if (oldest == null) break;
      chunks.remove(oldest.index);
    }
  }

  // --- Day separators --------------------------------------------------------

  /// Set a child's viewport [offset]. For a day-starting message it also
  /// refreshes the inline separator's fade opacity from the new position —
  /// pure parent-data writes, so this stays on the Tier-1 path.
  void _setOffset(RenderBox child, double offset) {
    final pd = _parentData(child);
    pd.offset = offset;
    if (pd.startsDay) pd.dividerOpacity = _dividerOpacityFor(offset);
  }

  /// Height of the floating header — its laid-out size, or a fallback before
  /// it has first laid out.
  double get _floatingHeaderHeight {
    final header = _floatingHeader;
    return (header != null && header.hasSize)
        ? header.size.height
        : _kHeaderFallbackHeight;
  }

  /// Fade opacity for an inline date separator whose top edge sits at
  /// viewport-Y [topY]. Reaches full as soon as the separator clears the
  /// floating header's bottom edge, fading over a short [_kDividerFadeBand] as
  /// it rises into the header's zone — so the two never both show.
  double _dividerOpacityFor(double topY) {
    final fadeEnd = _topPad + _floatingHeaderHeight;
    return ((topY - fadeEnd) / _kDividerFadeBand + 1.0).clamp(0.0, 1.0);
  }

  /// The topmost visible group — the bucket + message id of the first child
  /// crossing the top edge. O(visible children) of pure parent-data reads.
  ({Object? bucket, int? id}) _scanTopDay() {
    final topEdge = _topPad;
    final viewportHeight = size.height;
    for (final entry in _children.entries) {
      final child = entry.value;
      final pd = _parentData(child);
      if (pd.offset + child.size.height <= topEdge) continue; // above the top
      if (pd.offset >= viewportHeight) break; // below the viewport
      if (pd.dayBucket != null) return (bucket: pd.dayBucket, id: entry.key);
    }
    return (bucket: null, id: null);
  }

  /// Rebuild (only on a group change), lay out, and pin the floating header.
  /// Called from [performLayout].
  void _updateFloatingHeader() {
    final scan = _scanTopDay();
    final targetBucket = _groupBy == null ? null : scan.bucket;

    // Rebuild the header widget only when the group it shows changes (or its
    // builder changed). Building during layout is legal inside a callback.
    if (targetBucket != _headerBucket || _headerDirty) {
      _headerBucket = targetBucket;
      _headerDirty = false;
      _headerDate = (targetBucket == null || scan.id == null)
          ? null
          : _dataSource.getMessage(scan.id!)?.createdAt;
      final date = _headerDate;
      invokeLayoutCallback<BoxConstraints>((_) {
        childManager!.buildFloatingHeader(date);
      });
    }

    final header = _floatingHeader;
    if (header == null) return;
    header.layout(
      BoxConstraints.tightFor(width: size.width),
      parentUsesSize: true,
    );
    _placeFloatingHeader();
  }

  /// During a Tier-1 scroll: re-pin the header and report whether the topmost
  /// day changed — the caller then relayouts to rebuild the header text.
  bool _tickFloatingHeader() {
    if (_floatingHeader == null && _groupBy == null) return false;
    final scan = _scanTopDay();
    _placeFloatingHeader();
    final targetBucket = _groupBy == null ? null : scan.bucket;
    return targetBucket != _headerBucket;
  }

  /// Pin the floating header just below the top inset. It never moves with the
  /// scroll — inline separators fade out before they reach it, so there is
  /// nothing to push it.
  void _placeFloatingHeader() {
    final header = _floatingHeader;
    if (header != null) _parentData(header).offset = _topPad;
  }

  // --- Scroll ----------------------------------------------------------------

  void _markScrollActive() =>
      _lastScrollTs = DateTime.now().millisecondsSinceEpoch;

  void _ensureTicker() {
    final ticker = _ticker;
    if (ticker != null && !ticker.isActive) ticker.start();
  }

  void _stopTickerIfIdle() {
    if (_simulation == null && _pendingScrollDelta == 0.0) {
      _ticker?.stop();
      // Scroll ended — drop the directional lead so the next layout re-fans
      // a symmetric range and collects the now-unneeded lead children.
      if (_scrollVelocity != 0.0) {
        _scrollVelocity = 0.0;
        markNeedsLayout();
      }
    }
  }

  void _startFling(double velocity) {
    _cancelFling();
    _simulation = ClampingScrollSimulation(position: 0.0, velocity: velocity);
    _lastFlingValue = 0.0;
    _flingStartTime = null;
    _ensureTicker();
    _controller.notifyScrollEvent(ChatFlingStart(velocity));
  }

  void _cancelFling() {
    final wasFlinging = _simulation != null;
    _simulation = null;
    if (wasFlinging) _controller.notifyScrollEvent(const ChatFlingEnd());
  }

  // --- animateTo ------------------------------------------------------------

  /// Maximum distance (px) for which the close-path animation is used. Beyond
  /// this the viewport falls back to the far-path: crossfade + jumpTo.
  static const double _kCloseAnimateDistance = 2400.0;

  @override
  Future<void> animate(
    int targetId, {
    required Duration duration,
    required Curve curve,
  }) {
    // Re-entrant animateTo: cancel the in-flight one, schedule the new one.
    _cancelAnimate();
    if (duration <= Duration.zero) {
      _controller.jumpTo(targetId);
      return Future<void>.value();
    }

    final completer = Completer<void>();
    _animateCompleter = completer;
    _animateTargetId = targetId;
    _animateDuration = duration;
    _animateCurve = curve;
    _animateStartTime = null;

    final offsetToTarget = _offsetToBuiltMessage(targetId);
    if (offsetToTarget != null &&
        offsetToTarget.abs() <= _kCloseAnimateDistance) {
      // Close path: re-base the anchor onto the target with its current
      // offset, then animate that offset toward 0 ("scroll the target to the
      // top edge").
      _controller.reassignAnchor(targetId, offsetToTarget);
      _animateStartOffset = offsetToTarget;
      _animateEndOffset = 0.0;
      _farAnimateActive = false;
      _farAnimateJumped = false;
      _fadeOpacity = 1.0;
    } else {
      // Far path: a crossfade — fade out, jumpTo at the midpoint, fade back.
      _farAnimateActive = true;
      _farAnimateJumped = false;
      _animateStartOffset = 1.0;
      _animateEndOffset = 0.0;
      _fadeOpacity = 1.0;
    }
    _cancelFling();
    _ensureTicker();
    return completer.future;
  }

  /// Anchor-relative Y offset of message [id] in the currently-laid-out
  /// children, or `null` if [id] is not in `_children`.
  double? _offsetToBuiltMessage(int id) {
    final child = _children[id];
    if (child == null) return null;
    return _parentData(child).offset;
  }

  void _cancelAnimate() {
    final completer = _animateCompleter;
    if (completer == null) return;
    _animateCompleter = null;
    _animateStartTime = null;
    _farAnimateActive = false;
    _farAnimateJumped = false;
    if (_fadeOpacity != 1.0) {
      _fadeOpacity = 1.0;
      _fadeLayer.layer = null;
      markNeedsPaint();
    }
    // Completing the completer resumes `ChatScrollController.animateTo`, which
    // emits `ChatAnimateEnd` in its `finally` — don't emit it here too.
    if (!completer.isCompleted) completer.complete();
  }

  /// Drive the in-flight animation by one tick. Returns the additional scroll
  /// delta to apply (for the close path); the far path mutates fade opacity
  /// in-place and returns 0.
  double _tickAnimate(Duration elapsed) {
    if (_animateCompleter == null) return 0.0;
    final start = _animateStartTime ??= elapsed;
    final totalUs = _animateDuration.inMicroseconds;
    final elapsedUs = (elapsed - start).inMicroseconds;
    final t = totalUs <= 0 ? 1.0 : (elapsedUs / totalUs).clamp(0.0, 1.0);

    if (_farAnimateActive) {
      // 0 → 0.5 → 1: opacity 1 → 0 → 1. Mid-point performs the jumpTo.
      // Apply the curve to each half independently. Using one
      // `curve.transform(t)` across the full 0..1 range would not guarantee
      // opacity == 0 at the midpoint for non-symmetric curves (e.g.
      // `easeInOut*` family transforms 0.5 to ≈0.5 but easeIn / easeOut
      // do not), so the synchronous `jumpTo` could happen while the
      // viewport is still partially visible. Per-half normalisation pins
      // opacity to exactly 0 at t == 0.5.
      if (t < 0.5) {
        final eased = _animateCurve.transform(t * 2.0);
        _fadeOpacity = (1.0 - eased).clamp(0.0, 1.0);
      } else {
        if (!_farAnimateJumped) {
          _farAnimateJumped = true;
          _controller.jumpTo(_animateTargetId);
        }
        final eased = _animateCurve.transform((t - 0.5) * 2.0);
        _fadeOpacity = eased.clamp(0.0, 1.0);
      }
      if (t >= 1.0) {
        _fadeOpacity = 1.0;
        _completeAnimate();
      } else {
        markNeedsPaint();
      }
      return 0.0;
    }

    // Close path: interpolate anchor offset linearly along the curve.
    final eased = _animateCurve.transform(t);
    final target =
        _animateStartOffset + (_animateEndOffset - _animateStartOffset) * eased;
    final delta = target - _controller.anchorPixelOffset;
    if (t >= 1.0) _completeAnimate();
    return delta;
  }

  void _completeAnimate() {
    final completer = _animateCompleter;
    _animateCompleter = null;
    _animateStartTime = null;
    _farAnimateActive = false;
    _farAnimateJumped = false;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Ticker callback — the entire scroll path. Bypasses layout: repositions
  /// children and calls [markNeedsPaint] (Tier 1). Falls back to
  /// [markNeedsLayout] only when the built range no longer covers the viewport.
  void _onTick(Duration elapsed) {
    // Overlay mode owns the viewport — no scroll, no fling, no animate. A
    // ticker that survives the transition (or a stray re-arm) must not
    // mutate the anchor while no children are positioned.
    if (_overlayKind != ChatOverlayKind.none) {
      _pendingScrollDelta = 0.0;
      _cancelFling();
      _cancelAnimate();
      _ticker?.stop();
      return;
    }
    _markScrollActive();
    var delta = _pendingScrollDelta;
    _pendingScrollDelta = 0.0;

    final simulation = _simulation;
    if (simulation != null) {
      final startTime = _flingStartTime ??= elapsed;
      final seconds =
          (elapsed - startTime).inMicroseconds / Duration.microsecondsPerSecond;
      if (simulation.isDone(seconds)) {
        _cancelFling();
      } else {
        final value = simulation.x(seconds);
        delta += value - _lastFlingValue;
        _lastFlingValue = value;
      }
    }

    // animateTo drives the same Ticker — the close path contributes a delta
    // to the anchor offset, the far path mutates fade opacity and triggers
    // jumpTo on its own.
    delta += _tickAnimate(elapsed);

    if (delta != 0.0) _controller.applyScrollDelta(delta);
    // Smooth the per-frame scroll delta; biases the next fan-out lead.
    _scrollVelocity = _scrollVelocity * 0.7 + delta * 0.3;
    _repositionFromAnchor();
    // Keep the anchor on a visible message so the next layout fans out a
    // tight range rather than rebuilding everything back to a drifted anchor.
    _renormalizeAnchor();
    if (_clampBoundaries()) {
      _cancelFling();
      _cancelAnimate();
    }
    _updateScrollSemantics();
    _publishVisibleRange();
    // Reposition the header (Tier-1); a day crossing needs a relayout to
    // rebuild its text.
    final headerDayChanged = _tickFloatingHeader();

    if (_rangeNoLongerCovers() || headerDayChanged) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }

    if (_simulation == null && _animateCompleter == null) _stopTickerIfIdle();
  }

  /// Whether the built child range no longer covers viewport + cache extent.
  /// Considers both message tiles and chunk-error tiles — the latter may be
  /// the outermost build at a boundary (e.g. the anchor's chunk errored).
  bool _rangeNoLongerCovers() {
    // Tier-1 hot path: the inline walk below allocates no closures and uses
    // the same min/max accumulation that the original (messages-only)
    // implementation did.
    final hasMessages = _children.isNotEmpty;
    final hasErrors = _chunkErrors.isNotEmpty;
    if (!hasMessages && !hasErrors) return true;

    double topY = double.infinity;
    double bottomY = double.negativeInfinity;
    int firstId = 1 << 62;
    int lastId = -(1 << 62);

    if (hasMessages) {
      // Sorted by id — the outermost id bounds are the first and last keys.
      // Offsets must still be scanned in full because mid-range entries can
      // dictate top/bottom when the directional lead biased the fan-out.
      final fk = _children.firstKey()!;
      final lk = _children.lastKey()!;
      if (fk < firstId) firstId = fk;
      if (lk > lastId) lastId = lk;
      for (final box in _children.values) {
        final pd = _parentData(box);
        if (pd.offset < topY) topY = pd.offset;
        final b = pd.offset + box.size.height;
        if (b > bottomY) bottomY = b;
      }
    }
    if (hasErrors) {
      final fc = _chunkErrors.firstKey()!;
      final lc = _chunkErrors.lastKey()!;
      final eFirst = ChatScrollChunk.firstIdOf(fc);
      final eLast = ChatScrollChunk.firstIdOf(lc + 1) - 1;
      if (eFirst < firstId) firstId = eFirst;
      if (eLast > lastId) lastId = eLast;
      for (final box in _chunkErrors.values) {
        final pd = _parentData(box);
        if (pd.offset < topY) topY = pd.offset;
        final b = pd.offset + box.size.height;
        if (b > bottomY) bottomY = b;
      }
    }

    if (topY > size.height || bottomY < 0) return true;

    if (bottomY < size.height + _cacheExtent) {
      final newest = _dataSource.newestKnownId;
      if (newest == null || lastId < newest) return true;
    }
    if (topY > -_cacheExtent) {
      final oldest = _dataSource.oldestKnownId;
      if (oldest == null || firstId > oldest) return true;
    }
    return false;
  }

  // --- Fetch poll ------------------------------------------------------------

  /// Arm the one-shot fetch poll, but only while the laid-out range still has
  /// a missing or dirty chunk. A fully-loaded, idle viewport arms nothing —
  /// no periodic wake-ups.
  ///
  /// Outside an active scroll the timer fires on the next microtask instead
  /// of waiting a full [_pollInterval] — initial load, jumpTo settle, and
  /// "new chunk arrived" don't need the scroll-debounce. The interval still
  /// applies while the user is actively scrolling, so a fast fling doesn't
  /// spam the network with every chunk that briefly enters the viewport.
  void _scheduleFetchPoll() {
    if (_pollTimer != null || !_rangeHasPendingChunks()) return;
    final sinceScroll = DateTime.now().millisecondsSinceEpoch - _lastScrollTs;
    final delay = sinceScroll >= _pollInterval.inMilliseconds
        ? Duration.zero
        : _pollInterval;
    _pollTimer = Timer(delay, _onPollTick);
  }

  void _onPollTick() {
    _pollTimer = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Skip the fetch while a scroll is still in flight (light debounce); the
    // re-arm below keeps re-checking until it settles.
    if (now - _lastScrollTs >= _pollInterval.inMilliseconds &&
        _layoutMaxChunk >= _layoutMinChunk) {
      _dataSource.requestChunks(_layoutMinChunk, _layoutMaxChunk);
    }
    // Keep polling until everything in range has loaded, then go idle.
    _scheduleFetchPoll();
  }

  /// Whether the laid-out chunk range has any missing or dirty chunk that is
  /// not already being fetched.
  ///
  /// A chunk with `dirty | fetching` would otherwise keep the poll re-arming
  /// while its own fetch is in flight — a tight loop when the poll fires
  /// immediately. The fetch result will arrive via `notifyDataChanged`, which
  /// markNeedsLayout's the viewport, so a subsequent layout will re-evaluate
  /// the poll naturally.
  bool _rangeHasPendingChunks() {
    if (_layoutMaxChunk < _layoutMinChunk) return false;
    for (var ci = _layoutMinChunk; ci <= _layoutMaxChunk; ci++) {
      final chunk = _dataSource.chunks[ci];
      if (chunk == null) return true;
      final status = chunk.status;
      if (status.isFetching) continue;
      if (status.isDirty || status.isError) return true;
    }
    return false;
  }

  // --- Gestures --------------------------------------------------------------

  void _onDragStart(DragStartDetails details) {
    _cancelFling();
    _cancelAnimate();
    _ensureTicker();
    _controller.notifyScrollEvent(const ChatUserDragStart());
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _markScrollActive();
    _pendingScrollDelta += details.delta.dy;
    _ensureTicker();
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0.0;
    _controller.notifyScrollEvent(ChatUserDragEnd(velocity));
    if (velocity.abs() >= 50.0) {
      _startFling(velocity);
    } else {
      _stopTickerIfIdle();
    }
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    assert(debugHandleEvent(event, entry));

    // Overlay mode: no messages to scroll over. The overlay child handles
    // its own pointers via the normal hit-test path; the viewport itself
    // contributes nothing.
    if (_overlayKind != ChatOverlayKind.none) return;

    // Scrollbar drag in progress — consume move/up/cancel.
    if (_scrollbar.isDragging) {
      if (event is PointerMoveEvent && _scrollbar.ownsPointer(event)) {
        _jumpToScrollbar(
          _scrollbar.progressFromY(event.localPosition.dy, size),
        );
        return;
      }
      if ((event is PointerUpEvent || event is PointerCancelEvent) &&
          _scrollbar.ownsPointer(event)) {
        _scrollbar.endDrag();
        markNeedsPaint();
        return;
      }
    }

    if (event is PointerDownEvent) {
      if (_dataSource.newestKnownId != null &&
          _scrollbar.tryStartDrag(event, size)) {
        _cancelFling();
        markNeedsPaint();
        _jumpToScrollbar(
          _scrollbar.progressFromY(event.localPosition.dy, size),
        );
        return;
      }
      _drag?.addPointer(event);
    } else if (event is PointerPanZoomStartEvent) {
      _cancelFling();
      _drag?.addPointerPanZoom(event);
    } else if (event is PointerScrollEvent) {
      _cancelFling();
      _markScrollActive();
      _pendingScrollDelta -= event.scrollDelta.dy;
      _ensureTicker();
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // Overlay mode: only the overlay child is hit-testable; messages and the
    // floating header are not built.
    final overlay = _overlay;
    if (_overlayKind != ChatOverlayKind.none && overlay != null) {
      return result.addWithPaintOffset(
        offset: Offset(0, _parentData(overlay).offset),
        position: position,
        hitTest: (BoxHitTestResult innerResult, Offset transformed) =>
            overlay.hitTest(innerResult, position: transformed),
      );
    }

    final viewportHeight = size.height;
    // Mirror paint order: chunk-error tiles paint on top of message tiles
    // (the second paint loop). Hit-test them first so a tap on the Retry
    // button is not absorbed by a co-existing message tile during a
    // chunk's error → valid transition frame.
    for (final child in _chunkErrors.values) {
      final pd = _parentData(child);
      if (pd.offset >= viewportHeight || pd.offset + child.size.height <= 0) {
        continue;
      }
      final hit = result.addWithPaintOffset(
        offset: Offset(0, pd.offset),
        position: position,
        hitTest: (BoxHitTestResult innerResult, Offset transformed) =>
            child.hitTest(innerResult, position: transformed),
      );
      if (hit) return true;
    }
    for (final child in _children.values) {
      final pd = _parentData(child);
      // Only on-screen children are hit-testable — off-screen build-extent
      // children may hold a stale offset.
      if (pd.offset >= viewportHeight || pd.offset + child.size.height <= 0) {
        continue;
      }
      final hit = result.addWithPaintOffset(
        offset: Offset(0, pd.offset),
        position: position,
        hitTest: (BoxHitTestResult innerResult, Offset transformed) =>
            child.hitTest(innerResult, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  // --- Scroll semantics ------------------------------------------------------

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..explicitChildNodes = true
      ..hasImplicitScrolling = true;
    // `scrollUp` semantically means "scroll the container up" — i.e. expose
    // content currently below the viewport. In a chat (`reverse: true`)
    // assistive-tech users typically think of "scroll up" as "look at older
    // history" — older is *above*, so we flip the mapping there.
    if (_reverse) {
      if (_canRevealOlder) config.onScrollUp = _semanticRevealOlder;
      if (_canRevealNewer) config.onScrollDown = _semanticRevealNewer;
    } else {
      if (_canRevealNewer) config.onScrollUp = _semanticRevealNewer;
      if (_canRevealOlder) config.onScrollDown = _semanticRevealOlder;
    }
  }

  // --- Visible range publishing --------------------------------------------

  /// Push the current first/last on-screen ids + anchor id to the controller's
  /// `visibleRange` listenable. Called after every layout and Tier-1 tick —
  /// O(visible children) of pure parent-data reads.
  void _publishVisibleRange() {
    if (_children.isEmpty) {
      _controller.visibleRange = null;
      return;
    }
    final topEdge = _topPad;
    final bottomEdge = size.height - _bottomPad;
    int? firstId;
    int? lastId;
    for (final entry in _children.entries) {
      final child = entry.value;
      final pd = _parentData(child);
      final childTop = pd.offset;
      final childBottom = childTop + child.size.height;
      if (childBottom <= topEdge) continue;
      if (childTop >= bottomEdge) break;
      firstId ??= entry.key;
      lastId = entry.key;
    }
    // Chunk-error tiles count as visible id coverage — their chunks' id range
    // is what the listener (mark-as-read, lazy media) cares about, even when
    // the actual messages are not built.
    for (final entry in _chunkErrors.entries) {
      final child = entry.value;
      final pd = _parentData(child);
      final childTop = pd.offset;
      final childBottom = childTop + child.size.height;
      if (childBottom <= topEdge || childTop >= bottomEdge) continue;
      final chunkFirst = ChatScrollChunk.firstIdOf(entry.key);
      final chunkLast = chunkFirst + ChatScrollChunk.kSize - 1;
      final priorFirst = firstId;
      final priorLast = lastId;
      firstId = priorFirst == null || chunkFirst < priorFirst
          ? chunkFirst
          : priorFirst;
      lastId = priorLast == null || chunkLast > priorLast
          ? chunkLast
          : priorLast;
    }
    if (firstId == null || lastId == null) {
      _controller.visibleRange = null;
      return;
    }
    final current = _controller.visibleRange.value;
    final anchorId = _controller.anchorMessageId;
    if (current != null &&
        current.firstId == firstId &&
        current.lastId == lastId &&
        current.anchorId == anchorId) {
      return;
    }
    _controller.visibleRange = (
      firstId: firstId,
      lastId: lastId,
      anchorId: anchorId,
    );
  }

  // Note: `visitChildrenForSemantics` is intentionally NOT overridden to filter
  // by on-screen position. The semantic-child set must only change when
  // children are created/collected (both mark semantics dirty); filtering by
  // scroll position would let a child cross the viewport edge during a Tier-1
  // paint-only frame and become a visible semantic node with stale (null)
  // parent data. Off-screen cache-extent children therefore contribute
  // semantics — the same trade-off `ListView`'s cache extent makes.

  void _semanticRevealNewer() => _semanticScroll(-size.height * 0.8);
  void _semanticRevealOlder() => _semanticScroll(size.height * 0.8);

  void _semanticScroll(double delta) {
    _cancelFling();
    _controller.applyScrollDelta(delta);
    markNeedsLayout();
  }

  /// Recompute the scroll-action availability and request a semantics update
  /// only when it actually changed.
  void _updateScrollSemantics() {
    final canOlder = _computeCanRevealOlder();
    final canNewer = _computeCanRevealNewer();
    if (canOlder != _canRevealOlder || canNewer != _canRevealNewer) {
      _canRevealOlder = canOlder;
      _canRevealNewer = canNewer;
      markNeedsSemanticsUpdate();
    }
  }

  bool _computeCanRevealOlder() {
    if (_children.isEmpty && _chunkErrors.isEmpty) return false;
    final oldest = _dataSource.oldestKnownId;
    if (oldest != null && _dataSource.reachedOldest) {
      // `_boundaryBox` mirrors what `_clampBoundaries` pins to, so semantics
      // agree with the clamp — assistive tech does not announce scrollable
      // history that the next layout will bounce back into place.
      final first = _boundaryBox(oldest);
      if (first != null && _parentData(first).offset >= -0.5) return false;
    }
    return true;
  }

  bool _computeCanRevealNewer() {
    if (_children.isEmpty && _chunkErrors.isEmpty) return false;
    final newest = _dataSource.newestKnownId;
    if (newest != null && _dataSource.reachedNewest) {
      final last = _boundaryBox(newest);
      if (last != null &&
          _parentData(last).offset + last.size.height <=
              size.height - _bottomPad + 0.5) {
        return false;
      }
    }
    return true;
  }

  // --- Scrollbar -------------------------------------------------------------

  /// Map a 0..1 scrollbar [progress] to a message id and teleport there.
  void _jumpToScrollbar(double progress) {
    final newest = _dataSource.newestKnownId;
    final oldest = _dataSource.oldestKnownId;
    if (newest == null || oldest == null || newest <= oldest) return;
    final targetId = (oldest + progress * (newest - oldest)).round();
    if (targetId != _controller.anchorMessageId) {
      _controller.jumpTo(targetId);
    }
  }

  /// Scrollbar thumb progress (0..1) derived from the anchor — pure id math,
  /// no dependency on a global content height. Returns `null` when hidden.
  double? _scrollbarProgress() {
    final newest = _dataSource.newestKnownId;
    final oldest = _dataSource.oldestKnownId;
    if (newest == null || oldest == null) return null;
    final range = newest - oldest;
    if (range <= 0) return null;

    final anchorId = _controller.anchorMessageId;
    final anchor = _children[anchorId];
    final slotHeight = (anchor != null && anchor.size.height > 0)
        ? anchor.size.height
        : 60.0;
    final fractionalId = anchorId - _controller.anchorPixelOffset / slotHeight;
    return ((fractionalId - oldest) / range).clamp(0.0, 1.0);
  }

  // --- Paint -----------------------------------------------------------------

  @override
  void paint(PaintingContext context, Offset offset) {
    assert(() {
      _debugSw
        ..reset()
        ..start();
      return true;
    }());

    // Reuse the clip layer across repaints — the framework idiom. Even though
    // this object is a repaint boundary (so its layer children are re-added on
    // every repaint), holding the ClipRectLayer in a LayerHandle and passing
    // it back as `oldLayer` keeps a stable layer identity for the engine.
    _clipLayer.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      _paintWithFade,
      oldLayer: _clipLayer.layer,
    );

    assert(() {
      debugLastPaintDuration = _debugSw.elapsed;
      _debugSw.stop();
      debugPaintFrameId++;
      return true;
    }());
  }

  /// Wraps [_paintContents] in an [OpacityLayer] while a far-target
  /// `animateTo` crossfade is in flight. Otherwise paints straight through.
  void _paintWithFade(PaintingContext context, Offset offset) {
    if (_fadeOpacity >= 0.999) {
      _fadeLayer.layer = null;
      _paintContents(context, offset);
      return;
    }
    if (_fadeOpacity <= 0.001) {
      // Fully invisible — skip the children entirely. Cheap mid-crossfade.
      _fadeLayer.layer = null;
      return;
    }
    _fadeLayer.layer = context.pushOpacity(
      offset,
      (_fadeOpacity * 255).round().clamp(0, 255),
      (innerContext, innerOffset) => _paintContents(innerContext, innerOffset),
      oldLayer: _fadeLayer.layer,
    );
  }

  void _paintContents(PaintingContext context, Offset offset) {
    // Overlay mode: a single full-viewport child takes the place of every
    // message — no scrollbar, no floating header, no per-message cull.
    final overlay = _overlay;
    if (_overlayKind != ChatOverlayKind.none && overlay != null) {
      context.paintChild(overlay, offset + Offset(0, _parentData(overlay).offset));
      return;
    }

    final viewportHeight = size.height;
    for (final child in _children.values) {
      final pd = _parentData(child);
      // Cull children fully outside the viewport — off-screen build-extent
      // children stay built but are not composited until they scroll in.
      if (pd.offset >= viewportHeight || pd.offset + child.size.height <= 0) {
        continue;
      }
      context.paintChild(child, offset + Offset(0, pd.offset));
    }
    for (final child in _chunkErrors.values) {
      final pd = _parentData(child);
      if (pd.offset >= viewportHeight || pd.offset + child.size.height <= 0) {
        continue;
      }
      context.paintChild(child, offset + Offset(0, pd.offset));
    }
    // The floating day header — above the messages, below the scrollbar.
    final header = _floatingHeader;
    if (header != null) {
      context.paintChild(
        header,
        offset + Offset(0, _parentData(header).offset),
      );
    }
    _paintScrollbar(context, offset);
  }

  void _paintScrollbar(PaintingContext context, Offset offset) {
    final progress = _scrollbarProgress();
    if (progress == null) return;
    _scrollbar.paint(context.canvas, offset, size, progress);
  }

  @override
  void dispose() {
    _cancelFling();
    _cancelAnimate();
    _ticker?.dispose();
    _ticker = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _drag?.dispose();
    _drag = null;
    _clipLayer.layer = null;
    _fadeLayer.layer = null;
    super.dispose();
  }
}
