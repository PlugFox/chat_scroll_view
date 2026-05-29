import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Wraps a [child] in a `Shortcuts` + `Actions` + `Focus` stack that handles
/// the canonical desktop keyboard navigation for a chat viewport:
///
/// * `ArrowUp` / `ArrowDown` — scroll by one [lineExtent] (default 60 px).
///   Tune to your typical message-row height — this is not derived from
///   text-line metrics.
/// * `PageUp` / `PageDown` — scroll by [pageExtent]; when `null`, falls back
///   to the wrapper's *own* measured height (via an internal `LayoutBuilder`)
///   times [pageFraction], so the page step matches the actual chat viewport
///   even when the wrapper sits under an `AppBar` / next to a side panel.
///   The latest measurement is captured each rebuild — keys fired before
///   the first layout fall back to the ambient `MediaQuery` height.
/// * `Home` — `controller.jumpTo(dataSource.oldestKnownId)`. No-op when the
///   oldest is unknown (initial load).
/// * `End` — `controller.jumpTo(dataSource.newestKnownId)`.
///
/// `controller.scrollBy` is anchor-relative, so PageUp / ArrowUp always
/// reveal older history in both layouts — no direction flip is needed for
/// scroll. Home / End target ids do flip with [reverse]: in a chat-style
/// layout Home lands on the newest (top of the reverse stack), End on the
/// oldest.
///
/// ### Focus
///
/// The default [autofocus] is **false**. Most chat layouts host a composer
/// `TextField` below the viewport which should keep focus on mount — an
/// autofocused wrapper here would silently steal the cursor and force the
/// user to tap the input before typing. Pass `autofocus: true` when the
/// wrapper is the only focusable on the route.
///
/// Tapping or clicking the wrapped child also requests focus on the
/// internal node, so the shortcuts become live after the user interacts
/// with the chat even when [autofocus] is `false`. Focus is *not* re-
/// requested if the wrapper already owns it (no churn for repeated taps).
///
/// ### Example
///
/// ```dart
/// ChatKeyboardShortcuts(
///   controller: _controller,
///   dataSource: _ds,
///   child: ChatScrollView(
///     controller: _controller,
///     dataSource: _ds,
///     messageBuilder: _buildBubble,
///   ),
/// )
/// ```
class ChatKeyboardShortcuts extends StatefulWidget {
  const ChatKeyboardShortcuts({
    required this.controller,
    required this.dataSource,
    required this.child,
    this.reverse = false,
    this.lineExtent = 60.0,
    this.pageExtent,
    this.pageFraction = 0.85,
    this.autofocus = false,
    super.key,
  });

  final ChatScrollController controller;
  final ChatDataSource dataSource;
  final Widget child;

  /// Mirrors `ChatScrollView.reverse`. When `true`, PageUp / Home reveal
  /// older history (the chat-app intuition) instead of "scroll the
  /// container up".
  final bool reverse;

  /// Pixel step for arrow keys. Approximates one message-row scroll —
  /// tune to your typical row height. Not derived from text-line metrics.
  final double lineExtent;

  /// Pixel step for PageUp / PageDown. `null` derives the step from the
  /// wrapper's measured height × [pageFraction] at key-fire time (falling
  /// back to `MediaQuery.sizeOf(context).height` only before the first
  /// layout has produced a measurement).
  final double? pageExtent;

  /// Fraction of the viewport height to use as the page step when
  /// [pageExtent] is `null`. 0.85 keeps a small overlap between pages.
  final double pageFraction;

  /// When `true`, the wrapper claims keyboard focus on mount so the
  /// shortcuts respond without a click. Defaults to `false` so the typical
  /// chat layout's composer `TextField` keeps focus by default.
  final bool autofocus;

  @override
  State<ChatKeyboardShortcuts> createState() =>
      _ChatKeyboardShortcutsState();
}

class _ChatKeyboardShortcutsState extends State<ChatKeyboardShortcuts> {
  late final FocusNode _focusNode;

  /// Latest height the `LayoutBuilder` reported for the wrapped subtree —
  /// the actual viewport size, not the full screen. `null` until the first
  /// layout has produced a finite measurement (e.g. before mount completes
  /// or inside an unbounded ancestor).
  double? _viewportHeight;

