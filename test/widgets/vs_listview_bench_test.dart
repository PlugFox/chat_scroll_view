// Headless A/B benchmark: widget ChatScrollView vs ListView.builder.
//
//   flutter test test/widgets/vs_listview_bench_test.dart
//
// Both sides render the *identical* [_Bubble] widget, so every difference is
// architectural: anchor-based custom viewport vs the Sliver protocol.
// Debug mode (flutter test) — absolute numbers are inflated by asserts; the
// CSV/LV ratio is the meaningful figure.

import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../benchmark/shared/metrics.dart';
import '../benchmark/shared/test_messages.dart';

/// Message bubble — identical on both sides of the comparison.
class _Bubble extends StatelessWidget {
  const _Bubble(this.message);

  final IChatMessage message;

  @override
  Widget build(BuildContext context) {
    final content = switch (message) {
      UserChatMessage(:final content) => content,
      SystemChatMessage(:final content) => content,
      _ => 'Message #${message.id}',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: message.id.isEven
              ? const Color(0xFFE3F2FD)
              : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            content,
            style: const TextStyle(
              fontSize: 15,
              height: 1.4,
              color: Color(0xFF1A1A1A),
            ),
          ),
        ),
      ),
    );
  }
}

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

Widget _csvApp(List<IChatMessage> msgs, ChatScrollController ctrl) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 600,
        child: ChatScrollView(
          dataSource: _Preloaded(msgs),
          controller: ctrl,
          messageBuilder: (context, id, message, status) =>
              message == null ? const SizedBox(height: 60) : _Bubble(message),
        ),
      ),
    ),
  ),
);

Widget _lvApp(List<IChatMessage> msgs, ScrollController sc) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 600,
        child: ListView.builder(
          controller: sc,
          physics: const ClampingScrollPhysics(),
          itemCount: msgs.length,
          itemBuilder: (_, i) => _Bubble(msgs[i]),
        ),
      ),
    ),
  ),
);

/// Wall-clock cost of each of 300 frames during a fling.
Future<List<int>> _flingFrames(WidgetTester tester, Finder target) async {
  final samples = <int>[];
  await tester.fling(target, const Offset(0, -500), 2000.0);
  for (var i = 0; i < 300; i++) {
    final sw = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 16));
    samples.add(sw.elapsedMicroseconds);
  }
  return samples;
}

int _renderObjectCount(WidgetTester tester) {
  var n = 0;
  void visit(Element e) {
    if (e.renderObject != null) n++;
    e.visitChildren(visit);
  }

  visit(tester.element(find.byType(MaterialApp)));
  return n;
}

int _bubbleCount(WidgetTester tester) =>
    tester.elementList(find.byType(_Bubble, skipOffstage: false)).length;

void main() {
  final flingRows =
      <(int, BenchmarkMetrics, BenchmarkMetrics)>[];
  final memRows = <(int, MemorySnapshot, MemorySnapshot)>[];

  for (final count in <int>[kSmall, kMedium, kLarge]) {
    testWidgets('fling + memory — $count messages', (tester) async {
      final messages = generateMessages(count);

      // --- Widget ChatScrollView ---
      final ctrl = ChatScrollController()..jumpTo(count - 1);
      await tester.pumpWidget(_csvApp(messages, ctrl));
      await tester.pumpAndSettle();
      ctrl.jumpTo(count ~/ 2);
      await tester.pumpAndSettle();

      final csvFling = await _flingFrames(
        tester,
        find.byType(ChatScrollView),
      );
      await tester.pumpAndSettle();
      final csvRender = tester.renderObject<RenderChatScrollView>(
        find.byType(ChatScrollView),
      );
      final csvMem = MemorySnapshot(
        label: 'CSV ($count msgs)',
        elementCount: csvRender.debugChildCount,
        renderObjectCount: _renderObjectCount(tester),
        chunkCount: csvRender.debugChunkCount,
      );
      await tester.pumpWidget(const SizedBox.shrink());

      // --- ListView.builder ---
      final sc = ScrollController();
      await tester.pumpWidget(_lvApp(messages, sc));
      await tester.pumpAndSettle();
      sc.jumpTo(sc.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();

      final lvFling = await _flingFrames(tester, find.byType(ListView));
      await tester.pumpAndSettle();
      final lvMem = MemorySnapshot(
        label: 'LV ($count msgs)',
        elementCount: _bubbleCount(tester),
        renderObjectCount: _renderObjectCount(tester),
      );
      sc.dispose();

      flingRows.add((
        count,
        BenchmarkMetrics('CSV fling', csvFling),
        BenchmarkMetrics('LV fling', lvFling),
      ));
      memRows.add((count, csvMem, lvMem));

      // ignore: avoid_print
      print('\n$count messages:');
      // ignore: avoid_print
      print('  CSV fling: ${flingRows.last.$2}');
      // ignore: avoid_print
      print('  LV  fling: ${flingRows.last.$3}');
      // ignore: avoid_print
      print('  CSV mem: $csvMem');
      // ignore: avoid_print
      print('  LV  mem: $lvMem');
    });
  }

  tearDownAll(() {
    // ignore: avoid_print
    print('\n${'=' * 70}');
    // ignore: avoid_print
    print(
      generateComparisonTable(
        title: 'Fling frame time — widget ChatScrollView vs ListView.builder',
        rows: flingRows,
      ),
    );
    // ignore: avoid_print
    print(
      generateMemoryTable(
        title: 'Live objects',
        rows: memRows,
      ),
    );
  });
}
