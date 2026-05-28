import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

class _PreloadedDataSource extends ChatDataSource {
  _PreloadedDataSource(List<IChatMessage> messages) {
    upsertMessages(messages);
    if (messages.isNotEmpty) {
      seedBoundaries(
        oldestKnownId: 0,
        newestKnownId: messages.length - 1,
        reachedOldest: true,
        reachedNewest: true,
      );
    }
  }

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async => const <IChatMessage>[];
}

/// Messages per calendar day in the generated fixture.
const int _perDay = 8;

/// `count` messages, [_perDay] per calendar day starting 2026-01-01.
List<IChatMessage> _generate(int count) => <IChatMessage>[
  for (var i = 0; i < count; i++)
    UserChatMessage(
      id: i,
      sender: 'User',
      createdAt: DateTime(2026, 1, 1 + i ~/ _perDay, 9, i % _perDay),
      updatedAt: DateTime(2026, 1, 1 + i ~/ _perDay, 9, i % _perDay),
      content: 'content $i',
    ),
];

Widget _harness({
  required ChatDataSource dataSource,
  required ChatScrollController controller,
  bool separators = true,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 600,
        child: ChatScrollView(
          dataSource: dataSource,
          controller: controller,
          messageBuilder: (context, id, message, status) =>
              SizedBox(height: 60, child: Text('msg-$id')),
          dateSeparatorBuilder: separators
              ? (context, date) => SizedBox(
                  height: 24,
                  child: Text('sep-${date.month}-${date.day}'),
                )
              : null,
        ),
      ),
    ),
  ),
);

RenderChatScrollView _render(WidgetTester tester) =>
    tester.renderObject<RenderChatScrollView>(find.byType(ChatScrollView));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ChatScrollView day separators', () {
    testWidgets('inline date separators mark day boundaries', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(16);
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
        ),
      );
      await tester.pump();

      // jumpTo(16): msg-16 starts day 3 (2026-01-03); msg-24 starts day 4.
      expect(find.text('msg-16'), findsOneWidget);
      expect(find.text('sep-1-3'), findsWidgets);
      expect(find.text('sep-1-4'), findsWidgets);
    });

    testWidgets('no separators and no header when the builder is null', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count - 1);
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
          separators: false,
        ),
      );
      await tester.pump();

      expect(find.textContaining('sep-'), findsNothing);
      expect(_render(tester).debugHasFloatingHeader, isFalse);
    });

    testWidgets('a floating header is present and tracks the topmost day', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(8);
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
        ),
      );
      await tester.pump();
      final ro = _render(tester);

      expect(ro.debugHasFloatingHeader, isTrue);
      // jumpTo(8): msg-8 is the first message of day 2 (2026-01-02).
      expect(ro.debugHeaderDate, isNotNull);
      expect(ro.debugHeaderDate!.month, 1);
      expect(ro.debugHeaderDate!.day, 2);

      // Teleport deep into another day — the header follows.
      controller.jumpTo(80); // 80 ~/ 8 == 10 -> 2026-01-11
      await tester.pump();
      expect(ro.debugHeaderDate!.day, 11);
    });

    testWidgets('the inline date separator fades out as it nears the top', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(8);
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
        ),
      );
      await tester.pump();
      final ro = _render(tester);

      // jumpTo(8): msg-8 (first of day 2) sits at the very top, inside the
      // floating header's zone — its inline separator is faded out.
      expect(ro.debugDividerOpacity(8), isNotNull);
      expect(ro.debugDividerOpacity(8), lessThan(0.5));

      // msg-16 (first of day 3) is far below — its separator is fully opaque.
      expect(ro.debugDividerOpacity(16), closeTo(1.0, 0.01));

      // The floating header stays pinned — it is never pushed.
      expect(ro.debugFloatingHeaderOffset, closeTo(0, 1));

      // Scroll msg-16's separator up into the fade band near the top edge:
      // it is then partially transparent.
      controller.applyScrollDelta(-490);
      ro.markNeedsLayout();
      await tester.pump();
      final fading = ro.debugDividerOpacity(16);
      expect(fading, isNotNull);
      expect(fading, greaterThan(0.1));
      expect(fading, lessThan(0.9));
    });

    testWidgets('several day separators can be visible at once', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count - 1);
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
        ),
      );
      await tester.pump();

      // A 600px viewport spans more than one ~500px day section: inline
      // dividers for the visible boundaries plus the floating header.
      expect(find.textContaining('sep-'), findsAtLeastNWidgets(2));
    });

    testWidgets('the header date advances while scrolling across days', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(8);
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
        ),
      );
      await tester.pump();
      final ro = _render(tester);
      expect(ro.debugHeaderDate!.day, 2);

      // A long scroll toward newer messages crosses many day boundaries.
      for (var i = 0; i < 100; i++) {
        controller.applyScrollDelta(-60);
        ro.markNeedsLayout();
        await tester.pump();
      }
      expect(
        ro.debugHeaderDate!.isAfter(DateTime(2026, 1, 2, 23, 59)),
        isTrue,
        reason: 'the header should follow the topmost message into later days',
      );
    });
  });
}
