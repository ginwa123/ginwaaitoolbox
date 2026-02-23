import { TextAttributes } from "@opentui/core";
import { render } from "@opentui/solid";
import { createSignal, onMount } from "solid-js";
import { sendIpcMessage } from "./ipc";

render(() => {
  const [input, setInput] = createSignal("");
  const [submitted, setSubmitted] = createSignal("");
  let inputRef: any;

  onMount(() => {
    inputRef?.focus();
  });

  const handleSubmit = async () => {
    const msg = input();
    if (msg.len == 0) return;
    
    setSubmitted(msg);
    setInput("");
    
    try {
      const response = await sendIpcMessage({
        command_type: "agent_ask",
        message: msg,
      });
      console.log("Response:", response);
    } catch (err) {
      console.error("Failed to send message:", err);
    }
  };

  return (
    <box flexDirection="column" flexGrow={1}>
      <box justifyContent="center" alignItems="center">
        <ascii_font font="tiny" text="OpenTUI" />
      </box>
      <box flexGrow={1} />
      <box flexDirection="row" alignItems="center" marginBottom={1} flexGrow={1} width="100%">
        <text attributes={TextAttributes.DIM}>Enter message: </text>
        <input
          ref={inputRef}
          value={input()}
          onInput={(e) => setInput(e.target.value)}
          onSubmit={handleSubmit}
          placeholder="Type something..."
          width={50}
        />
        {submitted() && (
          <box marginLeft={1}>
            <text>Submitted: {submitted()}</text>
          </box>
        )}
      </box>
    </box>
  );
});
