import { Route, Router } from '@solidjs/router';
/* @refresh reload */
import { render } from 'solid-js/web';
import { AppLayout } from './AppLayout';
import SessionChat from './pages/SessionChat';
import Welcome from './pages/Welcome';
import './app.css';

const App: Component = () => {
  return (
    <Router root={AppLayout}>
      <Route path="/" component={Welcome} />
      <Route path="/session/:sessionId" component={SessionChat} />
    </Router>
  );
};

render(() => <App />, document.getElementById('app')!);
