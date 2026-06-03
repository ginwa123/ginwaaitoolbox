import { inject, type InjectionKey } from 'vue'

/**
 * Options for opening a file in the in-app CodeEditor.
 * Provided by `AppLayout` and consumed by tool output components
 * (TextReplace, WriteFile, ReadFile, Search, Glob, RemoveFile) so they
 * can offer an "Open in editor" button that drives the same code-editor
 * flow as the right-sidebar file explorer.
 */
export type OpenInCodeEditorOptions = {
  filePath: string
  fileName?: string
  cwd: string
}

export type OpenInCodeEditorFn = (opts: OpenInCodeEditorOptions) => Promise<void> | void

export const OPEN_IN_CODE_EDITOR_KEY: InjectionKey<OpenInCodeEditorFn> = Symbol(
  'openInCodeEditor',
) as InjectionKey<OpenInCodeEditorFn>

/**
 * Inject the `openInCodeEditor` handler provided by `AppLayout`.
 * Returns `null` when the component is rendered outside of an `AppLayout`
 * subtree (e.g. in unit tests), so the calling component can gracefully
 * hide its "Open in editor" button.
 */
export function useInjectOpenInCodeEditor(): OpenInCodeEditorFn | null {
  return inject(OPEN_IN_CODE_EDITOR_KEY, null)
}
