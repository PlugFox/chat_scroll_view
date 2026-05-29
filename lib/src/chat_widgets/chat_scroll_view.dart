import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:chatscrollview/src/chat_scroll/chat_selection_controller.dart';
import 'package:chatscrollview/src/chat_widgets/chat_scroll_element.dart';
import 'package:chatscrollview/src/chat_widgets/render_chat_scroll_view.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// Builds the widget for message [id].
///
/// [message] is `null` when the message is not loaded yet (its chunk is being
/// fetched) — return a shimmer/placeholder in that case. [status] reflects the
/// owning chunk's fetch state (dirty / fetching / error / valid).
///
/// When [ChatScrollView.chunkErrorBuilder] is wired *and* the message's
/// chunk is in error state, this builder is **not** invoked for any id in
/// that chunk — the chunk renders as a single chunk-level tile instead.
/// Without that builder, ids in the errored chunk are passed to this builder
/// with `status.isError == true`.
typedef ChatMessageBuilder =
    Widget Function(
      BuildContext context,
      int id,
      IChatMessage? message,
      ChatMessageStatus status,
    );

/// Builds a day separator for [date].
///
/// The same builder produces both the inline divider above the first message
/// of each day and the floating header pinned to the top of the viewport.
typedef ChatDateSeparatorBuilder =
    Widget Function(BuildContext context, DateTime date);

/// Information passed to a [ChatChunkErrorBuilder] when its chunk has failed
/// to load.
///
/// * [chunkIndex] — pagination index of the chunk (id `>> 6`); useful for
///   logging or chunk-scoped diagnostics.
/// * [firstId] / [lastId] — inclusive id range the chunk would cover when
///   fully loaded. The conversation's actual boundaries may sit inside this
///   range — clamp against `ChatDataSource.oldestKnownId` /
///   `newestKnownId` if your UI needs the visible portion.
/// * [error] — the last exception thrown by `fetchRange`. `null` only on
///   the first frame before any fetch resolved, which is unusual since the
///   builder is invoked once the chunk's status is `error`.
/// * [attempt] — count of failed fetch attempts since the last success (both
///   automatic-backoff and user-driven retries). Use it to render copy like
///   "Still failing (attempt 3)".
/// * [retry] — fire-and-forget callback that cancels any pending backoff and
///   re-fetches the chunk immediately.
typedef ChatChunkErrorDetails = ({
  int chunkIndex,
  int firstId,
  int lastId,
  Object? error,
  int attempt,
  VoidCallback retry,
});

/// Builds the error widget shown in place of an entire failed chunk.
///
/// One widget per chunk — not 64 per-message tiles — sits where the chunk
/// would have lived, sized to its own intrinsic height. See
/// [ChatChunkErrorDetails] for the data handed in and the retry hook.
typedef ChatChunkErrorBuilder =
    Widget Function(BuildContext context, ChatChunkErrorDetails details);

/// Default day grouping — the local calendar day. A `DateTime` with
/// hours/minutes/seconds zeroed is equatable enough for the day-bucket gate;
/// no need to pack y/m/d into an int.
DateTime _defaultGroupBy(IChatMessage message) {
  final d = message.createdAt.toLocal();
  return DateTime(d.year, d.month, d.day);
}

/// Widget-based endless chat viewport.
///
/// Anchor-based (id-relative) layout: messages are positioned around
/// [ChatScrollController.anchorMessageId], never against a global content
/// height. Children are real widgets — built lazily during layout via a
/// custom [ChatScrollElement] and wrapped in [RepaintBoundary] for picture +
/// layer caching. Scrolling repositions cached layers without re-layout.
///
/// Pass [dateSeparatorBuilder] to group messages by day — an inline separator
/// above the first message of each day plus a floating header pinned to the
/// top showing the topmost day.
class ChatScrollView extends RenderObjectWidget {
  const ChatScrollView({
    required this.dataSource,
    required this.controller,
    required this.messageBuilder,
    this.chunkErrorBuilder,
    this.emptyBuilder,
    this.loadingBuilder,
    this.selectionController,
    this.bottomPadding,
    this.topPadding,
    this.dateSeparatorBuilder,
    this.groupBy,
    this.highlightColor = const Color(0x402196F3),
    this.highlightDuration = const Duration(milliseconds: 1500),
    this.textDirection,
    this.cacheExtent = 250.0,
    this.extraBuildExtent = 0.0,
    this.reverse = false,
    super.key,
  });

