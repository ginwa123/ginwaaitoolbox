import { Accessor, Setter } from 'solid-js';
import { ChatMessage } from '../../shared/rpc';

export function useMessagesInfiniteScroll(options: {
  messages: Accessor<ChatMessage[]>;
  setMessages: Setter<ChatMessage[]>;
}) {
  let prevScrollHeight = 0;
  let scrollRef: HTMLDivElement | undefined;

  const storeScrollPosition = () => {
    prevScrollHeight = scrollRef?.scrollHeight ?? 0;
  };

  const restoreScrollPosition = () => {
    requestAnimationFrame(() => {
      if (scrollRef) {
        const delta = scrollRef.scrollHeight - prevScrollHeight;
        scrollRef.scrollTop += delta;
      }
    });
  };

  const prependMessages = (newMessages: ChatMessage[]) => {
    storeScrollPosition();
    options.setMessages((prev) => [...newMessages, ...prev]);
    restoreScrollPosition();
  };

  return {
    prependMessages,
    setScrollRef: (el: HTMLDivElement) => {
      scrollRef = el;
    },
  };
}
