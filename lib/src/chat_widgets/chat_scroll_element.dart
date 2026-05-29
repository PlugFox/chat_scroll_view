import 'dart:collection';

import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_widgets/chat_data_source_ext.dart';
import 'package:chatscrollview/src/chat_widgets/chat_dated_message.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/chat_selectable_message.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/widgets.dart';

/// Singleton slots — kept distinct from the int-keyed message children and
/// the chunk-error slots so [ChatScrollElement] can route them separately.
///
/// * `floatingHeader` — pinned day pill at the top of the viewport.
/// * `overlay` — the single full-viewport child for the loading skeleton or
///   the empty state.
enum _ChatSlot { floatingHeader, overlay }

/// Slot for a chunk-error tile — one tile per failed chunk. Wraps the chunk
/// index so it cannot be confused with an `int` message-id slot.
@immutable
class _ChunkErrorSlot {
  const _ChunkErrorSlot(this.chunkIndex);
  final int chunkIndex;

  @override
  bool operator ==(Object other) =>
      other is _ChunkErrorSlot && other.chunkIndex == chunkIndex;

  @override
  int get hashCode => Object.hash(_ChunkErrorSlot, chunkIndex);
}

/// Element for [ChatScrollView].
///
/// Owns a sparse, id-keyed set of child elements and inflates them on demand —
/// the same lazy-child machinery as `SliverMultiBoxAdaptorElement`, minus the
/// sliver protocol. [RenderChatScrollView] drives building during layout via
/// the [ChatChildManager] interface — message children and the one floating
/// day header alike.
class ChatScrollElement extends RenderObjectElement
    implements ChatChildManager {
  ChatScrollElement(ChatScrollView super.widget);

  /// messageId -> child element, sorted so iteration is top-to-bottom.
  final SplayTreeMap<int, Element> _children = SplayTreeMap<int, Element>();

  /// Skip-rebuild cache: the message instance, status, and first-of-day flag
  /// each child was last built with. When [buildChild] is asked for an id whose
  /// inputs are all unchanged, the existing child is reused without running
  /// `updateChild` / the message widget's `build()` again.
  final Map<int, IChatMessage?> _builtMessage = <int, IChatMessage?>{};
  final Map<int, ChatMessageStatus> _builtStatus = <int, ChatMessageStatus>{};
  final Map<int, bool> _builtStartsDay = <int, bool>{};

  /// chunkIndex -> chunk-error tile element, sorted ascending. Empty unless
  /// the host widget supplies an `errorBuilder`.
  final SplayTreeMap<int, Element> _chunkErrors = SplayTreeMap<int, Element>();

  /// The floating day header element, or `null` when no header is shown.
  Element? _floatingHeader;

  /// The full-viewport overlay element (loading skeleton or empty state), or
  /// `null` when the viewport is in normal fan-out mode. The render side
  /// owns the active [ChatOverlayKind] and only calls `buildOverlay` when it
  /// changes — the element just holds the inflated child.
  Element? _overlay;

  ChatScrollView get _widget => widget as ChatScrollView;

  @override
  RenderChatScrollView get renderObject =>
      super.renderObject as RenderChatScrollView;

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    renderObject.childManager = this;
  }

  @override
  void update(ChatScrollView newWidget) {
    final old = _widget;
    super.update(
      newWidget,
    ); // -> updateRenderObject (dataSource/controller/...)
    // No builder is handed to the render object; if any changed, drop the
    // skip-cache and force a layout so every active child re-inflates.
    // Use `==` instead of `identical` — instance-method tear-offs are equal
    // across accesses but not necessarily identical, so `identical` here
    // would force every parent rebuild to throw away the skip-cache.
    //
    // `textDirection` is included: the explicit override changes the
    // ambient Directionality that wraps every message subtree (see
    // [_buildWidget]). Without dropping the cache, already-built messages
    // would keep the old direction until their data changes.
    if (old.messageBuilder != newWidget.messageBuilder ||
        old.selectionController != newWidget.selectionController ||
        old.dateSeparatorBuilder != newWidget.dateSeparatorBuilder ||
        old.textDirection != newWidget.textDirection) {
      _builtMessage.clear();
      _builtStatus.clear();
      _builtStartsDay.clear();
      renderObject.markNeedsLayout();
    }
    // A changed separator builder *or* direction must rebuild the header
    // even if the day did not change — the day-bucket gate alone would
    // skip it.
    if (old.dateSeparatorBuilder != newWidget.dateSeparatorBuilder ||
        old.textDirection != newWidget.textDirection) {
      renderObject.invalidateFloatingHeader();
    }
    // A swapped chunkErrorBuilder must re-inflate every visible chunk-error
    // tile so the new builder runs against existing slots.
    if (old.chunkErrorBuilder != newWidget.chunkErrorBuilder &&
        _chunkErrors.isNotEmpty) {
      renderObject.markNeedsLayout();
    }
  }

  /// Inflate the widget for message [id].
  ///
  /// When a selection controller is wired the content is wrapped in
  /// [SelectableMessage] (checkbox gutter + row tint). When [startsNewDay] is
  /// set, the message is built as a [DatedMessage] — an inline date separator
  /// stacked above the body, *outside* [SelectableMessage] so selection chrome
  /// never tints the date. Plain messages are wrapped in a [RepaintBoundary]
  /// for picture / layer caching; [DatedMessage] does its own wrapping.
  ///
  /// When an explicit `textDirection` override is supplied on
  /// `ChatScrollView`, [messageBuilder] and the date-separator builder are
  /// invoked inside a `Builder` sitting *under* a [Directionality] with the
  /// override — so builders that follow the documented
  /// `Directionality.of(context)` pattern read the same direction the
  /// viewport uses for its chrome. Without the wrap, bubble alignment
  /// would silently disagree with the scrollbar mirroring.
  Widget _buildWidget(
    int id,
    IChatMessage? message,
    ChatMessageStatus status,
    bool startsNewDay,
  ) {
    final override = _widget.textDirection;
    final selection = _widget.selectionController;
    final separator = _widget.dateSeparatorBuilder;
    final hasDateHeader =
        startsNewDay && separator != null && message != null;

    Widget compose(BuildContext context) {
      Widget content = _widget.messageBuilder(context, id, message, status);
      if (selection != null) {
        content = SelectableMessage(
          id: id,
          controller: selection,
          child: content,
        );
      }
      return hasDateHeader
          ? DatedMessage(
              key: ValueKey<int>(id),
              separator: separator(context, message.createdAt),
              body: content,
            )
          : RepaintBoundary(key: ValueKey<int>(id), child: content);
    }

    if (override != null) {
      // Builder installs a descendant BuildContext so `compose` runs *under*
      // the Directionality; calling `messageBuilder(this, ...)` would have
      // resolved Directionality.of against the ambient ancestor instead.
      return Directionality(
        textDirection: override,
        child: Builder(builder: compose),
      );
    }
    return compose(this);
  }

  // --- ChatChildManager (driven by RenderChatScrollView.performLayout) ------

  @override
  RenderBox? buildChild(int id, {required bool startsNewDay}) {
    final ds = _widget.dataSource;
    final message = ds.getMessage(id);
    final status = ds.statusOf(id);
    final existing = _children[id];

    // Fast path: every input is unchanged since this child was last built —
    // reuse it without rebuilding. Inherited-widget changes (Theme, ...) still
    // rebuild through the normal dependency mechanism, and width changes are
    // handled by the subsequent `child.layout()`.
    if (existing != null &&
        _builtStatus[id] == status &&
        _builtStartsDay[id] == startsNewDay &&
        identical(_builtMessage[id], message)) {
      return existing.renderObject as RenderBox?;
    }

    RenderBox? result;
    owner!.buildScope(this, () {
      final updated = updateChild(
        existing,
        _buildWidget(id, message, status, startsNewDay),
        id,
      );
      if (updated != null) {
        _children[id] = updated;
        _builtMessage[id] = message;
        _builtStatus[id] = status;
        _builtStartsDay[id] = startsNewDay;
        result = updated.renderObject as RenderBox?;
      } else {
        _children.remove(id);
        _builtMessage.remove(id);
        _builtStatus.remove(id);
        _builtStartsDay.remove(id);
      }
    });
    return result;
  }

  @override
  void removeChildren(List<int> ids) {
    if (ids.isEmpty) return;
    owner!.buildScope(this, () {
      for (final id in ids) {
        final removed = updateChild(_children[id], null, id);
        assert(removed == null);
        _children.remove(id);
        _builtMessage.remove(id);
        _builtStatus.remove(id);
        _builtStartsDay.remove(id);
      }
    });
  }

  @override
  RenderBox? buildFloatingHeader(DateTime? date) {
    final build = _widget.dateSeparatorBuilder;
    // Feature off, or no day known yet -> no header widget.
    final headerWidget = (build == null || date == null)
        ? null
        : RepaintBoundary(child: build(this, date));
    owner!.buildScope(this, () {
      _floatingHeader = updateChild(
        _floatingHeader,
        headerWidget,
        _ChatSlot.floatingHeader,
      );
    });
    return _floatingHeader?.renderObject as RenderBox?;
  }

  @override
  RenderBox? buildChunkError(int chunkIndex, int firstId, int lastId) {
    // Defensive: the render side only calls this when `hasErrorBuilder` is
    // true, but the host may have flipped the builder away on the same frame.
    if (_widget.chunkErrorBuilder == null) return null;
    final widget = RepaintBoundary(
      key: ValueKey<({Symbol tag, int idx})>((
        tag: #chunkError,
        idx: chunkIndex,
      )),
      // Builder reads `_widget` and the chunk at *call* time, not at *build*
      // time — a data-source swap before the user taps Retry sends the
      // retry to the current data source rather than the captured one, and
      // a fresh fetch failure refreshes `error` / `attempt` on the next
      // rebuild without re-keying the slot.
      child: Builder(
        builder: (ctx) {
          final ds = _widget.dataSource;
          final chunk = ds.chunks[chunkIndex];
          return _widget.chunkErrorBuilder!(
            ctx,
            (
              chunkIndex: chunkIndex,
              firstId: firstId,
              lastId: lastId,
              error: chunk?.lastError,
              attempt: chunk?.failedAttempts ?? 0,
              retry: () => ds.retryChunk(firstId),
            ),
          );
        },
      ),
    );
    Element? updated;
    owner!.buildScope(this, () {
      updated = updateChild(
        _chunkErrors[chunkIndex],
        widget,
        _ChunkErrorSlot(chunkIndex),
      );
      if (updated != null) {
        _chunkErrors[chunkIndex] = updated!;
      } else {
        _chunkErrors.remove(chunkIndex);
      }
    });
    return updated?.renderObject as RenderBox?;
  }

  @override
  void removeChunkErrors(List<int> chunkIndices) {
    if (chunkIndices.isEmpty) return;
    owner!.buildScope(this, () {
      for (final idx in chunkIndices) {
        final removed = updateChild(
          _chunkErrors[idx],
          null,
          _ChunkErrorSlot(idx),
        );
        assert(removed == null);
        _chunkErrors.remove(idx);
      }
    });
  }

  @override
  RenderBox? buildOverlay(ChatOverlayKind kind) {
    final Widget? widget;
    switch (kind) {
      case ChatOverlayKind.none:
        widget = null;
      case ChatOverlayKind.loading:
        final build = _widget.loadingBuilder;
        widget = build == null ? null : Builder(builder: build);
      case ChatOverlayKind.empty:
        final build = _widget.emptyBuilder;
        widget = build == null ? null : Builder(builder: build);
    }
    owner!.buildScope(this, () {
      _overlay = updateChild(_overlay, widget, _ChatSlot.overlay);
    });
    return _overlay?.renderObject as RenderBox?;
  }

  // --- RenderObjectElement plumbing -----------------------------------------

  @override
  void insertRenderObjectChild(RenderObject child, Object? slot) {
    if (slot is int) {
      renderObject.insertChild(child as RenderBox, slot);
    } else if (slot is _ChunkErrorSlot) {
      renderObject.insertChunkError(child as RenderBox, slot.chunkIndex);
    } else if (slot == _ChatSlot.floatingHeader) {
      renderObject.floatingHeader = child as RenderBox;
    } else {
      assert(slot == _ChatSlot.overlay);
      renderObject.overlay = child as RenderBox;
    }
  }

  @override
  void removeRenderObjectChild(RenderObject child, Object? slot) {
    if (slot is int) {
      renderObject.removeChild(slot);
    } else if (slot is _ChunkErrorSlot) {
      renderObject.removeChunkError(slot.chunkIndex);
    } else if (slot == _ChatSlot.floatingHeader) {
      renderObject.floatingHeader = null;
    } else {
      assert(slot == _ChatSlot.overlay);
      renderObject.overlay = null;
    }
  }

  @override
  void moveRenderObjectChild(
    RenderObject child,
    Object? oldSlot,
    Object? newSlot,
  ) {
    assert(false, 'ChatScrollElement children never change slot');
  }

  @override
  void visitChildren(ElementVisitor visitor) {
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
  void forgetChild(Element child) {
    if (identical(child, _floatingHeader)) {
      _floatingHeader = null;
    } else if (identical(child, _overlay)) {
      _overlay = null;
    } else if (child.slot is _ChunkErrorSlot) {
      final idx = (child.slot! as _ChunkErrorSlot).chunkIndex;
      _chunkErrors.remove(idx);
    } else {
      assert(child.slot is int);
      assert(_children.containsKey(child.slot));
      final id = child.slot! as int;
      _children.remove(id);
      _builtMessage.remove(id);
      _builtStatus.remove(id);
      _builtStartsDay.remove(id);
    }
    super.forgetChild(child);
  }
}
