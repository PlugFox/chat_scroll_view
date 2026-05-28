import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:chatscrollview/src/chat_scroll/chat_scroll_chunk.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:meta/meta.dart';

/// Bootstrap result returned by [ChatDataSource.fetchInitial].
///
/// Carries the first page of messages along with the boundary metadata the
/// viewport needs to position the anchor and know where the conversation
/// ends — so the consumer doesn't have to mirror this state onto the
/// controller manually.
typedef ChatInitialPage = ({
  /// Messages to seed the chunk cache with — typically the newest page.
  List<IChatMessage> messages,

  /// Lowest known id at bootstrap time (`null` if completely unknown — the
  /// data source has no idea what the oldest id is yet).
  int? oldestId,

  /// Highest known id at bootstrap time. `null` only when the conversation
  /// is empty (then anchor stays at its default).
  int? newestId,

  /// Whether [oldestId] is the very first message of the conversation
  /// (`reachedOldest`). Default to `false` when unknown.
  bool reachedOldest,

  /// Whether [newestId] is the very last message of the conversation
  /// (`reachedNewest`). Default to `false` when unknown.
  bool reachedNewest,
});

/// Data source for [ChatScrollView].
///
/// Owns message data (chunks), the fetch contract, and the conversation
/// boundary state (`oldestKnownId`, `reachedNewest`, …). Boundary state used
/// to live on the controller but it describes the *data*, not the
/// navigation — keeping a single source of truth here means consumers don't
/// have to mirror page metadata onto two objects after every fetch.
///
/// Uses typed listeners instead of [ChangeNotifier] — subscribers know
/// exactly what event occurred.
abstract class ChatDataSource {
  // --- Fetch contract (subclass implements) ---

  /// Load messages whose ids fall in `[fromId, toId]` (both inclusive). The
  /// subclass may return fewer messages than the range when the end of the
  /// conversation lies inside it. Required.
  Future<List<IChatMessage>> fetchRange({
    required int fromId,
    required int toId,
  });

  /// Optional bootstrap: load the first page when no boundary is known yet.
  ///
  /// The viewport calls this once on first layout if [newestKnownId] is
  /// `null`. Default implementation throws — override to enable automatic
  /// initial load. Consumers that prepare their data before mounting can
  /// skip overriding and configure boundaries explicitly via
  /// [seedBoundaries] / [upsertMessages] / [ChatScrollController.jumpTo].
  ///
  /// [limit] hints how many messages the viewport wants — the data source
  /// is free to return more or fewer.
  Future<ChatInitialPage> fetchInitial({int? limit}) =>
      throw UnimplementedError(
        '$runtimeType does not implement fetchInitial — either override it '
        'or seed boundaries + messages explicitly before mounting the '
        'viewport.',
      );

  /// Maximum number of chunks to keep in memory.
  /// Override to control the memory/re-fetch tradeoff.
  /// Default 16 ≈ 1024 messages.
  int get maxChunks => 16;

  // --- Boundary state -------------------------------------------------------

  int? _oldestKnownId;
  int? _newestKnownId;
  bool _reachedOldest = false;
  bool _reachedNewest = false;

  /// Lowest message id the data source has seen so far. `null` until the
  /// first page lands. Bumped down by subsequent fetches that reveal older
  /// pages.
  int? get oldestKnownId => _oldestKnownId;

  /// Highest message id the data source has seen so far. `null` while the
  /// conversation is empty.
  int? get newestKnownId => _newestKnownId;

  /// Whether [oldestKnownId] is the very first message of the conversation —
  /// no more older pages exist. The viewport pins content to the top edge
  /// when both this is `true` and the oldest is in view.
  bool get reachedOldest => _reachedOldest;

  /// Whether [newestKnownId] is the very last message of the conversation —
  /// no more newer pages exist. The viewport pins content to the bottom
  /// edge when both this is `true` and the newest is in view.
  bool get reachedNewest => _reachedNewest;

  /// Atomically set the boundary state. Notifies listeners only if anything
  /// actually changed. Intended for subclasses to call after a fetch resolves
  /// — but also exposed publicly so consumers that pre-load their data can
  /// configure the viewport in one statement.
  @mustCallSuper
  void seedBoundaries({
    int? oldestKnownId,
    int? newestKnownId,
    bool? reachedOldest,
    bool? reachedNewest,
  }) {
    var changed = false;
    if (oldestKnownId != null && oldestKnownId != _oldestKnownId) {
      _oldestKnownId = oldestKnownId;
      changed = true;
    }
    if (newestKnownId != null && newestKnownId != _newestKnownId) {
      _newestKnownId = newestKnownId;
      changed = true;
    }
    if (reachedOldest != null && reachedOldest != _reachedOldest) {
      _reachedOldest = reachedOldest;
      changed = true;
    }
    if (reachedNewest != null && reachedNewest != _reachedNewest) {
      _reachedNewest = reachedNewest;
      changed = true;
    }
    assert(
      _oldestKnownId == null ||
          _newestKnownId == null ||
          _oldestKnownId! <= _newestKnownId!,
      'oldestKnownId ($_oldestKnownId) must be ≤ newestKnownId '
      '($_newestKnownId)',
    );
    assert(
      !_reachedOldest || _oldestKnownId != null,
      'reachedOldest=true requires oldestKnownId to be set',
    );
    assert(
      !_reachedNewest || _newestKnownId != null,
      'reachedNewest=true requires newestKnownId to be set',
    );
    if (changed) _notifyBoundary();
  }

