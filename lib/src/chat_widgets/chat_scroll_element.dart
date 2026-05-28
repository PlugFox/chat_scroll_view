import 'dart:collection';

import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_widgets/chat_data_source_ext.dart';
import 'package:chatscrollview/src/chat_widgets/chat_dated_message.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/chat_selectable_message.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/widgets.dart';

/// Slot for the single floating day header — kept distinct from the int-keyed
/// message children so [ChatScrollElement] can route it separately.
enum _ChatSlot { floatingHeader }

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

  /// The floating day header element, or `null` when no header is shown.
  Element? _floatingHeader;

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
    if (old.messageBuilder != newWidget.messageBuilder ||
        old.selectionController != newWidget.selectionController ||
        old.dateSeparatorBuilder != newWidget.dateSeparatorBuilder) {
      _builtMessage.clear();
      _builtStatus.clear();
      _builtStartsDay.clear();
      renderObject.markNeedsLayout();
    }
    // A changed separator builder must rebuild the header even if the day did
    // not change — the day-bucket gate alone would skip it.
    if (old.dateSeparatorBuilder != newWidget.dateSeparatorBuilder) {
      renderObject.invalidateFloatingHeader();
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
  Widget _buildWidget(
    int id,
    IChatMessage? message,
    ChatMessageStatus status,
    bool startsNewDay,
  ) {
    Widget content = _widget.messageBuilder(this, id, message, status);
    final selection = _widget.selectionController;
    if (selection != null) {
      content = SelectableMessage(
        id: id,
        controller: selection,
        child: content,
      );
    }
    final separator = _widget.dateSeparatorBuilder;
    if (startsNewDay && separator != null && message != null) {
      return DatedMessage(
        key: ValueKey<int>(id),
        separator: separator(this, message.createdAt),
        body: content,
      );
    }
    return RepaintBoundary(key: ValueKey<int>(id), child: content);
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

  // --- RenderObjectElement plumbing -----------------------------------------

  @override
  void insertRenderObjectChild(RenderObject child, Object? slot) {
    if (slot is int) {
      renderObject.insertChild(child as RenderBox, slot);
    } else {
      assert(slot == _ChatSlot.floatingHeader);
      renderObject.floatingHeader = child as RenderBox;
    }
  }

  @override
  void removeRenderObjectChild(RenderObject child, Object? slot) {
    if (slot is int) {
      renderObject.removeChild(slot);
    } else {
      assert(slot == _ChatSlot.floatingHeader);
      renderObject.floatingHeader = null;
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
    final header = _floatingHeader;
    if (header != null) visitor(header);
  }

  @override
  void forgetChild(Element child) {
    if (identical(child, _floatingHeader)) {
      _floatingHeader = null;
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
