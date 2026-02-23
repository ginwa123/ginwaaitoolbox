const SOCKET_PATH = "/tmp/agent.sock";

export async function sendIpcMessage(message: object): Promise<string> {
  const decoder = new TextDecoder();
  const data = JSON.stringify(message);
  
  return new Promise((resolve) => {
    const chunks: Uint8Array[] = [];
    
    const socket = new Bun.Socket({
      unix: SOCKET_PATH,
      socket: {
        data(socket, buffer) {
          chunks.push(new Uint8Array(buffer));
        },
        close() {
          if (chunks.length > 0) {
            const result = decoder.decode(Buffer.concat(chunks.map(c => Buffer.from(c))));
            resolve(result);
          } else {
            resolve("");
          }
        },
        error(socket, error) {
          resolve("");
        },
      },
    });
    
    socket.write(data).then(() => {
      socket.end();
    });
  });
}
