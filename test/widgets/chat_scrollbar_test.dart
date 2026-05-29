import 'dart:ui';

import 'package:chatscrollview/src/chat_widgets/chat_scrollbar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatScrollbar', () {
    const size = Size(400, 600);

    test('hit area is the right-edge strip in LTR', () {
      final sb = ChatScrollbar();
      const ltr = TextDirection.ltr;
      expect(sb.inHitArea(399, size, ltr), isTrue);
      expect(
        sb.inHitArea(size.width - ChatScrollbar.hitWidth, size, ltr),
        isTrue,
      );
      expect(
        sb.inHitArea(size.width - ChatScrollbar.hitWidth - 1, size, ltr),
        isFalse,
      );
      expect(sb.inHitArea(0, size, ltr), isFalse);
    });

    test('hit area mirrors to the left-edge strip in RTL', () {
      final sb = ChatScrollbar();
      const rtl = TextDirection.rtl;
      expect(sb.inHitArea(0, size, rtl), isTrue);
      expect(sb.inHitArea(ChatScrollbar.hitWidth, size, rtl), isTrue);
      expect(sb.inHitArea(ChatScrollbar.hitWidth + 1, size, rtl), isFalse);
      expect(sb.inHitArea(size.width - 1, size, rtl), isFalse);
    });

    test('progressFromY spans the track 0..1 and clamps past the ends', () {
      final sb = ChatScrollbar();
      expect(sb.progressFromY(-1000, size), 0.0);
      expect(sb.progressFromY(10000, size), 1.0);
      final mid = sb.progressFromY(size.height / 2, size);
      expect(mid, greaterThan(0.0));
      expect(mid, lessThan(1.0));
    });

    test('progressFromY increases monotonically down the track', () {
      final sb = ChatScrollbar();
      expect(
        sb.progressFromY(450, size),
        greaterThan(sb.progressFromY(150, size)),
      );
    });

    test('claims, tracks, and releases its drag pointer', () {
      final sb = ChatScrollbar();
      expect(sb.isDragging, isFalse);

      // A pointer-down inside the strip is claimed.
      const ltr = TextDirection.ltr;
      final inside = PointerDownEvent(
        pointer: 7,
        position: Offset(size.width - 6, 100),
      );
      expect(sb.tryStartDrag(inside, size, ltr), isTrue);
      expect(sb.isDragging, isTrue);
      expect(sb.ownsPointer(const PointerMoveEvent(pointer: 7)), isTrue);
      expect(sb.ownsPointer(const PointerMoveEvent(pointer: 9)), isFalse);

      sb.endDrag();
      expect(sb.isDragging, isFalse);

      // A pointer-down outside the strip is ignored.
      final outside = PointerDownEvent(
        pointer: 8,
        position: const Offset(10, 100),
      );
      expect(sb.tryStartDrag(outside, size, ltr), isFalse);
      expect(sb.isDragging, isFalse);
    });
  });
}
