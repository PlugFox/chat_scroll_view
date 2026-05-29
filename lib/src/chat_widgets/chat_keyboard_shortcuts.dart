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
///   to `MediaQuery.sizeOf(context).height * pageFraction` so the page step
///   roughly matches the viewport height. The `MediaQuery` is read *when
///   the key fires*, not on every rebuild.
/// * `Home` — `controller.jumpTo(dataSource.oldestKnownId)`. No-op when the
///   oldest is unknown (initial load).
/// * `End` — `controller.jumpTo(dataSource.newestKnownId)`.
///
/// Direction-flipping when `reverse` is `true` (chat-style stacking) — so
/// `PageUp` still reveals *older* messages, which is what chat users expect.
///
/// ### Focus
///
/// The default [autofocus] is **false**. Most chat layouts host a composer
/// `TextField` below the viewport which should keep focus on mount — an
/// autofocused wrapper here would silently steal the cursor and force the
/// user to tap the input before typing. Pass `autofocus: true` when the
/// wrapper is the only focusable on the route.
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

  /// Pixel step for PageUp / PageDown. `null` derives the step from
  /// `MediaQuery.sizeOf(context).height * pageFraction` at key-fire time.
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
      onInvoke: (_) => _onScrollLines(_olderSign),
    ),
    _ScrollLineDownIntent: CallbackAction<_ScrollLineDownIntent>(
      onInvoke: (_) => _onScrollLines(_newerSign),
    ),
    _ScrollPageUpIntent: CallbackAction<_ScrollPageUpIntent>(
      onInvoke: (_) => _onScrollPage(_olderSign),
    ),
    _ScrollPageDownIntent: CallbackAction<_ScrollPageDownIntent>(
      onInvoke: (_) => _onScrollPage(_newerSign),
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

  /// Sign for keys whose intuition is "go back in time" (PageUp, ArrowUp,
  /// Home in non-reverse layouts). Reverse mode flips it so PageUp still
  /// reveals older history.
  int get _olderSign => widget.reverse ? -1 : 1;
  int get _newerSign => -_olderSign;

  Object? _onScrollLines(int sign) {
    widget.controller.scrollBy(widget.lineExtent * sign);
    return null;
  }

  Object? _onScrollPage(int sign) {
    final pageExtent = widget.pageExtent;
    final step = pageExtent ??
        MediaQuery.sizeOf(context).height * widget.pageFraction;
    widget.controller.scrollBy(step * sign);
    return null;
  }

  Object? _onJumpHome() {
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

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: _kShortcuts,
    child: Actions(
      actions: _actions,
      child: Focus(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        child: widget.child,
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