  // --- Typed listener: boundary changed ---

  final _boundaryListeners = <VoidCallback>[];

  /// Subscribe to boundary state changes.
  void addBoundaryListener(VoidCallback callback) =>
      _boundaryListeners.add(callback);

  /// Unsubscribe from boundary state changes.
  void removeBoundaryListener(VoidCallback callback) =>
      _boundaryListeners.remove(callback);

  void _notifyBoundary() {
    for (final cb in List<VoidCallback>.of(
      _boundaryListeners,
      growable: false,
    )) {
      cb();
    }
  }

  // --- Chunk storage ---

  final Map<int, ChatScrollChunk> _chunks = HashMap<int, ChatScrollChunk>();

  /// Direct access to chunks for the viewport.
  @internal
  Map<int, ChatScrollChunk> get chunks => _chunks;

  /// Get a message by ID from the chunk cache.
  IChatMessage? getMessage(int messageId) {
    final chunkIndex = ChatScrollChunk.chunkOf(messageId);
    final chunk = _chunks[chunkIndex];
    if (chunk == null) return null;
    final slot = messageId - chunk.firstId;
    assert(
      slot >= 0 && slot < ChatScrollChunk.kSize,
      'Chunk $chunkIndex stored at the wrong index for id $messageId: '
      'firstId=${chunk.firstId} → slot=$slot out of [0..${ChatScrollChunk.kSize})',
    );
    return chunk.messages[slot];
  }

  /// Upsert a message into the chunk cache.
  /// Creates the chunk if it does not exist yet.
  void upsertMessage(IChatMessage message) {
    final chunkIndex = ChatScrollChunk.chunkOf(message.id);
    final chunk = _chunks.putIfAbsent(
      chunkIndex,
      () => ChatScrollChunk(index: chunkIndex),
    );
    chunk.messages[message.id - chunk.firstId] = message;
    notifyDataChanged();
  }

  /// Upsert multiple messages into the chunk cache.
  void upsertMessages(Iterable<IChatMessage> messages) {
    var changed = false;
    for (final message in messages) {
      final chunkIndex = ChatScrollChunk.chunkOf(message.id);
      final chunk = _chunks.putIfAbsent(
        chunkIndex,
        () => ChatScrollChunk(index: chunkIndex),
      );
      chunk.messages[message.id - chunk.firstId] = message;
      changed = true;
    }
    if (changed) notifyDataChanged();
  }

  // --- Range fetch orchestration ---

  static final math.Random _rnd = math.Random();
  Object? _fetchToken;
  int _fetchRetryStep = 0;
  Timer? _retryTimer;
  int _fetchingMinChunk = 0;
  int _fetchingMaxChunk = -1;

  /// Chunk indices touched by the in-flight fetch — the subset of
  /// `[_fetchingMinChunk, _fetchingMaxChunk]` that actually needed loading.
  /// On resolution / cancellation only these chunks have their status
  /// updated; already-valid neighbours inside the bounding range are left
  /// alone so a transient failure on one chunk does not flicker a sibling
  /// from valid → error.
  final Set<int> _fetchingChunks = <int>{};

  /// Whether [chunk] should be (re-)fetched. Missing, dirty, or errored
  /// chunks are eligible; already-fetching and clean chunks are not. Without
  /// the `error` branch a chunk that failed while neighbouring a valid one
  /// would stay errored forever — `requestChunks` would not see it as dirty.
  static bool _needsFetch(ChatScrollChunk? chunk) {
    if (chunk == null) return true;
    final status = chunk.status;
    if (status.isFetching) return false;
    return status.isDirty || status.isError;
  }

  /// Check visible chunk range and fetch missing/dirty data.
  /// Called from the viewport's periodic poll timer.
  @internal
  void requestChunks(int layoutMinChunk, int layoutMaxChunk) {
    // Find the actual range that needs fetching.
    var needsMin = -1;
    var needsMax = -1;
    for (var ci = layoutMinChunk; ci <= layoutMaxChunk; ci++) {
      if (_needsFetch(_chunks[ci])) {
        if (needsMin < 0) needsMin = ci;
        needsMax = ci;
      }
    }
    if (needsMin < 0) return; // all chunks valid

    // Same range already fetching — wait for it.
    if (_fetchToken != null &&
        _fetchingMinChunk == needsMin &&
        _fetchingMaxChunk == needsMax) {
      return;
    }

    // New range — cancel old request and start fresh.
    _cancelFetch();
    _fetchingMinChunk = needsMin;
    _fetchingMaxChunk = needsMax;
    _fetchRetryStep = 0;
    _executeFetch();
  }

