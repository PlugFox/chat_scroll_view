import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_scroll/chat_selection_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/chat_selectable_message.dart';
import 'package:chatscrollview/src/chat_widgets/demo/chat_composer.dart';
import 'package:chatscrollview/src/chat_widgets/demo/selection_app_bar.dart';
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

IChatMessage _msg(int i) => UserChatMessage(
  id: i,
  sender: 'User',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  content: 'content $i',
);

List<IChatMessage> _generate(int n) => <IChatMessage>[
  for (var i = 0; i < n; i++) _msg(i),
];

Widget _harness({
  required ChatDataSource dataSource,
  required ChatScrollController controller,
  ChatSelectionController? selectionController,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 600,
        child: ChatScrollView(
          dataSource: dataSource,
          controller: controller,
          selectionController: selectionController,
          messageBuilder: (context, id, message, status) => SizedBox(
            height: 60,
            child: Text(message == null ? 'shimmer-$id' : 'msg-$id'),
          ),
        ),
      ),
    ),
  ),
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ChatScrollView selection', () {
    testWidgets('wraps messages in SelectableMessage when a controller is '
        'provided', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count - 1);
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
          selectionController: ChatSelectionController(),
        ),
      );
      await tester.pump();

      expect(find.byType(SelectableMessage), findsWidgets);
    });

    testWidgets('adds no SelectableMessage wrapper without a controller', (
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

      expect(find.byType(SelectableMessage), findsNothing);
      expect(find.text('msg-255'), findsOneWidget);
    });

    testWidgets('long-press enters selection mode and selects the message', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count - 1);
      final selection = ChatSelectionController();
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
          selectionController: selection,
        ),
      );
      await tester.pump();

      expect(selection.isSelectionMode, isFalse);

      await tester.longPress(find.text('msg-255'));
      await tester.pumpAndSettle();

      expect(selection.isSelectionMode, isTrue);
      expect(selection.isSelected(255), isTrue);
      expect(selection.count, 1);
    });

    testWidgets('tap toggles messages while in selection mode', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count - 1);
      final selection = ChatSelectionController();
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
          selectionController: selection,
        ),
      );
      await tester.pump();

      await tester.longPress(find.text('msg-255'));
      await tester.pumpAndSettle();

      // A second message is added by a plain tap.
      await tester.tap(find.text('msg-254'));
      await tester.pumpAndSettle();
      expect(selection.isSelected(254), isTrue);
      expect(selection.count, 2);

      // Tapping it again removes it.
      await tester.tap(find.text('msg-254'));
      await tester.pumpAndSettle();
      expect(selection.isSelected(254), isFalse);
      expect(selection.count, 1);
    });

    testWidgets('tap does nothing outside selection mode', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count - 1);
      final selection = ChatSelectionController();
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
          selectionController: selection,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('msg-255'));
      await tester.pumpAndSettle();

      expect(selection.isSelectionMode, isFalse);
      expect(selection.count, 0);
    });

    testWidgets('drag still scrolls the viewport while in selection mode', (
      tester,
    ) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count - 1);
      final selection = ChatSelectionController();
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
          selectionController: selection,
        ),
      );
      await tester.pump();

      await tester.longPress(find.text('msg-255'));
      await tester.pumpAndSettle();
      expect(selection.isSelectionMode, isTrue);

      // The per-message tap/long-press recognizers must not swallow drags.
      await tester.drag(find.byType(ChatScrollView), const Offset(0, 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('msg-255'), findsNothing);
      expect(selection.isSelectionMode, isTrue);
    });

    testWidgets('clearing selection exits selection mode', (tester) async {
      const count = 256;
      final controller = ChatScrollController()..jumpTo(count - 1);
      final selection = ChatSelectionController();
      await tester.pumpWidget(
        _harness(
          dataSource: _PreloadedDataSource(_generate(count)),
          controller: controller,
          selectionController: selection,
        ),
      );
      await tester.pump();

      await tester.longPress(find.text('msg-255'));
      await tester.pumpAndSettle();
      expect(selection.isSelectionMode, isTrue);

      selection.clear();
      await tester.pumpAndSettle();
      expect(selection.isSelectionMode, isFalse);
    });
  });

  group('selection chrome', () {
    testWidgets('SelectionAppBar reveals a count and closes the selection', (
      tester,
    ) async {
      final selection = ChatSelectionController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                const SizedBox.expand(),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SelectionAppBar(selection: selection),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // Hidden while idle.
      expect(find.byIcon(Icons.close_rounded), findsNothing);

      selection.startSelection(3);
      await tester.pumpAndSettle();
      expect(find.text('Выбрано: 1'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(selection.isSelectionMode, isFalse);
    });

    testWidgets('ChatComposer copy action copies and clears the selection', (
      tester,
    ) async {
      final selection = ChatSelectionController();
      final dataSource = _PreloadedDataSource(_generate(32));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                const Expanded(child: SizedBox()),
                ChatComposer(selection: selection, dataSource: dataSource),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // The input field is present while idle.
      expect(find.byType(TextField), findsOneWidget);

      selection
        ..startSelection(5)
        ..startSelection(6);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pumpAndSettle();

      expect(selection.isSelectionMode, isFalse);
    });
  });
}
