import 'dart:ui';

import 'package:flutter/gestures.dart' show PointerDownEvent, PointerEvent;

/// Overlay scrollbar for the chat viewport.
///
/// Pure geometry, paint, and drag-pointer state — no dependency on the render
/// object, the data source, or the controller. [RenderChatScrollView] owns the
/// id ⇄ progress mapping; it routes pointer events here and feeds [paint] a
/// 0..1 thumb progress derived from the anchor.
class ChatScrollbar {
  /// Width of the invisible touch strip along the right edge.
  static const double hitWidth = 32.0;

  static const double _trackWidth = 4.0;
  static const double _activeTrackWidth = 6.0;
  static const double _thumbHeight = 48.0;
  static const double _pad = 8.0;
  static const double _right = 4.0;

  /// Pointer id of the in-progress scrollbar drag, or `null` when idle.
  int? _pointer;

  /// Whether a scrollbar drag is currently in progress.
  bool get isDragging => _pointer != null;

  /// Whether [localX] falls inside the trailing-edge touch strip. The strip
  /// sits on the right in LTR and on the left in RTL — matching where the
  /// user expects the scrollbar to be in their reading order.
  bool inHitArea(
    double localX,
    Size size,
    TextDirection direction,
  ) => direction == TextDirection.rtl
      ? localX <= hitWidth
      : localX >= size.width - hitWidth;

  /// Begin a drag if [event] landed in the touch strip. Returns `true` when
  /// the drag was claimed (the caller should then consume the event).
  bool tryStartDrag(
    PointerDownEvent event,
    Size size,
    TextDirection direction,
  ) {
    if (!inHitArea(event.localPosition.dx, size, direction)) return false;
    _pointer = event.pointer;
    return true;
  }

  /// Whether [event] belongs to the active scrollbar drag.
  bool ownsPointer(PointerEvent event) => event.pointer == _pointer;

  /// End the active drag.
  void endDrag() => _pointer = null;

  /// Map a pointer Y inside the track to a 0..1 thumb progress (clamped).
  double progressFromY(double localY, Size size) {
    final travel = size.height - _pad * 2 - _thumbHeight;
    if (travel <= 0) return 0.0;
    return ((localY - _pad - _thumbHeight / 2) / travel).clamp(0.0, 1.0);
  }

  /// Cached paints — every Tier-1 paint tick hits this method, so allocating
  /// fresh [Paint] objects each time is wasted GC pressure.
  final Paint _trackPaint = Paint()..color = const Color(0x1A000000);
  final Paint _thumbPaint = Paint();

  /// Paint the track and thumb. [progress] is the 0..1 thumb position;
  /// [direction] places the track on the trailing edge (right in LTR, left
  /// in RTL).
  void paint(
    Canvas canvas,
    Offset offset,
    Size size,
    double progress,
    TextDirection direction,
  ) {
    final trackWidth = isDragging ? _activeTrackWidth : _trackWidth;
    final trackX = direction == TextDirection.rtl
        ? offset.dx + _right
        : offset.dx + size.width - _right - trackWidth;
    final trackY = offset.dy + _pad;
    final trackHeight = size.height - _pad * 2;
    if (trackHeight <= 0) return;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(trackX, trackY, trackWidth, trackHeight),
        Radius.circular(trackWidth / 2),
      ),
      _trackPaint,
    );

    final travel = trackHeight - _thumbHeight;
    if (travel <= 0) return;
    final thumbY = trackY + travel * progress;
    _thumbPaint.color = Color(isDragging ? 0x99000000 : 0x66000000);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(trackX, thumbY, trackWidth, _thumbHeight),
        Radius.circular(trackWidth / 2),
      ),
      _thumbPaint,
    );
  }
}
