import type { ParentComponent } from "solid-js";
import Header from "./components/Header";
import Sidebar from "./components/Sidebar";
import Footer from "./components/Footer";

export const AppLayout: ParentComponent = (props) => {
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
