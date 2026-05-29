# Changelog

All notable changes to this project will be documented in this file. The
format is loosely based on [Keep a Changelog](https://keepachangelog.com/);
this project is pre-1.0 and not strictly SemVer yet.

## [Unreleased]

### Added

- **Follow-tail auto-scroll** + `ChatScrollController.isAtTail` listenable.
  When the viewport is pinned to the newest message and a new one arrives,
  the viewport auto-scrolls so the new message stays at the bottom edge.
  When the user has scrolled away, the anchor is left alone — they are
  reading history.
- **Post-`animateTo` highlight fade.** After a successful `animateTo`
  lands, a translucent tint paints over the target message and fades to
  zero over the configured duration. Configurable via
  `ChatScrollView.highlightColor` and `ChatScrollView.highlightDuration`;
  pass `highlightDuration: Duration.zero` to opt out.
- **`ChatKeyboardShortcuts`** wrapper widget for desktop keyboard
  navigation (PageUp/Down, Home/End, ArrowUp/Down). Defaults to
  `autofocus: false` so a sibling composer `TextField` retains focus.
- **`ChatScrollController.scrollBy(double pixels)`** — programmatic
  scroll API with `addScrollByListener` callbacks and a new
  `ChatProgrammaticScroll` typed event.
- **`ChatDataSource.invalidate()`** — marks all loaded chunks stale so
  the viewport refetches on the next pass. Lazy: in-range chunks get a
  fresh fetch from the existing poll; off-range chunks stay dirty until
  visited. Use after SSE / WebSocket reconnect, `AppLifecycleState.resumed`,
  or pull-to-refresh.
- **Rubber-band overscroll** on conversation boundaries. Pulling past
  the oldest or newest applies damping; on release a short spring-back
  animation pulls the anchor back to the boundary. Mouse-wheel, keyboard,
  fling, and `animateTo` keep the hard clamp.
- **RTL support.** `ChatScrollView` honours ambient `Directionality` and
  accepts an explicit `textDirection` override; the scrollbar mirrors to
  the leading edge. When an override is set, a `Directionality` widget is
  installed around the message subtree so `messageBuilder` reads the same
  direction the chrome uses.
- **Golden-test baselines** for the demo widgets (bubbles, shimmer,
  chunk-error tile, empty state, initial skeleton, date separator).
  Linux-only — see `test/golden/demo_widgets_golden_test.dart`.

### Behavior changes (silent on upgrade)

- **Drag past a known boundary now bounces** with a damped overshoot and
  a spring-back animation on release. Existing apps that asserted a hard
  clamp on direct user drag will see a different physics curve. Other
  paths (wheel, keyboard, fling, `animateTo`) keep the hard clamp.
- **Ambient `Directionality.rtl` flips the scrollbar to the left edge.**
  RTL hosts that were running before this PR rendered the scrollbar on
  the right; this is now correctly mirrored. Force LTR via
  `ChatScrollView.textDirection: TextDirection.ltr` if needed.

### Fixed

- `_layoutOverlayMode` now resets `_dragInProgress` and clears any
  bounceback state, preventing `_clampBoundaries` from being silently
  suspended after an overlay transition.
- `_onJump` clears any active post-`animateTo` highlight so a programmatic
  `jumpTo` does not leave a ticker tinting a now-invisible target.
- `_onScrollBy` cancels any in-flight bounceback so a programmatic
  scroll wins over the passive spring-back.
- Controller swap with an in-flight drag re-creates the gesture
  recognizer and clears `_dragInProgress` instead of leaking the drag
  state into the new controller.
- `invalidate()` no longer fires two `notifyDataChanged` events on a
  source with running fetches — the cancel-fetch and dirty-marking
  passes are coalesced.
- `_signedOverscroll` returns the larger-magnitude violation when both
  boundaries are violated simultaneously (short conversation pulled past
  both edges) so the bounceback pulls toward the dominant side.
- `_publishIsAtTail` skips snapshot writes while the viewport is in
  overlay mode so follow-tail is not lost across an overlay → normal
  transition.

### Performance

- `_applyOverscrollResistance` short-circuits when neither boundary is
  reached, eliding the per-drag-tick `_signedOverscroll` walk on the
  dominant case of mid-conversation drags.
- `ChatKeyboardShortcuts` hoists its `Shortcuts` / `Actions` maps out of
  the per-rebuild `LayoutBuilder`, so a keyboard show/hide no longer
  reallocates the six action callbacks.

### Migration notes

- If your tests assert on the hard-clamp behavior at a boundary, expect
  to see the new bounceback instead. The bounceback completes in
  ~200 ms; wait via `pumpAndSettle()` to land at the boundary again.
- `animateTo` now paints a highlight tint by default — pass
  `highlightDuration: Duration.zero` on `ChatScrollView` to opt out
  without any other change.
- `ChatKeyboardShortcuts.autofocus` defaults to `false`. Existing code
  that relied on the wrapper claiming focus on mount should pass
  `autofocus: true` explicitly.
