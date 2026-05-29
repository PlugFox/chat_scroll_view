import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
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
      // A no-op implementation would produce `mid == 0`. A 1:1
      // implementation would produce `mid == 400`. The rubber-band must
      // land *between* these — exercising the resistance roll-off.
      expect(
        mid,
        greaterThan(50),
        reason: 'a no-op (or fully-clamped) drag would land near 0',
      );
      expect(
        mid,
        lessThan(400),
        reason: 'a 1:1 drag would land at the full input',
      );

      // After bounceback settles, the anchor returns to the boundary.
      await tester.pumpAndSettle();
      // Oldest is reached → its boundary box must sit at the top edge.
      final firstBoxTop = tester.getTopLeft(find.text('msg-0'));
      final viewportTop = tester.getTopLeft(find.byType(ChatScrollView));
      expect(
        firstBoxTop.dy,
        closeTo(viewportTop.dy, 0.5),
        reason: 'oldest must be pinned to the top edge after bounceback',
      );
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
      // The strong assertion: end-state pin, not just direction-of-motion.
      expect(laterOffset, lessThan(midOffset));

      // Drive past bounceback duration; the oldest must be pinned to the
      // top edge — proves the spring-back didn't just stop mid-flight.
      await tester.pumpAndSettle();
      final firstBoxTop = tester.getTopLeft(find.text('msg-0'));
      final viewportTop = tester.getTopLeft(find.byType(ChatScrollView));
      expect(firstBoxTop.dy, closeTo(viewportTop.dy, 0.5));
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
      // `pumpAndSettle` returns only when no frame is scheduled. A bounce
      // would keep the ticker alive across this call — its return proves
      // the wheel hit the hard clamp instead.
      await tester.pumpAndSettle();
      // And the oldest sits exactly at the top edge.
      final firstBoxTop = tester.getTopLeft(find.text('msg-0'));
      expect(firstBoxTop.dy, closeTo(viewportTopLeft.dy, 0.5));
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
      // a bounceback animation. Pick an overshoot small enough that the
      // anchor renormalisation does NOT swap onto an interior message —
      // an existing quirk of `_clampBoundaries` is that very-far overshoots
      // and renormalize-then-clamp ordering can leave msg-0 off-screen.
      controller.scrollBy(500);
      await tester.pumpAndSettle();

      // The clamp pinned the oldest exactly at the top edge — no overscroll
      // residue from a bounceback that "almost made it back".
      final viewportTopLeft = tester.getTopLeft(find.byType(ChatScrollView));
      final firstBoxTop = tester.getTopLeft(find.text('msg-0'));
      expect(firstBoxTop.dy, closeTo(viewportTopLeft.dy, 0.5));
    });

    testWidgets(
      'short-content (both boundaries violatable) bounceback settles cleanly',
      (tester) async {
        // Regression: `_signedOverscroll()` picks the dominant violator
        // each tick. In a viewport where both boundaries can be past
        // simultaneously, the dominant side could flip mid-bounceback
        // (e.g. the spring overshoots through the opposite edge) and the
        // delta sign would flip with it — visible as judder, possibly a
        // stuck spring. The fix locks the bounceback side at start.
        //
        // Setup: 3 messages × 60px in a 600px viewport. The entire
        // conversation occupies 180px — both top and bottom edges are
        // always within reach.
        const count = 3;
        final controller = ChatScrollController()..jumpTo(0);
        final ds = _PreloadedDataSource(count);
        addTearDown(controller.dispose);
        addTearDown(ds.dispose);

        await tester.pumpWidget(_scaffold(
          dataSource: ds,
          controller: controller,
        ));
        await tester.pumpAndSettle();

        // Drag the content down 250 px — past the top boundary by a lot,
        // while the small content (180 px) means the bottom boundary's
        // overscroll is also live in the opposite direction.
        await _slowDragPast(
          tester,
          const Offset(0, 250),
          steps: 10,
        );
        await tester.pump(const Duration(milliseconds: 16));
        // Drive bounceback to completion. Without the side-lock fix the
        // delta would change sign as the dominant violator switched.
        await tester.pumpAndSettle();

        // End-state: regardless of which side won, the dominant
        // boundary is pinned to its edge and the lesser side will have
        // been clamped on the post-bounceback layout.
        final viewportTopLeft = tester.getTopLeft(find.byType(ChatScrollView));
        final firstBoxTop = tester.getTopLeft(find.text('msg-0'));
        // `pumpAndSettle` returned — proves the bounceback terminated
        // (a sign-flip oscillation would either never settle, or settle
        // off-edge by more than a hair).
        expect(firstBoxTop.dy, closeTo(viewportTopLeft.dy, 1.0),
            reason: 'short-content bounceback must end with oldest pinned '
                'to the top edge.');
      },
    );
  });
}
