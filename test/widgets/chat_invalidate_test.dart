import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_chunk.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

IChatMessage _msg(int i, [String content = '']) => UserChatMessage(
  id: i,
  sender: 'User',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  content: content.isEmpty ? 'content $i' : content,
);

/// Data source whose `fetchRange` returns whatever the test sets via
/// [setResponse], with a fixed micro-delay so async flow exercises ticks.
class _ProgrammableDataSource extends ChatDataSource {
  _ProgrammableDataSource(int count) {
    if (count == 0) {
      seedBoundaries(reachedOldest: true, reachedNewest: true);
      return;
    }
    for (var i = 0; i < count; i++) {
      upsertMessage(_msg(i));
    }
    seedBoundaries(
      oldestKnownId: 0,
      newestKnownId: count - 1,
      reachedOldest: true,
      reachedNewest: true,
    );
    // `upsertMessage` marks freshly-created chunks as valid (the upsert is
    // the source of truth), so no manual chunk-status promotion is needed.
  }

  int fetchCalls = 0;
  List<IChatMessage> Function(int from, int to)? response;

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async {
    fetchCalls += 1;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final builder = response;
    return builder == null ? const <IChatMessage>[] : builder(fromId, toId);
  }
}

void main() {
  group('ChatDataSource.invalidate (unit)', () {
    test('marks every loaded chunk dirty', () {
      final ds = _ProgrammableDataSource(256);
      addTearDown(ds.dispose);

      // After construction every existing chunk is valid.
      expect(
        ds.chunks.values.every((c) => c.status.isValid),
        isTrue,
        reason: 'initial state',
      );

      ds.invalidate();

      // All present chunks are dirty; none is fetching or errored.
      for (final chunk in ds.chunks.values) {
        expect(chunk.status.isDirty, isTrue);
        expect(chunk.status.isFetching, isFalse);
        expect(chunk.status.isError, isFalse);
      }
    });

    test('resets failedAttempts and lastError', () {
      final ds = _ProgrammableDataSource(64);
      addTearDown(ds.dispose);

      // Forge an errored chunk.
      final chunk = ds.chunks.values.first
        ..status = ChatMessageStatus.error
        ..failedAttempts = 3
        ..lastError = StateError('boom');

      ds.invalidate();

      expect(chunk.status.isDirty, isTrue);
      expect(chunk.failedAttempts, 0);
      expect(chunk.lastError, isNull);
    });

    test('no-op on a fresh source emits no listener event', () {
      // A source with no loaded chunks has nothing to invalidate.
      final ds = _ProgrammableDataSource(0);
      addTearDown(ds.dispose);

      var notifications = 0;
      ds.addDataListener(() => notifications++);
      ds.invalidate();
      expect(notifications, 0);
    });

    test('idempotent — second call does not re-notify', () {
      final ds = _ProgrammableDataSource(128);
      addTearDown(ds.dispose);
      ds.invalidate();
      var notifications = 0;
      ds.addDataListener(() => notifications++);
      ds.invalidate();
      // Every chunk is already dirty with cleared error state — no change.
      expect(notifications, 0);
    });
  });

  group('viewport behaviour around invalidate', () {
    testWidgets('visible chunks refetch after invalidate; stale data stays', (
      tester,
    ) async {
      final ds = _ProgrammableDataSource(128);
      final controller = ChatScrollController()..jumpTo(64);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      Widget content(String label) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 600,
              child: ChatScrollView(
                dataSource: ds,
                controller: controller,
                cacheExtent: 100,
                messageBuilder: (context, id, message, status) => SizedBox(
                  height: 60,
                  child: Text(
                    message == null
                        ? 'shimmer-$id'
                        : '${(message as UserChatMessage).content} [${status.isDirty ? "stale" : "fresh"}]',
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(content('init'));
      await tester.pumpAndSettle();
      // First load — no fetch fired (data was preloaded by the harness).
      expect(ds.fetchCalls, 0);

      // Stage a server response that replaces content of every requested id.
      ds.response = (from, to) {
        final lo = from.clamp(0, 127);
        final hi = to.clamp(0, 127);
        return <IChatMessage>[
          for (var i = lo; i <= hi; i++) _msg(i, 'refreshed $i'),
        ];
      };

      ds.invalidate();
      await tester.pump(); // markNeedsLayout takes effect; arms fetch poll
      // Stale content still visible while the refetch is in flight.
      expect(find.textContaining('content 64 [stale]'), findsOneWidget);

      // Let the poll fire + fetch resolve.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(find.textContaining('refreshed 64 [fresh]'), findsOneWidget);
      expect(ds.fetchCalls, greaterThan(0));
    });

    testWidgets(
      'off-range chunks remain dirty until they enter the build range',
      (tester) async {
        final ds = _ProgrammableDataSource(256);
        final controller = ChatScrollController()..jumpTo(128);
        addTearDown(controller.dispose);
        addTearDown(ds.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 600,
                  child: ChatScrollView(
                    dataSource: ds,
                    controller: controller,
                    cacheExtent: 100,
                    messageBuilder: (context, id, message, status) => SizedBox(
                      height: 60,
                      child: Text(message == null ? 'shimmer-$id' : (message as UserChatMessage).content),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        ds.response = (from, to) => <IChatMessage>[
          for (var i = from.clamp(0, 255); i <= to.clamp(0, 255); i++)
            _msg(i, 'fresh $i'),
        ];
        ds.invalidate();
        // First pump lets the markNeedsLayout from invalidate take effect
        // (which arms the fetch-poll Timer); the 200 ms pump advances past
        // the Timer's delay and the fetch await.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();

        // The visible chunk (chunkOf(128) = 2) is now fresh.
        final visibleChunk = ds.chunks[ChatScrollChunk.chunkOf(128)]!;
        expect(visibleChunk.status.isValid, isTrue);
        expect((ds.getMessage(128)! as UserChatMessage).content, 'fresh 128');

        // A far-away chunk (chunk 0, ids 0..63) is still dirty — it never
        // entered the layout range so the poll did not fetch it.
        final farChunk = ds.chunks[0];
        expect(farChunk, isNotNull);
        expect(farChunk!.status.isDirty, isTrue);
        expect((ds.getMessage(0)! as UserChatMessage).content, 'content 0'); // pre-invalidate data
      },
    );

    testWidgets('invalidate cancels a pending retry-backoff timer', (
      tester,
    ) async {
      final ds = _ProgrammableDataSource(64);
      final controller = ChatScrollController()..jumpTo(0);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      // Force the next fetch to fail.
      ds.response = (_, _) => throw StateError('first attempt fails');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 600,
                child: ChatScrollView(
                  dataSource: ds,
                  controller: controller,
                  cacheExtent: 100,
                  messageBuilder: (context, id, message, status) => SizedBox(
                    height: 60,
                    child: Text(message == null ? 'shimmer-$id' : (message as UserChatMessage).content),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Trigger the failing fetch.
      ds.invalidate();
      await tester.pump(); // process markNeedsLayout → arms poll timer
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      // Chunk 0 errored.
      final chunk = ds.chunks[0]!;
      expect(chunk.status.isError, isTrue);
      expect(chunk.failedAttempts, greaterThanOrEqualTo(1));

      // Now flip the source back to "success" responses and invalidate again.
      // The backoff timer (≥ 500 ms) is cancelled by invalidate, the next
      // poll re-fires the fetch immediately.
      ds.response = (from, to) => <IChatMessage>[
        for (var i = from.clamp(0, 63); i <= to.clamp(0, 63); i++)
          _msg(i, 'recovered $i'),
      ];
      ds.invalidate();
      // Chunk should be dirty (error cleared, attempts reset).
      expect(chunk.status.isError, isFalse);
      expect(chunk.status.isDirty, isTrue);
      expect(chunk.failedAttempts, 0);

      // Drive poll + fetch.
      await tester.pump(); // markNeedsLayout from invalidate
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect((ds.getMessage(0)! as UserChatMessage).content, 'recovered 0');
    });
  });
}
