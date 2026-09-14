export {
  stripThinkingTags,
  getThinkingTags,
  isThinkingTags,
  getHtmlTags,
  isHtmlTags,
} from "./stripTags";
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
export { renderResponse } from "./renderResponse";
export {
  SEARCH_URL_TEMPLATE,
  normalizeAddressInput,
  isHttpUrl,
  hostOf,
  browserTabTitle,
} from "./browserUrl";
export type { AddressResult } from "./browserUrl";
export {
  PREVIEW_AUTO_RESIZE_SOURCE,
  CHAT_HTML_FRAME_RESIZE_SOURCE,
  MIN_FRAME_HEIGHT,
  MAX_FRAME_HEIGHT,
  clampFrameHeight,
  readAutoResizeHeight,
  findSenderFrame,
  autoResizeScript,
  PREVIEW_AUTO_RESIZE_SCRIPT,
} from "./iframeAutoResize";