  /// Static shortcut map — `const`-promotable so the framework can compare
  /// by identity across rebuilds rather than reallocating per frame.
  static const Map<ShortcutActivator, Intent> _kShortcuts =
      <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp): _ScrollLineUpIntent(),
    SingleActivator(LogicalKeyboardKey.arrowDown): _ScrollLineDownIntent(),
    SingleActivator(LogicalKeyboardKey.pageUp): _ScrollPageUpIntent(),
    SingleActivator(LogicalKeyboardKey.pageDown): _ScrollPageDownIntent(),
    SingleActivator(LogicalKeyboardKey.home): _JumpHomeIntent(),
    SingleActivator(LogicalKeyboardKey.end): _JumpEndIntent(),
  };

  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    _ScrollLineUpIntent: CallbackAction<_ScrollLineUpIntent>(
      onInvoke: (_) => _onScrollLines(_scrollOlderSign),
    ),
    _ScrollLineDownIntent: CallbackAction<_ScrollLineDownIntent>(
      onInvoke: (_) => _onScrollLines(_scrollNewerSign),
    ),
    _ScrollPageUpIntent: CallbackAction<_ScrollPageUpIntent>(
      onInvoke: (_) => _onScrollPage(_scrollOlderSign),
    ),
    _ScrollPageDownIntent: CallbackAction<_ScrollPageDownIntent>(
      onInvoke: (_) => _onScrollPage(_scrollNewerSign),
    ),
    _JumpHomeIntent: CallbackAction<_JumpHomeIntent>(
      onInvoke: (_) => _onJumpHome(),
    ),
    _JumpEndIntent: CallbackAction<_JumpEndIntent>(
      onInvoke: (_) => _onJumpEnd(),
    ),
  };

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'ChatKeyboardShortcuts');
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Scroll sign for keys whose intuition is "go back in time" (PageUp,
  /// ArrowUp). `controller.scrollBy` is *anchor*-relative — its sign does
  /// not flip with `reverse` (the message-id direction is the same in
  /// both layouts; `reverse` only changes short-content stacking and a11y
  /// labelling). So PageUp / ArrowUp always pass `+lineExtent / +step`.
  static const int _scrollOlderSign = 1;
  static const int _scrollNewerSign = -1;

  Object? _onScrollLines(int sign) {
    widget.controller.scrollBy(widget.lineExtent * sign);
    return null;
  }

  Object? _onScrollPage(int sign) {
    final pageExtent = widget.pageExtent;
    // Viewport-relative default: the wrapper's measured height (captured
    // by the `LayoutBuilder` below). Falls back to the ambient `MediaQuery`
    // only if a key fires before the first layout — covers a stray pre-
    // layout invocation rather than the steady-state default. `pageFraction`
    // keeps a small overlap between pages.
    final viewport = _viewportHeight ?? MediaQuery.sizeOf(context).height;
    final step = pageExtent ?? viewport * widget.pageFraction;
    widget.controller.scrollBy(step * sign);
    return null;
  }

  Object? _onJumpHome() {
    // In a chat-style (`reverse: true`) layout Home conventionally lands on
    // the most recent message — the top of a reverse-stacked list — so the
    // jump-target ids flip with reverse even though the scroll signs do
    // not.
    final id = widget.reverse
        ? widget.dataSource.newestKnownId
        : widget.dataSource.oldestKnownId;
    if (id != null) widget.controller.jumpTo(id);
    return null;
  }

  Object? _onJumpEnd() {
    final id = widget.reverse
        ? widget.dataSource.oldestKnownId
        : widget.dataSource.newestKnownId;
    if (id != null) widget.controller.jumpTo(id);
    return null;
  }

  /// Translucent pointer-down handler that grabs focus when the user taps
  /// or clicks anywhere inside the viewport. Without this the shortcuts
  /// are dead until the wrapper is focused by traversal — `autofocus` is
  /// off by default so the composer keeps focus on mount, but the user
  /// still expects a tap on the chat to make arrow keys work.
  ///
  /// The translucent `Listener` always fires regardless of who else
  /// consumed the pointer, so a tap on a focusable descendant (e.g. an
  /// inline reply input, a focusable selectable text inside a message)
  /// would otherwise have its focus immediately yanked back to the
  /// wrapper. Skip the grab when focus already landed inside our subtree.
  void _handlePointerDown(PointerDownEvent _) {
    if (_focusNode.hasFocus) return;
    final scope = _focusNode.enclosingScope;
    final focused = scope?.focusedChild ?? FocusManager.instance.primaryFocus;
    if (focused != null && focused != _focusNode) {
      // Walk up: if the current primary focus sits inside our subtree, the
      // descendant intentionally claimed focus on this tap. Leave it alone.
      FocusNode? n = focused;
      while (n != null) {
        if (n == _focusNode) return;
        n = n.parent;
      }
    }
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: _kShortcuts,
    child: Actions(
      actions: _actions,
      child: Focus(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handlePointerDown,
          // `LayoutBuilder` captures the wrapper's actual height so PageUp /
          // PageDown step against the chat viewport rather than the full
          // screen (the previous `MediaQuery.sizeOf(context).height` default
          // overshot whenever the wrapper sat under an `AppBar`, above a
          // composer, or inside a constrained pane). Reading from inside the
          // builder is cheap — no per-frame allocation; the captured height
          // is only consumed when a Page key actually fires.
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              if (constraints.hasBoundedHeight) {
                _viewportHeight = constraints.maxHeight;
              }
              return widget.child;
            },
          ),
        ),
      ),
    ),
  );
}

// --- Intents --------------------------------------------------------------

class _ScrollLineUpIntent extends Intent {
  const _ScrollLineUpIntent();
}

class _ScrollLineDownIntent extends Intent {
  const _ScrollLineDownIntent();
}

class _ScrollPageUpIntent extends Intent {
  const _ScrollPageUpIntent();
}

class _ScrollPageDownIntent extends Intent {
  const _ScrollPageDownIntent();
}

class _JumpHomeIntent extends Intent {
  const _JumpHomeIntent();
}

class _JumpEndIntent extends Intent {
  const _JumpEndIntent();
}
