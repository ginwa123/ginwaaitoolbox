<script setup lang="ts">
import type { SkillInfo } from '../../api'

const props = defineProps<{
  show: boolean
  skills: SkillInfo[]
  sessionCwd?: string
}>()

const emit = defineEmits<{
  close: []
  'skill-click': [skill: SkillInfo]
}>()

const handleClose = () => {
  emit('close')
}

const handleSkillClick = (skill: SkillInfo) => {
  emit('skill-click', skill)
}

const formatDate = (ts: number | undefined): string => {
  if (!ts) return 'Unknown'
  return new Date(ts * 1000).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit'
  })
}
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 bg-black/60 backdrop-blur-sm"
          @click="handleClose"
        />

        <!-- Modal Content -->
        <div
          class="relative w-full max-w-md mx-4 max-h-[80vh] flex flex-col rounded-xl shadow-2xl"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <!-- Header -->
          <div
            class="flex items-center justify-between px-5 py-4 shrink-0"
            style="border-bottom: 1px solid var(--color-border);"
          >
            <div class="flex items-center gap-2">
              <span class="text-xl">🧠</span>
              <h3
                class="text-base font-semibold"
                style="color: var(--semantic-text);"
              >
                Loaded Skills
              </h3>
              <span
                class="px-2 py-0.5 text-xs rounded-full"
                style="background-color: var(--semantic-active-bg); color: var(--semantic-text-dim);"
              >
                {{ skills.length }}
              </span>
            </div>
            <button
              @click="handleClose"
              class="p-1.5 rounded-lg transition-colors hover:opacity-70"
              style="color: var(--semantic-text-dim);"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <!-- Skills List -->
          <div class="flex-1 overflow-y-auto p-3">
            <div v-if="skills.length === 0" class="text-center py-8">
              <span class="text-3xl mb-2 block">📭</span>
              <p class="text-sm" style="color: var(--semantic-text-dim);">
                No skills loaded for this session
              </p>
            </div>

            <div v-else class="space-y-2">
              <button
                v-for="skill in skills"
                :key="skill.skill_name"
                @click="handleSkillClick(skill)"
                class="w-full text-left p-3 rounded-lg transition-all duration-200 hover:scale-[1.01]"
                style="background-color: var(--semantic-active-bg); border: 1px solid var(--color-border);"
              >
                <div class="flex items-start gap-3">
                  <span class="text-xl mt-0.5">📜</span>
                  <div class="flex-1 min-w-0">
                    <h4
                      class="text-sm font-medium truncate"
                      style="color: var(--semantic-text);"
                    >
                      {{ skill.skill_name }}
                    </h4>
                    <p
                      v-if="skill.loaded_at"
                      class="text-xs mt-0.5"
                      style="color: var(--semantic-text-dim);"
                    >
                      Loaded: {{ formatDate(skill.loaded_at) }}
                    </p>
                    <p
                      class="text-xs mt-1 line-clamp-2"
                      style="color: var(--semantic-text-dim);"
                    >
                      {{ skill.content?.substring(0, 150) }}{{ skill.content?.length > 150 ? '...' : '' }}
                    </p>
                  </div>
                  <svg
                    class="w-4 h-4 mt-1 shrink-0"
                    style="color: var(--semantic-text-dim);"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
                  </svg>
                </div>
              </button>
            </div>
          </div>

          <!-- Footer -->
          <div
            v-if="sessionCwd"
            class="px-5 py-3 shrink-0 text-xs"
            style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim);"
          >
            Session working directory: {{ sessionCwd }}
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.modal-enter-active,
.modal-leave-active {
  transition: opacity 0.2s ease;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-active > div:last-child,
.modal-leave-active > div:last-child {
  transition: transform 0.2s ease;
}

.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child {
  transform: scale(0.95);
}
</style>