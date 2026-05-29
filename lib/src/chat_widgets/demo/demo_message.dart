import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:flutter/material.dart';

/// Builds a demo message widget for the widget-based [ChatScrollView].
///
/// Returns a shimmer placeholder while [message] is `null` (chunk loading),
/// and a chat bubble once the message has been fetched. Every message shows
/// its sender, time, and avatar.
///
/// For run-grouped rendering (sender / avatar only on the first message of a
/// run from a given user) build a closure that captures the data source and
/// consults `getMessage(id - 1)` — see `widget_chat_screen.dart`.
Widget buildDemoMessage(
  BuildContext context,
  int id,
  IChatMessage? message,
  ChatMessageStatus status,
) {
  if (message == null) return const DemoShimmerBubble();
  return DemoMessageBubble(message: message);
}

/// Max width of a message's content column (the column inside the viewport,
/// not the bubble itself — the viewport hands each message the full viewport
/// width, then we centre this column within it).
const double _kContentMaxWidth = 620.0;

/// Max width of a single bubble inside the content column.
const double _kBubbleMaxWidth = 480.0;

/// Avatar diameter; doubles as the left gutter for run-grouped messages
/// (those without a fresh avatar still indent by this much).
const double _kAvatarSize = 32.0;

/// Senders treated as "team members" — right-aligned, distinct bubble color.
/// In a real chat this would be "is the current user" — the team list just
/// gives the demo two visually-distinct columns to compare.
const Set<String> _teamMembers = {
  'Hixie', 'justinmc', 'jonahwilliams', 'chunhtai', 'tvolkert', 'goderbauer',
  'zanderso', 'liyuqian', 'aam', 'gspencergoog', 'mit-mit', 'xster',
  'AlexV525', 'maheshj01', 'darshankawar', 'gaaclarke', 'knopp', 'mraleph',
  'jmagman', 'danagbemava-nc', 'huycozy', 'slightfoot', 'guidezpl',
  'pedromassango', 'abarth', 'gnprice', 'cbracken', 'exaby73', 'loic-sharma',
  'nt4f04uNd', 'jason-simmons', 'ColdPaleLight',
};

bool _isOutgoing(String sender) => _teamMembers.contains(sender);

const List<Color> _senderColors = <Color>[
  Color(0xFF42A5F5), Color(0xFF66BB6A), Color(0xFFEF5350), Color(0xFFAB47BC),
  Color(0xFFFF7043), Color(0xFF26C6DA), Color(0xFFFFCA28), Color(0xFFEC407A),
  Color(0xFF8D6E63), Color(0xFF78909C),
];

Color _colorForSender(String sender) =>
    _senderColors[sender.hashCode.abs() % _senderColors.length];

