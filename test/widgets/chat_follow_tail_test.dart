import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Test data source: messages preloaded + counts grow via `appendOne`.
// ---------------------------------------------------------------------------

IChatMessage _msg(int i) => UserChatMessage(
  id: i,
  sender: 'User',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  content: 'content $i',
);

class _GrowingDataSource extends ChatDataSource {
  _GrowingDataSource(int initialCount) {
    if (initialCount > 0) {
      for (var i = 0; i < initialCount; i++) {
        upsertMessage(_msg(i));
      }
      seedBoundaries(
        oldestKnownId: 0,
        newestKnownId: initialCount - 1,
        reachedOldest: true,
        reachedNewest: true,
      );
      _newestId = initialCount - 1;
    }
  }

  int _newestId = -1;

  /// Append a single new message and bump the newest boundary.
  void appendOne() {
    final next = _newestId + 1;
    upsertMessage(_msg(next));
    seedBoundaries(newestKnownId: next, reachedNewest: true);
    _newestId = next;
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

void main() {
  group('follow tail: isAtTail listenable', () {
    testWidgets('starts false, flips true once viewport pins newest', (
      tester,
    ) async {
      final ds = _GrowingDataSource(20);
      final controller = ChatScrollController()..jumpTo(19);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      // Before mount.
      expect(controller.isAtTail.value, isFalse);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pump();

      expect(controller.isAtTail.value, isTrue);
      expect(find.text('msg-19'), findsOneWidget);
    });

    testWidgets('flips false after scrolling away from the bottom', (
      tester,
    ) async {
      final ds = _GrowingDataSource(40);
      final controller = ChatScrollController()..jumpTo(39);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pump();
      expect(controller.isAtTail.value, isTrue);

      // Drag down (= reveal older history).
      await tester.drag(find.byType(ChatScrollView), const Offset(0, 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.isAtTail.value, isFalse);
    });

    testWidgets('flips back true after scrolling to the bottom again', (
      tester,
    ) async {
      final ds = _GrowingDataSource(40);
      final controller = ChatScrollController()..jumpTo(39);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pump();

      // Scroll up.
      await tester.drag(find.byType(ChatScrollView), const Offset(0, 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.isAtTail.value, isFalse);

      // jumpTo newest brings us back to tail after the next layout.
      controller.jumpTo(39);
      await tester.pump();
      expect(controller.isAtTail.value, isTrue);
    });
  });

  group('follow tail: auto-scroll on new message', () {
    testWidgets('new message at the tail keeps the viewport pinned to it', (
      tester,
    ) async {
      final ds = _GrowingDataSource(20);
      final controller = ChatScrollController()..jumpTo(19);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pump();
      expect(find.text('msg-19'), findsOneWidget);
      expect(controller.isAtTail.value, isTrue);

      // A new message arrives. Because we were at tail, the viewport must
      // auto-scroll so the new newest (id 20) is visible.
      ds.appendOne();
      await tester.pump();
      await tester.pump();

      // Strong assertion: msg-20 sits exactly at the bottom edge — proving
      // the pin moved, not just that the widget is in the cache extent.
      final viewportBottom = tester.getBottomLeft(find.byType(ChatScrollView));
      final msg20Bottom = tester.getBottomLeft(find.text('msg-20'));
      expect(
        msg20Bottom.dy,
        closeTo(viewportBottom.dy, 0.5),
        reason: 'newest must be pinned to the bottom edge after auto-scroll',
      );
      expect(controller.isAtTail.value, isTrue);
    });

    testWidgets('new message while scrolled away does not move the anchor', (
      tester,
    ) async {
      final ds = _GrowingDataSource(40);
      final controller = ChatScrollController()..jumpTo(39);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pump();

      // Move off the tail.
      await tester.drag(find.byType(ChatScrollView), const Offset(0, 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.isAtTail.value, isFalse);
      final anchorBefore = controller.anchorMessageId;
      final offsetBefore = controller.anchorPixelOffset;

      // A new message arrives. We must NOT auto-scroll — user is reading
      // history.
      ds.appendOne();
      await tester.pump();
      await tester.pump();

      expect(controller.anchorMessageId, anchorBefore);
      expect(controller.anchorPixelOffset, offsetBefore);
      expect(controller.isAtTail.value, isFalse);
      // The newest is not built into the visible band.
      expect(find.text('msg-40'), findsNothing);
    });

    testWidgets('multiple appended messages keep pinning when at tail', (
      tester,
    ) async {
      final ds = _GrowingDataSource(10);
      final controller = ChatScrollController()..jumpTo(9);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pump();
      expect(controller.isAtTail.value, isTrue);

      for (var i = 10; i < 15; i++) {
        ds.appendOne();
        await tester.pump();
        await tester.pump();
        expect(
          find.text('msg-$i'),
          findsOneWidget,
          reason: 'msg-$i should auto-scroll into view at tail',
        );
        expect(controller.isAtTail.value, isTrue);
      }
    });
  });

  group('follow tail: render-side counters', () {
    testWidgets('debugChildCount stays bounded after many appends', (
      tester,
    ) async {
      final ds = _GrowingDataSource(20);
      final controller = ChatScrollController()..jumpTo(19);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pump();
      final initialChildren = _render(tester).debugChildCount;

      for (var i = 0; i < 30; i++) {
        ds.appendOne();
      }
      await tester.pump();
      await tester.pump();

      // Builds are tied to viewport + cache extent — appending shouldn't
      // inflate everything ever produced. Allow a small slack for the
      // directional-lead build-ahead.
      expect(
        _render(tester).debugChildCount,
        lessThanOrEqualTo(initialChildren + 8),
      );
      // And much less than the conversation's total size.
      expect(_render(tester).debugChildCount, lessThan(50));
    });
  });
}
