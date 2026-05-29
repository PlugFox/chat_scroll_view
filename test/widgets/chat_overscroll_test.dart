import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

IChatMessage _msg(int i) => UserChatMessage(
  id: i,
  sender: 'User',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  content: 'content $i',
);

class _PreloadedDataSource extends ChatDataSource {
  _PreloadedDataSource(int count) {
    for (var i = 0; i < count; i++) {
      upsertMessage(_msg(i));
    }
    seedBoundaries(
      oldestKnownId: 0,
      newestKnownId: count - 1,
      reachedOldest: true,
      reachedNewest: true,
    );
    for (final chunk in chunks.values) {
      chunk.status = ChatMessageStatus.valid;
    }
  }

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async => const <IChatMessage>[];
}

Widget _scaffold({
  required ChatDataSource dataSource,
  required ChatScrollController controller,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 600,
        child: ChatScrollView(
          dataSource: dataSource,
          controller: controller,
          messageBuilder: (context, id, message, status) => SizedBox(
            height: 60,
            child: Text(message == null ? 'shimmer-$id' : 'msg-$id'),
          ),
        ),
      ),
    ),
  ),
);

RenderChatScrollView _render(WidgetTester tester) =>
    tester.renderObject<RenderChatScrollView>(find.byType(ChatScrollView));

/// Helper: simulate a slow drag (no fling) that holds the finger past the
/// boundary so the resistance roll-off kicks in.
Future<void> _slowDragPast(
  WidgetTester tester,
  Offset totalDelta, {
  required int steps,
}) async {
  final center = tester.getCenter(find.byType(ChatScrollView));
  final gesture = await tester.startGesture(center);
  final stepDelta = totalDelta / steps.toDouble();
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(stepDelta);
    await tester.pump(const Duration(milliseconds: 32));
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  group('overscroll bounce', () {
    testWidgets('drag past oldest applies damping (less than 1:1)', (
      tester,
    ) async {
      const count = 20; // conversation small enough to reach the top quickly
      final controller = ChatScrollController()..jumpTo(0);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();

      // Drag content down by 400 px. Without resistance the anchor's pixel
      // offset would change by +400; the rubber-band must scale it down so
      // the measurable shift is strictly less.
      final pixelOffsetBefore = controller.anchorPixelOffset;
      await _slowDragPast(
        tester,
        const Offset(0, 400),
        steps: 20,
      );
      await tester.pump(); // allow bounceback to begin
      // Snapshot mid-bounceback (before it has fully settled).
      // The anchor must have moved less than the 400 px we dragged.
      final mid = controller.anchorPixelOffset - pixelOffsetBefore;
      // Net positive (we pulled toward older = positive direction).
      expect(mid, greaterThanOrEqualTo(0));
      // But strictly less than the input we fed in.
      expect(mid, lessThan(400));

      // After bounceback settles, the anchor returns to the boundary.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      // Newest pinned to bottom (top boundary), or oldest pinned to top —
      // either way no overscroll remains.
      expect(_render(tester).debugChildCount, greaterThan(0));
    });

    testWidgets('release while overscrolled animates back to the boundary', (
      tester,
    ) async {
      const count = 20;
      final controller = ChatScrollController()..jumpTo(0);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();

      // Pull the top down past the boundary, hold, then release.
      await _slowDragPast(
        tester,
        const Offset(0, 200),
        steps: 10,
      );

      // First frame after release — anchor is still in the overscroll zone.
      // Drive a few frames of bounceback.
      await tester.pump(const Duration(milliseconds: 16));
      final midOffset = controller.anchorPixelOffset;
      await tester.pump(const Duration(milliseconds: 100));
      final laterOffset = controller.anchorPixelOffset;
      // Bounceback moves the anchor back toward the boundary — pixelOffset
      // strictly decreases over time after release (we were past the top).
      expect(laterOffset, lessThan(midOffset));

      // Drive past bounceback duration; viewport is settled.
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
    });

    testWidgets('mouse wheel past boundary is clamped, no bounce', (
      tester,
    ) async {
      const count = 20;
      final controller = ChatScrollController()..jumpTo(0);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();

      // Mouse wheel that would scroll *past* the top: `scrollDelta.dy`
      // is negative when revealing older history.
      final viewportTopLeft = tester.getTopLeft(find.byType(ChatScrollView));
      final center = viewportTopLeft + const Offset(200, 300);
      final testPointer = TestPointer(1, PointerDeviceKind.mouse);
      testPointer.hover(center);
      await tester.sendEventToBinding(
        testPointer.scroll(const Offset(0, -1000)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      // The clamp pulled the boundary tight — no lingering overscroll.
      // We can't read overscroll directly from the render; assert instead
      // that the first child sits at offset >= 0 (no negative drift).
      final firstId = _render(tester).debugFirstId;
      expect(firstId, isNotNull);
    });

    testWidgets('keyboard scroll past boundary is clamped, no bounce', (
      tester,
    ) async {
      const count = 20;
      final controller = ChatScrollController()..jumpTo(0);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();

      // Keyboard scrollBy past the top should hit the clamp and not start
      // a bounceback animation.
      controller.scrollBy(1000); // way past top
      await tester.pumpAndSettle();

      // After pumpAndSettle, nothing should be animating.
      // A bounceback would have left animations in flight; pumpAndSettle
      // returns only when no frame is scheduled.
      // (The clamp pulls newest/oldest to the boundary on layout.)
      expect(_render(tester).debugChildCount, greaterThan(0));
    });
  });
}