  /// Cancel any in-flight fetch and retry timer.
  @internal
  void cancelFetch() => _cancelFetch();

  void _cancelFetch() {
    // Clear the `fetching` flag from chunks that were part of the in-flight
    // range so they don't get stuck in an indeterminate state.
    var changed = false;
    if (_fetchingChunks.isNotEmpty) {
      for (final ci in _fetchingChunks) {
        final chunk = _chunks[ci];
        if (chunk == null) continue;
        chunk.status = chunk.status.remove(ChatMessageStatus.fetching);
        changed = true;
      }
      _fetchingChunks.clear();
    }
    _fetchToken = null;
    _fetchingMinChunk = 0;
    _fetchingMaxChunk = -1;
    _retryTimer?.cancel();
    _retryTimer = null;
    // Listeners (the viewport, debug overlays) need to know the fetching
    // flag dropped — a chunk stuck in `fetching` after detach / source-swap
    // would render an indefinite shimmer.
    if (changed) notifyDataChanged();
  }

  void _executeFetch() {
    final token = Object();
    _fetchToken = token;

    // Pre-create only the chunks that actually need loading and mark them
    // `fetching`. Valid chunks in the middle of the bounding range stay
    // valid — they piggyback on the request but their status is not touched
    // by success or failure of the fetch.
    _fetchingChunks.clear();
    for (var ci = _fetchingMinChunk; ci <= _fetchingMaxChunk; ci++) {
      final existing = _chunks[ci];
      if (existing != null && !_needsFetch(existing)) continue;
      final chunk = existing ??
          (_chunks[ci] = ChatScrollChunk(index: ci));
      chunk.status = chunk.status
          .remove(ChatMessageStatus.error)
          .add(ChatMessageStatus.fetching);
      _fetchingChunks.add(ci);
    }
    notifyDataChanged();

    final fromId = ChatScrollChunk.firstIdOf(_fetchingMinChunk);
    final toId =
        ChatScrollChunk.firstIdOf(_fetchingMaxChunk) +
        ChatScrollChunk.kSize -
        1;

    fetchRange(fromId: fromId, toId: toId).then(
      (messages) {
        if (_fetchToken != token) return; // cancelled or replaced
        _fetchToken = null;

        // Upsert and mark chunks valid.
        for (final msg in messages) {
          final ci = ChatScrollChunk.chunkOf(msg.id);
          final chunk = _chunks.putIfAbsent(
            ci,
            () => ChatScrollChunk(index: ci),
          );
          chunk.messages[msg.id - chunk.firstId] = msg;
        }
        for (final ci in _fetchingChunks) {
          _chunks[ci]?.status = ChatMessageStatus.valid;
        }
        _fetchingChunks.clear();
        notifyDataChanged();
      },
      onError: (Object _) {
        if (_fetchToken != token) return; // cancelled or replaced
        _fetchToken = null;

        // Clear fetching, mark error so UI can react. Touch only the chunks
        // we actually requested — neighbouring valid chunks must not flip
        // to error.
        for (final ci in _fetchingChunks) {
          final chunk = _chunks[ci];
          if (chunk == null) continue;
          chunk.status = chunk.status
              .remove(ChatMessageStatus.fetching)
              .add(ChatMessageStatus.error);
        }
        _fetchingChunks.clear();
        notifyDataChanged();

        // Retry with backoff.
        final delay = _nextDelay(_fetchRetryStep, 500, 30000);
        _fetchRetryStep++;
        _retryTimer = Timer(delay, _executeFetch);
      },
    );
  }

  static Duration _nextDelay(int step, int minDelay, int maxDelay) {
    if (minDelay >= maxDelay) return Duration(milliseconds: maxDelay);
    final val = math.min(maxDelay, minDelay * math.pow(2, step.clamp(0, 31)));
    // `nextInt(0)` would throw; clamp the jitter window to at least 1ms so a
    // misconfigured `minDelay=0` stays well-defined.
    final window = math.max(1, val.toInt());
    final interval = _rnd.nextInt(window);
    return Duration(milliseconds: (minDelay + interval).clamp(0, maxDelay));
  }

  // --- Typed listener: data changed ---

  final _dataListeners = <VoidCallback>[];

  /// Subscribe to data changes.
  void addDataListener(VoidCallback callback) => _dataListeners.add(callback);

  /// Unsubscribe from data changes.
  void removeDataListener(VoidCallback callback) =>
      _dataListeners.remove(callback);

  /// Notify all listeners that message data has changed.
  ///
  /// Iterates over a snapshot to remain safe if a listener adds or removes
  /// listeners (including itself) during dispatch.
  @protected
  void notifyDataChanged() {
    for (final cb in List<VoidCallback>.of(_dataListeners, growable: false)) {
      cb();
    }
  }

  /// Cancel any in-flight fetch / retry timer and drop all listeners. Call
  /// from the owning widget's `dispose` so the retry timer cannot resurrect
  /// network work after the viewport is gone.
  void dispose() {
    _cancelFetch();
    _dataListeners.clear();
    _boundaryListeners.clear();
  }
}
