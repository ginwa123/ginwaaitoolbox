import { type ParentComponent } from 'solid-js';
import Footer from './components/Footer';
import Header from './components/Header';
import Sidebar from './components/Sidebar';

export const AppLayout: ParentComponent = (props) => {
  return (
    <div class="flex flex-col w-full bg-[#050505]" style="height: 100vh;">
      <Header />
      <div class="flex flex-1 min-h-0">
        <Sidebar />
        <main class="flex-1 min-h-0 overflow-auto flex justify-center">
          <div class="w-full max-w-[85%] px-6">{props.children}</div>
        </main>
      </div>
      <Footer />
    </div>
  );
};
