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
  background: var(--color-bg-p1);
}

.diffview-section {
  flex: 1;
  overflow: hidden;
}

.diffview-section:last-child {
  border-left: 1px solid var(--color-border);
}

.diffview-section-label {
  padding: 4px 8px;
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
  background: rgba(0,0,0,0.2);
  border-bottom: 1px solid var(--color-border);
}

.diffview-section-content {
  overflow-x: auto;
  font-family: var(--font-mono);
  font-size: 11px;
  line-height: 1.5;
}

.diffview-line {
  display: flex;
  min-width: max-content;
  padding: 0 8px;
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
  margin-right: 4px;
  font-weight: 600;
  flex-shrink: 0;
}

.diffview-line-content {
  flex-shrink: 0;
}

.diffview-line-removed .diffview-line-content,
.diffview-line-added .diffview-line-content {
  color: inherit;
}
</style>