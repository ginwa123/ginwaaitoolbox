/**
 * Tool Call Renderer Component
 *
 * Renders structured tool call data with appropriate formatting
 * based on the tool type. Uses a distinctive dark terminal aesthetic.
 */

import { type Component, For, Show, createMemo } from 'solid-js';
import type { ToolData } from '../utils/toolParser';

// ============================================================================
// Types
// ============================================================================

interface ToolCallRendererProps {
  tool: ToolData;
  expanded?: boolean;
}

// ============================================================================
// Utility Components
// ============================================================================

/**
 * Terminal-style frame with header
 */
const TerminalFrame: Component<{ title: string; titleColor?: string; children: any }> = (props) => {
  const titleColor = () => props.titleColor || 'text-[#fbbf24]';

  return (
    <div class="font-mono text-sm border border-[#27272a] bg-[#0d0d0d] overflow-hidden">
      {/* Header */}
      <div
        class={`flex items-center gap-2 px-3 py-1.5 bg-[#18181b] border-b border-[#27272a] ${titleColor()}`}
      >
        <span class="text-[10px] opacity-60">┌─</span>
        <span class="uppercase tracking-wider text-xs font-semibold">{props.title}</span>
        <span class="flex-1 text-[10px] opacity-60">{'─'.repeat(20)}</span>
        <span class="text-[10px] opacity-60">┐</span>
      </div>
      {/* Content */}
      <div class="p-3">{props.children}</div>
      {/* Footer */}
      <div class="px-3 py-1 bg-[#18181b] border-t border-[#27272a]">
        <span class="text-[10px] opacity-60">└{'─'.repeat(50)}┘</span>
      </div>
    </div>
  );
};

/**
 * Code block with optional line numbers
 */
const CodeBlock: Component<{
  content: string;
  showLineNumbers?: boolean;
  maxLines?: number;
  class?: string;
}> = (props) => {
  const lines = createMemo(() => {
    const allLines = props.content.split('\n');
    const max = props.maxLines || allLines.length;
    return allLines.slice(0, max);
  });

  const hasMore = createMemo(() => {
    const allLines = props.content.split('\n');
    return allLines.length > (props.maxLines || allLines.length);
  });

  return (
    <div class={`font-mono text-sm bg-[#111] border border-[#1f1f1f] ${props.class || ''}`}>
      <Show
        when={props.showLineNumbers}
        fallback={
          <pre class="p-2 text-[#a1a1aa] whitespace-pre-wrap break-words overflow-x-auto">
            {lines().join('\n')}
          </pre>
        }
      >
        <div class="flex">
          {/* Line numbers */}
          <div class="flex-shrink-0 py-2 pl-2 pr-3 bg-[#0a0a0a] border-r border-[#1f1f1f] text-right select-none">
            <For each={lines()}>
              {(_line, i) => (
                <div class="text-[#3f3f46] text-xs leading-relaxed">
                  {String(i() + 1).padStart(3, ' ')}
                </div>
              )}
            </For>
          </div>
          {/* Code content */}
          <pre class="flex-1 p-2 text-[#a1a1aa] whitespace-pre-wrap break-words overflow-x-auto leading-relaxed">
            <For each={lines()}>{(line) => <div>{line}</div>}</For>
          </pre>
        </div>
      </Show>
      <Show when={hasMore()}>
        <div class="px-2 py-1 text-xs text-[#52525b] border-t border-[#1f1f1f]">
          ... {props.content.split('\n').length - (props.maxLines || 0)} more lines
        </div>
      </Show>
    </div>
  );
};

// ============================================================================
// Tool-Specific Renderers
// ============================================================================

/**
 * Bash Tool Renderer
 */
