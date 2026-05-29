// Regression tests for production-readiness fixes:
//  * `ChatDataSource.dispose` / `ChatScrollController.dispose` /
//    `ChatSelectionController.dispose` are idempotent.
//  * Mutating entry points on a disposed `ChatDataSource` become silent no-ops
//    (no exceptions, no listener notifications, no late timer fires).
//  * `upsertMessage` / `upsertMessages` create chunks in `valid` status so the
//    next poll does not refetch and overwrite a local message.
//  * `retryChunk` resets `failedAttempts` / `lastError` and skips when an
//    in-flight fetch already covers the chunk.

import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_chunk.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_scroll/chat_selection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

IChatMessage _msg(int i) => UserChatMessage(
  id: i,
  sender: 'User',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  content: 'content $i',
);

/// Records every fetchRange call; can be told to fail or succeed.
class _RecorderDataSource extends ChatDataSource {
  final List<({int from, int to})> calls = <({int from, int to})>[];
  bool shouldFail = false;

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async {
    calls.add((from: fromId, to: toId));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (shouldFail) throw StateError('boom');
    return <IChatMessage>[
      for (var i = fromId; i <= toId; i++) _msg(i),
    ];
  }
}

void main() {
  group('upsertMessage chunk status', () {
    test('a freshly-created chunk is marked valid, not dirty', () {
      final ds = _RecorderDataSource();
      addTearDown(ds.dispose);

      ds.upsertMessage(_msg(0));

      final chunk = ds.chunks[0]!;
      expect(chunk.status.isValid, isTrue);
      expect(chunk.status.isDirty, isFalse);
    });

    test('upsertMessages on a fresh source marks every new chunk valid', () {
      final ds = _RecorderDataSource();
      addTearDown(ds.dispose);

      ds.upsertMessages([_msg(0), _msg(64), _msg(128)]);

      for (final chunk in ds.chunks.values) {
        expect(chunk.status.isValid, isTrue, reason: 'chunk ${chunk.index}');
      }
    });

    test('upsert into an existing dirty chunk does NOT overwrite status', () {
      // Edge case: a chunk created by the fetch path (status = dirty/fetching)
      // must not be silently promoted to valid by a later upsert — the fetch
      // is still authoritative for that chunk's pagination state.
      final ds = _RecorderDataSource();
      addTearDown(ds.dispose);

      // Forge a dirty chunk that already exists.
      ds.chunks[0] =
          ChatScrollChunk(index: 0)..status = ChatMessageStatus.fetching;

      ds.upsertMessage(_msg(5));

      expect(ds.chunks[0]!.status.isFetching, isTrue);
      expect(ds.chunks[0]!.status.isValid, isFalse);
    });
  });

  group('idempotent dispose', () {
    test('ChatDataSource.dispose is idempotent', () {
      final ds = _RecorderDataSource();
      ds
        ..dispose()
        ..dispose();
      expect(ds.isDisposed, isTrue);
    });

    test('ChatScrollController.dispose is idempotent', () {
      final c = ChatScrollController();
      c
        ..dispose()
        ..dispose();
      expect(c.isDisposed, isTrue);
    });

    test('ChatSelectionController.dispose is idempotent', () {
      final s = ChatSelectionController();
      s
        ..dispose()
        ..dispose();
      expect(s.isDisposed, isTrue);
    });
  });

  group('post-dispose mutations are no-ops', () {
    test('upsertMessage after dispose does not throw or notify', () {
      final ds = _RecorderDataSource();
      var notifications = 0;
      ds.addDataListener(() => notifications++);
      ds.dispose();

      // dispose clears the listener list — re-adding after dispose is
      // tolerated (no-op) but the listener won't fire.
      ds.addDataListener(() => notifications++);
      ds.upsertMessage(_msg(0));
      ds.upsertMessages([_msg(1), _msg(2)]);

      expect(notifications, 0);
      expect(ds.chunks, isEmpty);
    });

    test('requestChunks after dispose does not call fetchRange', () {
      final ds = _RecorderDataSource();
      ds.dispose();
      ds.requestChunks(0, 3);
      expect(ds.calls, isEmpty);
    });

    test('retryChunk / invalidate / cancelFetch after dispose are no-ops', () {
      final ds = _RecorderDataSource();
      ds.dispose();
      // All of these would crash if they tried to touch listeners or schedule
      // timers.
      ds
        ..retryChunk(0)
        ..invalidate()
        ..cancelFetch();
      expect(ds.calls, isEmpty);
    });
  });

  group('retryChunk', () {
    test('resets failedAttempts and lastError on the targeted chunk', () async {
      final ds = _RecorderDataSource()..shouldFail = true;
      addTearDown(ds.dispose);

      // Drive one failed fetch attempt so the chunk is in error with
      // a non-zero failure counter.
      ds.requestChunks(0, 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final chunk = ds.chunks[0]!;
      expect(chunk.status.isError, isTrue);
      expect(chunk.failedAttempts, 1);
      expect(chunk.lastError, isNotNull);

      // The retry-chunk path should treat the user tap as a fresh first
      // attempt — counter and lastError reset.
      ds
        ..shouldFail = false
        ..retryChunk(0);
      expect(chunk.failedAttempts, 0);
      expect(chunk.lastError, isNull);
    });

    test('no-op when an in-flight fetch already covers the chunk', () async {
      final ds = _RecorderDataSource();
      addTearDown(ds.dispose);

      ds.requestChunks(0, 4); // starts a fetch for chunks 0..4
      final callsBefore = ds.calls.length;
      ds.retryChunk(64); // chunk 1 — inside the in-flight range
      expect(
        ds.calls.length,
        callsBefore,
        reason: 'retryChunk should not start a new fetch when the running '
            'one already covers the requested chunk',
      );
      // Let the original fetch resolve cleanly so the tearDown is quiet.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  });
}
