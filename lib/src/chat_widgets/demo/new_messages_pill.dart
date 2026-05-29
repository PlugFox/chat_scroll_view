import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_controller.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

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
    if (widget.controller.isAtTail.value) {
      _lastSeenNewestId = widget.dataSource.newestKnownId;
    }
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
      _lastSeenNewestId = widget.controller.isAtTail.value
          ? widget.dataSource.newestKnownId
          : null;
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
    setState(() {});
  }

  void _onBoundaryChanged() => setState(() {});

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
