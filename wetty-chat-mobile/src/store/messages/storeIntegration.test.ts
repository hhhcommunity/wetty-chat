import { describe, expect, it } from 'vitest';
import { createStore, type RootState } from '../index';
import { selectAllChats, selectChatUnreadCount } from '../chatsSlice';
import { messageAdded } from '../messageEvents';
import { insertAround } from './slice';
import {
  selectActiveTimelineMessages,
  selectCanLoadNewer,
  selectPendingLiveCount,
  selectTimelineMode,
} from './selectors';
import { ids, testMessage } from './testUtils';

describe('message listener projections', () => {
  it('projects websocket message events into the chat list while preserving historical rendering', async () => {
    const store = createStore();

    store.dispatch(
      insertAround({
        chatId: '1',
        targetMessageId: '10',
        messages: [testMessage('10')],
        nextCursor: '10',
        prevCursor: '10',
      }),
    );
    store.dispatch(
      messageAdded({ chatId: '1', storeChatId: '1', message: testMessage('20'), origin: 'ws', scope: 'main' }),
    );
    await Promise.resolve();

    const root = store.getState() as RootState;
    expect(selectPendingLiveCount(root, '1')).toBe(1);
    expect(ids(selectActiveTimelineMessages(root, '1'))).toEqual(['10']);
    expect(selectAllChats(root)[0].lastMessage?.id).toBe('20');
    expect(selectChatUnreadCount(root, '1')).toBe(1);
  });

  it('keeps websocket messages visible when an around window is already at the latest edge', async () => {
    const store = createStore();

    store.dispatch(
      insertAround({
        chatId: '1',
        targetMessageId: '10',
        messages: [testMessage('10'), testMessage('11')],
        nextCursor: '10',
        prevCursor: null,
      }),
    );
    store.dispatch(
      messageAdded({ chatId: '1', storeChatId: '1', message: testMessage('12'), origin: 'ws', scope: 'main' }),
    );
    await Promise.resolve();

    const root = store.getState() as RootState;
    expect.soft(selectPendingLiveCount(root, '1')).toBe(0);
    expect.soft(ids(selectActiveTimelineMessages(root, '1'))).toEqual(['10', '11', '12']);
    expect.soft(selectTimelineMode(root, '1')).toEqual({ type: 'around', targetMessageId: '10' });
    expect.soft(selectCanLoadNewer(root, '1')).toBe(false);
    expect(selectAllChats(root)[0].lastMessage?.id).toBe('12');
    expect(selectChatUnreadCount(root, '1')).toBe(1);
  });
});
