@Tags(<String>['golden'])
library;

import 'dart:io' show Platform;

import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_widgets/demo/date_separator.dart';
import 'package:chatscrollview/src/chat_widgets/demo/demo_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Golden tests run only on Linux — the project's reference platform. Other
// platforms render fonts and anti-aliasing differently enough to trip the
// exact-pixel default comparator. The group is `skip`-gated below so a
// plain `flutter test` on macOS/Windows leaves the baselines untouched
// instead of failing on platform drift.
//
// To refresh the baselines after an intentional visual change run, on Linux:
//   flutter test --update-goldens test/golden/demo_widgets_golden_test.dart

/// Non-null when the host platform is not the golden-reference one — passed
/// as the `skip` argument so the test reporter prints a single `[SKIPPED]`
/// line per case explaining why.
final String? _platformSkip = Platform.isLinux
    ? null
    : 'Golden baselines are Linux-only; skipping on ${Platform.operatingSystem}.';

UserChatMessage _msg({
  required String sender,
  required String content,
  int id = 0,
  DateTime? when,
}) => UserChatMessage(
  id: id,
  sender: sender,
  createdAt: when ?? DateTime(2026, 5, 29, 14, 15),
  updatedAt: when ?? DateTime(2026, 5, 29, 14, 15),
  content: content,
);

/// Wrap [child] in a fixed-size dark background so golden images don't drift
/// when the surrounding theme changes.
Widget _box({
  required Widget child,
  double width = 400,
  double height = 120,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    backgroundColor: const Color(0xFF121215),
    body: Center(
      child: SizedBox(width: width, height: height, child: child),
    ),
  ),
);

void main() {
  group('demo widget goldens', skip: _platformSkip, () {
    testWidgets('incoming message bubble', (tester) async {
      await tester.pumpWidget(_box(
        child: DemoMessageBubble(
          message: _msg(sender: 'aliceR', content: 'hey, how are you?'),
        ),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DemoMessageBubble),
        matchesGoldenFile('goldens/bubble_incoming.png'),
      );
    });

    testWidgets('outgoing message bubble (team member sender)', (tester) async {
      await tester.pumpWidget(_box(
        child: DemoMessageBubble(
          message: _msg(
            sender: 'Hixie',
            content: 'sounds good — merging now',
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DemoMessageBubble),
        matchesGoldenFile('goldens/bubble_outgoing.png'),
      );
    });

    testWidgets('shimmer placeholder', (tester) async {
      await tester.pumpWidget(_box(
        child: const DemoShimmerBubble(),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DemoShimmerBubble),
        matchesGoldenFile('goldens/shimmer.png'),
      );
    });

    testWidgets('chunk-error tile (first attempt)', (tester) async {
      await tester.pumpWidget(_box(
        height: 80,
        child: DemoChunkErrorTile(
          firstId: 192,
          lastId: 255,
          onRetry: () {},
        ),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DemoChunkErrorTile),
        matchesGoldenFile('goldens/chunk_error.png'),
      );
    });

    testWidgets('chunk-error tile (third attempt — copy widens)', (
      tester,
    ) async {
      await tester.pumpWidget(_box(
        height: 80,
        child: DemoChunkErrorTile(
          firstId: 192,
          lastId: 255,
          attempt: 3,
          onRetry: () {},
        ),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DemoChunkErrorTile),
        matchesGoldenFile('goldens/chunk_error_retried.png'),
      );
    });

    testWidgets('empty state', (tester) async {
      await tester.pumpWidget(_box(
        height: 200,
        child: const DemoEmptyState(),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DemoEmptyState),
        matchesGoldenFile('goldens/empty_state.png'),
      );
    });

    testWidgets('initial loading skeleton', (tester) async {
      await tester.pumpWidget(_box(
        height: 600,
        child: const DemoInitialSkeleton(),
      ));
      // The skeleton hosts a CircularProgressIndicator — an unbounded
      // animation, so `pumpAndSettle` would loop forever. One frame is
      // enough to snapshot a deterministic state.
      await tester.pump();
      await expectLater(
        find.byType(DemoInitialSkeleton),
        matchesGoldenFile('goldens/initial_skeleton.png'),
      );
    });

    testWidgets('date separator pill', (tester) async {
      await tester.pumpWidget(_box(
        height: 56,
        child: DateSeparator(date: DateTime(2026, 5, 29)),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DateSeparator),
        matchesGoldenFile('goldens/date_separator.png'),
      );
    });

    testWidgets('bubble run-grouping: subsequent message in a run', (
      tester,
    ) async {
      // Same sender as the previous message → no avatar, no sender label,
      // bubble tail removed. Visual contract for run-grouped rendering.
      await tester.pumpWidget(_box(
        child: DemoMessageBubble(
          message: _msg(
            sender: 'aliceR',
            content: 'one more thought…',
          ),
          isFirstInRun: false,
        ),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DemoMessageBubble),
        matchesGoldenFile('goldens/bubble_run_continuation.png'),
      );
    });
  });
}
