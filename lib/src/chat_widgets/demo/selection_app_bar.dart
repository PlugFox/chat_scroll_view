import 'package:chatscrollview/src/chat_scroll/chat_selection_controller.dart';
import 'package:flutter/material.dart';

/// Contextual top bar shown while selection mode is active.
///
/// Slides down from above the viewport with a close button and a live count
/// of selected messages. Meant to be overlaid (e.g. inside a [Stack]) so the
/// chat itself never resizes — when idle it collapses to nothing.
class SelectionAppBar extends StatefulWidget {
  const SelectionAppBar({required this.selection, super.key});

  /// Selection state — drives visibility and the count.
  final ChatSelectionController selection;

  @override
  State<SelectionAppBar> createState() => _SelectionAppBarState();
}

class _SelectionAppBarState extends State<SelectionAppBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t;
  late final CurvedAnimation _slideCurve;
  late final Animation<Offset> _slide;
  bool _mode = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.selection.isSelectionMode;
    _t = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: _mode ? 1.0 : 0.0,
    );
    _slideCurve = CurvedAnimation(parent: _t, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(_slideCurve);
    widget.selection.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(SelectionAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) {
      oldWidget.selection.removeListener(_onSelectionChanged);
      widget.selection.addListener(_onSelectionChanged);
      _onSelectionChanged();
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelectionChanged);
    _slideCurve.dispose();
    _t.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    // Guard the entire callback: the selection controller's listener list is
    // owned by the controller, not the State, so a late notification (e.g.
    // controller outlives the route) can otherwise reach `_t.forward()`
    // after `_t.dispose()` ran.
    if (!mounted) return;
    final mode = widget.selection.isSelectionMode;
    if (mode != _mode) {
      _mode = mode;
      if (mode) {
        _t.forward();
      } else {
        _t.reverse();
      }
    }
    // Rebuild for the live count even when the mode itself did not change.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    builder: (context, _) {
      if (_t.isDismissed) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      return ClipRect(
        child: SlideTransition(
          position: _slide,
          child: IgnorePointer(ignoring: _t.value < 0.5, child: _bar(scheme)),
        ),
      );
    },
  );

  Widget _bar(ColorScheme scheme) => DecoratedBox(
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHigh,
      border: Border(
        bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
      ),
    ),
    child: SafeArea(
      bottom: false,
      child: SizedBox(
        height: 52,
        child: Row(
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Отменить выделение',
              color: scheme.onSurface,
              onPressed: widget.selection.clear,
            ),
            Text(
              'Выбрано: ${widget.selection.count}',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    ),
  );
}
