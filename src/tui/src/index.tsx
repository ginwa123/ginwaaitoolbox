import { TextAttributes } from "@opentui/core";
import { render } from "@opentui/solid";
import { createSignal, onMount, For } from "solid-js";
import {
  sendIpcMessage,
  parseAgentResponse,
  parseAndFormatContent,
  type AgentResponse,
  type ToolCall
} from "./ipc";
import { logStartup, logIpcSend, logIpcReceive, logError, log } from "./logger";

interface ChatMessage {
  role: "user" | "assistant";
  content: string;
  thought?: string;
  markdown?: string;
  toolCalls?: ToolCall[];
  finishReason?: string;
}

interface ExpandedState {
  thought?: boolean;
  markdown?: boolean;
}

try {
  render(() => {
    const [input, setInput] = createSignal("");
    const [debug, setDebug] = createSignal("");
    const [messages, setMessages] = createSignal<ChatMessage[]>([]);
    const [expanded, setExpanded] = createSignal<Record<number, { thought: boolean; markdown: boolean }>>({});
    const [isLoading, setIsLoading] = createSignal(false);

    const isExpanded = (idx: number, field: "thought" | "markdown") => {
      const state = expanded()[idx];
      if (state === undefined) return true;
      return state[field] ?? true;
    };

    const toggleExpand = (idx: number, field: "thought" | "markdown") => {
      setExpanded(prev => {
        const current = prev[idx] || { thought: true, markdown: true };
        return {
          ...prev,
          [idx]: { ...current, [field]: !current[field] }
        };
      });
    };

    onMount(() => {
      logStartup();
    });

    const handleInput = (value: string) => {
      log("handleInput: " + value);
      setDebug("onInput: " + value);
      setInput(value);
    };

    const handleSubmit = (value: string) => {
      log("handleSubmit CALLED with value: " + value);
      setDebug("onSubmit triggered! Input: " + value);
      const msg = value;
      if (!msg || msg.length === 0) return;

      setInput("");
      setDebug("Sending: " + msg);
      setIsLoading(true);

      setMessages((prev) => [...prev, { role: "user", content: msg }]);
      logIpcSend(msg);

      sendIpcMessage({
        command_type: "agent_ask",
        message: msg,
      }).then((rawResponse) => {
        logIpcReceive(rawResponse);
        setDebug("Response: " + rawResponse);

        const parsed = parseAgentResponse(rawResponse);
        const assistantMsg: ChatMessage = { role: "assistant", content: "" };

        if (parsed && parsed.choices && parsed.choices.length > 0) {
          const choice = parsed.choices[0];

          if (choice.message.content) {
            assistantMsg.content = choice.message.content;
            const formatted = parseAndFormatContent(choice.message.content);
            if (formatted.thought) assistantMsg.thought = formatted.thought;
            if (formatted.markdown) assistantMsg.markdown = formatted.markdown;
          }

          if (choice.message.tool_calls) {
            assistantMsg.toolCalls = choice.message.tool_calls;
          }

          if (choice.finish_reason) {
            assistantMsg.finishReason = choice.finish_reason;
          }
        }

        setMessages((prev) => [...prev, assistantMsg]);
        setExpanded((prev) => {
          const newState = { ...prev };
          newState[Object.keys(newState).length] = { thought: true, markdown: true };
          return newState;
        });
        setIsLoading(false);
      }).catch((err) => {
        setDebug("Error: " + err);
        logError("IPC request failed", err);
        setMessages((prev) => [...prev, { role: "assistant", content: "Error: " + err }]);
        setExpanded((prev) => {
          const newState = { ...prev };
          newState[Object.keys(newState).length] = { thought: true, markdown: true };
          return newState;
        });
        setIsLoading(false);
      });
    };

    return (
      <>
        <box flexDirection="column" flexGrow={1}>
          <box justifyContent="center" alignItems="center" flexShrink={0}>
            <ascii_font font="tiny" text="OpenTUI" />
          </box>

          <box flexDirection="column" flexGrow={1} paddingX={1} marginTop={1} flexShrink={1}>
            <For each={messages()}>
              {(msg, idx) => (
                <box flexDirection="column" marginBottom={1}>
                  <text attributes={TextAttributes.BOLD} color={msg.role === "user" ? "green" : "blue"}>
                    {msg.role === "user" ? "You:" : "Assistant:"}
                  </text>
                  
                  {msg.role === "user" && (
                    <text>{msg.content}</text>
                  )}

                  {msg.role === "assistant" && (
                    <>
                      {msg.thought && (
                        <box flexDirection="column" marginLeft={1}>
                          <text 
                            color="yellow"
                            onClick={() => toggleExpand(idx(), "thought")}
                          >
                            {isExpanded(idx(), "thought") ? "▼ Thought" : "▶ Thought"}
                          </text>
                          {isExpanded(idx(), "thought") && (
                            <text attributes={TextAttributes.DIM}>{msg.thought}</text>
                          )}
                        </box>
                      )}

                      {msg.markdown && (
                        <box flexDirection="column" marginLeft={1}>
                          <text 
                            onClick={() => toggleExpand(idx(), "markdown")}
                          >
                            {isExpanded(idx(), "markdown") ? "▼ Markdown" : "▶ Markdown"}
                          </text>
                          {isExpanded(idx(), "markdown") && (
                            <text>{msg.markdown}</text>
                          )}
                        </box>
                      )}

                      {msg.content && !msg.markdown && (
                        <box flexDirection="column" marginLeft={1}>
                          <text>{msg.content}</text>
                        </box>
                      )}

                      {msg.toolCalls && msg.toolCalls.length > 0 && (
                        <box flexDirection="column" marginLeft={1} marginTop={1}>
                          <text color="yellow">Tool Calls:</text>
                          <For each={msg.toolCalls}>
                            {(tc) => (
                              <box flexDirection="column" marginLeft={1}>
                                <text color="cyan">- {tc.function.name}</text>
                                <text attributes={TextAttributes.DIM}>{tc.function.arguments}</text>
                              </box>
                            )}
                          </For>
                        </box>
                      )}

                      {msg.finishReason && (
                        <text attributes={TextAttributes.DIM} marginLeft={1}>Finish: {msg.finishReason}</text>
                      )}
                    </>
                  )}
                </box>
              )}
            </For>

            {isLoading() && (
              <box marginTop={1}>
                <text attributes={TextAttributes.DIM} color="cyan">Thinking...</text>
              </box>
            )}
          </box>

          <box flexDirection="column" flexShrink={0} marginBottom={1}>
            <box flexDirection="row" alignItems="center">
              <text attributes={TextAttributes.DIM}>Enter message: </text>
              <InputWithHistory
                input={input}
                setInput={setInput}
                handleSubmit={handleSubmit}
                isLoading={isLoading}
              />
              <text> </text>
            </box>
          </box>
        </box>

      </>
    );
  });
} catch (e) {
  logError("RENDER ERROR", e);
}

function InputWithHistory(props: {
  input: () => string;
  setInput: (v: string) => void;
  handleSubmit: (v: string) => void;
  isLoading: () => boolean;
}) {
  return (
    <input
      value={props.input()}
      focused={true}
      onInput={(value: string) => props.setInput(value)}
      onSubmit={(value: string) => {
        if (!props.isLoading()) {
          props.handleSubmit(value);
        }
      }}
      placeholder={props.isLoading() ? "Waiting for response..." : "Type message..."}
      width={60}
    />
  );
}
