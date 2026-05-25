<script setup lang="ts">
import { computed } from 'vue'

interface Props {
  before: string
  after: string
}

const props = defineProps<Props>()

const beforeLines = computed(() => props.before.split('\n'))
const afterLines = computed(() => props.after.split('\n'))

const isLineChanged = (idx: number): boolean => {
  return beforeLines.value[idx] !== afterLines.value[idx]
}
</script>

<template>
  <div class="diffview-container">
    <div class="diffview-section">
      <div class="diffview-section-label" style="color: var(--color-red);">Before</div>
      <div class="diffview-section-content">
        <div v-for="(line, idx) in beforeLines" :key="'b'+idx" class="diffview-line" :class="isLineChanged(idx) ? 'diffview-line-removed' : ''">
          <span class="diffview-line-prefix">-</span><span class="diffview-line-content">{{ line }}</span>
        </div>
      </div>
    </div>
    <div class="diffview-divider"></div>
    <div class="diffview-section">
      <div class="diffview-section-label" style="color: var(--color-green);">After</div>
      <div class="diffview-section-content">
        <div v-for="(line, idx) in afterLines" :key="'a'+idx" class="diffview-line" :class="isLineChanged(idx) ? 'diffview-line-added' : ''">
          <span class="diffview-line-prefix">+</span><span class="diffview-line-content">{{ line }}</span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.diffview-container {
  display: flex;
  border: 1px solid var(--color-border);
  border-radius: 6px;
  overflow: hidden;
  background: var(--semantic-card-bg);
}

.diffview-section {
  flex: 1;
  overflow: hidden;
}

.diffview-section:last-child {
  border-left: 1px solid var(--color-border);
}

.diffview-section-label {
  padding: 0.25rem 0.5rem;
  font-size: 0.7rem;
  font-weight: 600;
  text-transform: uppercase;
  background: rgba(0,0,0,0.02);
  border-bottom: 1px solid var(--color-border);
}

.diffview-section-label:hover {
  background: rgba(139, 92, 246, 0.04);
}

.diffview-section-content {
  overflow-x: auto;
  font-family: monospace;
  font-size: 0.72rem;
  line-height: 1.5;
}

.diffview-line {
  display: flex;
  min-width: max-content;
  padding: 0.125rem 0.5rem;
  white-space: pre;
}

.diffview-line-removed {
  background: rgba(196, 116, 110, 0.15);
  color: var(--color-red);
}

.diffview-line-added {
  background: rgba(135, 169, 135, 0.15);
  color: var(--color-green);
}

.diffview-line-prefix {
  margin-right: 0.75rem;
  font-weight: 600;
  flex-shrink: 0;
  min-width: 1rem;
  text-align: center;
}

.diffview-line-content {
  flex-shrink: 0;
}

.diffview-line-removed .diffview-line-content,
.diffview-line-added .diffview-line-content {
  color: inherit;
}

.diffview-line:hover {
  background: rgba(139, 92, 246, 0.04);
}

.diffview-line-removed:hover {
  background: rgba(196, 116, 110, 0.2);
}

.diffview-line-added:hover {
  background: rgba(135, 169, 135, 0.2);
}
</style>