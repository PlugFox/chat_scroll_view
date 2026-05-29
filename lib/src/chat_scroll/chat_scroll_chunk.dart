import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:meta/meta.dart';

/// Chunk of chat messages used for pagination and eviction.
///
/// Holds message data in a fixed-size array. The chunk index is the message id
/// shifted right by [kBits].
@internal
class ChatScrollChunk {
  static const int kBits = 6;
  static const int kSize = 64; // 1 << kBits

  /// Get the chunk index for a given message id.
  /// Dart's `>>` is arithmetic shift — works correctly for negative IDs.
  static int chunkOf(int messageId) => messageId >> kBits;

  /// Get the first message id for a given chunk index.
  static int firstIdOf(int chunkIndex) => chunkIndex << kBits;

  ChatScrollChunk({required this.index})
    : messages = List<IChatMessage?>.filled(kSize, null, growable: false),
      firstId = firstIdOf(index);

  /// The chunk index, calculated as messageId >> kBits.
  /// Can be negative for messages with negative IDs.
  final int index;

  /// The first message id in this chunk (inclusive).
  final int firstId;

  /// The last message id in this chunk (inclusive).
  int get lastId => firstId + kSize - 1;

  /// Message data — populated from fetch results.
  final List<IChatMessage?> messages;

  /// Data status (dirty, fetching, error, valid).
  ChatMessageStatus status = ChatMessageStatus.dirty;

  /// Monotonic access tick — bumped on layout to track LRU order.
  int lastAccessTick = 0;

  /// Last error thrown by a fetch of this chunk, or `null` when the chunk
  /// has never failed (or recovered to `valid`). Cleared on success.
  Object? lastError;

  /// Count of failed fetches for this chunk since the last success. Reset to
  /// 0 on a successful fetch. Includes both auto-retries (backoff timer)
  /// and user-driven retries — what the UI typically wants to show.
  int failedAttempts = 0;
}
