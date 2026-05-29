import 'package:chatscrollview/src/chat_scroll/chat_selection_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Per-message selection chrome for the widget-based chat viewport.
///
/// Wraps a message [child] with:
/// * a long-press / tap gesture surface driving [controller];
/// * a circular checkbox that slides in from the left in selection mode;
/// * a full-row tint behind selected messages.
///
/// ### Efficiency
///
/// The [child] (the actual message content) is handed to [AnimatedBuilder] as
/// its `child` argument, so it is built **once** and never re-built when
/// selection state changes — only the lightweight chrome around it animates.
/// The widget subtree shape is constant regardless of selection state, so the
/// content element (and any `State` it holds) survives entering / leaving
/// selection mode. When no selection controller is wired the viewport skips
/// this wrapper entirely, so it costs nothing.
class SelectableMessage extends StatefulWidget {
  const SelectableMessage({
    required this.id,
    required this.controller,
    required this.child,
    super.key,
  });

  /// Message id this row represents.
  final int id;

  /// Selection state, shared across the whole viewport.
  final ChatSelectionController controller;

  /// The message content widget.
  final Widget child;

  @override
  State<SelectableMessage> createState() => _SelectableMessageState();
}

/// Width of the checkbox gutter when selection mode is fully open.
const double _kSlotWidth = 44.0;
const double _kCheckSize = 22.0;
const Duration _kModeDuration = Duration(milliseconds: 260);
const Duration _kSelectDuration = Duration(milliseconds: 200);

class _SelectableMessageState extends State<SelectableMessage>
    with TickerProviderStateMixin {
  /// 0 → no selection mode, 1 → selection mode fully open. Shared visual.
  late final AnimationController _mode;

  /// 0 → not selected, 1 → selected. Per-message.
  late final AnimationController _select;

  late final CurvedAnimation _modeCurve;
  late final Listenable _animation;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    _mode = AnimationController(
      vsync: this,
      duration: _kModeDuration,
      value: c.isSelectionMode ? 1.0 : 0.0,
    );
    _select = AnimationController(
      vsync: this,
      duration: _kSelectDuration,
      value: c.isSelected(widget.id) ? 1.0 : 0.0,
    );
    _modeCurve = CurvedAnimation(parent: _mode, curve: Curves.easeOutCubic);
    _animation = Listenable.merge(<Listenable>[_modeCurve, _select]);
    c.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(SelectableMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerSwapped = !identical(
      oldWidget.controller,
      widget.controller,
    );
    final idSwapped = oldWidget.id != widget.id;
    if (controllerSwapped) {
      oldWidget.controller.removeListener(_onSelectionChanged);
      widget.controller.addListener(_onSelectionChanged);
    }
    // Only re-sync when something the animation depends on actually changed.
    // Parent rebuilds with the same id+controller would otherwise enqueue
    // animation work for every visible message every frame.
    if (controllerSwapped || idSwapped) {
      _onSelectionChanged();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSelectionChanged);
    _modeCurve.dispose();
    _mode.dispose();
    _select.dispose();
    super.dispose();
  }

  /// Controller callback — drive the two animations toward the new state.
  /// `animateTo` is a cheap no-op when the target already matches.
  void _onSelectionChanged() {
    final c = widget.controller;
    _mode.animateTo(c.isSelectionMode ? 1.0 : 0.0);
    _select.animateTo(c.isSelected(widget.id) ? 1.0 : 0.0);
  }

  void _handleLongPress() {
    final c = widget.controller;
    // Already selected: long-press on an already-selected message is a no-op
    // for the controller, so don't buzz either.
    if (c.isSelected(widget.id)) return;
    HapticFeedback.selectionClick();
    c.startSelection(widget.id);
  }

  void _handleTap() {
    final c = widget.controller;
    // Outside selection mode a tap on a message does nothing (there is no
    // in-message interaction in this demo); inside it toggles the message.
    if (!c.isSelectionMode) return;
    HapticFeedback.selectionClick();
    c.toggle(widget.id);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: _handleTap,
    onLongPress: _handleLongPress,
    child: AnimatedBuilder(
      animation: _animation,
      builder: _buildChrome,
      child: widget.child,
    ),
  );

  /// Builds the constant-shape chrome. [child] is the message content, passed
  /// straight through from [AnimatedBuilder] — never rebuilt here.
  Widget _buildChrome(BuildContext context, Widget? child) {
    final m = _modeCurve.value.clamp(0.0, 1.0);
    final s = _select.value.clamp(0.0, 1.0);
    final accent = Theme.of(context).colorScheme.primary;

    return Stack(
      children: <Widget>[
        // Full-row selection tint. Skipped entirely when the message is not
        // selected — a `ColoredBox` with alpha 0 still records a paint op,
        // and for a 256-msg viewport that adds up. The viewport lays every
        // message out at the full viewport width, so when shown this tint
        // spans the whole row without bleeding past a narrower box.
        if (s > 0.0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: accent.withValues(alpha: 0.13 * s)),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            // Checkbox gutter: grows 0 → _kSlotWidth, pushing the content
            // right. ClipRect hides the checkbox until the gutter opens.
            SizedBox(
              width: _kSlotWidth * m,
              child: ClipRect(
                child: Center(
                  child: _SelectionCheck(mode: m, select: s, accent: accent),
                ),
              ),
            ),
            Expanded(child: child!),
          ],
        ),
      ],
    );
  }
}

/// The circular checkbox: a grey ring that fills with [accent] and grows a
/// white checkmark when selected. [mode] fades the whole control in/out.
class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck({
    required this.mode,
    required this.select,
    required this.accent,
  });

  final double mode;
  final double select;
  final Color accent;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(_kCheckSize),
    painter: _CheckPainter(mode: mode, select: select, accent: accent),
  );
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({
    required this.mode,
    required this.select,
    required this.accent,
  });

  final double mode;
  final double select;
  final Color accent;

  /// Neutral ring color for an unselected checkbox.
  static const Color _ring = Color(0xFF8E8E93);

  @override
  void paint(Canvas canvas, Size size) {
    if (mode <= 0.0) return;
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 1.5;

    // Ring — lerps from neutral grey to the accent as the message is selected.
    final ringColor = Color.lerp(_ring, accent, select)!;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = ringColor.withValues(alpha: ringColor.a * mode),
    );

    if (select <= 0.0) return;

    // Filled disc.
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = accent.withValues(alpha: accent.a * select * mode),
    );

    // Checkmark — pops in with a slight overshoot.
    final scale = Curves.easeOutBack.transform(select);
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..scale(scale);
    final tick = Path()
      ..moveTo(-4.5, 0.5)
      ..lineTo(-1.5, 3.7)
      ..lineTo(5.0, -3.5);
    canvas
      ..drawPath(
        tick,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xFFFFFFFF).withValues(alpha: mode),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.mode != mode || old.select != select || old.accent != accent;
}