const BashToolRenderer: Component<{ fields: Record<string, string> }> = (props) => {
  const exitCode = () => props.fields.exit_code;
  const isSuccess = () => exitCode() === '0' || exitCode() === undefined;

  return (
    <TerminalFrame
      title={`TOOL: ${props.fields.command ? 'bash' : 'command'}`}
      titleColor="text-[#34d399]"
    >
      <Show when={props.fields.command}>
        <div class="mb-3">
          <div class="text-[10px] text-[#52525b] uppercase tracking-wider mb-1">Command:</div>
          <div class="flex items-center gap-2">
            <span class="text-[#34d399]">$</span>
            <code class="text-[#e4e4e7] bg-[#1a1a1a] px-2 py-1 rounded text-sm">
              {props.fields.command}
            </code>
          </div>
        </div>
      </Show>

      <Show when={props.fields.result}>
        <div class="border-t border-[#27272a] pt-3">
          <div class="flex items-center gap-2 mb-2">
            <span class="text-[10px] text-[#52525b] uppercase tracking-wider">Result:</span>
            <Show when={exitCode()}>
              <span
                class={`text-[10px] px-1.5 py-0.5 rounded ${
                  isSuccess() ? 'bg-[#34d399]/10 text-[#34d399]' : 'bg-[#ef4444]/10 text-[#ef4444]'
                }`}
              >
                exit {exitCode()}
              </span>
            </Show>
          </div>
          <CodeBlock content={props.fields.result} maxLines={20} class="border-[#27272a]" />
        </div>
      </Show>

      <Show when={!props.fields.command && !props.fields.result}>
        <div class="text-[#52525b] text-sm italic">No output</div>
      </Show>
    </TerminalFrame>
  );
};

/**
 * Read File Tool Renderer
 */
const ReadFileToolRenderer: Component<{ fields: Record<string, string> }> = (props) => {
  const filename = createMemo(() => {
    const path = props.fields.path || '';
    return path.split('/').pop() || path;
  });

  return (
    <TerminalFrame title={`TOOL: ${filename()}`} titleColor="text-[#38bdf8]">
      <Show when={props.fields.path}>
        <div class="flex items-center gap-2 mb-3 pb-2 border-b border-[#27272a]">
          <span class="text-[#fbbf24]">📄</span>
          <span class="text-[#71717a] text-sm">{props.fields.path}</span>
          <Show when={props.fields.hash}>
            <span class="ml-auto text-[10px] text-[#3f3f46] font-mono">
              {props.fields.hash.slice(0, 8)}...
            </span>
          </Show>
        </div>
      </Show>

      <Show when={props.fields.content}>
        <CodeBlock
          content={props.fields.content}
          showLineNumbers={props.fields.show_line_numbers === 'true'}
          maxLines={30}
          class="border-[#27272a]"
        />
      </Show>

      <Show when={!props.fields.content}>
        <div class="text-[#52525b] text-sm italic">Empty file or content not available</div>
      </Show>
    </TerminalFrame>
  );
};

/**
 * Write File Tool Renderer
 */
const WriteFileToolRenderer: Component<{ fields: Record<string, string> }> = (props) => {
  const filename = createMemo(() => {
    const path = props.fields.path || '';
    return path.split('/').pop() || path;
  });

  return (
    <TerminalFrame title={`TOOL: written ${filename()}`} titleColor="text-[#a78bfa]">
      <Show when={props.fields.path}>
        <div class="flex items-center gap-2 mb-3 pb-2 border-b border-[#27272a]">
          <span class="text-[#34d399]">✓</span>
          <span class="text-[#71717a] text-sm">{props.fields.path}</span>
          <Show when={props.fields.hash}>
            <span class="ml-auto text-[10px] text-[#3f3f46] font-mono">
              {props.fields.hash.slice(0, 8)}...
            </span>
          </Show>
        </div>
      </Show>

      <Show when={props.fields.content}>
        <div class="text-[10px] text-[#52525b] uppercase tracking-wider mb-2">Content written:</div>
        <CodeBlock content={props.fields.content} maxLines={15} class="border-[#27272a]" />
      </Show>

      <Show when={!props.fields.content}>
        <div class="text-[#34d399] text-sm flex items-center gap-2">
          <span>✓</span> File created (no content preview)
        </div>
      </Show>
    </TerminalFrame>
  );
};

/**
 * Search Tool Renderer
 */
const SearchToolRenderer: Component<{ fields: Record<string, string> }> = (props) => {
  return (
    <TerminalFrame title="TOOL: search" titleColor="text-[#f472b6]">
      <div class="flex flex-wrap gap-x-4 gap-y-1 mb-3 pb-2 border-b border-[#27272a]">
        <Show when={props.fields.pattern}>
          <div class="text-sm">
            <span class="text-[#52525b]">Pattern: </span>
            <code class="text-[#f472b6] bg-[#1a1a1a] px-1.5 py-0.5 rounded">
              {props.fields.pattern}
            </code>
          </div>
        </Show>
        <Show when={props.fields.path}>
          <div class="text-sm">
            <span class="text-[#52525b]">in: </span>
            <code class="text-[#a1a1aa] bg-[#1a1a1a] px-1.5 py-0.5 rounded">
              {props.fields.path}
            </code>
          </div>
        </Show>
      </div>

      <Show when={props.fields.matches}>
        <div class="text-[10px] text-[#52525b] uppercase tracking-wider mb-2">Matches:</div>
        <CodeBlock content={props.fields.matches} class="border-[#27272a]" />
      </Show>

      <Show when={!props.fields.matches}>
        <div class="text-[#52525b] text-sm italic">No matches found</div>
      </Show>
    </TerminalFrame>
  );
};

