import {
  type Accessor,
  type ParentComponent,
  createContext,
  createSignal,
  useContext,
} from 'solid-js';

// Signal to trigger session list refresh
const [sessionListVersion, setSessionListVersion] = createSignal(0);

export const refreshSessionList = () => {
  setSessionListVersion((v) => v + 1);
};

// Export the signal getter for use in effects
export const getSessionListVersion: Accessor<number> = () => sessionListVersion();

// Signal to track selected folder for session_dir filtering
const [selectedFolder, setSelectedFolder] = createSignal('/');

export const getSelectedFolder: Accessor<string> = () => selectedFolder();

export const setSelectedFolderValue = (path: string) => {
  setSelectedFolder(path);
};

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
