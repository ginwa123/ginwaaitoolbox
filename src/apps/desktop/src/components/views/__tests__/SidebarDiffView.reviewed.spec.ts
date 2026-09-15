/**
 * Reviewed-lines markers on the sidebar diff.
 * - listSavedCommentRanges() scans localStorage for saved comment ranges
 * - SidebarDiffView renders a marker on covered add/remove rows only,
 *   clicking a marked row reopens the box with the saved draft, and the
 *   save flow adds markers without a remount.
 */
import { describe, expect, it, beforeEach } from "vitest";
import { mount, flushPromises } from "@vue/test-utils";
import SidebarDiffView from "../chat_right_sidebar/SidebarDiffView.vue";
import DiffCommentBox, {
  buildDraftKey,
  listSavedCommentRanges,
} from "../chat_right_sidebar/DiffCommentBox.vue";
import type { ParsedDiffLine } from "../chat_right_sidebar/parseUnifiedDiff";
import { makeLocalStorageStub } from "../../../__tests__/helpers";

const CWD = "/repo";
const PATH = "src/reviewed.ts";

// Lines spanning 17-30. Covered add/remove rows (20, 21, 22, 24, 26)
// fall inside the seeded 20-26 range; 28/29 sit outside it; context
// rows never get markers even when their number is in range.
const LINES: ParsedDiffLine[] = [
  { type: "hunk", content: "@@ -17,14 +17,14 @@", lineIndex: 0 },
  { type: "context", content: "ctx-17", oldLineNum: 17, newLineNum: 17, lineIndex: 1 },
  { type: "context", content: "ctx-18", oldLineNum: 18, newLineNum: 18, lineIndex: 2 },
  { type: "context", content: "ctx-19", oldLineNum: 19, newLineNum: 19, lineIndex: 3 },
  { type: "remove", content: "old-20", oldLineNum: 20, lineIndex: 4 },
  { type: "add", content: "new-21", newLineNum: 21, lineIndex: 5 },
  { type: "add", content: "new-22", newLineNum: 22, lineIndex: 6 },
  { type: "context", content: "ctx-23", oldLineNum: 23, newLineNum: 23, lineIndex: 7 },
  { type: "remove", content: "old-24", oldLineNum: 24, lineIndex: 8 },
  { type: "context", content: "ctx-25", oldLineNum: 25, newLineNum: 25, lineIndex: 9 },
  { type: "add", content: "new-26", newLineNum: 26, lineIndex: 10 },
  { type: "context", content: "ctx-27", oldLineNum: 27, newLineNum: 27, lineIndex: 11 },
  { type: "add", content: "new-28", newLineNum: 28, lineIndex: 12 },
  { type: "remove", content: "old-29", oldLineNum: 29, lineIndex: 13 },
  { type: "context", content: "ctx-30", oldLineNum: 30, newLineNum: 30, lineIndex: 14 },
];

function installStorage(): void {
  Object.defineProperty(globalThis, "localStorage", {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  });
}

function seed(cwd: string, path: string, start: number, end: number, message: string): void {
  localStorage.setItem(
    buildDraftKey(cwd, path, start, end),
    JSON.stringify({ message, savedAt: 1 }),
  );
}

function mountView() {
  return mount(SidebarDiffView, {
    props: {
      path: PATH,
      lines: LINES,
      added: 4,
      removed: 3,
      staged: false,
      loading: false,
      error: null,
      cwd: CWD,
    },
  });
}

function rowByText(wrapper: ReturnType<typeof mountView>, text: string) {
  const row = wrapper.findAll("tr").find((r) => r.text().includes(text));
  expect(row, `expected a row containing ${text}`).toBeTruthy();
  return row!;
}

beforeEach(() => {
  installStorage();
});