  /// Owns message data, chunks, and the fetch contract.
  final ChatDataSource dataSource;

  /// Owns anchor state, conversation boundaries, and jumps.
  final ChatScrollController controller;

  /// Builds the widget for each message id. Pass a stable reference (a
  /// top-level function or a cached closure) — a new closure each parent
  /// rebuild forces every visible message to re-inflate.
  final ChatMessageBuilder messageBuilder;

  /// Builds the failure tile shown in place of an entire errored chunk.
  ///
  /// When set, an errored chunk in the build range is replaced by **one**
  /// widget (sized to its own intrinsic height) rather than per-message
  /// placeholders carrying `status.isError`. When this builder fires,
  /// [messageBuilder] is **not** called for any id in that chunk —
  /// chunk-level rendering fully replaces per-message rendering for the
  /// affected range. When `null`, falls back to the per-message path —
  /// [messageBuilder] receives the error status for every id and chooses
  /// what to render.
  ///
  /// The supplied [ChatChunkErrorDetails.retry] cancels the running backoff
  /// and re-fetches the chunk immediately. Pass a stable reference, like
  /// [messageBuilder].
  final ChatChunkErrorBuilder? chunkErrorBuilder;

  /// Builds the full-viewport widget shown when the conversation is known to
  /// be empty (data source reports [ChatDataSource.isEmpty]).
  ///
  /// When `null`, the viewport simply renders nothing — `messageBuilder`
  /// is never called because no ids exist.
  ///
  /// Like [loadingBuilder] and [chunkErrorBuilder], invoked during the
  /// viewport's layout pass — avoid triggering `setState` / `markNeedsLayout`
  /// synchronously from inside this builder.
  final WidgetBuilder? emptyBuilder;

  /// Builds the full-viewport skeleton shown before the first chunk lands
  /// (data source reports [ChatDataSource.isInitialLoading]).
  ///
  /// When `null`, the viewport falls back to the standard fan-out path: the
  /// `messageBuilder` is invoked with `message: null` and a fetching status
  /// for ids around the anchor, and whatever placeholder *your* builder
  /// produces in that case (shimmer, blank space, …) fills the viewport.
  /// The package itself does not ship a built-in placeholder.
  final WidgetBuilder? loadingBuilder;

  /// Optional whole-message selection. When non-null every message is wrapped
  /// in selection chrome (a checkbox gutter + row tint) and long-press / tap
  /// drive the [controller]. When null the viewport adds no selection wrapper
  /// and costs nothing.
  final ChatSelectionController? selectionController;

  /// Empty space reserved inside the viewport after the newest message.
  ///
  /// Use it to keep the newest message clear of chrome stacked on top of the
  /// viewport — the composer, attachment previews, status strips. The viewport
  /// listens to it and relayouts when the value changes, so the inset can grow
  /// and shrink (e.g. a multi-line input field) without a jump.
  final ValueListenable<double>? bottomPadding;

  /// Empty space reserved at the top of the viewport — for chrome stacked over
  /// the viewport top (an app bar). The floating day header rests just below
  /// this inset.
  final ValueListenable<double>? topPadding;

  /// Builds a day separator. When non-null the viewport groups messages by
  /// day: the first message of each day carries an inline separator, and a
  /// floating copy is pinned to the top showing the topmost visible day. When
  /// null the day-separator feature is off and costs nothing.
  ///
  /// The inline separator fades out as it scrolls up toward the floating
  /// header, so the two are never both visible — the builder is free to style
  /// and pad the separator however it likes.
  ///
  /// Format the date in the same day notion as [groupBy] (both default to the
  /// local calendar day) — otherwise a label can disagree with the grouping
  /// near midnight, e.g. printing UTC dates while grouping by local.
  ///
  /// Pass a stable reference, like [messageBuilder].
  final ChatDateSeparatorBuilder? dateSeparatorBuilder;

  /// Groups messages into sections — messages whose returned keys are equal
  /// (`==`) share a section. Consulted only when [dateSeparatorBuilder] is
  /// set; defaults to the local calendar day.
  ///
  /// The separator builder always receives the first message's `createdAt`
  /// for each section, so return a date-derived equatable value: a
  /// `DateTime` truncated to the day (the default), a `(year, week)` record
  /// for weekly grouping, or `(year, month)` for monthly. Pass a stable
  /// reference.
  final Object Function(IChatMessage message)? groupBy;

