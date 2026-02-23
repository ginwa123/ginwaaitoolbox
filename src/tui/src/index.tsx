import { TextAttributes } from "@opentui/core";
import { render } from "@opentui/solid";
import { createSignal, onMount } from "solid-js";
import {
  sendIpcMessage,
  parseAgentResponse,
  parseAndFormatContent,
  type AgentResponse,
  type ToolCall
} from "./ipc";
import { logStartup, logIpcSend, logIpcReceive, logError, log } from "./logger";

try {
  render(() => {
    const [input, setInput] = createSignal("");
    const [submitted, setSubmitted] = createSignal("");
    const [debug, setDebug] = createSignal("");
    const [response, setResponse] = createSignal<string>("");
    const [thought, setThought] = createSignal<string>("");
    const [markdown, setMarkdown] = createSignal<string>("");
    const [toolCalls, setToolCalls] = createSignal<ToolCall[]>([]);
    const [finishReason, setFinishReason] = createSignal<string>("");

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

      setSubmitted(msg);
      setInput("");
      setDebug("Sending: " + msg);
      setResponse("");
      setThought("");
      setMarkdown("");
      setToolCalls([]);
      setFinishReason("");
      logIpcSend(msg);

      sendIpcMessage({
        command_type: "agent_ask",
        message: msg,
      }).then((rawResponse) => {
        logIpcReceive(rawResponse);
        setDebug("Response: " + rawResponse);

        const parsed = parseAgentResponse(rawResponse);
        if (parsed && parsed.choices && parsed.choices.length > 0) {
          const choice = parsed.choices[0];

          if (choice.message.content) {
            const formatted = parseAndFormatContent(choice.message.content);
            if (formatted.thought) setThought(formatted.thought);
            if (formatted.markdown) setMarkdown(formatted.markdown);
            if (formatted.plain) setResponse(formatted.plain);
          }

          if (choice.message.tool_calls) {
            setToolCalls(choice.message.tool_calls);
          }

          if (choice.finish_reason) {
            setFinishReason(choice.finish_reason);
          }
        }
      }).catch((err) => {
        setDebug("Error: " + err);
        logError("IPC request failed", err);
      });
    };

    return (
	    <>
      <box flexDirection="column" flexGrow={1}>
        <box justifyContent="center" alignItems="center">
          <ascii_font font="tiny" text="OpenTUI" />
        </box>

        {thought() && (
          <box flexDirection="column" marginTop={1} paddingX={1}>
            <text attributes={TextAttributes.BOLD}>Thought:</text>
            <text>{thought()}</text>
          </box>
        )}

        {markdown() && (
          <box flexDirection="column" marginTop={1} paddingX={1}>
            <text attributes={TextAttributes.BOLD}>Response:</text>
            <text>{markdown()}</text>
          </box>
        )}

        {response() && !markdown() && (
          <box flexDirection="column" marginTop={1} paddingX={1}>
            <text attributes={TextAttributes.BOLD}>Response:</text>
            <text>{response()}</text>
          </box>
        )}

        {toolCalls().length > 0 && (
          <box flexDirection="column" marginTop={1} paddingX={1}>
            <text attributes={TextAttributes.BOLD} color="yellow">Tool Calls:</text>
            {toolCalls().map((tc) => (
              <box flexDirection="column" marginLeft={1}>
                <text color="cyan">- {tc.function.name}</text>
                <text>{tc.function.arguments}</text>
              </box>
            ))}
          </box>
        )}

        {finishReason() && (
          <box marginTop={1} paddingX={1}>
            <text attributes={TextAttributes.DIM}>Finish: {finishReason()}</text>
          </box>
        )}

        <box flexGrow={1} />

        <box flexDirection="column" marginBottom={1}>
          <box flexDirection="row" alignItems="center">
            <text attributes={TextAttributes.DIM}>Enter message: </text>
            <input
              value={input()}
              focused={true}
              onInput={(value: string) => handleInput(value)}
              onSubmit={(value: string) => handleSubmit(value)}
              placeholder="Type message..."
              width={40}
            />
            <text> </text>
          </box>
          {debug() && (
            <box marginTop={1}>
              <text attributes={TextAttributes.DIM}>{debug()}</text>
            </box>
          )}
          {submitted() && (
            <box marginTop={1}>
              <text attributes={TextAttributes.DIM}>Sent: {submitted()}</text>
            </box>
          )}
        </box>
      </box>

	    </>
    );
  });
} catch (e) {
  logError("RENDER ERROR", e);
}
