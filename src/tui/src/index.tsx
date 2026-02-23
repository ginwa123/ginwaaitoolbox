import { TextAttributes } from "@opentui/core";
import { render } from "@opentui/solid";
import { createSignal, onMount } from "solid-js";
import { sendIpcMessage } from "./ipc";
import { logStartup, logIpcSend, logIpcReceive, logError, log } from "./logger";

try {
  render(() => {
    const [input, setInput] = createSignal("");
    const [submitted, setSubmitted] = createSignal("");
    const [debug, setDebug] = createSignal("");

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
      <box flexDirection="column" flexGrow={1} onClick={() => log("BOX CLICKED")}>
        <box justifyContent="center" alignItems="center" onClick={() => log("TITLE CLICKED")}>
          <ascii_font font="tiny" text="OpenTUI" />
        </box>
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
            <box borderStyle="round" paddingX={1} onClick={handleSubmit}>
              <text>Send</text>
            </box>
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
} catch (e) {
  logError("RENDER ERROR", e);
}