  /// Peak colour of the fade-out highlight painted over a message that just
  /// became the target of [ChatScrollController.animateTo]. Alpha drives the
  /// initial opacity; set the alpha channel to 0 to opt out without changing
  /// [highlightDuration].
  final Color highlightColor;

  /// How long the post-animate highlight stays on the target before fully
  /// fading out. [Duration.zero] disables the feature entirely — successful
  /// `animateTo` calls land silently.
  final Duration highlightDuration;

  /// Reading direction. `null` (the default) inherits from `Directionality`
  /// of the build context — set explicitly to override (e.g. force LTR for
  /// a specific chat thread inside an RTL app).
  ///
  /// Drives where the scrollbar paints (right in LTR, left in RTL) and where
  /// its touch strip lives. The `messageBuilder` does not receive this value
  /// — to mirror bubble alignment, read `Directionality.of(context)` inside
  /// the builder.
  final TextDirection? textDirection;

  /// Pixels above and below the viewport to keep built.
  final double cacheExtent;

  /// Extra pixels beyond [cacheExtent] that stay built while off-screen
  /// (paint-culled), so a message's `State` survives a short scroll out and
  /// back. `0` (the default) collects children as soon as they leave the
  /// cache extent.
  ///
  /// Distance-based only — unrelated to the `KeepAlive` widget, which retains
  /// specific children regardless of how far they scroll away.
  final double extraBuildExtent;

  /// When the entire conversation fits in the viewport, where should the
  /// content stack?
  ///
  /// * `false` (list-style, default): pin the oldest message to the top, gap
  ///   below the newest. Matches `ListView`-shaped UIs.
  /// * `true` (chat-style): pin the newest message to the bottom, gap above
  ///   the oldest. Matches Telegram / iMessage when only a couple of
  ///   messages exist yet.
  ///
  /// Also flips the assistive-tech mapping for `scrollUp`/`scrollDown`
  /// actions: in `reverse` mode `scrollUp` reveals older history (what
  /// chat-app users expect).
  final bool reverse;

  /// The effective grouping function, or `null` when day separators are off.
  Object Function(IChatMessage)? get _effectiveGroupBy =>
      dateSeparatorBuilder == null ? null : (groupBy ?? _defaultGroupBy);

  @override
  RenderObjectElement createElement() => ChatScrollElement(this);

  /// Effective reading direction: an explicit override wins; otherwise read
  /// from `Directionality`, falling back to `TextDirection.ltr` only when
  /// no `Directionality` ancestor is in scope.
  TextDirection _resolveDirection(BuildContext context) =>
      textDirection ?? Directionality.maybeOf(context) ?? TextDirection.ltr;

  @override
  RenderChatScrollView createRenderObject(BuildContext context) =>
      RenderChatScrollView(
        dataSource: dataSource,
        controller: controller,
        cacheExtent: cacheExtent,
        extraBuildExtent: extraBuildExtent,
        ticking: TickerMode.valuesOf(context).enabled,
        reverse: reverse,
        bottomPadding: bottomPadding,
        topPadding: topPadding,
        groupBy: _effectiveGroupBy,
        hasErrorBuilder: chunkErrorBuilder != null,
        hasEmptyBuilder: emptyBuilder != null,
        hasLoadingBuilder: loadingBuilder != null,
        highlightColor: highlightColor,
        highlightDuration: highlightDuration,
        textDirection: _resolveDirection(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderChatScrollView renderObject,
  ) {
    renderObject
      ..dataSource = dataSource
      ..controller = controller
      ..cacheExtent = cacheExtent
      ..extraBuildExtent = extraBuildExtent
      ..ticking = TickerMode.valuesOf(context).enabled
      ..reverse = reverse
      ..bottomPadding = bottomPadding
      ..topPadding = topPadding
      ..groupBy = _effectiveGroupBy
      ..hasErrorBuilder = chunkErrorBuilder != null
      ..hasEmptyBuilder = emptyBuilder != null
      ..hasLoadingBuilder = loadingBuilder != null
      ..highlightColor = highlightColor
      ..highlightDuration = highlightDuration
      ..textDirection = _resolveDirection(context);
  }
}
