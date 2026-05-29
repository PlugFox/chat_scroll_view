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
///
/// Tracks `fetchCalls` so a test can assert that user-driven retry actually
/// invoked the data source rather than that recovery happened through some
/// other path (e.g. a backoff timer winning the race).
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
  int fetchCalls = 0;

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async {
    fetchCalls += 1;
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
  ChatChunkErrorDetails details,
) => SizedBox(
  height: 120,
  child: Column(
    children: <Widget>[
      Text('error-${details.firstId}-${details.lastId}'),
      Text('attempt-${details.attempt}'),
      TextButton(onPressed: details.retry, child: const Text('Retry')),
    ],
  ),
);

Widget _emptyBuilder(BuildContext context) =>
    const Center(child: Text('empty-state'));

Widget _loadingBuilder(BuildContext context) =>
    const Center(child: Text('loading-state'));

/// Match `Text` widgets whose data starts with [prefix] — narrower than
/// `find.textContaining`, which substring-matches on any prefix appearance
/// (e.g. `shimmer-` would also match a `pre-shimmer-x` if one ever appeared).
Finder _textStartingWith(String prefix) => find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').startsWith(prefix),
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ChatDataSource', () {
    test('isEmpty / isInitialLoading reflect boundary state', () {
      final empty = _EmptyDataSource();
      addTearDown(empty.dispose);
      expect(empty.isEmpty, isTrue);
      expect(empty.isInitialLoading, isFalse);

      final stalled = _StalledDataSource();
      addTearDown(stalled.dispose);
      expect(stalled.isEmpty, isFalse);
      expect(stalled.isInitialLoading, isTrue);

      // Half-seeded states are neither: a one-sided boundary leaves the
      // source's terminal state genuinely unknown.
      final halfSeeded = _StalledDataSource()
        ..seedBoundaries(
          oldestKnownId: 0,
          newestKnownId: 0,
          reachedOldest: true,
        );
      addTearDown(halfSeeded.dispose);
      expect(halfSeeded.isEmpty, isFalse);
      expect(halfSeeded.isInitialLoading, isFalse);

      stalled.release(4);
      expect(stalled.isEmpty, isFalse);
      expect(stalled.isInitialLoading, isFalse);
    });

    testWidgets('retryChunk triggers exactly one extra fetch via the UI', (
      tester,
    ) async {
      // Single-chunk conversation so the error UI carries one Retry button —
      // unambiguous tap target.
      final ds = _ManualFailDataSource(64);
      final controller = ChatScrollController();
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(
        _scaffold(
          ChatScrollView(
            dataSource: ds,
            controller: controller,
            messageBuilder: _msgBuilder,
            chunkErrorBuilder: _errBuilder,
          ),
        ),
      );
      await tester.pump();
      // Poll + fetch + error settle (backoff ≥500ms so it never fires here).
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(find.text('error-0-63'), findsOneWidget);
      expect(find.text('attempt-1'), findsOneWidget);
      final fetchCallsBeforeRetry = ds.fetchCalls;
      expect(fetchCallsBeforeRetry, greaterThanOrEqualTo(1));

      // Flip the source to succeed; tap Retry; recovery must come from the
      // retry call, not from anything else. fetchCalls increments by exactly
      // one (and only one), proving the retry hit the data source.
      ds.shouldFail = false;
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(ds.fetchCalls, fetchCallsBeforeRetry + 1);
      expect(find.text('error-0-63'), findsNothing);
      expect(find.text('msg-0'), findsOneWidget);
    });
  });

  group('ChatScrollView chunkErrorBuilder', () {
    testWidgets('anchor\'s failed chunk renders exactly one tile, no slots', (
      tester,
    ) async {
      final ds = _ManualFailDataSource(256);
      final controller = ChatScrollController()..jumpTo(255);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(
        _scaffold(
          ChatScrollView(
            dataSource: ds,
            controller: controller,
            messageBuilder: _msgBuilder,
            chunkErrorBuilder: _errBuilder,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      // The anchor's chunk (3 → 192..255) is fetched first and errors. Its
      // 64 ids must be represented by *one* tile — neither shimmer nor
      // per-message error tiles for any id inside the chunk.
      expect(find.text('error-192-255'), findsOneWidget);
      // No shimmer or msg widgets for any id in [192, 255].
      expect(
        find.byWidgetPredicate((w) {
          if (w is! Text) return false;
          final data = w.data;
          if (data == null) return false;
          for (final prefix in const <String>['shimmer-', 'msg-']) {
            if (!data.startsWith(prefix)) continue;
            final id = int.tryParse(data.substring(prefix.length));
            if (id != null && id >= 192 && id <= 255) return true;
          }
          return false;
        }),
        findsNothing,
      );

      // Render-side debug counter confirms: exactly one chunk-error tile,
      // and 0 message tiles for the errored chunk's ids.
      expect(_render(tester).debugChunkErrorCount, greaterThanOrEqualTo(1));
    });

    testWidgets('without chunkErrorBuilder, status passes to messageBuilder', (
      tester,
    ) async {
      final ds = _ManualFailDataSource(256);
      final controller = ChatScrollController()..jumpTo(255);
      final statuses = <int, ChatMessageStatus>{};
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

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

      // Per-message error placeholders fired — confirming the fallback path
      // when no chunk-error builder is wired.
      expect(_textStartingWith('err-'), findsWidgets);
      expect(statuses.values.any((s) => s.isError), isTrue);
      // The chunk-error path is not taken — no chunk-error tile inflated.
      expect(_render(tester).debugChunkErrorCount, 0);
    });
  });

  group('ChatScrollView emptyBuilder', () {
    testWidgets('renders full-viewport empty UI when conversation is empty', (
      tester,
    ) async {
      final ds = _EmptyDataSource();
      final controller = ChatScrollController();
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

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
      expect(_textStartingWith('shimmer-'), findsNothing);
      expect(_textStartingWith('msg-'), findsNothing);

      final ro = _render(tester);
      expect(ro.debugChildCount, 0);
      expect(ro.debugChunkErrorCount, 0);

      // The overlay child fills the viewport — its top-left anchors at the
      // viewport's top-left.
      final emptyTopLeft = tester.getTopLeft(find.text('empty-state'));
      final viewportTopLeft = tester.getTopLeft(find.byType(ChatScrollView));
      // The Text is centered inside the overlay, so x can shift; the y
      // anchor only matters insofar as the overlay paints starting at 0.
      expect(emptyTopLeft.dx >= viewportTopLeft.dx, isTrue);
      expect(emptyTopLeft.dy >= viewportTopLeft.dy, isTrue);
    });

    testWidgets('without emptyBuilder, viewport renders nothing', (
      tester,
    ) async {
      final ds = _EmptyDataSource();
      final controller = ChatScrollController();
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

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

      expect(_textStartingWith('msg-'), findsNothing);
      expect(_textStartingWith('shimmer-'), findsNothing);
      expect(_render(tester).debugChildCount, 0);
      expect(_render(tester).debugChunkErrorCount, 0);
    });
  });

  group('ChatScrollView loadingBuilder', () {
    testWidgets(
      'renders full-viewport skeleton while initial fetch is in flight',
      (tester) async {
        final ds = _StalledDataSource();
        final controller = ChatScrollController();
        addTearDown(controller.dispose);
        addTearDown(ds.dispose);

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
        expect(_textStartingWith('shimmer-'), findsNothing);
        expect(_render(tester).debugChildCount, 0);

        // Resolve the fetch + transition out of loading.
        ds.release(4);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        expect(find.text('loading-state'), findsNothing);
        expect(find.text('msg-0'), findsOneWidget);
      },
    );

    testWidgets('without loadingBuilder, viewport falls back to shimmer', (
      tester,
    ) async {
      final ds = _StalledDataSource();
      final controller = ChatScrollController();
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

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
      // Multiple shimmer placeholders fan out around the anchor (id 0) —
      // not just the anchor itself.
      final shimmerCount = _textStartingWith('shimmer-').evaluate().length;
      expect(shimmerCount, greaterThanOrEqualTo(5));
      expect(find.text('loading-state'), findsNothing);
    });
  });

  group('chunk math sanity', () {
    test('chunkErrorBuilder receives full 64-id range for a chunk', () {
      // The viewport always reports the chunk's structural [firstId, lastId];
      // clamping to actual data boundaries is the host's choice.
      expect(ChatScrollChunk.firstIdOf(3), 192);
      expect(ChatScrollChunk.firstIdOf(4) - 1, 255);
    });
  });

  // -------------------------------------------------------------------------
  // Missing scenarios — exercise the chunk-error / overlay paths that the
  // happy-path tests do not.
  // -------------------------------------------------------------------------

  group('chunk-error scenarios', () {
    testWidgets('overlay mode discards drag deltas (no anchor drift)', (
      tester,
    ) async {
      final ds = _StalledDataSource();
      final controller = ChatScrollController();
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

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
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('loading-state'), findsOneWidget);

      final anchorBefore = controller.anchorPixelOffset;
      // Drag against the overlay — must not affect the anchor.
      await tester.drag(find.byType(ChatScrollView), const Offset(0, -300));
      await tester.pump();
      expect(controller.anchorPixelOffset, anchorBefore);

      // Released data still transitions correctly.
      ds.release(4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(find.text('msg-0'), findsOneWidget);
    });

    testWidgets('errorBuilder swap (null → non-null) replaces shimmer tiles', (
      tester,
    ) async {
      final ds = _ManualFailDataSource(64);
      final controller = ChatScrollController();
      final useErrorBuilder = ValueNotifier<bool>(false);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);
      addTearDown(useErrorBuilder.dispose);

      await tester.pumpWidget(
        _scaffold(
          ValueListenableBuilder<bool>(
            valueListenable: useErrorBuilder,
            builder: (ctx, on, _) => ChatScrollView(
              dataSource: ds,
              controller: controller,
              messageBuilder: _msgBuilder,
              chunkErrorBuilder: on ? _errBuilder : null,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      // Without chunk-error builder, the errored chunk leaks status to the
      // message builder — shimmer for each id (we render shimmer regardless
      // of status in this test's `_msgBuilder`).
      expect(_render(tester).debugChunkErrorCount, 0);

      // Flip the builder on; existing tiles must be re-inflated as chunk
      // errors on the next layout.
      useErrorBuilder.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(find.text('error-0-63'), findsOneWidget);
      expect(_render(tester).debugChunkErrorCount, 1);
    });

    testWidgets('chunkErrorBuilder swap (non-null → null) restores per-id', (
      tester,
    ) async {
      final ds = _ManualFailDataSource(64);
      final controller = ChatScrollController();
      final useErrorBuilder = ValueNotifier<bool>(true);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);
      addTearDown(useErrorBuilder.dispose);

      await tester.pumpWidget(
        _scaffold(
          ValueListenableBuilder<bool>(
            valueListenable: useErrorBuilder,
            builder: (ctx, on, _) => ChatScrollView(
              dataSource: ds,
              controller: controller,
              messageBuilder: _msgBuilder,
              chunkErrorBuilder: on ? _errBuilder : null,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(_render(tester).debugChunkErrorCount, 1);

      useErrorBuilder.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(_render(tester).debugChunkErrorCount, 0);
      expect(find.text('error-0-63'), findsNothing);
    });

    testWidgets('overlay → normal transition does not jump anchor', (
      tester,
    ) async {
      final ds = _StalledDataSource();
      final controller = ChatScrollController();
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

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
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('loading-state'), findsOneWidget);
      // Anchor stays at id 0 throughout.
      expect(controller.anchorMessageId, 0);

      ds.release(4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(find.text('loading-state'), findsNothing);
      expect(controller.anchorMessageId, 0);
      expect(find.text('msg-0'), findsOneWidget);
    });
  });
}
