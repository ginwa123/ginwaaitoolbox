<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
/**
 * The app's first page: what Nalar is.
 *
 * Deliberately inert — no composer, no buttons, no lists. Starting work is the
 * sidebar's job (`+ New Chat`, or a workspace item), and the hint line says so.
 * The previous version faked a single assistant turn with a live timestamp,
 * which read as a real reply that could not be answered; the scope guards in
 * `ChatsLanding.spec.ts` keep both that message and any form control out.
 *
 * Spec: docs/superpowers/specs/2026-09-13-home-landing-design.md
 */
</script>

<template>
  <div
    data-testid="home-landing"
    class="flex flex-col items-center justify-center h-full px-6 text-center"
  >
    <span class="text-3xl leading-none" style="color: var(--color-violet)" aria-hidden="true">✦</span>

    <h1
      data-testid="home-wordmark"
      class="mt-4 text-4xl font-semibold tracking-tight"
      style="color: var(--semantic-text)"
    >
      nalar
    </h1>

    <p
      data-testid="home-tagline"
      class="mt-2 text-xs uppercase"
      style="color: var(--semantic-text-muted); letter-spacing: 0.2em"
    >
      AI agent workspace
    </p>

    <p
      data-testid="home-blurb"
      class="mt-6 max-w-[520px] text-sm leading-relaxed"
      style="color: var(--semantic-text-muted)"
    >
      Nalar is an AI agent workspace. It runs your own model against real files: chat with it, break
      the work into kanban tasks, or design in a canvas — with the tools you attach.
    </p>

    <p class="mt-10 text-xs" style="color: var(--semantic-text-dim)">
      Open a chat in the sidebar, or start a new one.
    </p>
  </div>
</template>
