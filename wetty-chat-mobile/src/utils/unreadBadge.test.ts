import { describe, expect, it } from 'vitest';
import { formatUnreadBadge, UNREAD_BADGE_COUNT_CAP, UNREAD_BADGE_DISPLAY_MAX } from './unreadBadge';

describe('formatUnreadBadge', () => {
  it('formats counts up to the display max exactly', () => {
    expect(UNREAD_BADGE_DISPLAY_MAX).toBe(999);
    expect(UNREAD_BADGE_COUNT_CAP).toBe(1000);
    expect(formatUnreadBadge(0)).toBe('0');
    expect(formatUnreadBadge(1)).toBe('1');
    expect(formatUnreadBadge(999)).toBe('999');
  });

  it('formats counts above the display max as an overflow label', () => {
    expect(formatUnreadBadge(1000)).toBe('999+');
    expect(formatUnreadBadge(2500)).toBe('999+');
  });
});
