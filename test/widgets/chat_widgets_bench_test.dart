// Headless benchmarks for the widget-based ChatScrollView.
//
// Run alongside `test/v2/chat_scroll_bench_test.dart` (the canvas-render
// implementation) to compare layout / paint / memory between the two.
//
//   flutter test test/widgets/chat_widgets_bench_test.dart
//
// Layout here includes lazy widget inflation (buildChild) — the honest cost
// of the widget approach. Paint is the Tier-1 scroll-frame cost.

import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/demo/demo_message.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../benchmark/shared/metrics.dart';
import '../benchmark/shared/test_messages.dart';

class _Preloaded extends ChatDataSource {
  _Preloaded(List<IChatMessage> messages) {
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

Future<RenderChatScrollView> _pump(WidgetTester tester, int count) async {
  final controller = ChatScrollController()..jumpTo(count - 1);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 800,
          child: ChatScrollView(
            dataSource: _Preloaded(generateMessages(count)),
            controller: controller,
            messageBuilder: buildDemoMessage,
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final ro = tester.renderObject<RenderChatScrollView>(
    find.byType(ChatScrollView),
  );
  // Mid-list so scrolling never hits a boundary.
  controller.jumpTo(count ~/ 2);
  ro.markNeedsLayout();
  await tester.pump();
  return ro;
}

void main() {
  for (final count in <int>[kSmall, kMedium, kLarge]) {
    testWidgets('widget ChatScrollView — $count messages', (tester) async {
      final ro = await _pump(tester, count);

      // Layout: each step shifts the anchor and forces a full relayout
      // (rebuilds in-range message widgets).
      final layout = <int>[];
      for (var i = 0; i < 150; i++) {
        ro.markNeedsLayout();
        await tester.pump();
        layout.add(ro.debugLastLayoutDuration.inMicroseconds);
      }

      // Paint: Tier-1 scroll-frame cost (no layout, no rebuild).
      final paint = <int>[];
      for (var i = 0; i < 150; i++) {
        ro.markNeedsPaint();
        await tester.pump();
        paint.add(ro.debugLastPaintDuration.inMicroseconds);
      }

      // ignore: avoid_print
      print('\n--- widget ChatScrollView, $count messages ---');
      // ignore: avoid_print
      print(BenchmarkMetrics('  layout', layout));
      // ignore: avoid_print
      print(BenchmarkMetrics('  paint ', paint));
      // ignore: avoid_print
      print('  children=${ro.debugChildCount} chunks=${ro.debugChunkCount}');

      expect(ro.debugChildCount, greaterThan(0));
    });
  }
}
