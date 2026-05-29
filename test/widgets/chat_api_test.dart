import 'dart:async';

import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_chunk.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Test data sources
// ---------------------------------------------------------------------------

IChatMessage _msg(int i) => UserChatMessage(
  id: i,
  sender: 'User',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  content: 'content $i',
);

/// Fetches always error until [shouldFail] flips to false. Used to exercise
/// the chunk-error UI and the `retryChunk` recovery path.
class _ManualFailDataSource extends ChatDataSource {
  _ManualFailDataSource(this.count) {
    seedBoundaries(
      oldestKnownId: 0,
      newestKnownId: count - 1,
      reachedOldest: true,
      reachedNewest: true,
    );
  }

  final int count;
  bool shouldFail = true;

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (shouldFail) throw StateError('manual fail');
    final lo = fromId.clamp(0, count - 1);
    final hi = toId.clamp(0, count - 1);
    return <IChatMessage>[for (var i = lo; i <= hi; i++) _msg(i)];
  }
}

/// Seeded as an empty conversation. `fetchRange` never gets called because no
/// chunk is needed; included only to satisfy the abstract contract.
class _EmptyDataSource extends ChatDataSource {
  _EmptyDataSource() {
    seedBoundaries(reachedOldest: true, reachedNewest: true);
  }

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async => const <IChatMessage>[];
}

/// Fetches stall until [release] is called — used to hold the data source in
/// the initial-loading state long enough to assert the loading overlay. After
/// `release`, subsequent fetches resolve synchronously with the seeded data
/// so the viewport can transition out of overlay mode.
class _StalledDataSource extends ChatDataSource {
  Completer<List<IChatMessage>>? _pending;
  bool _released = false;
  int _count = 0;

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async {
    if (_released) {
      final lo = fromId.clamp(0, _count - 1);
      final hi = toId.clamp(0, _count - 1);
      return <IChatMessage>[for (var i = lo; i <= hi; i++) _msg(i)];
    }
    _pending = Completer<List<IChatMessage>>();
    return _pending!.future;
  }

  /// Resolve the pending fetch with [count] messages and seed boundaries so
  /// the viewport transitions out of the loading overlay.
  void release(int count) {
    _released = true;
    _count = count;
    seedBoundaries(
      oldestKnownId: 0,
      newestKnownId: count - 1,
      reachedOldest: true,
      reachedNewest: true,
    );
    _pending?.complete(<IChatMessage>[for (var i = 0; i < count; i++) _msg(i)]);
    _pending = null;
  }

  int get count => _count;
}

// ---------------------------------------------------------------------------
// Harnesses
// ---------------------------------------------------------------------------

Widget _scaffold(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 400, height: 600, child: child)),
  ),
);

RenderChatScrollView _render(WidgetTester tester) =>
    tester.renderObject<RenderChatScrollView>(find.byType(ChatScrollView));

Widget _msgBuilder(
  BuildContext context,
  int id,
  IChatMessage? message,
  ChatMessageStatus status,
) => SizedBox(
  height: 60,
  child: Text(message == null ? 'shimmer-$id' : 'msg-$id'),
);

Widget _errBuilder(
  BuildContext context,
  ChatChunkRange chunk,
  VoidCallback retry,
) => SizedBox(
  height: 80,
  child: Column(
    children: <Widget>[
      Text('error-${chunk.firstId}-${chunk.lastId}'),
      TextButton(onPressed: retry, child: const Text('Retry')),
    ],
  ),
);

Widget _emptyBuilder(BuildContext context) =>
    const Center(child: Text('empty-state'));