describe("listSavedCommentRanges", () => {
  it("returns ranges with non-empty messages", () => {
    seed(CWD, PATH, 20, 26, "looks good");
    expect(listSavedCommentRanges(CWD, PATH)).toEqual([{ start: 20, end: 26 }]);
  });

  it("isolates by cwd and file path prefix", () => {
    seed(CWD, PATH, 20, 26, "mine");
    seed(CWD, "src/other.ts", 20, 26, "other file");
    seed("/elsewhere", PATH, 20, 26, "other cwd");
    seed(CWD, "src/reviewed.ts.bak", 1, 5, "prefix lookalike");
    expect(listSavedCommentRanges(CWD, PATH)).toEqual([{ start: 20, end: 26 }]);
  });

  it("ignores garbage keys", () => {
    const prefix = `diff-comment:${CWD}:${PATH}:`;
    localStorage.setItem(`${prefix}abc`, JSON.stringify({ message: "x" }));
    localStorage.setItem(`${prefix}10-`, JSON.stringify({ message: "x" }));
    localStorage.setItem(`${prefix}-14`, JSON.stringify({ message: "x" }));
    localStorage.setItem(`${prefix}10-14-extra`, JSON.stringify({ message: "x" }));
    localStorage.setItem(`${prefix}10-x`, JSON.stringify({ message: "x" }));
    localStorage.setItem("unrelated-key", JSON.stringify({ message: "x" }));
    expect(listSavedCommentRanges(CWD, PATH)).toEqual([]);
  });

  it("excludes empty messages but keeps legacy raw-string values", () => {
    const prefix = `diff-comment:${CWD}:${PATH}:`;
    localStorage.setItem(`${prefix}1-2`, JSON.stringify({ message: "" }));
    localStorage.setItem(`${prefix}3-4`, JSON.stringify({ message: 42 }));
    localStorage.setItem(`${prefix}5-6`, "not json at all");
    localStorage.setItem(`${prefix}7-8`, "");
    expect(listSavedCommentRanges(CWD, PATH)).toEqual([{ start: 5, end: 6 }]);
  });

  it("never throws when storage is unavailable", () => {
    Object.defineProperty(globalThis, "localStorage", {
      value: {
        get length(): number {
          throw new Error("denied");
        },
        clear: () => {},
        getItem: () => null,
        key: () => null,
        removeItem: () => {},
        setItem: () => {},
      },
      writable: true,
      configurable: true,
    });
    expect(listSavedCommentRanges(CWD, PATH)).toEqual([]);
  });
});

describe("SidebarDiffView reviewed markers", () => {
  it("marks exactly the covered add/remove rows", () => {
    seed(CWD, PATH, 20, 26, "reviewed twenty to twenty-six");
    const wrapper = mountView();
    const markers = wrapper.findAll('[data-testid="diff-reviewed-marker"]');
    expect(markers).toHaveLength(5);
    for (const text of ["old-20", "new-21", "new-22", "old-24", "new-26"]) {
      expect(rowByText(wrapper, text).find('[data-testid="diff-reviewed-marker"]').exists()).toBe(
        true,
      );
    }
    for (const text of ["new-28", "old-29", "ctx-23", "ctx-25", "ctx-19"]) {
      expect(rowByText(wrapper, text).find('[data-testid="diff-reviewed-marker"]').exists()).toBe(
        false,
      );
    }
  });

  it("clicking a marked row reopens the box with the saved draft", async () => {
    // Clicking new-22 opens a +-3 context window over rows 3..9, i.e.
    // lines 19-25 — seed that deterministic key so the draft reloads.
    seed(CWD, PATH, 20, 26, "reviewed twenty to twenty-six");
    seed(CWD, PATH, 19, 25, "window draft nineteen twenty-five");
    const wrapper = mountView();
    await rowByText(wrapper, "new-22").trigger("click");
    await flushPromises();
    const box = wrapper.findComponent(DiffCommentBox);
    expect(box.exists()).toBe(true);
    expect(box.props("startLine")).toBe(19);
    expect(box.props("endLine")).toBe(25);
    expect(
      (box.get("[data-testid=diff-comment-input]").element as HTMLTextAreaElement).value,
    ).toBe("window draft nineteen twenty-five");
  });

  it("save flow adds a marker without remount", async () => {
    seed(CWD, PATH, 20, 26, "reviewed twenty to twenty-six");
    const wrapper = mountView();
    expect(
      rowByText(wrapper, "new-28").find('[data-testid="diff-reviewed-marker"]').exists(),
    ).toBe(false);
    await rowByText(wrapper, "new-28").trigger("click");
    await flushPromises();
    const box = wrapper.findComponent(DiffCommentBox);
    expect(box.exists()).toBe(true);
    await box.get("[data-testid=diff-comment-input]").setValue("fresh note 28");
    await box.get("[data-testid=diff-comment-save]").trigger("click");
    await flushPromises();
    expect(wrapper.emitted("comment-saved")).toHaveLength(1);
    expect(
      rowByText(wrapper, "new-28").find('[data-testid="diff-reviewed-marker"]').exists(),
    ).toBe(true);
  });
});
