import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:flutter/widgets.dart';

/// Builds a demo message widget for the widget-based [ChatScrollView].
///
/// Returns a shimmer placeholder while [message] is `null` (chunk loading),
/// and a chat bubble once the message has been fetched.
Widget buildDemoMessage(
  BuildContext context,
  int id,
  IChatMessage? message,
  ChatMessageStatus status,
) {
  if (message == null) return const DemoShimmerBubble();
  return DemoMessageBubble(message: message);
}

/// Max width of a message's content column. The viewport lays every message
/// out at the full viewport width; wider viewports center the column within.
const double _kContentMaxWidth = 620.0;

/// Senders treated as "team members" — right-aligned, distinct bubble color.
const Set<String> _teamMembers = {
  'Hixie', 'justinmc', 'jonahwilliams', 'chunhtai', 'tvolkert', 'goderbauer',
  'zanderso', 'liyuqian', 'aam', 'gspencergoog', 'mit-mit', 'xster',
  'AlexV525', 'maheshj01', 'darshankawar', 'gaaclarke', 'knopp', 'mraleph',
  'jmagman', 'danagbemava-nc', 'huycozy', 'slightfoot', 'guidezpl',
  'pedromassango', 'abarth', 'gnprice', 'cbracken', 'exaby73', 'loic-sharma',
  'nt4f04uNd', 'jason-simmons', 'ColdPaleLight',
};

const List<Color> _senderColors = <Color>[
  Color(0xFF42A5F5), Color(0xFF66BB6A), Color(0xFFEF5350), Color(0xFFAB47BC),
  Color(0xFFFF7043), Color(0xFF26C6DA), Color(0xFFFFCA28), Color(0xFFEC407A),
  Color(0xFF8D6E63), Color(0xFF78909C),
];

Color _colorForSender(String sender) =>
    _senderColors[sender.hashCode.abs() % _senderColors.length];

/// A single chat message bubble — sender label + content text.
///
/// Plain widget tree: the viewport wraps it in a [RepaintBoundary], so its
/// painting is picture-cached and only re-composited while scrolling.
class DemoMessageBubble extends StatelessWidget {
  const DemoMessageBubble({required this.message, super.key});

  final IChatMessage message;

  @override
  Widget build(BuildContext context) {
    final content = switch (message) {
      UserChatMessage(:final content) => content,
      SystemChatMessage(:final content) => content,
      _ => 'Message #${message.id}',
    };
    final isTeam = _teamMembers.contains(message.sender);
    final bg = isTeam ? const Color(0xFF1A237E) : const Color(0xFF2C2C2C);

    final bubble = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 464),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message.sender,
                style: TextStyle(
                  color: _colorForSender(message.sender),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                content,
                style: const TextStyle(
                  color: Color(0xFFE0E0E0),
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // The viewport hands each message the full viewport width; center a
    // max-width content column within it, then align the bubble left/right.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Align(
            alignment: isTeam ? Alignment.centerRight : Alignment.centerLeft,
            child: bubble,
          ),
        ),
      ),
    );
  }
}

/// Placeholder shown for a message whose chunk is still loading.
class DemoShimmerBubble extends StatelessWidget {
  const DemoShimmerBubble({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    // SizedBox(width:) clamps to the viewport when it is narrower, so this
    // behaves as a max-width column — and stays const, unlike ConstrainedBox.
    child: SizedBox(
      width: _kContentMaxWidth,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 280,
            height: 56,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFF2C2C2C),
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
