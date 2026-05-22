const int unreadBadgeDisplayMax = 999;
const int unreadBadgeCountCap = unreadBadgeDisplayMax + 1;

String formatUnreadBadgeCount(int count) {
  if (count > unreadBadgeDisplayMax) {
    return '$unreadBadgeDisplayMax+';
  }
  return '$count';
}
