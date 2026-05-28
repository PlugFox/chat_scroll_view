// Integration benchmark for the widget-based ChatScrollView (lib/src/chat_widgets).
//
// Mirrors integration_test/benchmark_test.dart scenario-for-scenario so the
// two implementations can be compared on the same machine.
//
// Profile: flutter drive --driver=test_driver/integration_test.dart \
//            --target=integration_test/widget_benchmark_test.dart -d macos --profile

import 'dart:math';

import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ---------------------------------------------------------------------------
// Test data (identical content distribution to benchmark_test.dart)
// ---------------------------------------------------------------------------

const _kShort = ['Hello!', 'Sure thing.', 'Got it, thanks.', 'On my way.', 'OK'];
const _kMedium = [
  'The quick brown fox jumps over the lazy dog near the riverbank.',
  'I was thinking we could meet up tomorrow at the coffee shop downtown.',
  'Can you send me the latest version of the document when you get a chance?',
  'We should probably discuss the project timeline before the meeting.',
];
const _kLong = [
  'The first rule of Fight Club is: you do not talk about Fight Club. '
      'The second rule of Fight Club is: you DO NOT talk about Fight Club! '
      'Third rule of Fight Club: if someone yells stop, goes limp, or taps '
      'out, the fight is over. Fourth rule: only two guys to a fight.',
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
      'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim '
      'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea '
      'commodo consequat. Duis aute irure dolor in reprehenderit.',
];

List<IChatMessage> _generateMessages(int count) {
  final rng = Random(42);
  final now = DateTime(2026, 1, 1);
  return [
    for (var i = 0; i < count; i++)
      UserChatMessage(
        id: i,
        sender: 'User',
        createdAt: now.add(Duration(minutes: i)),
        updatedAt: now.add(Duration(minutes: i)),
        content: () {
          final roll = rng.nextDouble();
          if (roll < 0.3) return _kShort[rng.nextInt(_kShort.length)];
          if (roll < 0.8) return _kMedium[rng.nextInt(_kMedium.length)];
          return _kLong[rng.nextInt(_kLong.length)];
        }(),
      ),
  ];
}

class _BenchDataSource extends ChatDataSource {
  _BenchDataSource(List<IChatMessage> messages) {
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
  }) async => const [];
}

