import 'package:flutter_test/flutter_test.dart';

import 'package:chahua/features/chat_list/presentation/widgets/unread_badge_formatter.dart';

void main() {
  group('formatUnreadBadgeCount', () {
    test('formats counts up to the display max exactly', () {
      expect(unreadBadgeDisplayMax, 999);
      expect(unreadBadgeCountCap, 1000);
      expect(formatUnreadBadgeCount(0), '0');
      expect(formatUnreadBadgeCount(1), '1');
      expect(formatUnreadBadgeCount(999), '999');
    });

    test('formats counts above the display max as an overflow label', () {
      expect(formatUnreadBadgeCount(1000), '999+');
      expect(formatUnreadBadgeCount(2500), '999+');
    });
  });
}
