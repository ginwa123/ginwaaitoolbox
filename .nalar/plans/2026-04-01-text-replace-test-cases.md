# Plan: Add Text Replace Test Cases Based on Failure Patterns

## Goal
Add comprehensive test cases for `text_replace` tool based on real-world failure patterns from database history.

## Failure Patterns Identified

### 1. **OldStrNotUnique (DUPLICATE PATTERNS)** ⚠️ HIGH PRIORITY
- Multiple text_replace attempts with same `old_str` in same file
- **Root cause:** Users don't provide enough context for uniqueness
- **Test needed:** Verify correct behavior when old_str appears multiple times

### 2. **Escape Sequence Issues** ⚠️ MEDIUM PRIORITY
- Failed patterns like `'\\\\.'` vs `\\.` 
- **Root cause:** JSON/Zig string escaping confusion
- **Test needed:** Test patterns with backslashes, special regex-like chars

### 3. **Whitespace Sensitivity** ⚠️ MEDIUM PRIORITY
- Some multiline replacements failed due to whitespace/newline differences
- **Root cause:** Tab vs space, trailing whitespace
- **Test needed:** Test whitespace edge cases

### 4. **Special Character Edge Cases** ⚠️ MEDIUM PRIORITY
- Patterns containing `[`, `]`, `*`, `?` (regex-like syntax)
- **Test needed:** Test special characters that might have special meaning

---

## Test Cases to Implement

### Category 1: Duplicate Detection (OldStrNotUnique)
```zig
test "text_replace - OldStrNotUnique with 3+ occurrences" {
    // File has same pattern 3 times -> should return OldStrNotUnique
}

test "text_replace - OldStrNotUnique at different positions" {
    // Same pattern at start, middle, end of file -> should fail
}

test "text_replace - OldStrNotUnique adjacent occurrences" {
    // "aaa" appears overlapping -> should fail
}

test "text_replace - uniqueness with surrounding context" {
    // Add context to make pattern unique -> should succeed
}
```

### Category 2: Error Handling (OldStrNotFound)
```zig
test "text_replace - OldStrNotFound with typo" {
    // old_str has slight difference -> should return OldStrNotFound
}

test "text_replace - OldStrNotFound case sensitive" {
    // "Hello" vs "hello" -> should fail
}

test "text_replace - OldStrNotFound with extra space" {
    // File has "hello" but old_str is "hello " -> should fail
}

test "text_replace - empty path returns PathNotFound" {
    // path = "" -> PathNotFound
}

test "text_replace - empty expected_hash returns HashNotFound" {
    // expected_hash = "" -> HashNotFound
}
```

### Category 3: Escape Sequences & Special Chars
```zig
test "text_replace - backslash in pattern" {
    // old_str contains \n, \t, \"
    // Should work as literal backslash
}

test "text_replace - double backslash \\\\"" {
    // old_str is exactly "\\"
}

test "text_replace - special regex chars [ ] * ?" {
    // These are special in fd/regex context
    // Should be treated as LITERAL in text_replace
}

test "text_replace - unicode emoji" {
    // Test with emoji like 🚀, 🌟
}

test "text_replace - unicode non-Latin" {
    // Test with 中文, العربية, etc.
}
```

### Category 4: Whitespace Sensitivity
```zig
test "text_replace - trailing whitespace matters" {
    // "hello " vs "hello" are different
}

test "text_replace - leading whitespace matters" {
    // " hello" vs "hello" are different
}

test "text_replace - tab vs space" {
    // File has tabs, old_str has spaces -> should return OldStrNotFound
}

test "text_replace - multiple spaces vs single space" {
    // "a  b" vs "a b" are different
}
```

### Category 5: Edge Cases
```zig
test "text_replace - single character replacement" {
    // Replace single char
}

test "text_replace - replace entire file content" {
    // old_str is almost entire file
}

test "text_replace - empty new_str (delete entire line)" {
    // Delete a line completely
}

test "text_replace - old_str == new_str (no-op)" {
    // Should succeed but do nothing
}

test "text_replace - empty file" {
    // File has no content
}

test "text_replace - file with only newlines" {
    // File is just "\n\n\n"
}
```

### Category 6: Batch Operation Edge Cases
```zig
test "text_replace batch - chained replacements" {
    // A -> B, then B -> C in same batch
    // Should work correctly
}

test "text_replace batch - first op fails" {
    // If any op fails, entire batch should fail
}

test "text_replace batch - partial success doesn't persist" {
    // If op 2 fails, op 1 changes should NOT be in file
}

test "text_replace batch - multiple successful ops" {
    // Replace 3 different strings in one batch
}

test "text_replace batch - op 2 old_str matches op 1 new_str" {
    // Op1: "foo" -> "bar", Op2: "bar" -> "baz"
    // Should succeed (foo becomes baz)
}
```

---

## Implementation Phases

### Phase 1: OldStrNotFound Error Tests (Priority: HIGH)
- Typo detection
- Case sensitivity
- Whitespace mismatch

### Phase 2: Duplicate Detection Tests (Priority: HIGH)
- 3+ occurrences
- Adjacent occurrences
- Context uniqueness

### Phase 3: Special Characters Tests (Priority: MEDIUM)
- Backslash handling
- Unicode/emoji
- Regex-like chars

### Phase 4: Whitespace Sensitivity Tests (Priority: MEDIUM)
- Trailing/leading whitespace
- Tab vs space
- Multiple spaces

### Phase 5: Batch Operation Tests (Priority: MEDIUM)
- Chained replacements
- Transaction behavior (all-or-nothing)
- Partial failure handling

### Phase 6: Edge Case Tests (Priority: LOW)
- Single char
- Empty strings
- Large content

---

## Files to Modify
- `src/modules/agent/tools/text_replace_test.zig` - Add new test cases

## Verification
```bash
zig build test 2>&1 | grep -E "(test|text_replace)"
```

## Success Criteria
- ✅ All new tests pass
- ✅ No regression in existing tests
- ✅ Tests cover the failure patterns from database history
