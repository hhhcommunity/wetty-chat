export const UNREAD_BADGE_DISPLAY_MAX = 999;
export const UNREAD_BADGE_COUNT_CAP = UNREAD_BADGE_DISPLAY_MAX + 1;

export function formatUnreadBadge(count: number): string {
  return count > UNREAD_BADGE_DISPLAY_MAX ? `${UNREAD_BADGE_DISPLAY_MAX}+` : String(count);
}
