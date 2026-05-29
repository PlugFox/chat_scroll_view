import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scrollbar.dart';
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

/// Mounts a viewport with the given ambient `Directionality` and / or an
/// explicit override on `ChatScrollView.textDirection`.
///
/// `Directionality` must wrap the *child* of `MaterialApp.home` — the
/// MaterialApp injects its own Directionality based on the locale and would
/// shadow an outer wrapper.
Widget _scaffold({
  required ChatDataSource dataSource,
  required ChatScrollController controller,
  TextDirection ambient = TextDirection.ltr,
  TextDirection? override,
}) => MaterialApp(
  home: Directionality(
    textDirection: ambient,
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          height: 600,
          child: ChatScrollView(
            dataSource: dataSource,
            controller: controller,
            textDirection: override,
            messageBuilder: (context, id, message, status) {
              final dir = Directionality.of(context);
              return Align(
                alignment: dir == TextDirection.rtl
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: SizedBox(
                  height: 60,
                  width: 200,
                  child: Text(message == null ? 'shimmer-$id' : 'msg-$id'),
                ),
              );
            },
          ),
        ),
      ),
    ),
  ),
);

void main() {
  group('ChatScrollbar direction-awareness (unit)', () {
    test('paint places the track on the trailing edge', () {
      // We can't intercept Canvas in a unit test, but `inHitArea` mirrors
      // the same convention — so paint and hit-test stay in sync.
      const sz = Size(400, 600);
      final sb = ChatScrollbar();
      // LTR: a touch on the far-right is in the strip.
      expect(sb.inHitArea(399, sz, TextDirection.ltr), isTrue);
      // RTL: a touch on the far-left is in the strip.
      expect(sb.inHitArea(0, sz, TextDirection.rtl), isTrue);
    });
  });

  group('ChatScrollView RTL widget integration', () {
    testWidgets('scrollbar drag area is on the right in LTR', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(128);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
      ));
      await tester.pumpAndSettle();

      final viewportTopLeft = tester.getTopLeft(find.byType(ChatScrollView));
      // Hit the right-edge strip.
      final rightStripHit = viewportTopLeft + const Offset(395, 100);
      // Hit the left edge — must NOT trigger a scrollbar drag.
      final leftEdge = viewportTopLeft + const Offset(5, 100);
      final anchorBefore = controller.anchorMessageId;

      // Tap left edge → no jump.
      await tester.tapAt(leftEdge);
      await tester.pumpAndSettle();
      expect(controller.anchorMessageId, anchorBefore);

      // Tap right edge → scrollbar drag start → jumpTo somewhere.
      await tester.tapAt(rightStripHit);
      await tester.pumpAndSettle();
      expect(controller.anchorMessageId, isNot(anchorBefore));
    });

    testWidgets('scrollbar drag area mirrors to the left in RTL', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(128);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        ambient: TextDirection.rtl,
      ));
      await tester.pumpAndSettle();

      final viewportTopLeft = tester.getTopLeft(find.byType(ChatScrollView));
      final leftStripHit = viewportTopLeft + const Offset(5, 100);
      final rightEdge = viewportTopLeft + const Offset(395, 100);
      final anchorBefore = controller.anchorMessageId;

      // Right edge no longer triggers scrollbar in RTL.
      await tester.tapAt(rightEdge);
      await tester.pumpAndSettle();
      expect(controller.anchorMessageId, anchorBefore);

      // Left edge now owns the scrollbar.
      await tester.tapAt(leftStripHit);
      await tester.pumpAndSettle();
      expect(controller.anchorMessageId, isNot(anchorBefore));
    });

    testWidgets('explicit textDirection override wins over Directionality', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(128);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      // Ambient LTR but override RTL: scrollbar should sit on the left.
      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        override: TextDirection.rtl,
      ));
      await tester.pumpAndSettle();

      final viewportTopLeft = tester.getTopLeft(find.byType(ChatScrollView));
      final leftStripHit = viewportTopLeft + const Offset(5, 100);
      final anchorBefore = controller.anchorMessageId;
      await tester.tapAt(leftStripHit);
      await tester.pumpAndSettle();
      expect(controller.anchorMessageId, isNot(anchorBefore));
    });

    testWidgets('messageBuilder reads ambient Directionality for alignment', (
      tester,
    ) async {
      const count = 8;
      final controller = ChatScrollController()..jumpTo(4);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      // LTR: msg aligned to the LEFT edge of the row.
      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
      ));
      await tester.pumpAndSettle();
      final ltrPos = tester.getTopLeft(find.text('msg-4'));

      // Switch to RTL: msg should align to the RIGHT edge of the row.
      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        ambient: TextDirection.rtl,
      ));
      await tester.pumpAndSettle();
      final rtlPos = tester.getTopLeft(find.text('msg-4'));

      // The horizontal position must shift — RTL alignment puts msg on
      // the opposite side of the available row width.
      expect(rtlPos.dx, isNot(closeTo(ltrPos.dx, 1.0)));
      expect(rtlPos.dx, greaterThan(ltrPos.dx));
    });
  });

  group('Mouse wheel + scrollbar drag in RTL', () {
    testWidgets('wheel scrolls regardless of direction', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(128);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        ambient: TextDirection.rtl,
      ));
      await tester.pumpAndSettle();

      final viewportTopLeft = tester.getTopLeft(find.byType(ChatScrollView));
      final center = viewportTopLeft + const Offset(200, 300);
      final offsetBefore = controller.anchorPixelOffset;
      final testPointer = TestPointer(1, PointerDeviceKind.mouse);
      testPointer.hover(center);
      await tester.sendEventToBinding(
        testPointer.scroll(const Offset(0, 200)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.anchorPixelOffset, isNot(closeTo(offsetBefore, 0.5)));
    });
  });
}
