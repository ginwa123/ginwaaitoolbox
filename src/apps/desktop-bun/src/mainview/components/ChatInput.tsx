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
    // Reset textarea height
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
      // Auto-expand up to 4 lines (approx 96px with 24px line-height)
      textareaRef.style.height = 'auto';
      textareaRef.style.height = `${Math.min(textareaRef.scrollHeight, 96)}px`;
    }
  };

  const canSend = () => message().trim().length > 0;

  return (
    <div class="flex items-end gap-3 px-4 pb-4 bg-neutral-950">
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
            bg-neutral-900
            border border-neutral-800
            rounded-xl
            px-4 py-3
            text-sm text-neutral-200
            font-mono
            placeholder:text-neutral-600
            resize-none
            outline-none
            transition-all
            duration-200
            focus:border-yellow-400/50
            focus:shadow-[0_0_0_2px_rgba(250,204,21,0.15)]
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
          rounded-xl
          transition-all
          duration-200
          disabled:opacity-40 disabled:cursor-not-allowed
          ${
            canSend()
              ? 'bg-gradient-to-br from-yellow-400 to-amber-500 hover:from-yellow-300 hover:to-amber-400 hover:scale-105 active:scale-95 shadow-lg shadow-amber-500/20'
              : 'bg-neutral-800'
          }
        `}
        title="Send message"
      >
        <svg
          width="20"
          height="20"
          viewBox="0 0 24 24"
          fill="none"
          stroke={canSend() ? '#0a0a0a' : '#525252'}
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <line x1="22" y1="2" x2="11" y2="13" />
          <polygon points="22 2 15 22 11 13 2 9 22 2" />
        </svg>
      </button>
    </div>
  );
};

export default ChatInput;
