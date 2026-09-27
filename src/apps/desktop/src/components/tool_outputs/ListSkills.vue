<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent, parseListSkills, type ParsedSkill } from './_shared/toolOutputParser'

/** The shared parser shape plus the split tags the template renders. */
interface SkillRow extends Omit<ParsedSkill, 'tags'> {
  tagList: string[]
}

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
const parsed = computed(() => parseListSkills(normalized.value.data))

// Tags arrive '||'-joined (the agent_memories convention); '' means the
// skill's frontmatter carried no tags line, not a tag with no name.
const withTags = (skills: ParsedSkill[]): SkillRow[] =>
  skills.map(({ tags, ...skill }) => ({
    ...skill,
    tagList: tags
      .split('||')
      .map((t) => t.trim())
      .filter((t) => t !== ''),
  }))

// Parse global skills
const globalSkills = computed(() => withTags(parsed.value.globalSkills))

// Parse local skills
const localSkills = computed(() => withTags(parsed.value.localSkills))

// Total count
const totalCount = computed(() => parsed.value.totalCount)

// Has any skills
const hasSkills = computed(() => totalCount.value > 0)

const toggle = () => {
  isExpanded.value = !isExpanded.value
}

const copySkillName = async (e: Event, name: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(name)
}
</script>

<template>
  <div 
    class="chat-tool-card font-mono text-xs"
  >
    <!-- Header -->
    <div 
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">list_skills</span>
      <span class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-xs">
        {{ totalCount }} skill{{ totalCount !== 1 ? 's' : '' }} found
      </span>
      
      <!-- Toggle indicator -->
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Empty state -->
      <div v-if="!hasSkills" class="px-3 py-4 text-center text-[var(--semantic-text-muted)] text-xs">
        No skills available
      </div>

      <!-- Global Skills Section -->
      <div v-if="globalSkills.length > 0" class="py-1">
        <div class="px-3 py-0.5 text-[0.65rem] text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] border-b border-dashed border-[var(--color-border)]">
          Global Skills ({{ globalSkills.length }})
        </div>
        <div class="px-2 py-1 space-y-1">
          <div 
            v-for="skill in globalSkills" 
            :key="'global-' + skill.name"
            class="flex items-start gap-2 py-1 px-1 rounded hover:bg-violet-500/5 group"
          >
            <span class="text-[var(--color-violet)] mt-0.5 shrink-0">-</span>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-1">
                <span class="text-[var(--semantic-text)] font-medium truncate">{{ skill.name }}</span>
                <button 
                  class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-xs transition-opacity shrink-0"
                  @click.stop="copySkillName($event, skill.name)"
                  title="Copy skill name"
                >
                  ⎘
                </button>
              </div>
              <p class="text-[0.65rem] text-[var(--semantic-text-muted)] line-clamp-2 mt-0.5">
                {{ skill.description }}
              </p>
              <div
                v-if="skill.tagList.length > 0"
                class="flex flex-wrap gap-1 mt-1"
                data-testid="list-skill-tags"
              >
                <span
                  v-for="tag in skill.tagList"
                  :key="tag"
                  class="inline-block px-1.5 py-0.5 bg-violet-500/10 text-[var(--color-violet)] rounded text-[0.6rem]"
                >
                  {{ tag }}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Local Skills Section -->
      <div v-if="localSkills.length > 0" class="py-1 border-t border-dashed border-[var(--color-border)]">
        <div class="px-3 py-0.5 text-[0.65rem] text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] border-b border-dashed border-[var(--color-border)]">
          Local Skills ({{ localSkills.length }})
        </div>
        <div class="px-2 py-1 space-y-1">
          <div 
            v-for="skill in localSkills" 
            :key="'local-' + skill.name"
            class="flex items-start gap-2 py-1 px-1 rounded hover:bg-violet-500/5 group"
          >
            <span class="text-[var(--color-violet)] mt-0.5 shrink-0">-</span>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-1">
                <span class="text-[var(--semantic-text)] font-medium truncate">{{ skill.name }}</span>
                <button 
                  class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-xs transition-opacity shrink-0"
                  @click.stop="copySkillName($event, skill.name)"
                  title="Copy skill name"
                >
                  ⎘
                </button>
              </div>
              <p class="text-[0.65rem] text-[var(--semantic-text-muted)] line-clamp-2 mt-0.5">
                {{ skill.description }}
              </p>
              <div
                v-if="skill.tagList.length > 0"
                class="flex flex-wrap gap-1 mt-1"
                data-testid="list-skill-tags"
              >
                <span
                  v-for="tag in skill.tagList"
                  :key="tag"
                  class="inline-block px-1.5 py-0.5 bg-violet-500/10 text-[var(--color-violet)] rounded text-[0.6rem]"
                >
                  {{ tag }}
                </span>
              </div>
              <p v-if="skill.path" class="text-[0.6rem] text-[var(--semantic-text-dim)] mt-0.5 truncate">
                {{ skill.path }}
              </p>
            </div>
          </div>
        </div>
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
