import 'dart:ui' as ui;

import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// ---------------------------------------------------------------------------
// Variant 1: CustomPaint — identical Canvas rendering to ChatScrollView's
// _DemoMessageRender. Apples-to-apples comparison of architecture overhead.
// ---------------------------------------------------------------------------

/// ListView.builder chat with CustomPaint message bubbles.
/// Uses the exact same ui.ParagraphBuilder + Canvas.drawRRect rendering
/// as the ChatScrollView demo, so any performance difference is purely
/// architectural (Sliver protocol vs custom LeafRenderObject).
class ListViewChatCustomPaint extends StatelessWidget {
  const ListViewChatCustomPaint({
    super.key,
    required this.messages,
    required this.scrollController,
  });

  final List<IChatMessage> messages;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: scrollController,
    physics: const ClampingScrollPhysics(),
    itemCount: messages.length,
    itemBuilder: (_, index) => CustomPaintBubble(message: messages[index]),
  );
}

class CustomPaintBubble extends LeafRenderObjectWidget {
  const CustomPaintBubble({super.key, required this.message});

  final IChatMessage message;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderCustomPaintBubble(message);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCustomPaintBubble renderObject,
  ) {
    renderObject.message = message;
  }
}

class RenderCustomPaintBubble extends RenderBox {
  RenderCustomPaintBubble(this._message);

  static const double _padding = 12.0;
  static const double _bubblePadding = 16.0;
  static const double _bubbleRadius = 12.0;

  IChatMessage _message;
  ui.Paragraph? _paragraph;
  double _lastWidth = 0;

  set message(IChatMessage value) {
    if (identical(_message, value)) return;
    _message = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final maxWidth = constraints.maxWidth;
    if (_paragraph == null || _lastWidth != maxWidth) {
      _lastWidth = maxWidth;
      _buildParagraph(maxWidth);
    }
    final height = _paragraph!.height + _bubblePadding * 2 + _padding;
    size = constraints.constrain(Size(maxWidth, height));
  }

  void _buildParagraph(double maxWidth) {
    final content = switch (_message) {
      UserChatMessage(:final content) => content,
      SystemChatMessage(:final content) => content,
      _ => 'Message #${_message.id}',
    };

    final textWidth = maxWidth - _bubblePadding * 2 - _padding * 2;
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontSize: 15.0,
              fontFamily: '.AppleSystemUIFont',
              height: 1.4,
            ),
          )
          ..pushStyle(ui.TextStyle(color: const Color(0xFF1A1A1A)))
          ..addText(content)
          ..pop();

    _paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: textWidth));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final paragraph = _paragraph;
    if (paragraph == null) return;

    final canvas = context.canvas;
    final bubbleRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        offset.dx + _padding,
        offset.dy + _padding / 2,
        size.width - _padding * 2,
        size.height - _padding,
      ),
      const Radius.circular(_bubbleRadius),
    );

    final isEven = _message.id.isEven;
    final bgColor = isEven ? const Color(0xFFE3F2FD) : const Color(0xFFF5F5F5);

    canvas.drawRRect(bubbleRect, Paint()..color = bgColor);
    canvas.save();
    canvas.translate(
      offset.dx + _padding + _bubblePadding,
      offset.dy + _padding / 2 + _bubblePadding,
    );
    canvas.drawParagraph(paragraph, Offset.zero);
    canvas.restore();
  }
}

// ---------------------------------------------------------------------------
// Variant 2: Text widget — how a real Flutter app would typically render
// chat messages. Includes RenderParagraph, semantics, accessibility.
// ---------------------------------------------------------------------------

/// ListView.builder chat with standard Text widgets.
/// Represents the idiomatic Flutter approach to building a chat list.
class ListViewChatText extends StatelessWidget {
  const ListViewChatText({
    super.key,
    required this.messages,
    required this.scrollController,
  });

  final List<IChatMessage> messages;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: scrollController,
    physics: const ClampingScrollPhysics(),
    itemCount: messages.length,
    itemBuilder: (_, index) => _TextBubble(message: messages[index]),
  );
}

class _TextBubble extends StatelessWidget {
  const _TextBubble({required this.message});

  final IChatMessage message;

  @override
  Widget build(BuildContext context) {
    final content = switch (message) {
      UserChatMessage(:final content) => content,
      SystemChatMessage(:final content) => content,
      _ => 'Message #${message.id}',
    };

    final isEven = message.id.isEven;
    final bgColor = isEven ? const Color(0xFFE3F2FD) : const Color(0xFFF5F5F5);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12.0),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            content,
            style: const TextStyle(
              fontSize: 15.0,
              fontFamily: '.AppleSystemUIFont',
              height: 1.4,
              color: Color(0xFF1A1A1A),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Benchmark wrapper that records layout/paint timing for ListView variants.
// ---------------------------------------------------------------------------

/// Wraps a ListView variant and measures layout + paint duration
/// of the internal [RenderSliverList].
class BenchmarkListViewWrapper extends SingleChildRenderObjectWidget {
  const BenchmarkListViewWrapper({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderBenchmarkListViewWrapper();
}

class RenderBenchmarkListViewWrapper extends RenderProxyBox {
  Duration debugLastLayoutDuration = Duration.zero;
  int debugLayoutFrameId = 0;
  Duration debugLastPaintDuration = Duration.zero;
  int debugPaintFrameId = 0;

  @override
  void performLayout() {
    final sw = Stopwatch()..start();
    super.performLayout();
    debugLastLayoutDuration = sw.elapsed;
    debugLayoutFrameId++;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final sw = Stopwatch()..start();
    super.paint(context, offset);
    debugLastPaintDuration = sw.elapsed;
    debugPaintFrameId++;
  }
}
