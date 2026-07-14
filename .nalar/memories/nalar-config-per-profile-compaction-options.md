# nalar — Config per-profile compaction options (the option 1 vs option 2 decision)

When adding new configurable settings to `LlmConfig`, the user can choose
between two architectural shapes. The decision was made on
2026-07-06 during the `feature/config-compact` work for the
`max_capacity_tokens` + `compaction_threshold_percent` settings.

## Option 1 — Top-level on `LlmConfig`

Both fields live on the top-level `LlmConfig` struct (NOT on `LlmProfile`).
The HTTP wire format exposes them as top-level keys in `GET/PUT
/api/config/nalar`. The frontend renders ONE input row for the whole
config (the `CompactionSection.vue` shape shipped in commit `78e3656e`).

**Pros:**
- Simpler resolver: `cfg.maxCapacityForModel(model)` — no profile/sub-agent
  cascade. No "which profile am I editing?" question.
- Matches `model_compaction_size_kb` (the existing precedent: a global
  knob that applies to every chat regardless of profile).

**Cons:**
- Loses the per-profile override. A user with a "dev" profile that uses
  a self-hosted 32k-window model AND a "prod" profile that uses
  MiniMax-M3 (500k default) cannot give them different compaction
  thresholds.
- The single top-level field becomes ambiguous when multiple profiles
  exist: which profile does it apply to?

## Option 2 — Per-profile on `LlmProfile`

Both fields live on `LlmProfile`. Sub-agents inherit from the parent
profile unless they override (SubAgentConfig gets the same two fields
with default `null`). The HTTP wire format removes the top-level keys
and the `profiles` map (already in `NalarConfigResponse`) carries the
new fields through. The frontend iterates profiles and renders one
row per profile.

**Pros:**
- Per-profile override for free. Sub-agent cascade for free.
- Every profile knows its compaction settings (matches the mental model
  "a profile bundles model + endpoint + compaction policy").
- Future-proof: when more per-profile knobs land (e.g. per-profile
  `temperature`, per-profile `max_tokens` defaults), they all live in
  the same struct.

**Cons:**
- Resolver signature grows: `maxCapacityForModel(profile, sub_agent, model)`
  instead of `maxCapacityForModel(model)`. Call sites that don't have
  a profile/sub-agent in scope must pass `null, null`.
- Frontend UI is more code (one row per profile, plus save logic that
  sends a whole profiles map).

## The user's choice (option 2)

> "because it is much easy to configure, and every profile will have
> a [compaction_setting] ..."

Reasoning:
- Every profile needs its own context window (the self-hosted model has
  a different window than MiniMax-M3). Putting the field on the
  profile keeps the model + window bundled together — no "where do I
  set this for the dev profile?" hunt.
- The per-profile map shape is already there for `model` and
  `base_url`; adding two more keys to it is incremental. The top-level
  shape would require a NEW top-level map keyed by profile name
  (a 1:1 mirror of `profiles_models`), doubling the API surface.

## How the choice was decided

The user said "i choose option 2 i think" — tentative phrasing, then
followed by reasoning ("because it is much easy to configure"). The
small "i think" hedge was acknowledged but not re-litigated; the
reasoning was clear and the trade-offs were well-understood.

If you face a similar "top-level vs per-profile" decision in the future,
**default to per-profile** unless there's a strong reason (e.g. global
hard limit like `model_compaction_size_kb`). The cost of migration
back to top-level is high (every test, every UI element, every HTTP
field).

## How Chunk 7 landed

Branch: `worktree/config-compact` (PR #81).
Commits: `ccaca0d7` (plan + status) → `49c19739` (implementation).
Test count: 991/994 pass, 0 regressions vs the 990 baseline.
Plan file: `docs/superpowers/plans/2026-07-06-configurable-compaction.md` Chunk 7.
Tasks 7.1-7.5 done in commit `49c19739`. Tasks 7.6 (frontend
CompactionSection.vue rewrite) and 7.7 (smoke test) remain.

## Reshape-vs-partial-state decision

The first attempt at option 2 modified `Config.zig` (removed top-level
fields, added per-profile fields) but didn't update the downstream
consumers (workflow.zig, http_response.zig, nalar_config_get.zig,
nalar_config_put.zig, 3 test files). This left the build broken with
~8 compile errors and no clear path to land the change incrementally.

**Decision:** revert the partial state to keep the build green, then
write a dedicated Chunk 7 plan capturing the full reshape (Tasks
7.1-7.7 across 12 files), then execute the chunk in one focused pass.

The "fix the partial state" approach was slower than "rewrite from
scratch with a plan" because:
1. Each consumer had a different signature change (cascading edits).
2. Tests needed to be rewritten alongside the code (not added
   incrementally).
3. The frontend UI change is large enough that it needs its own chunk
   (Task 7.6) rather than being interleaved with backend changes.

**General lesson:** when the user makes an architectural decision that
inverts a substantial portion of an already-shipped feature, DON'T
try to land it as a series of "fix the partial state" edits. Instead,
revert, plan, and execute as a single focused chunk. The plan is the
deliverable that captures the WHY for the next agent; the partial
state is a distraction.