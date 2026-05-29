import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A floating "↓ N new" pill that surfaces when:
///
/// * the user has scrolled away from the bottom
///   (`controller.isAtTail.value == false`), and
/// * one or more newer messages have arrived in the data source since the
///   user was last at the tail.
///
/// Tap → animate back to the newest message. The unseen counter resets to
/// zero whenever `isAtTail` flips true (the user came back on their own or
/// followed the pill).
///
/// Composed from the controller's `isAtTail` listenable + the data source's
/// `newestKnownId` — both already exposed by the package; the pill itself
/// owns just the "last seen" id bookkeeping.
class NewMessagesPill extends StatefulWidget {
  const NewMessagesPill({
    required this.controller,
    required this.dataSource,
    this.bottomInset,
    super.key,
  });

  final ChatScrollController controller;
  final ChatDataSource dataSource;

  /// Reserved space at the bottom of the screen — typically the composer's
  /// measured height, so the pill clears the input row.
  final ValueListenable<double>? bottomInset;

  @override
  State<NewMessagesPill> createState() => _NewMessagesPillState();
}

class _NewMessagesPillState extends State<NewMessagesPill> {
  int? _lastSeenNewestId;

  @override
  void initState() {
    super.initState();
    widget.controller.isAtTail.addListener(_onIsAtTailChanged);
    widget.dataSource.addBoundaryListener(_onBoundaryChanged);
    // Seed the "last seen" baseline unconditionally — `isAtTail` starts as
    // `false` and is only pushed `true` after the first layout, so gating
    // the snapshot on it leaves the baseline `null` for the entire session
    // when the consumer mounts the pill at a non-tail position (e.g. a
    // permalink to an older message). With a `null` baseline `_unseenCount`
    // short-circuits to 0 and the pill silently stays hidden even when new
    // messages have arrived. Seeding here treats "everything that exists
    // now" as already-seen, which is the correct baseline regardless of
    // anchor position.
    //
    // If the source is currently empty (`newestKnownId == null`) the seed
    // stays null — the first non-null arrival on a *non-tail* anchor is
    // promoted in `_onBoundaryChanged` so the pill can surface those
    // messages instead of being silently suppressed forever.
    _lastSeenNewestId = widget.dataSource.newestKnownId;
  }

  @override
  void didUpdateWidget(NewMessagesPill old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.isAtTail.removeListener(_onIsAtTailChanged);
      widget.controller.isAtTail.addListener(_onIsAtTailChanged);
    }
    if (!identical(old.dataSource, widget.dataSource)) {
      old.dataSource.removeBoundaryListener(_onBoundaryChanged);
      widget.dataSource.addBoundaryListener(_onBoundaryChanged);
      // New source ⇒ re-baseline: treat everything currently known as seen
      // (same rationale as `initState`).
      _lastSeenNewestId = widget.dataSource.newestKnownId;
    }
  }

  @override
  void dispose() {
    widget.controller.isAtTail.removeListener(_onIsAtTailChanged);
    widget.dataSource.removeBoundaryListener(_onBoundaryChanged);
    super.dispose();
  }

  void _onIsAtTailChanged() {
    if (widget.controller.isAtTail.value) {
      // User is back at the tail — snapshot the current newest as "seen"
      // so subsequent arrivals start the counter from zero.
      _lastSeenNewestId = widget.dataSource.newestKnownId;
    }
    _scheduleRebuild();
  }

  void _onBoundaryChanged() {
    final newest = widget.dataSource.newestKnownId;
    // When new messages arrive while the user is already pinned at the
    // tail, the follow-tail layout auto-scrolls them into view — they
    // are *visible*, not unseen. `isAtTail` stays `true` across that
    // transition so `_onIsAtTailChanged` never fires. Without this
    // snapshot the next time the user scrolls away the pill would count
    // those already-viewed messages as "new".
    if (widget.controller.isAtTail.value) {
      _lastSeenNewestId = newest;
    } else if (_lastSeenNewestId == null && newest != null) {
      // Promote a never-seeded baseline: the pill mounted while the source
      // was still empty (initial loading / permalink to a not-yet-loaded
      // anchor) and the first non-null id has now arrived off-tail. Seed to
      // `newest - 1` so the just-arrived id counts as one unseen and the
      // pill surfaces; without this the pill would stay silently hidden
      // forever (`_unseenCount` short-circuits on `lastSeen == null`).
      // The count for a bulk first-arrival is intentionally lossy — what
      // matters here is that the pill becomes *visible*; the consumer can
      // tap it to jump and the counter resets cleanly afterwards.
      _lastSeenNewestId = newest - 1;
    }
    _scheduleRebuild();
  }

  // The controller pushes `isAtTail` from inside `performLayout`, so the
  // listener fires during the `persistentCallbacks` phase where `setState`
  // is illegal. Defer the rebuild to the end of the frame in that case.
  void _scheduleRebuild() {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  int _unseenCount() {
    final newest = widget.dataSource.newestKnownId;
    if (newest == null) return 0;
    final lastSeen = _lastSeenNewestId;
    if (lastSeen == null) return 0;
    final diff = newest - lastSeen;
    return diff > 0 ? diff : 0;
  }

  Future<void> _onTap() async {
    final newest = widget.dataSource.newestKnownId;
    if (newest == null) return;
    await widget.controller.animateTo(newest);
  }

  @override
  Widget build(BuildContext context) {
    final atTail = widget.controller.isAtTail.value;
    final count = atTail ? 0 : _unseenCount();
    final visible = !atTail && count > 0;
    final inset = widget.bottomInset;
    final positioned = Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: inset == null
          ? _Pill(count: count, onTap: _onTap, visible: visible)
          : ValueListenableBuilder<double>(
              valueListenable: inset,
              builder: (ctx, value, _) => Padding(
                padding: EdgeInsets.only(bottom: value + 12),
                child: _Pill(count: count, onTap: _onTap, visible: visible),
              ),
            ),
    );
    return positioned;
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.count,
    required this.onTap,
    required this.visible,
  });

  final int count;
  final VoidCallback onTap;
  final bool visible;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: Center(
        child: Material(
          color: const Color(0xFF0B81F6),
          elevation: 4,
          shape: const StadiumBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 18, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.arrow_downward_rounded,
                    size: 18,
                    color: Color(0xFFFFFFFF),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    count == 1 ? '1 new message' : '$count new messages',
                    style: const TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
