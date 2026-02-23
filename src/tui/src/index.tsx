import { TextAttributes } from "@opentui/core";
import { render } from "@opentui/solid";
import { createSignal, onMount } from "solid-js";
import { sendIpcMessage } from "./ipc";
import { logStartup, logIpcSend, logIpcReceive, logError } from "./logger";

render(() => {
  const [input, setInput] = createSignal("");
  const [submitted, setSubmitted] = createSignal("");
  const [debug, setDebug] = createSignal("");

  onMount(() => {
    logStartup();
  });

  const handleInput = (value: string) => {
    setDebug("onInput: " + value);
    setInput(value);
  };

  const handleSubmit = () => {
    setDebug("onSubmit triggered! Input: " + input());
    const msg = input();
    if (!msg || msg.len == 0) return;
    
    setSubmitted(msg);
    setInput("");
    setDebug("Sending: " + msg);
    logIpcSend(msg);
    
    sendIpcMessage({
      command_type: "agent_ask",
      message: msg,
    }).then((response) => {
      setDebug("Response: " + response);
      logIpcReceive(response);
    }).catch((err) => {
      setDebug("Error: " + err);
      logError("IPC request failed", err);
    });
  };

  return (
    <box flexDirection="column" flexGrow={1}>
      <box justifyContent="center" alignItems="center">
        <ascii_font font="tiny" text="OpenTUI" />
      </box>
      <box flexGrow={1} />
      <box flexDirection="column" marginBottom={1}>
        <box flexDirection="row" alignItems="center">
          <text attributes={TextAttributes.DIM}>Enter message: </text>
          <textarea
            value={input()}
            focused={true}
            onInput={(e: any) => handleInput(e.target.value)}
            onSubmit={handleSubmit}
            placeholder="Type message..."
            width={50}
            height={3}
          />
        </box>
        {debug() && (
          <box marginTop={1}>
            <text>{debug()}</text>
          </box>
        )}
        {submitted() && (
          <box marginTop={1}>
            <text>Sent: {submitted()}</text>
          </box>
        )}
      </box>
    </box>
  );
});
