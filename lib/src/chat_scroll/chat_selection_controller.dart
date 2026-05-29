import 'dart:collection';

import 'package:flutter/foundation.dart' show Listenable, VoidCallback;

/// Whole-message selection controller for the chat viewport.
///
/// Long press enters selection mode and selects the message.
/// Taps toggle messages. Selection mode exits when the set empties.
///
/// Lives outside the render tree — survives render eviction and can be
/// queried by external UI (toolbar, copy button). Implements [Listenable]
/// so the widget-based viewport can drive `ListenableBuilder` directly.
///
/// ### Swapping conversations
///
/// Selection is a bare `Set<int>` of message ids — it has no notion of
/// *which* conversation those ids belong to. When the consumer swaps the
/// `ChatDataSource` (e.g. opening a different chat thread on the same
/// viewport) the previously-selected ids stay in the set and will now
/// silently match unrelated messages in the new conversation. Call [clear]
/// from your own dataSource-swap logic, or scope a separate
/// [ChatSelectionController] per conversation, to avoid this footgun.
class ChatSelectionController implements Listenable {
  final _selectedIds = HashSet<int>();

  /// Whether selection mode is active.
  bool get isSelectionMode => _selectedIds.isNotEmpty;

  /// The number of selected messages.
  int get count => _selectedIds.length;

  /// The set of selected message IDs (unmodifiable view).
  Set<int> get selectedIds => UnmodifiableSetView<int>(_selectedIds);

  /// Whether [messageId] is in the selection.
  bool isSelected(int messageId) => _selectedIds.contains(messageId);

  /// Enter selection mode and select [messageId].
  void startSelection(int messageId) {
    if (!_selectedIds.add(messageId)) return;
    _notify();
  }

  /// Toggle [messageId] in/out of selection.
  /// Exits selection mode when the set becomes empty.
  void toggle(int messageId) {
    if (!_selectedIds.remove(messageId)) {
      _selectedIds.add(messageId);
    }
    _notify();
  }

  /// Clear all selection. Exits selection mode.
  void clear() {
    if (_selectedIds.isEmpty) return;
    _selectedIds.clear();
    _notify();
  }

  // --- Listeners ---

  /// `LinkedHashSet` (literal `<...>{}` is a `LinkedHashSet`) so a duplicate
  /// `addListener` is a no-op — otherwise the symmetric `removeListener`
  /// only strips one of multiple registrations and the listener silently
  /// keeps firing for the rest of the controller's lifetime.
  final _listeners = <VoidCallback>{};

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    // Iterate a snapshot: a listener may add/remove listeners while reacting
    // (e.g. a message widget unmounting during the resulting rebuild).
    for (final cb in _listeners.toList(growable: false)) {
      cb();
    }
  }

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;
  bool _disposed = false;

  /// Drop all listeners. Call from the owning widget's `dispose`. Idempotent
  /// — safe to call twice.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    // Drop the set: a stale reference held by a consumer (e.g. a toolbar
    // queueing an undo) must not silently match unrelated ids in a fresh
    // conversation that happens to reuse the same numeric range.
    _selectedIds.clear();
  }
}
