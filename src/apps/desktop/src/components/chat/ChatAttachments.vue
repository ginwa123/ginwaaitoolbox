<script setup lang="ts">
/**
 * The attachment strip on a user turn: one fixed-size thumbnail per attached
 * image, one player per attached clip, click an image to open the lightbox.
 *
 * Extracted from `ChatView.vue` so the `src` binding is reachable by a mount
 * test. The block used to live inline in ChatView's 4000-line template, which
 * cannot render its transcript in jsdom (VirtualScroller needs real layout
 * measurements), so the one thing that actually breaks — a thumbnail bound to
 * `:src=""` — had no test that could reach it. That is how a
 * `||`-joined wire value went on rendering a broken-image icon for years.
 *
 * The `src` never comes straight from the caller: `renderableMediaUrls`
 * drops blanks, so an empty or whitespace-only entry never reaches `:src`
 * however the list was produced.
 */
import { renderableMediaUrls } from '../../helpers/mediaUrls'

defineProps<{
  imageUrls?: string[]
  videoUrls?: string[]
}>()

const emit = defineEmits<{
  (e: 'open-image', url: string): void
}>()
</script>

<template>
  <div class="mb-2">
    <div class="flex flex-wrap gap-2">
      <div
        v-for="(imgUrl, imgIdx) in renderableMediaUrls(imageUrls)"
        :key="`img-${imgIdx}`"
        class="chat-attached-image-thumb"
        @click="emit('open-image', imgUrl)"
      >
        <img
          :src="imgUrl"
          alt="Attached image"
          width="80"
          height="80"
          class="chat-attached-image-img"
        />
      </div>
      <div
        v-for="(vidUrl, vidIdx) in renderableMediaUrls(videoUrls)"
        :key="`vid-${vidIdx}`"
        class="chat-attached-image-thumb"
      >
        <video
          :src="vidUrl"
          width="160"
          class="chat-attached-image-img"
          controls
          preload="metadata"
        />
      </div>
    </div>
  </div>
</template>
