import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
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
  Duration highlightDuration = const Duration(milliseconds: 600),
  Color highlightColor = const Color(0x80FF0000),
  double cacheExtent = 1000,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 600,
        child: ChatScrollView(
          dataSource: dataSource,
          controller: controller,
          cacheExtent: cacheExtent,
          highlightColor: highlightColor,
          highlightDuration: highlightDuration,
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

/// Helper: drive an animateTo to completion with explicit ticker frames.
/// `await controller.animateTo(...)` alone would never resolve because the
/// future needs the ticker to fire — and the ticker only runs across pumps.
Future<void> _driveAnimate(
  WidgetTester tester,
  Future<void> animateFuture, {
  required Duration animateDuration,
}) async {
  await tester.pump();
  // One pump per ~16 ms of animation; plus 32 ms of slack for the final
  // tick that crosses t == 1.0 and the `_completeAnimate` follow-up.
  final pumps = (animateDuration.inMilliseconds ~/ 16) + 2;
  for (var i = 0; i < pumps; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await animateFuture;
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  group('animateTo highlight', () {
    testWidgets('close-path animateTo lands the highlight on the target', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
      ));
      await tester.pumpAndSettle();
      expect(_render(tester).debugHighlightTargetId, isNull);

      const target = 120;
      final future = controller.animateTo(
        target,
        duration: const Duration(milliseconds: 80),
      );
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        _render(tester).debugHighlightTargetId,
        isNull,
        reason: 'no highlight while animation is in transit',
      );

      await _driveAnimate(
        tester,
        future,
        animateDuration: const Duration(milliseconds: 80),
      );

      expect(_render(tester).debugHighlightTargetId, target);
      expect(_render(tester).debugHighlightFactor, greaterThan(0.0));
      expect(_render(tester).debugHighlightFactor, lessThanOrEqualTo(1.0));
    });

    testWidgets('highlight clears once the duration elapses', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        highlightDuration: const Duration(milliseconds: 200),
      ));
      await tester.pumpAndSettle();

      final future = controller.animateTo(
        120,
        duration: const Duration(milliseconds: 80),
      );
      await _driveAnimate(
        tester,
        future,
        animateDuration: const Duration(milliseconds: 80),
      );
      expect(_render(tester).debugHighlightTargetId, 120);

      // Advance past the highlight duration.
      await tester.pump(const Duration(milliseconds: 220));
      expect(_render(tester).debugHighlightTargetId, isNull);
      expect(_render(tester).debugHighlightFactor, 0.0);
    });

    testWidgets('factor monotonically decreases across frames', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        highlightDuration: const Duration(milliseconds: 800),
      ));
      await tester.pumpAndSettle();

      final future = controller.animateTo(
        120,
        duration: const Duration(milliseconds: 60),
      );
      await _driveAnimate(
        tester,
        future,
        animateDuration: const Duration(milliseconds: 60),
      );
      final f0 = _render(tester).debugHighlightFactor;
      await tester.pump(const Duration(milliseconds: 100));
      final f1 = _render(tester).debugHighlightFactor;
      await tester.pump(const Duration(milliseconds: 100));
      final f2 = _render(tester).debugHighlightFactor;

      expect(f0, greaterThan(f1));
      expect(f1, greaterThan(f2));
    });

    testWidgets('zero-duration animate falls through to jumpTo, no highlight', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
      ));
      await tester.pumpAndSettle();

      // Zero-duration animateTo synchronously jumps and returns immediately.
      await controller.animateTo(120, duration: Duration.zero);
      await tester.pump();

      expect(_render(tester).debugHighlightTargetId, isNull);
    });

    testWidgets('highlightDuration = 0 disables the effect entirely', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        highlightDuration: Duration.zero,
      ));
      await tester.pumpAndSettle();

      final future = controller.animateTo(
        120,
        duration: const Duration(milliseconds: 80),
      );
      await _driveAnimate(
        tester,
        future,
        animateDuration: const Duration(milliseconds: 80),
      );

      expect(_render(tester).debugHighlightTargetId, isNull);
    });

    testWidgets('re-entrant animateTo retargets the highlight', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        highlightDuration: const Duration(milliseconds: 800),
      ));
      await tester.pumpAndSettle();

      // First animation lands.
      final firstFuture = controller.animateTo(
        120,
        duration: const Duration(milliseconds: 60),
      );
      await _driveAnimate(
        tester,
        firstFuture,
        animateDuration: const Duration(milliseconds: 60),
      );
      expect(_render(tester).debugHighlightTargetId, 120);

      // Start a new animation while the previous highlight is still active.
      // The new animateTo's setup clears the leftover highlight; once the
      // new one lands, it owns the highlight.
      final secondFuture = controller.animateTo(
        125,
        duration: const Duration(milliseconds: 80),
      );
      await tester.pump();
      expect(
        _render(tester).debugHighlightTargetId,
        isNull,
        reason: 'old highlight is cleared at the start of the new animateTo',
      );

      await _driveAnimate(
        tester,
        secondFuture,
        animateDuration: const Duration(milliseconds: 80),
      );
      expect(_render(tester).debugHighlightTargetId, 125);
    });

    testWidgets('drag during highlight does not cancel the fade', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        highlightDuration: const Duration(milliseconds: 800),
      ));
      await tester.pumpAndSettle();

      final future = controller.animateTo(
        120,
        duration: const Duration(milliseconds: 60),
      );
      await _driveAnimate(
        tester,
        future,
        animateDuration: const Duration(milliseconds: 60),
      );
      expect(_render(tester).debugHighlightTargetId, 120);

      // A short drag — won't sweep msg-120 off-screen at 60 px tall.
      await tester.drag(find.byType(ChatScrollView), const Offset(0, 30));
      await tester.pump();
      expect(_render(tester).debugHighlightTargetId, 120);
    });
  });
}
