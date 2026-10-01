<!--
  SearchSkills — renderer for the `search_skills` agent tool.

  `search_skills` is a paged regex-query search over the two skill tiers
  (global + local), the same contract `search_tool` uses: `query`,
  `pattern_mode`, `pattern_warning`, `scope`, `count`, `total`, `offset`,
  `limit`, `skills[]` (rows of `name` / `description` / `scope` / `path`),
  `truncated`, `next_offset`, `hint`. Backend renderer lives in
  `src/agentic_loop/skills_search.zig`; ChatView passes the inner body here
  via `innerToolData` and `parseSearchSkills` reads it (see
  `_shared/toolOutputParser.ts`).

  Header (always visible): `search_skills · "<query>" · <count>/<total> skills`
  plus the next offset when the page was truncated.
  Expanded body: a FLAT row list — the per-row `scope` badge replaces the
  old global/local sections — then the pattern warning, and finally the
  backend hint (which names the offset for the next page).

  Unrelated to the agent tool: the `/skills` HTTP endpoint still returns the
  legacy `global_skills` / `local_skills` object and still powers the Skills
  settings sidebar (`api.listSkills`, `SkillList.vue`,
  `RightSideBarSkillList.vue`). Do not route it through this card.

  Style matches the other tool_outputs cards: monospace, violet tool name,
  muted meta, expand/collapse indicator, CSS vars only (no literal colours).
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent, parseSearchSkills } from './_shared/toolOutputParser'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). Surfaced via the
   *  shared <ToolParameters> block in the expanded body; empty/'{}'
   *  renders nothing (see ToolParameters.vue hasArgs guard). */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => parseSearchSkills(normalized.value.data))

const skills = computed(() => parsed.value.skills)
const hasSkills = computed(() => skills.value.length > 0)
const query = computed(() => parsed.value.query)
const isEmptyQuery = computed(() => query.value.trim() === '')

const patternWarning = computed(() => parsed.value.patternWarning)
const hint = computed(() => parsed.value.hint)
const truncated = computed(() => parsed.value.truncated)
const nextOffset = computed(() => parsed.value.nextOffset)

/** Paging facts in `search_tool`'s convention: this page's rows against the
 *  pre-paging total, so a truncated page reads `50/120 skills`. */
const countLabel = computed(() => {
  const rows = skills.value.length
  const total = parsed.value.total
  const noun = `skill${total === 1 ? '' : 's'}`
  return total > rows ? `${rows}/${total} ${noun}` : `${rows} ${noun}`
})

const metaLabel = computed(() => {
  if (!truncated.value || nextOffset.value === null) return countLabel.value
  return `${countLabel.value} · next offset ${nextOffset.value}`
})

/** Full paging context for the header's tooltip (and for copy/paste). */
const headerTitle = computed(() => {
  const p = parsed.value
  const bits: string[] = [
    p.query ? `query: ${p.query}` : 'query: (empty — every skill)',
    p.patternMode ? `mode: ${p.patternMode}` : 'mode: —',
    p.scope ? `scope: ${p.scope}` : 'scope: global + local',
    `offset: ${p.offset ?? 0} · limit: ${p.limit ?? '—'}`,
  ]
  if (p.nextOffset !== null) bits.push(`next offset: ${p.nextOffset}`)
  return bits.join('  ·  ')
})

/**
 * "Nothing matched this query" and "no skills are installed at all" are
 * different facts and collapse into one row count, so branch on whether the
 * query was empty.
 */
const emptyMessage = computed(() =>
  isEmptyQuery.value
    ? 'No skills installed — nothing to list.'
    : `No skills match "${query.value}".`,
)

const toggle = () => {
  isExpanded.value = !isExpanded.value
}

const copySkillName = async (e: Event, name: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(name)
}
</script>

<template>
  <div class="chat-tool-card font-mono text-dense" data-testid="search-skills">
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense">search_skills</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-dense"
        :title="headerTitle"
        data-testid="search-skills-meta"
      >
        <template v-if="query">"{{ query }}" · </template>{{ metaLabel }}
      </span>

      <!-- Toggle indicator -->
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-body">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Pattern warning: the query was reinterpreted as a literal, or the
           match engine ran out of budget. Always worth surfacing: the model
           otherwise reads a literal fallback as a real regex result. -->
      <div
        v-if="patternWarning"
        class="px-3 py-1 text-micro text-[var(--semantic-text-muted)] border-b border-dashed border-[var(--color-border)]"
        data-testid="search-skills-warning"
      >
        <span class="font-semibold">Pattern:</span>
        <span class="whitespace-pre-wrap break-words">{{ patternWarning }}</span>
      </div>

      <!-- Empty state -->
      <div
        v-if="!hasSkills"
        class="px-3 py-4 text-center text-[var(--semantic-text-muted)] text-dense"
        data-testid="search-skills-empty"
      >
        {{ emptyMessage }}
      </div>

      <!-- One flat list — global/local is now a per-row badge, not a section -->
      <div v-else class="px-2 py-1 space-y-1">
        <div
          v-for="skill in skills"
          :key="`${skill.scope}-${skill.path}-${skill.name}`"
          class="flex items-start gap-2 py-1 px-1 rounded hover:bg-violet-500/5 group"
          data-testid="search-skills-row"
        >
          <span class="text-[var(--color-violet)] mt-0.5 shrink-0">-</span>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-1">
              <span class="text-[var(--semantic-text)] font-medium truncate">{{ skill.name }}</span>
              <span
                v-if="skill.scope"
                class="text-micro px-1 rounded shrink-0"
                :class="
                  skill.scope === 'local'
                    ? 'bg-green-500/10 text-green-500'
                    : 'bg-violet-500/10 text-violet-500'
                "
                data-testid="search-skills-scope"
                >{{ skill.scope }}</span
              >
              <button
                class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-dense transition-opacity shrink-0"
                @click.stop="copySkillName($event, skill.name)"
                title="Copy skill name"
              >
                ⎘
              </button>
            </div>
            <p
              v-if="skill.description"
              class="text-micro text-[var(--semantic-text-muted)] line-clamp-2 mt-0.5"
            >
              {{ skill.description }}
            </p>
            <p v-if="skill.path" class="text-micro text-[var(--semantic-text-dim)] mt-0.5 truncate">
              {{ skill.path }}
            </p>
          </div>
        </div>
      </div>

      <!-- Backend hint. When the page was truncated it names the offset to
           pass for the next one. -->
      <div
        v-if="hint"
        class="px-3 py-1 text-micro text-[var(--semantic-text-muted)] border-t border-dashed border-[var(--color-border)]"
        data-testid="search-skills-hint"
      >
        <span class="font-semibold">Hint:</span>
        <span class="whitespace-pre-wrap break-words">{{ hint }}</span>
      </div>

      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>

<style scoped>
.line-clamp-2 {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
</style>