/// "HH:MM" in the local time zone — what most chats show inside a bubble.
String _formatTime(DateTime dt) {
  final local = dt.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

const List<String> _monthsRu = <String>[
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];

/// Verbose "5 января 2026, 14:23:45" — shown in the tooltip on hover, so the
/// user can see the exact send time without burning bubble real estate.
String _formatFullDateTime(DateTime dt) {
  final local = dt.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  final s = local.second.toString().padLeft(2, '0');
  return '${local.day} ${_monthsRu[local.month - 1]} ${local.year}, '
      '$h:$m:$s';
}

// --- Palette --------------------------------------------------------------

const Color _kOutgoingBg = Color(0xFF0B81F6);
const Color _kIncomingBg = Color(0xFF2A2A2C);
const Color _kOutgoingText = Color(0xFFFFFFFF);
const Color _kIncomingText = Color(0xFFE6E7EB);
const Color _kShimmer = Color(0xFF2C2C2E);

// --- Bubble ---------------------------------------------------------------

/// A single chat bubble — sender label (optional), content text, time, and
/// (for outgoing) a delivery status icon.
///
/// [isFirstInRun] — `true` when the previous message in the chat has a
/// different sender (or there is no previous message). The first message in
/// a run carries an avatar, a sender label, and a bubble "tail" pointing
/// toward its column; subsequent messages omit the avatar / label, drop the
/// tail, and indent to keep the run visually aligned.
class DemoMessageBubble extends StatelessWidget {
  const DemoMessageBubble({
    required this.message,
    this.isFirstInRun = true,
    super.key,
  });

  final IChatMessage message;
  final bool isFirstInRun;

  @override
  Widget build(BuildContext context) {
    final content = switch (message) {
      UserChatMessage(:final content) => content,
      SystemChatMessage(:final content) => content,
      _ => 'Message #${message.id}',
    };
    final outgoing = _isOutgoing(message.sender);
    final bubble = _Bubble(
      sender: isFirstInRun ? message.sender : null,
      content: content,
      createdAt: message.createdAt,
      isOutgoing: outgoing,
      hasTail: isFirstInRun,
    );

    final Widget row;
    if (outgoing) {
      // Outgoing — bubble pinned to the right; no avatar.
      row = Align(alignment: Alignment.centerRight, child: bubble);
    } else {
      // Incoming — avatar on the left, then bubble. Subsequent messages
      // in the run keep the avatar gutter so the run reads as one block.
      row = Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          if (isFirstInRun)
            _Avatar(sender: message.sender)
          else
            const SizedBox(width: _kAvatarSize),
          const SizedBox(width: 8),
          Flexible(child: bubble),
        ],
      );
    }

    // Tighter vertical padding for non-first messages so a run reads as one
    // visual group.
    final topPad = isFirstInRun ? 6.0 : 2.0;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, topPad, 12, 2),
          child: row,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.sender});

  final String sender;

  @override
  Widget build(BuildContext context) {
    final initial = sender.isEmpty
        ? '?'
        : sender.characters.first.toUpperCase();
    return Container(
      width: _kAvatarSize,
      height: _kAvatarSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _colorForSender(sender),
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontWeight: FontWeight.w700,
          fontSize: 14,
          height: 1.0,
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.sender,
    required this.content,
    required this.createdAt,
    required this.isOutgoing,
    required this.hasTail,
  });

  /// `null` suppresses the sender label — non-first messages in a run.
  final String? sender;
  final String content;
  final DateTime createdAt;
  final bool isOutgoing;
  final bool hasTail;

  /// Border radius — asymmetric on the corner that points at the column the
  /// sender writes from (tail effect, without an actual tail glyph).
  BorderRadius get _radius {
    const r = Radius.circular(16);
    const tail = Radius.circular(4);
    if (!hasTail) return const BorderRadius.all(r);
    return isOutgoing
        ? const BorderRadius.only(
            topLeft: r,
            topRight: r,
            bottomLeft: r,
            bottomRight: tail,
          )
        : const BorderRadius.only(
            topLeft: tail,
            topRight: r,
            bottomLeft: r,
            bottomRight: r,
          );
  }

  @override
  Widget build(BuildContext context) {
    final bg = isOutgoing ? _kOutgoingBg : _kIncomingBg;
    final textColor = isOutgoing ? _kOutgoingText : _kIncomingText;
    final metaColor = isOutgoing
        ? _kOutgoingText.withValues(alpha: 0.78)
        : _kIncomingText.withValues(alpha: 0.55);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _kBubbleMaxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: _radius,
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (sender != null) ...<Widget>[
                Text(
                  sender!,
                  style: TextStyle(
                    color: _colorForSender(sender!),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 3),
              ],
              Text(
                content,
                style: TextStyle(
                  color: textColor,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 2),
              _MetaRow(
                createdAt: createdAt,
                color: metaColor,
                showStatus: isOutgoing,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "12:34 ✓✓" row at the bottom-right of a bubble. The double-check is a
/// "delivered" hint for outgoing messages; incoming bubbles show just time.
///
/// The whole row is wrapped in a [Tooltip] showing the full date and time —
/// on desktop / web a hover over the time pops the precise send timestamp,
/// on mobile a long-press does the same. Long-press on the bubble itself is
/// already used by selection mode, so the tooltip's gesture only fires on
/// the metadata strip; that's the right trade-off (long-press the bubble →
/// select; hover the time → see the date).
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.createdAt,
    required this.color,
    required this.showStatus,
  });

  final DateTime createdAt;
  final Color color;
  final bool showStatus;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    // Only the time-and-status cluster is the tooltip target — wrapping the
    // outer right-aligned row would stretch the hit zone across the whole
    // bubble width via the Spacer it used to need.
    child: Tooltip(
      message: _formatFullDateTime(createdAt),
      waitDuration: const Duration(milliseconds: 400),
      triggerMode: TooltipTriggerMode.longPress,
      preferBelow: false,
      textStyle: const TextStyle(
        color: Color(0xFFE6E7EB),
        fontSize: 12,
        fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
      ),
      decoration: BoxDecoration(
        color: const Color(0xE61C1C1E),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            _formatTime(createdAt),
            style: TextStyle(
              color: color,
              fontSize: 11,
              height: 1.0,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          if (showStatus) ...<Widget>[
            const SizedBox(width: 4),
            Icon(Icons.done_all_rounded, size: 14, color: color),
          ],
        ],
      ),
    ),
  );
}