Widget _loadingBuilder(BuildContext context) =>
    const Center(child: Text('loading-state'));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ChatDataSource', () {
    test('isEmpty / isInitialLoading reflect boundary state', () {
      final empty = _EmptyDataSource();
      expect(empty.isEmpty, isTrue);
      expect(empty.isInitialLoading, isFalse);

      final stalled = _StalledDataSource();
      expect(stalled.isEmpty, isFalse);
      expect(stalled.isInitialLoading, isTrue);

      stalled.release(4);
      expect(stalled.isEmpty, isFalse);
      expect(stalled.isInitialLoading, isFalse);
    });

    testWidgets('retryChunk cancels backoff and re-fetches errored chunk', (
      tester,
    ) async {
      // Single-chunk conversation so the error UI carries one Retry button —
      // unambiguous tap target.
      final ds = _ManualFailDataSource(64);
      final controller = ChatScrollController();
      await tester.pumpWidget(
        _scaffold(
          ChatScrollView(
            dataSource: ds,
            controller: controller,
            messageBuilder: _msgBuilder,
            errorBuilder: _errBuilder,
          ),
        ),
      );
      await tester.pump();
      // Poll + fetch + error settle.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(find.text('error-0-63'), findsOneWidget);
      expect(find.text('msg-0'), findsNothing);

      // Flip the data source to success and tap retry; the backoff timer
      // (≥500ms) doesn't fire in the few ms we wait, so the recovery is
      // entirely down to the retryChunk call wired through the builder.
      ds.shouldFail = false;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(find.text('error-0-63'), findsNothing);
      expect(find.text('msg-0'), findsOneWidget);

      controller.dispose();
      ds.dispose();
    });
  });

  group('ChatScrollView errorBuilder', () {
    testWidgets('renders one chunk-error tile per failed chunk, not 64 slots', (
      tester,
    ) async {
      final ds = _ManualFailDataSource(256);
      final controller = ChatScrollController()..jumpTo(255);
      await tester.pumpWidget(
        _scaffold(
          ChatScrollView(
            dataSource: ds,
            controller: controller,
            messageBuilder: _msgBuilder,
            errorBuilder: _errBuilder,
          ),
        ),
      );
      await tester.pump();
      // Poll + fetch + error settle.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      // The anchor's chunk (3 → 192..255) is the first to fetch + error.
      // Its 64 slots are replaced by one tile, never by per-message shimmer.
      expect(find.text('error-192-255'), findsOneWidget);
      for (final id in <int>[192, 200, 220, 250, 255]) {
        expect(find.text('shimmer-$id'), findsNothing);
        expect(find.text('msg-$id'), findsNothing);
      }

      controller.dispose();
      ds.dispose();
    });

    testWidgets('without errorBuilder, status is passed to messageBuilder', (
      tester,
    ) async {
      final ds = _ManualFailDataSource(256);
      final controller = ChatScrollController()..jumpTo(255);
      final statuses = <int, ChatMessageStatus>{};
      await tester.pumpWidget(
        _scaffold(
          ChatScrollView(
            dataSource: ds,
            controller: controller,
            messageBuilder: (context, id, message, status) {
              statuses[id] = status;
              return SizedBox(
                height: 60,
                child: Text(
                  status.isError ? 'err-$id' : 'msg-$id',
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      // Per-message error placeholders visible (the fallback path).
      expect(find.textContaining('err-'), findsWidgets);
      expect(statuses.values.any((s) => s.isError), isTrue);

      controller.dispose();
      ds.dispose();
    });
  });

  group('ChatScrollView emptyBuilder', () {
    testWidgets('renders full-viewport empty UI when conversation is empty', (
      tester,
    ) async {
      final ds = _EmptyDataSource();
      final controller = ChatScrollController();
      await tester.pumpWidget(
        _scaffold(
          ChatScrollView(
            dataSource: ds,
            controller: controller,
            messageBuilder: _msgBuilder,
            emptyBuilder: _emptyBuilder,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('empty-state'), findsOneWidget);
      expect(find.textContaining('shimmer-'), findsNothing);
      expect(find.textContaining('msg-'), findsNothing);

      final ro = _render(tester);
      expect(ro.debugChildCount, 0);

      controller.dispose();
      ds.dispose();
    });

    testWidgets('without emptyBuilder, viewport renders nothing', (
      tester,
    ) async {
      final ds = _EmptyDataSource();
      final controller = ChatScrollController();
      await tester.pumpWidget(
        _scaffold(
          ChatScrollView(
            dataSource: ds,
            controller: controller,
            messageBuilder: _msgBuilder,
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('msg-'), findsNothing);
      expect(find.textContaining('shimmer-'), findsNothing);

      controller.dispose();
      ds.dispose();
    });
  });

  group('ChatScrollView loadingBuilder', () {
    testWidgets(
      'renders full-viewport skeleton while initial fetch is in flight',
      (tester) async {
        final ds = _StalledDataSource();
        final controller = ChatScrollController();
        await tester.pumpWidget(
          _scaffold(
            ChatScrollView(
              dataSource: ds,
              controller: controller,
              messageBuilder: _msgBuilder,
              loadingBuilder: _loadingBuilder,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        // Loading overlay is up; no shimmer tiles fanned out.
        expect(find.text('loading-state'), findsOneWidget);
        expect(find.textContaining('shimmer-'), findsNothing);

        // Resolve the fetch + transition out of loading.
        ds.release(4);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        expect(find.text('loading-state'), findsNothing);
        expect(find.text('msg-0'), findsOneWidget);

        controller.dispose();
        ds.dispose();
      },
    );

    testWidgets('without loadingBuilder, viewport falls back to shimmer', (
      tester,
    ) async {
      final ds = _StalledDataSource();
      final controller = ChatScrollController();
      await tester.pumpWidget(
        _scaffold(
          ChatScrollView(
            dataSource: ds,
            controller: controller,
            messageBuilder: _msgBuilder,
          ),
        ),
      );
      await tester.pump();
      // Shimmer placeholders fan out from anchor (id 0).
      expect(find.text('shimmer-0'), findsOneWidget);
      expect(find.text('loading-state'), findsNothing);

      controller.dispose();
      ds.dispose();
    });
  });

  group('chunk math sanity', () {
    test('errorBuilder receives full 64-id range for a chunk', () {
      // The viewport always reports the chunk's structural [firstId, lastId];
      // clamping to actual data boundaries is the host's choice.
      expect(ChatScrollChunk.firstIdOf(3), 192);
      expect(ChatScrollChunk.firstIdOf(4) - 1, 255);
    });
  });
}
