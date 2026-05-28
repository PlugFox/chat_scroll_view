import 'package:chatscrollview/src/chat_message.dart';
import 'package:chatscrollview/src/chat_scroll/chat_data_source.dart';
import 'package:chatscrollview/src/chat_scroll/chat_scroll_common.dart';
import 'package:chatscrollview/src/chat_scroll/chat_selection_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Max width of the composer content column — the bar background still spans
/// the full width, but the input field / action buttons are centered within.
const double _kComposerMaxWidth = 620.0;

/// Bottom bar for the widget-based chat demo.
///
/// Idle: a rounded multi-line input field pinned to the bottom.
/// Selection mode: the input field slides down out of view while
/// copy / favorite / share icon buttons fly in from the sides.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    required this.selection,
    required this.dataSource,
    super.key,
  });

  /// Drives the input ⇄ actions transition.
  final ChatSelectionController selection;

  /// Source for message text when copying a selection to the clipboard.
  final ChatDataSource dataSource;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer>
    with SingleTickerProviderStateMixin {
  /// 0 → input field shown, 1 → action buttons shown.
  late final AnimationController _t;
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// Every [CurvedAnimation] built off [_t] — disposed together.
  final List<CurvedAnimation> _curves = <CurvedAnimation>[];

  late final Animation<Offset> _inputSlide;
  late final Animation<double> _inputFade;
  late final Animation<Offset> _copySlide;
  late final Animation<Offset> _shareSlide;
  late final Animation<double> _favScale;
  late final Animation<double> _actionsFade;

  bool _mode = false;

  CurvedAnimation _curve(Curve curve) {
    final ca = CurvedAnimation(parent: _t, curve: curve);
    _curves.add(ca);
    return ca;
  }

  @override
  void initState() {
    super.initState();
    _t = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    // Input field: drops straight down and fades out early.
    _inputSlide = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(0, 1.4),
    ).animate(_curve(Curves.easeInCubic));
    _inputFade = Tween<double>(
      begin: 1,
      end: 0,
    ).animate(_curve(const Interval(0.0, 0.5, curve: Curves.easeIn)));
    // Action buttons: copy from the left, share from the right, favorite pops
    // up in the middle — all slightly staggered with an ease-out overshoot.
    _copySlide = Tween<Offset>(
      begin: const Offset(-2.6, 0),
      end: Offset.zero,
    ).animate(_curve(const Interval(0.15, 0.9, curve: Curves.easeOutBack)));
    _shareSlide = Tween<Offset>(
      begin: const Offset(2.6, 0),
      end: Offset.zero,
    ).animate(_curve(const Interval(0.15, 0.9, curve: Curves.easeOutBack)));
    _favScale = _curve(const Interval(0.3, 1.0, curve: Curves.easeOutBack));
    _actionsFade = _curve(const Interval(0.28, 0.62));

    _mode = widget.selection.isSelectionMode;
    if (_mode) _t.value = 1.0;
    widget.selection.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) {
      oldWidget.selection.removeListener(_onSelectionChanged);
      widget.selection.addListener(_onSelectionChanged);
      _onSelectionChanged();
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelectionChanged);
    for (final c in _curves) {
      c.dispose();
    }
    _t.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    final mode = widget.selection.isSelectionMode;
    if (mode == _mode) return;
    setState(() => _mode = mode);
    if (mode) {
      _focus.unfocus();
      _t.forward();
    } else {
      _t.reverse();
    }
  }

  void _handleSend() {
    if (_text.text.trim().isEmpty) return;
    _text.clear();
    _focus.unfocus();
  }

  // --- Selection actions -----------------------------------------------------

  static String? _contentOf(IChatMessage? message) => switch (message) {
    UserChatMessage(:final content) => content,
    SystemChatMessage(:final content) => content,
    _ => null,
  };

  void _copy() {
    final ids = widget.selection.selectedIds.toList()..sort();
    final buffer = StringBuffer();
    for (final id in ids) {
      final text = _contentOf(widget.dataSource.getMessage(id));
      if (text == null) continue;
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.write(text);
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    _finish('Скопировано сообщений: ${ids.length}');
  }

  void _favorite() =>
      _finish('Добавлено в избранное: ${widget.selection.count}');

  void _share() => _finish('Готово к отправке: ${widget.selection.count}');

  void _finish(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    widget.selection.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kComposerMaxWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: ClipRect(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 66),
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: <Widget>[
                        // Input layer — sizes the bar.
                        SlideTransition(
                          position: _inputSlide,
                          child: FadeTransition(
                            opacity: _inputFade,
                            child: IgnorePointer(
                              ignoring: _mode,
                              child: _InputField(
                                controller: _text,
                                focusNode: _focus,
                                onSend: _handleSend,
                                scheme: scheme,
                              ),
                            ),
                          ),
                        ),
                        // Action layer — overlaid, fades / flies in.
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: !_mode,
                            child: FadeTransition(
                              opacity: _actionsFade,
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: <Widget>[
                                  SlideTransition(
                                    position: _copySlide,
                                    child: _ActionButton(
                                      icon: Icons.copy_rounded,
                                      label: 'Копировать',
                                      onTap: _copy,
                                      scheme: scheme,
                                    ),
                                  ),
                                  ScaleTransition(
                                    scale: _favScale,
                                    child: _ActionButton(
                                      icon: Icons.star_rounded,
                                      label: 'В избранное',
                                      onTap: _favorite,
                                      scheme: scheme,
                                    ),
                                  ),
                                  SlideTransition(
                                    position: _shareSlide,
                                    child: _ActionButton(
                                      icon: Icons.share_rounded,
                                      label: 'Поделиться',
                                      onTap: _share,
                                      scheme: scheme,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rounded multi-line input pill with a trailing send button.
class _InputField extends StatelessWidget {
  const _InputField({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.scheme,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                cursorColor: scheme.primary,
                style: TextStyle(color: scheme.onSurface, fontSize: 15),
                decoration: InputDecoration.collapsed(
                  hintText: 'Сообщение',
                  hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: _CircleButton(
              icon: Icons.send_rounded,
              size: 38,
              background: scheme.primary,
              foreground: scheme.onPrimary,
              onTap: onSend,
            ),
          ),
        ],
      ),
    ),
  );
}

/// A labelled circular action button (copy / favorite / share).
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.scheme,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      _CircleButton(
        icon: icon,
        size: 46,
        background: scheme.primary.withValues(alpha: 0.16),
        foreground: scheme.primary,
        onTap: onTap,
      ),
      const SizedBox(height: 4),
      Text(
        label,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    ],
  );
}

/// A circular icon button with an ink ripple.
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.size,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final IconData icon;
  final double size;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: background,
    shape: const CircleBorder(),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(icon, color: foreground, size: size * 0.5),
      ),
    ),
  );
}
