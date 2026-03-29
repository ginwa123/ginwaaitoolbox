/* @refresh reload */
import { render } from "solid-js/web";
import { Router, Route } from "@solidjs/router";
import { AppLayout } from "./AppLayout";
import Welcome from "./pages/Welcome";
import SessionChat from "./pages/SessionChat";
import "./app.css";

const App: Component = () => {
  return (
    <Router root={AppLayout}>
      <Route path="/" component={Welcome} />
      <Route path="/session/:sessionId" component={SessionChat} />
    </Router>
  );
};

render(() => <App />, document.getElementById("app")!);
