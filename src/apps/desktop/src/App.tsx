import type { Component } from "solid-js";
import { Router, Route } from "@solidjs/router";
import Header from "./components/Header";
import Sidebar from "./components/Sidebar";
import Footer from "./components/Footer";
import Welcome from "./pages/Welcome";
import SessionChat from "./pages/SessionChat";

const AppLayout: Component<{ children?: any }> = (props) => {
  return (
    <div class="flex flex-col h-full w-full bg-[#0a0a0a]">
      <Header />
      <div class="flex flex-1 overflow-hidden">
        <Sidebar />
        <main class="flex-1 overflow-auto p-8">
          {props.children}
        </main>
      </div>
      <Footer />
    </div>
  );
};

const App: Component = () => {
  return (
    <Router root={AppLayout}>
      <Route path="/" component={Welcome} />
      <Route path="/session/:sessionId" component={SessionChat} />
    </Router>
  );
};

export default App;
