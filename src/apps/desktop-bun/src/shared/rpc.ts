export interface DesktopRPC {
  request: {
    getNalarPort: () => Promise<number>;
    getNalarBaseUrl: () => Promise<string>;
  };
  send: {
    log: (params: { msg: string; level?: string }) => void;
  };
}
