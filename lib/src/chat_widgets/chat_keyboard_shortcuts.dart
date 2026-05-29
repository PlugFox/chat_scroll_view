import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Wraps a [child] in a `Shortcuts` + `Actions` + `Focus` stack that handles
/// the canonical desktop keyboard navigation for a chat viewport:
///
/// * `ArrowUp` / `ArrowDown` — scroll by one [lineExtent] (default 60 px).
/// * `PageUp` / `PageDown` — scroll by [pageExtent]; when `null`, falls back
///   to the receiver's `MediaQuery.size.height * pageFraction` so the page
///   step roughly matches the viewport height.
/// * `Home` — `controller.jumpTo(dataSource.oldestKnownId)`. No-op when the
///   oldest is unknown (initial load).
/// * `End` — `controller.jumpTo(dataSource.newestKnownId)`.
///
/// Direction-flipping when `reverse` is `true` (chat-style stacking) — so
/// `PageUp` still reveals *older* messages, which is what chat users expect.
///
/// The wrapper requests focus eagerly so the bindings work without an
/// explicit click; set [autofocus] to `false` if the host already manages
/// focus traversal.
class ChatKeyboardShortcuts extends StatefulWidget {
  const ChatKeyboardShortcuts({
    required this.controller,
    required this.dataSource,
    required this.child,
    this.reverse = false,
    this.lineExtent = 60.0,
    this.pageExtent,
    this.pageFraction = 0.85,
    this.autofocus = true,
    super.key,
  });

  final ChatScrollController controller;
  final ChatDataSource dataSource;
  final Widget child;

  /// Mirrors `ChatScrollView.reverse`. When `true`, PageUp / Home reveal
  /// older history (the chat-app intuition) instead of "scroll the
  /// container up".
  final bool reverse;

  /// Pixel step for arrow keys.
  final double lineExtent;

  /// Pixel step for PageUp / PageDown. `null` derives the step from the
  /// available size's height × [pageFraction].
  final double? pageExtent;

  /// Fraction of the viewport height to use as the page step when
  /// [pageExtent] is `null`. 0.85 keeps a small overlap between pages.
  final double pageFraction;

  /// When `true`, the wrapper claims keyboard focus on mount so the
  /// shortcuts respond without a click. Pass `false` if the host owns
  /// focus traversal.
  final bool autofocus;

  @override
  State<ChatKeyboardShortcuts> createState() =>
      _ChatKeyboardShortcutsState();
}

class _ChatKeyboardShortcutsState extends State<ChatKeyboardShortcuts> {
  late final FocusNode _focusNode;

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

  double _resolvePageStep(double viewportHeight) =>
      widget.pageExtent ?? (viewportHeight * widget.pageFraction);

  /// Sign convention: `controller.scrollBy(+px)` reveals **older** messages
  /// (content shifts down). Reverse mode flips the intended direction for
  /// PageUp / Home / ArrowUp.
  void _scrollLines(int sign) {
    widget.controller.scrollBy(widget.lineExtent * sign);
  }

  void _scrollPage(int sign, double viewportHeight) {
    widget.controller.scrollBy(_resolvePageStep(viewportHeight) * sign);
  }

  void _jumpHome() {
    final id = widget.reverse
        ? widget.dataSource.newestKnownId
        : widget.dataSource.oldestKnownId;
    if (id != null) widget.controller.jumpTo(id);
  }

  void _jumpEnd() {
    final id = widget.reverse
        ? widget.dataSource.oldestKnownId
        : widget.dataSource.newestKnownId;
    if (id != null) widget.controller.jumpTo(id);
  }

  @override
  Widget build(BuildContext context) {
    // Reverse-aware sign for keys that mean "go back in time": PageUp /
    // ArrowUp reveal older history in either stacking mode.
    final olderSign = widget.reverse ? -1 : 1;
    final newerSign = -olderSign;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.of(context).size.height;
        return Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowUp): _ScrollLineUpIntent(),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                _ScrollLineDownIntent(),
            SingleActivator(LogicalKeyboardKey.pageUp): _ScrollPageUpIntent(),
            SingleActivator(LogicalKeyboardKey.pageDown):
                _ScrollPageDownIntent(),
            SingleActivator(LogicalKeyboardKey.home): _JumpHomeIntent(),
            SingleActivator(LogicalKeyboardKey.end): _JumpEndIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _ScrollLineUpIntent: CallbackAction<_ScrollLineUpIntent>(
                onInvoke: (_) {
                  _scrollLines(olderSign);
                  return null;
                },
              ),
              _ScrollLineDownIntent: CallbackAction<_ScrollLineDownIntent>(
                onInvoke: (_) {
                  _scrollLines(newerSign);
                  return null;
                },
              ),
              _ScrollPageUpIntent: CallbackAction<_ScrollPageUpIntent>(
                onInvoke: (_) {
                  _scrollPage(olderSign, viewportHeight);
                  return null;
                },
              ),
              _ScrollPageDownIntent: CallbackAction<_ScrollPageDownIntent>(
                onInvoke: (_) {
                  _scrollPage(newerSign, viewportHeight);
                  return null;
                },
              ),
              _JumpHomeIntent: CallbackAction<_JumpHomeIntent>(
                onInvoke: (_) {
                  _jumpHome();
                  return null;
                },
              ),
              _JumpEndIntent: CallbackAction<_JumpEndIntent>(
                onInvoke: (_) {
                  _jumpEnd();
                  return null;
                },
              ),
            },
            child: Focus(
              focusNode: _focusNode,
              autofocus: widget.autofocus,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
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
