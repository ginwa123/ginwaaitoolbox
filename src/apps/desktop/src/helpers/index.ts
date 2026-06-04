export { stripThinkingTags, getThinkingTags, isThinkingTags } from "./stripTags";
export { default as VirtualScroller } from "./VirtualScroller.vue";
export { formatRelativeTime } from "./relativeTime";
export {
  createScrollLogger,
  buildScrollContext,
  BOTTOM_THRESHOLD,
  TOP_THRESHOLD,
  markProgrammatic,
} from "./scrollLogger";
export type {
  ScrollContext,
  ScrollLogger,
  ScrollOrigin,
  ScrollReason,
  ContainerInfo,
} from "./scrollLogger";
export { isAutoStickActive, AUTO_STICK_GATE_MS } from "./autoStickGate";

