import { type Component, createSignal } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { refreshSessionList } from '../store/sessionStore';

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
      if (props.sessionId) {
        // Send to existing session via /api/llm/run
        const res = await fetch('http://127.0.0.1:8080/api/llm/run', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ 
            session_id: props.sessionId,
            message: msg 
          }),
        });
        
        if (res.ok) {
          console.log('[ChatInput] Message sent to session:', props.sessionId);
          setText('');
          // Trigger SSE refresh by navigating (or we could use a different mechanism)
          window.location.reload();
        } else {
          console.error('[ChatInput] Error:', await res.text());
        }
      } else {
        // Create new session via /api/session
        const res = await fetch('http://127.0.0.1:8080/api/session', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ queue_message: msg }),
        });
        
        if (res.ok) {
          const data = await res.json();
          console.log('[ChatInput] Session created:', data);
          setText('');
          // Refresh session list in sidebar
          refreshSessionList();
          // Navigate to the new session
          navigate(`/session/${data.id}`, { replace: true });
        } else {
          console.error('[ChatInput] Error:', await res.text());
        }
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
