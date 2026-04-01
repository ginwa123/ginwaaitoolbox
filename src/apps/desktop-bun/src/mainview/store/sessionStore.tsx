import { createContext, useContext, type ParentComponent, createSignal, type Accessor } from 'solid-js';

// Signal to trigger session list refresh
const [sessionListVersion, setSessionListVersion] = createSignal(0);

export const refreshSessionList = () => {
  setSessionListVersion((v) => v + 1);
};

// Export the signal getter for use in effects
export const getSessionListVersion: Accessor<number> = () => sessionListVersion();

export const SessionContext = createContext({
  refresh: refreshSessionList,
});

export const SessionProvider: ParentComponent = (props) => {
  return (
    <SessionContext.Provider value={{ refresh: refreshSessionList }}>
      {props.children}
    </SessionContext.Provider>
  );
};

export const useSessionRefresh = () => {
  const context = useContext(SessionContext);
  return context?.refresh ?? refreshSessionList;
};
