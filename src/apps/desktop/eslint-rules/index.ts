/**
 * The banned-code plugin. Registered in `eslint.config.ts` as `local/…`.
 *
 * Keep the ban list and the enforcement in one place: if a rule exists here,
 * it is documented in `docs/vue-ts-banned-code.md`, and if a pattern is
 * documented there as banned, some rule or ratchet enforces it.
 */
import type { Rule } from 'eslint'
import { noDerivedStateWatch } from './bannedCode'
import { noSilentFallbackCatch } from './noSilentFallbackCatch'
import { noWatchEffect } from './noWatchEffect'

const rules: Record<string, Rule.RuleModule> = {
  'no-derived-state-watch': noDerivedStateWatch,
  'no-silent-fallback-catch': noSilentFallbackCatch,
  'no-watch-effect': noWatchEffect,
}

const plugin = { rules }

export default plugin
