/* @refresh reload */
import { render } from "solid-js/web";
import { Router, Route } from "@solidjs/router";
import { AppLayout } from "./AppLayout";
import Welcome from "./pages/Welcome";
import SessionChat from "./pages/SessionChat";
import { Electroview } from "electrobun/view";
import type { DesktopRPC } from "../shared/rpc";
import "./app.css";

// Initialize RPC for Bun communication
const electrobun = new Electroview({
  rpc: Electroview.defineRPC<DesktopRPC>(),
});

// Store for components to access
export const getRpc = () => electrobun.rpc;

// Expose for debugging
if (typeof window !== 'undefined') {
  (window as any).electrobun = electrobun;
}

const App: Component = () => {
  return (
    <Router root={AppLayout}>
      <Route path="/" component={Welcome} />
      <Route path="/session/:sessionId" component={SessionChat} />
    </Router>
  );
};

render(() => <App />, document.getElementById("app")!);
