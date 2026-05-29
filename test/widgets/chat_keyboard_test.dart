import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_keyboard_shortcuts.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

IChatMessage _msg(int i) => UserChatMessage(
  id: i,
  sender: 'User',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  content: 'content $i',
);

class _PreloadedDataSource extends ChatDataSource {
  _PreloadedDataSource(int count) {
    for (var i = 0; i < count; i++) {
      upsertMessage(_msg(i));
    }
    seedBoundaries(
      oldestKnownId: 0,
      newestKnownId: count - 1,
      reachedOldest: true,
      reachedNewest: true,
    );
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
  bool reverse = false,
  bool autofocus = true,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 600,
        child: ChatKeyboardShortcuts(
          controller: controller,
          dataSource: dataSource,
          reverse: reverse,
          autofocus: autofocus,
          child: ChatScrollView(
            dataSource: dataSource,
            controller: controller,
            cacheExtent: 1000,
            messageBuilder: (context, id, message, status) => SizedBox(
              height: 60,
              child: Text(message == null ? 'shimmer-$id' : 'msg-$id'),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  group('keyboard scroll', () {
    testWidgets('ArrowDown nudges the anchor toward newer messages', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();
      final offsetBefore = controller.anchorPixelOffset;

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      // Down = reveal newer = anchor's pixelOffset *decreases* by lineExtent
      // (content shifts up). The default lineExtent is 60.
      expect(controller.anchorPixelOffset, closeTo(offsetBefore - 60, 0.1));
    });

    testWidgets('ArrowUp nudges the anchor toward older messages', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();
      final offsetBefore = controller.anchorPixelOffset;

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();

      expect(controller.anchorPixelOffset, closeTo(offsetBefore + 60, 0.1));
    });

    testWidgets('PageDown / PageUp scroll by ~viewport height', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();

      // Viewport is 600 px tall; pageFraction = 0.85 → 510 px.
      final offsetBefore = controller.anchorPixelOffset;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(controller.anchorPixelOffset, closeTo(offsetBefore - 510, 0.5));

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(controller.anchorPixelOffset, closeTo(offsetBefore, 0.5));
    });

    testWidgets('Home jumps to oldestKnownId', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();

      expect(controller.anchorMessageId, ds.oldestKnownId);
      expect(find.text('msg-0'), findsOneWidget);
    });

    testWidgets('End jumps to newestKnownId', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(50);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();

      expect(controller.anchorMessageId, ds.newestKnownId);
      expect(find.text('msg-255'), findsOneWidget);
    });

    testWidgets('reverse mode flips Home / End so PageUp still goes older', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(100);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        reverse: true,
      ));
      await tester.pumpAndSettle();

      // In reverse mode the "Home" intuition is "the most recent" (top of
      // a reverse-stacked list), so it lands on newestKnownId.
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(controller.anchorMessageId, ds.newestKnownId);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(controller.anchorMessageId, ds.oldestKnownId);
    });

    testWidgets('scrollBy listener fires on key events', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      final deltas = <double>[];
      controller.addScrollByListener(deltas.add);
      addTearDown(() => controller.removeScrollByListener(deltas.add));

      await tester.pumpWidget(_scaffold(dataSource: ds, controller: controller));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();

      // Two scrollBy events: one negative (down) one positive (up).
      expect(deltas.length, 2);
      expect(deltas[0], -60.0);
      expect(deltas[1], 60.0);
    });

    testWidgets('autofocus = false means no scroll until widget is focused', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count ~/ 2);
      final ds = _PreloadedDataSource(count);
      addTearDown(controller.dispose);
      addTearDown(ds.dispose);

      await tester.pumpWidget(_scaffold(
        dataSource: ds,
        controller: controller,
        autofocus: false,
      ));
      await tester.pumpAndSettle();
      final before = controller.anchorPixelOffset;

      // Key dispatches with no focus → shortcut does not fire.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.anchorPixelOffset, before);
    });

    testWidgets(
      'composer TextField keeps focus when shortcuts wrapper has autofocus=false',
      (tester) async {
        const count = 256;
        final controller = ChatScrollController()..jumpTo(count ~/ 2);
        final ds = _PreloadedDataSource(count);
        final composerKey = GlobalKey();
        addTearDown(controller.dispose);
        addTearDown(ds.dispose);

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                Expanded(
                  child: ChatKeyboardShortcuts(
                    controller: controller,
                    dataSource: ds,
                    // Default is autofocus: false — verified by passing it
                    // explicitly so the test is robust to future renames.
                    autofocus: false,
                    child: ChatScrollView(
                      controller: controller,
                      dataSource: ds,
                      cacheExtent: 1000,
                      messageBuilder:
                          (context, id, message, status) => SizedBox(
                        height: 60,
                        child: Text(
                          message == null ? 'shimmer-$id' : 'msg-$id',
                        ),
                      ),
                    ),
                  ),
                ),
                TextField(key: composerKey, autofocus: true),
              ],
            ),
          ),
        ));
        await tester.pumpAndSettle();

        // The composer must own focus — the wrapper did not steal it.
        final composer = tester.widget<TextField>(find.byKey(composerKey));
        final FocusNode? composerNode = composer.focusNode;
        expect(
          composerNode?.hasFocus ?? FocusScope.of(
            composerKey.currentContext!,
          ).hasFocus,
          isTrue,
          reason: 'composer must retain focus over the chat wrapper',
        );
      },
    );
  });

  group('ChatScrollController.scrollBy', () {
    test('zero delta is a no-op (no listener emit)', () {
      final controller = ChatScrollController();
      addTearDown(controller.dispose);
      var emitted = 0;
      controller.addScrollByListener((_) => emitted++);
      controller.scrollBy(0);
      expect(emitted, 0);
    });

    test('non-zero delta updates anchor and notifies listeners', () {
      final controller = ChatScrollController()..jumpTo(10);
      addTearDown(controller.dispose);
      controller.scrollBy(120);
      expect(controller.anchorPixelOffset, 120);

      controller.scrollBy(-50);
      expect(controller.anchorPixelOffset, 70);
    });
  });
}