/**
 * Glob Tool Renderer
 */
const GlobToolRenderer: Component<{ fields: Record<string, string> }> = (props) => {
  const fileList = createMemo(() => {
    const results = props.fields.results || '';
    return results.split('\n').filter(Boolean);
  });

  return (
    <TerminalFrame title="TOOL: glob" titleColor="text-[#fb923c]">
      <Show when={props.fields.pattern}>
        <div class="flex items-center gap-2 mb-3 pb-2 border-b border-[#27272a]">
          <span class="text-[#52525b]">Pattern: </span>
          <code class="text-[#fb923c] bg-[#1a1a1a] px-1.5 py-0.5 rounded">
            {props.fields.pattern}
          </code>
          <span class="ml-auto text-[#52525b] text-xs">{fileList().length} files</span>
        </div>
      </Show>

      <Show when={fileList().length > 0}>
        <div class="space-y-0.5 max-h-48 overflow-y-auto">
          <For each={fileList()}>
            {(file) => (
              <div class="text-[#a1a1aa] text-sm flex items-center gap-2">
                <span class="text-[#fb923c] text-xs">◆</span>
                <span class="truncate">{file}</span>
              </div>
            )}
          </For>
        </div>
      </Show>

      <Show when={fileList().length === 0}>
        <div class="text-[#52525b] text-sm italic">No files matched</div>
      </Show>
    </TerminalFrame>
  );
};

/**
 * Web Search Tool Renderer
 */
const WebSearchToolRenderer: Component<{ fields: Record<string, string> }> = (props) => {
  return (
    <TerminalFrame title="TOOL: web_search" titleColor="text-[#60a5fa]">
      <Show when={props.fields.query}>
        <div class="mb-3 pb-2 border-b border-[#27272a]">
          <div class="text-[10px] text-[#52525b] uppercase tracking-wider mb-1">Query:</div>
          <div class="text-[#e4e4e7] text-sm">{props.fields.query}</div>
        </div>
      </Show>

      <Show when={props.fields.url}>
        <div class="mb-3 pb-2 border-b border-[#27272a]">
          <div class="text-[10px] text-[#52525b] uppercase tracking-wider mb-1">URL:</div>
          <a
            href={props.fields.url}
            target="_blank"
            rel="noopener noreferrer"
            class="text-[#60a5fa] text-sm hover:underline break-all"
          >
            {props.fields.url}
          </a>
        </div>
      </Show>

      <Show when={props.fields.results}>
        <div class="text-[10px] text-[#52525b] uppercase tracking-wider mb-2">Results:</div>
        <CodeBlock content={props.fields.results} maxLines={10} class="border-[#27272a]" />
      </Show>

      <Show when={!props.fields.results && !props.fields.url && !props.fields.query}>
        <div class="text-[#52525b] text-sm italic">No search results</div>
      </Show>
    </TerminalFrame>
  );
};

/**
 * LSP Tool Renderer
 */
const LspToolRenderer: Component<{ fields: Record<string, string> }> = (props) => {
  return (
    <TerminalFrame title="TOOL: LSP" titleColor="text-[#c084fc]">
      <div class="space-y-2">
        <Show when={props.fields.symbol}>
          <div class="flex items-center gap-2">
            <span class="text-[#52525b] text-xs">Symbol:</span>
            <code class="text-[#c084fc] bg-[#1a1a1a] px-1.5 py-0.5 rounded text-sm">
              {props.fields.symbol}
            </code>
          </div>
        </Show>

        <Show when={props.fields.file_path}>
          <div class="flex items-center gap-2">
            <span class="text-[#52525b] text-xs">File:</span>
            <code class="text-[#a1a1aa] bg-[#1a1a1a] px-1.5 py-0.5 rounded text-sm">
              {props.fields.file_path}
            </code>
          </div>
        </Show>

        <Show when={props.fields.line || props.fields.character}>
          <div class="flex items-center gap-4">
            <Show when={props.fields.line}>
              <div class="flex items-center gap-1">
                <span class="text-[#52525b] text-xs">Line:</span>
                <span class="text-[#34d399] font-mono">{props.fields.line}</span>
              </div>
            </Show>
            <Show when={props.fields.character}>
              <div class="flex items-center gap-1">
                <span class="text-[#52525b] text-xs">Col:</span>
                <span class="text-[#34d399] font-mono">{props.fields.character}</span>
              </div>
            </Show>
          </div>
        </Show>
      </div>
    </TerminalFrame>
  );
};

