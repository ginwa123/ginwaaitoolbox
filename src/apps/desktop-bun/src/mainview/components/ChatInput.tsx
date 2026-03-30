import { type Component, createSignal } from 'solid-js';

interface ChatInputProps {
  onSend?: (message: string) => void;
}

const ChatInput: Component<ChatInputProps> = (props) => {
  const [message, setMessage] = createSignal('');
  let textareaRef: HTMLTextAreaElement | undefined;

  const handleSubmit = () => {
    const text = message().trim();
    if (!text) return;
    props.onSend?.(text);
    setMessage('');
    if (textareaRef) {
      textareaRef.style.height = 'auto';
    }
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  const handleInput = () => {
    if (textareaRef) {
      textareaRef.style.height = 'auto';
      textareaRef.style.height = `${Math.min(textareaRef.scrollHeight, 96)}px`;
    }
  };

  const canSend = () => message().trim().length > 0;

  return (
    <div class="flex items-end gap-3 pt-4 bg-[#050505] border-t border-[#18181b]">
      <div class="flex-1 relative">
        <textarea
          ref={textareaRef}
          value={message()}
          onInput={(e) => {
            setMessage(e.currentTarget.value);
            handleInput();
          }}
          onKeyDown={handleKeyDown}
          placeholder="Type a message..."
          rows={1}
          class={`
            w-full
            bg-[#0a0a0a]
            border border-[#27272a]
            px-4 py-3
            text-[13px] text-[#e4e4e7]
            font-mono
            placeholder:text-[#52525b]
            resize-none
            outline-none
            transition-colors
            focus:border-[#fbbf24]
            disabled:opacity-50
            disabled:cursor-not-allowed
            max-h-24
          `}
          style={{ 'min-height': '48px', 'max-height': '96px' }}
        />
      </div>

      <button
        onClick={handleSubmit}
        disabled={!canSend()}
        class={`
          w-12 h-12
          flex items-center justify-center
          transition-colors
          disabled:opacity-30 disabled:cursor-not-allowed
          ${
            canSend()
              ? 'bg-[#fbbf24] hover:bg-[#fcd34d] active:bg-[#f59e0b] text-[#09090b]'
              : 'bg-[#18181b] text-[#52525b]'
          }
        `}
        title="Send message"
      >
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2.5"
          stroke-linecap="square"
          stroke-linejoin="miter"
        >
          <line x1="22" y1="2" x2="11" y2="13" />
          <polygon points="22 2 15 22 11 13 2 9 22 2" />
        </svg>
      </button>
    </div>
  );
};

export default ChatInput;
