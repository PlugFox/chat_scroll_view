import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_scroll/chat_selection_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_view.dart';
import 'package:chatscrollview/src/chat_widgets/demo/chat_composer.dart';
import 'package:chatscrollview/src/chat_widgets/demo/date_separator.dart';
import 'package:chatscrollview/src/chat_widgets/demo/demo_message.dart';
import 'package:chatscrollview/src/chat_widgets/demo/measure_size.dart';
import 'package:chatscrollview/src/chat_widgets/demo/selection_app_bar.dart';
import 'package:chatscrollview/src/comments_data_source.dart';
import 'package:flutter/material.dart';

/// Demo screen for the widget-based [ChatScrollView] — the chat viewport,
/// a bottom composer, and a contextual selection bar, wired together.
class WidgetChatScreen extends StatefulWidget {
  const WidgetChatScreen({super.key});

  @override
  State<WidgetChatScreen> createState() => _WidgetChatScreenState();
}

class _WidgetChatScreenState extends State<WidgetChatScreen> {
  ChatDataSource? _dataSource;
  late final ChatScrollController _controller;
  late final ChatSelectionController _selection;

  /// Bottom inset reserved inside the viewport — kept in sync with the
  /// composer's measured height so the newest message clears it.
  final ValueNotifier<double> _bottomInset = ValueNotifier<double>(96);
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = ChatScrollController();
    _selection = ChatSelectionController();
    _init();
  }

  @override
  void dispose() {
    _bottomInset.dispose();
    _controller.dispose();
    _selection.dispose();
    _dataSource?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final comments = await CommentsDataSource.load();
      _dataSource = comments;
      _configure(comments.manifest.totalMessages);
    } on Object {
      const count = 4000;
      _dataSource = _DemoDataSource(messageCount: count);
      _configure(count);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _configure(int count) {
    _dataSource!.seedBoundaries(
      oldestKnownId: 0,
      newestKnownId: count - 1,
      reachedOldest: true,
      reachedNewest: true,
    );
    _controller.jumpTo(count - 1);
  }

  /// Stable per-state tear-off — same reference for the widget's lifetime,
  /// so the viewport's skip-rebuild cache stays warm across parent rebuilds.
  /// Consults the previous message via the data source to suppress repeated
  /// sender/avatar for messages in the same run.
  Widget _buildMessage(
    BuildContext context,
    int id,
    IChatMessage? message,
    ChatMessageStatus status,
  ) {
    if (message == null) return const DemoShimmerBubble();
    final prev = _dataSource?.getMessage(id - 1);
    final isFirstInRun = prev?.sender != message.sender;
    return DemoMessageBubble(
      message: message,
      isFirstInRun: isFirstInRun,
    );
  }

  Widget _buildChunkError(
    BuildContext context,
    ChatChunkErrorDetails details,
  ) => DemoChunkErrorTile(
    firstId: details.firstId,
    lastId: details.lastId,
    attempt: details.attempt,
    onRetry: details.retry,
  );

  Widget _buildEmpty(BuildContext context) => const DemoEmptyState();

  Widget _buildInitialSkeleton(BuildContext context) =>
      const DemoInitialSkeleton();

  @override
  Widget build(BuildContext context) {
    if (_loading || _dataSource == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Stack(
        children: <Widget>[
          // Chat fills the screen; the composer is stacked over its bottom.
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: ChatScrollView(
                dataSource: _dataSource!,
                controller: _controller,
                selectionController: _selection,
                bottomPadding: _bottomInset,
                messageBuilder: _buildMessage,
                chunkErrorBuilder: _buildChunkError,
                emptyBuilder: _buildEmpty,
                loadingBuilder: _buildInitialSkeleton,
                dateSeparatorBuilder: (context, date) =>
                    DateSeparator(date: date),
              ),
            ),
          ),
          // Bottom composer — overlaid, not a column sibling. Its measured
          // height feeds the viewport's bottom inset so the newest message
          // always clears it (and any future attachment previews).
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: MeasureSize(
              onChange: (size) => _bottomInset.value = size.height,
              child: ChatComposer(
                selection: _selection,
                dataSource: _dataSource!,
              ),
            ),
          ),
          // Contextual selection bar — overlays the top, so the chat never
          // resizes when selection mode toggles.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SelectionAppBar(selection: _selection),
          ),
        ],
      ),
    );
  }
}

/// Fallback data source generating messages on demand (used when the bundled
/// `assets/comments` data fails to load).
class _DemoDataSource extends ChatDataSource {
  _DemoDataSource({required this.messageCount});

  final int messageCount;
  final DateTime _baseTime = DateTime.now();

  @override
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final lo = fromId.clamp(0, messageCount - 1);
    final hi = toId.clamp(0, messageCount - 1);
    return <IChatMessage>[
      for (var i = lo; i <= hi; i++)
        UserChatMessage(
          id: i,
          sender: 'User',
          // Spread messages across days so the date separators have something
          // to mark — roughly 21 minutes apart.
          createdAt: _baseTime.subtract(
            Duration(minutes: (messageCount - i) * 21),
          ),
          updatedAt: _baseTime.subtract(
            Duration(minutes: (messageCount - i) * 21),
          ),
          content:
              'Message #$i — The first rule of Fight Club is: '
              'you do not talk about Fight Club. The second rule of Fight '
              'Club is: you DO NOT talk about Fight Club!',
        ),
    ];
  }
}