/**
 * Spawn Sub Agent Tool Renderer
 */
const SpawnSubAgentToolRenderer: Component<{ fields: Record<string, string> }> = (props) => {
  return (
    <TerminalFrame title="TOOL: spawn_sub_agent" titleColor="text-[#fbbf24]">
      <div class="space-y-3">
        <Show when={props.fields.agents}>
          <div>
            <div class="text-[10px] text-[#52525b] uppercase tracking-wider mb-2">Agents:</div>
            <CodeBlock content={props.fields.agents} maxLines={10} class="border-[#27272a]" />
          </div>
        </Show>

        <Show when={props.fields.results}>
          <div class="border-t border-[#27272a] pt-3">
            <div class="text-[10px] text-[#52525b] uppercase tracking-wider mb-2">Results:</div>
            <CodeBlock content={props.fields.results} maxLines={15} class="border-[#27272a]" />
          </div>
        </Show>
      </div>
    </TerminalFrame>
  );
};

/**
 * Generic/Unknown Tool Renderer
 */
const GenericToolRenderer: Component<{ fields: Record<string, string>; rawContent?: string }> = (
  props
) => {
  return (
    <TerminalFrame title={`TOOL: ${props.fields.raw || 'unknown'}`} titleColor="text-[#71717a]">
      <Show when={props.rawContent && !props.fields.raw}>
        <CodeBlock content={props.rawContent} maxLines={10} class="border-[#27272a]" />
      </Show>
      <Show when={props.fields.raw && props.fields.raw !== props.rawContent}>
        <CodeBlock content={props.fields.raw} class="border-[#27272a]" />
      </Show>
      <Show when={!props.fields.raw && !props.rawContent}>
        <div class="text-[#52525b] text-sm italic">No content</div>
      </Show>
    </TerminalFrame>
  );
};

// ============================================================================
// Main ToolCallRenderer Component
// ============================================================================

/**
 * Main renderer component that routes to appropriate tool-specific renderer
 */
const ToolCallRenderer: Component<ToolCallRendererProps> = (props) => {
  const tool = () => props.tool;

  return (
    <Show
      when={tool()}
      fallback={<div class="text-[#52525b] text-sm italic">Invalid tool data</div>}
    >
      <Show when={tool().toolName === 'bash'}>
        <BashToolRenderer fields={tool().fields} />
      </Show>

      <Show when={tool().toolName === 'read_file'}>
        <ReadFileToolRenderer fields={tool().fields} />
      </Show>

      <Show when={tool().toolName === 'write_file'}>
        <WriteFileToolRenderer fields={tool().fields} />
      </Show>

      <Show when={tool().toolName === 'search'}>
        <SearchToolRenderer fields={tool().fields} />
      </Show>

      <Show when={tool().toolName === 'glob'}>
        <GlobToolRenderer fields={tool().fields} />
      </Show>

      <Show when={tool().toolName.includes('web_search')}>
        <WebSearchToolRenderer fields={tool().fields} />
      </Show>

      <Show when={tool().toolName.startsWith('lsp_')}>
        <LspToolRenderer fields={tool().fields} />
      </Show>

      <Show when={tool().toolName === 'spawn_sub_agent'}>
        <SpawnSubAgentToolRenderer fields={tool().fields} />
      </Show>

      <Show
        when={
          !['bash', 'read_file', 'write_file', 'search', 'glob', 'spawn_sub_agent'].includes(
            tool().toolName
          ) &&
          !tool().toolName.includes('web_search') &&
          !tool().toolName.startsWith('lsp_')
        }
      >
        <GenericToolRenderer fields={tool().fields} rawContent={tool().rawContent} />
      </Show>
    </Show>
  );
};

export default ToolCallRenderer;
