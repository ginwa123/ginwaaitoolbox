import { useNavigate } from '@solidjs/router';
import { type Component, createSignal } from 'solid-js';
import { electroview } from '../main';
import { getSelectedFolder, refreshSessionList } from '../store/sessionStore';
import { log } from '../utils/logger';

interface ChatInputProps {
  sessionId?: string; // If provided, sends to existing session via /api/llm/run
}

const ChatInput: Component<ChatInputProps> = (props) => {
  const navigate = useNavigate();
  const [text, setText] = createSignal('');
  const [sending, setSending] = createSignal(false);

  const handleSend = async () => {
    const msg = text().trim();
    if (!msg || sending()) return;

    setSending(true);

    try {
      // Get cwd_session from the sidebar's selected folder (shared state)
      // This ensures new sessions are created in the correct directory
      const cwdSession = getSelectedFolder();
      log.info(`[ChatInput] Using selectedFolder for cwd_session: ${cwdSession}`);

      // Use /api/session for both new and existing sessions
      // For existing: pass session_id and queue_message
      // For new: just pass queue_message
      const body: { session_id?: string; queue_message: string; cwd_session?: string } = {
        queue_message: msg,
        cwd_session: cwdSession !== '/' ? cwdSession : undefined,
      };
      if (props.sessionId) {
        body.session_id = props.sessionId;
      }

      const res = await fetch('http://127.0.0.1:8081/api/session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (res.ok) {
        const data = await res.json();
        log.info(`[ChatInput] Message sent: ${JSON.stringify(data)}`);
        setText('');

        if (props.sessionId) {
          // Existing session - refresh sidebar after delay
          setTimeout(() => {
            refreshSessionList();
            log.info('[ChatInput] Sidebar refreshed after delay');
          }, 1000);
        } else {
          // New session - navigate to it, then refresh sidebar
          navigate(`/session/${data.id}`, { replace: true });
          setTimeout(() => {
            refreshSessionList();
            log.info('[ChatInput] Sidebar refreshed after delay');
          }, 1000);
        }
      } else {
        log.error(`[ChatInput] Error: ${await res.text()}`);
      }
    } catch (err) {
      log.error(`[ChatInput] Network error: ${String(err)}`);
    } finally {
      setSending(false);
    }
  };

  return (
    <div class="flex items-end gap-3 pt-4 bg-[#050505] border-t border-[#18181b] p-4">
      <textarea
        value={text()}
        onInput={(e) => setText(e.currentTarget.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && !e.shiftKey && text().trim() && !sending()) {
            e.preventDefault();
            handleSend();
          }
          // Auto-resize: grow with content up to max
          if (e.key === 'Enter' && e.shiftKey) {
            const target = e.currentTarget;
            setTimeout(() => {
              target.style.height = 'auto';
              target.style.height = `${Math.min(target.scrollHeight, 200)}px`;
            }, 0);
          }
        }}
        placeholder={
          props.sessionId
            ? 'Type a message... (Shift+Enter to send)'
            : 'Type a message to start... (Shift+Enter to send)'
        }
        rows={3}
        class="flex-1 min-h-[80px] max-h-[200px] bg-[#0a0a0a] border border-[#27272a] px-4 py-3 text-[14px] text-[#e4e4e7] font-mono outline-none focus:border-[#fbbf24] resize-none rounded-md"
      />
      <button
        onClick={handleSend}
        disabled={sending()}
        class={`px-6 py-4 font-bold text-[14px] ${sending() ? 'bg-[#52525b] text-[#27272a]' : 'bg-[#fbbf24] text-[#09090b] hover:bg-[#fcd34d]'}`}
      >
        {sending() ? '...' : 'SEND'}
      </button>
    </div>
  );
};

export default ChatInput;
