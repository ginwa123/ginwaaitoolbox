import { type Component, createSignal } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { refreshSessionList } from '../store/sessionStore';
import { electroview } from '../main';

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
      // Get cwd from Bun's main process via RPC
      // electroview.rpc.request.getCwd() calls the Bun handler
      let cwdSession = '';
      try {
        if (electroview?.rpc?.request?.getCwd) {
          cwdSession = await electroview.rpc.request.getCwd();
          console.log('[ChatInput] Got cwd from Bun:', cwdSession);
        } else {
          console.warn('[ChatInput] getCwd not available on electroview.rpc.request');
        }
      } catch (err) {
        console.warn('[ChatInput] Failed to get cwd from Bun:', err);
      }

      // Use /api/session for both new and existing sessions
      // For existing: pass session_id and queue_message
      // For new: just pass queue_message
      const body: { session_id?: string; queue_message: string; cwd_session?: string } = {
        queue_message: msg,
        cwd_session: cwdSession || undefined,
      };
      if (props.sessionId) {
        body.session_id = props.sessionId;
      }

      const res = await fetch('http://127.0.0.1:8080/api/session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (res.ok) {
        const data = await res.json();
        console.log('[ChatInput] Message sent:', data);
        setText('');

        if (props.sessionId) {
          // Existing session - refresh sidebar after delay
          setTimeout(() => {
            refreshSessionList();
            console.log('[ChatInput] Sidebar refreshed after delay');
          }, 1000);
        } else {
          // New session - navigate to it, then refresh sidebar
          navigate(`/session/${data.id}`, { replace: true });
          setTimeout(() => {
            refreshSessionList();
            console.log('[ChatInput] Sidebar refreshed after delay');
          }, 1000);
        }
      } else {
        console.error('[ChatInput] Error:', await res.text());
      }
    } catch (err) {
      console.error('[ChatInput] Network error:', err);
    } finally {
      setSending(false);
    }
  };

  return (
    <div class="flex items-end gap-3 pt-4 bg-[#050505] border-t border-[#18181b] p-4">
      <input
        type="text"
        value={text()}
        onInput={(e) => setText(e.currentTarget.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && text().trim() && !sending()) {
            handleSend();
          }
        }}
        placeholder={props.sessionId ? "Type a message..." : "Type a message to start..."}
        class="flex-1 bg-[#0a0a0a] border border-[#27272a] px-4 py-3 text-[13px] text-[#e4e4e7] font-mono outline-none focus:border-[#fbbf24]"
      />
      <button
        onClick={handleSend}
        disabled={sending()}
        class={`px-6 py-3 font-bold ${sending() ? 'bg-[#52525b] text-[#27272a]' : 'bg-[#fbbf24] text-[#09090b] hover:bg-[#fcd34d]'}`}
      >
        {sending() ? '...' : 'SEND'}
      </button>
    </div>
  );
};

export default ChatInput;
