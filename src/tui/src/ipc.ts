import { connect } from "net";
import { TextEncoder } from "util";

const SOCKET_PATH = "/tmp/agent.sock";

export async function sendIpcMessage(message: object): Promise<string> {
  const encoder = new TextEncoder();
  const data = JSON.stringify(message);
  
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    
    const socket = connect(SOCKET_PATH, () => {
      socket.write(data + "\n", () => {
        socket.end();
      });
    });
    
    socket.on("data", (chunk: Buffer) => {
      chunks.push(chunk);
    });
    
    socket.on("close", () => {
      if (chunks.length > 0) {
        resolve(Buffer.concat(chunks).toString());
      } else {
        resolve("");
      }
    });
    
    socket.on("error", () => {
      resolve("");
    });
  });
}