/// Lean bubble — visually equivalent to benchmark_test.dart's `_BenchRender`
/// (rounded rect + one paragraph), so the comparison measures the architecture
/// rather than content richness.
Widget _benchBuilder(
  BuildContext context,
  int id,
  IChatMessage? message,
  ChatMessageStatus status,
) {
  if (message == null) return const SizedBox(height: 60);
  final content = switch (message) {
    UserChatMessage(:final content) => content,
    SystemChatMessage(:final content) => content,
    _ => 'Message #$id',
  };
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: id.isEven ? const Color(0xFFE3F2FD) : const Color(0xFFF5F5F5),
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

// ---------------------------------------------------------------------------
// FrameTiming collector (copied from benchmark_test.dart)
// ---------------------------------------------------------------------------

class _FrameTimingCollector {
  final timings = <FrameTiming>[];
  late final TimingsCallback _callback;

  void start() {
    _callback = (List<FrameTiming> list) => timings.addAll(list);
    SchedulerBinding.instance.addTimingsCallback(_callback);
  }

  void stop() => SchedulerBinding.instance.removeTimingsCallback(_callback);

  List<int> get buildTimesUs =>
      timings.map((t) => t.buildDuration.inMicroseconds).toList();
  List<int> get rasterTimesUs =>
      timings.map((t) => t.rasterDuration.inMicroseconds).toList();
  List<int> get totalTimesUs => timings
      .map((t) =>
          t.buildDuration.inMicroseconds + t.rasterDuration.inMicroseconds)
      .toList();
  int get jankCount => timings
      .where((t) => t.totalSpan > const Duration(milliseconds: 16))
      .length;

  String summary(String label) {
    if (timings.isEmpty) return '$label: no frames collected';
    final build = buildTimesUs..sort();
    final raster = rasterTimesUs..sort();
    final total = totalTimesUs..sort();
    return '$label (${timings.length} frames):\n'
        '  Build:  mean=${_mean(build)}µs  p50=${_p50(build)}µs  p95=${_p95(build)}µs  p99=${_p99(build)}µs  max=${build.last}µs\n'
        '  Raster: mean=${_mean(raster)}µs  p50=${_p50(raster)}µs  p95=${_p95(raster)}µs  p99=${_p99(raster)}µs  max=${raster.last}µs\n'
        '  Total:  mean=${_mean(total)}µs  p50=${_p50(total)}µs  p95=${_p95(total)}µs  p99=${_p99(total)}µs  max=${total.last}µs\n'
        '  Jank (>16ms): $jankCount / ${timings.length} (${(jankCount * 100 / timings.length).toStringAsFixed(1)}%)';
  }

  static int _mean(List<int> s) =>
      s.isEmpty ? 0 : s.reduce((a, b) => a + b) ~/ s.length;
  static int _p50(List<int> s) => s.isEmpty ? 0 : s[s.length ~/ 2];
  static int _p95(List<int> s) =>
      s.isEmpty ? 0 : s[((s.length - 1) * 0.95).round()];
  static int _p99(List<int> s) =>
      s.isEmpty ? 0 : s[((s.length - 1) * 0.99).round()];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

({_BenchDataSource ds, ChatScrollController ctrl}) _setup(int count) {
  final ds = _BenchDataSource(_generateMessages(count));
  final ctrl = ChatScrollController()..jumpTo(count - 1);
  return (ds: ds, ctrl: ctrl);
}

Widget _widgetApp(_BenchDataSource ds, ChatScrollController ctrl) => MaterialApp(
  home: Scaffold(
    body: ChatScrollView(
      dataSource: ds,
      controller: ctrl,
      messageBuilder: _benchBuilder,
    ),
  ),
);

RenderChatScrollView _ro(WidgetTester tester) =>
    tester.renderObject<RenderChatScrollView>(find.byType(ChatScrollView));

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 1. Drag scroll — forced relayout every frame (heaviest path).
  for (final count in [256, 6000, 20000]) {
    testWidgets('WIDGET drag scroll — $count msgs', (tester) async {
      final (:ds, :ctrl) = _setup(count);
      await tester.pumpWidget(_widgetApp(ds, ctrl));
      await tester.pumpAndSettle();

      final collector = _FrameTimingCollector()..start();
      for (var i = 0; i < 200; i++) {
        ctrl.applyScrollDelta(15.0);
        _ro(tester).markNeedsLayout();
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      collector.stop();

      debugPrint(collector.summary('WIDGET drag scroll ($count msgs)'));
    });
  }

  // 2. Fling — real gesture, Ticker-driven (realistic Tier-1 path).
  for (final count in [256, 6000, 20000]) {
    testWidgets('WIDGET fling — $count msgs', (tester) async {
      final (:ds, :ctrl) = _setup(count);
      await tester.pumpWidget(_widgetApp(ds, ctrl));
      await tester.pumpAndSettle();

      ctrl.jumpTo(count ~/ 2);
      await tester.pumpAndSettle();

      final collector = _FrameTimingCollector()..start();
      await tester.fling(
        find.byType(ChatScrollView),
        const Offset(0, -300),
        3000.0,
      );
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      collector.stop();

      debugPrint(collector.summary('WIDGET fling ($count msgs)'));
    });
  }

  // 3. Raw compute — layout + paint microseconds via debug stopwatches.
  for (final count in [256, 6000, 20000]) {
    testWidgets('WIDGET raw compute — $count msgs', (tester) async {
      final (:ds, :ctrl) = _setup(count);
      await tester.pumpWidget(_widgetApp(ds, ctrl));
      await tester.pumpAndSettle();

      ctrl.jumpTo(count ~/ 2);
      await tester.pumpAndSettle();

      final render = _ro(tester);

      for (var i = 0; i < 20; i++) {
        ctrl.applyScrollDelta(-5.0);
        render.markNeedsLayout();
        await tester.pump(const Duration(milliseconds: 16));
      }

      var totalLayoutUs = 0;
      var totalPaintUs = 0;
      var lastLId = render.debugLayoutFrameId;
      var lastPId = render.debugPaintFrameId;
      var layoutFrames = 0;
      var paintFrames = 0;

      for (var i = 0; i < 500; i++) {
        ctrl.applyScrollDelta(-5.0);
        render.markNeedsLayout();
        await tester.pump(const Duration(milliseconds: 16));
        if (render.debugLayoutFrameId != lastLId) {
          totalLayoutUs += render.debugLastLayoutDuration.inMicroseconds;
          layoutFrames++;
          lastLId = render.debugLayoutFrameId;
        }
        if (render.debugPaintFrameId != lastPId) {
          totalPaintUs += render.debugLastPaintDuration.inMicroseconds;
          paintFrames++;
          lastPId = render.debugPaintFrameId;
        }
      }

      final avgLayoutUs = layoutFrames > 0 ? totalLayoutUs / layoutFrames : 0.0;
      final avgPaintUs = paintFrames > 0 ? totalPaintUs / paintFrames : 0.0;
      final avgTotalUs = avgLayoutUs + avgPaintUs;
      final rawFps =
          avgTotalUs > 0 ? (1000000.0 / avgTotalUs).toStringAsFixed(0) : '∞';

      debugPrint(
        'WIDGET raw compute ($count msgs): '
        'layout=${avgLayoutUs.toStringAsFixed(1)}µs  '
        'paint=${avgPaintUs.toStringAsFixed(1)}µs  '
        'total=${avgTotalUs.toStringAsFixed(1)}µs  '
        'raw=$rawFps FPS  '
        '(layout frames: $layoutFrames, paint frames: $paintFrames, '
        'children: ${render.debugChildCount})',
      );
    });
  }
}