// --- Shimmer placeholder --------------------------------------------------

/// Placeholder shown for a message whose chunk is still loading. Mirrors the
/// real bubble layout — avatar circle + bubble silhouette — so the chat
/// doesn't jump when data lands.
class DemoShimmerBubble extends StatelessWidget {
  const DemoShimmerBubble({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
      child: const Padding(
        padding: EdgeInsets.fromLTRB(12, 6, 12, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                color: _kShimmer,
                shape: BoxShape.circle,
              ),
              child: SizedBox(width: _kAvatarSize, height: _kAvatarSize),
            ),
            SizedBox(width: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: _kShimmer,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: SizedBox(width: 240, height: 52),
            ),
          ],
        ),
      ),
    ),
  );
}

// --- Chunk-error tile -----------------------------------------------------

/// Failure tile shown in place of an entire chunk whose fetch errored. One
/// per chunk (not 64 per-message slots), tapping "Retry" cancels the
/// running backoff and re-fetches the chunk immediately.
class DemoChunkErrorTile extends StatelessWidget {
  const DemoChunkErrorTile({
    required this.firstId,
    required this.lastId,
    required this.onRetry,
    this.attempt = 0,
    super.key,
  });

  final int firstId;
  final int lastId;
  final int attempt;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final label = attempt > 1
        ? 'Failed to load messages $firstId–$lastId (attempt $attempt)'
        : 'Failed to load messages $firstId–$lastId';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF3A2A2A),
              border: Border.all(color: const Color(0xFF6B3A3A)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 20,
                    color: Color(0xFFE57373),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Color(0xFFE6E7EB),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFE57373),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Empty state ----------------------------------------------------------

/// Full-viewport empty state. Shown when the data source reports
/// [ChatDataSource.isEmpty] — the conversation has no messages.
class DemoEmptyState extends StatelessWidget {
  const DemoEmptyState({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          Icons.forum_outlined,
          size: 48,
          color: Color(0xFF6E7280),
        ),
        SizedBox(height: 12),
        Text(
          'No messages yet',
          style: TextStyle(
            color: Color(0xFFE6E7EB),
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Start the conversation below.',
          style: TextStyle(
            color: Color(0xFF8E94A2),
            fontSize: 13,
          ),
        ),
      ],
    ),
  );
}

// --- Initial loading skeleton --------------------------------------------

/// Full-viewport skeleton shown before the first chunk lands. A stack of
/// shimmer bubbles standing in for the message list, plus a small spinner —
/// fills the viewport so the user sees layout structure immediately instead
/// of waiting on a blank screen.
class DemoInitialSkeleton extends StatelessWidget {
  const DemoInitialSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    children: <Widget>[
      SizedBox(height: 24),
      DemoShimmerBubble(),
      DemoShimmerBubble(),
      DemoShimmerBubble(),
      DemoShimmerBubble(),
      Spacer(),
      SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8E94A2)),
        ),
      ),
      SizedBox(height: 32),
    ],
  );
}
