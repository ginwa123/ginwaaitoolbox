# Task: Implement Hash Guard for read_file and text_replace
Created: 2025-07-20
Status: completed

## Description
Implement a guard mechanism for AI agents: before editing a file, the agent must provide the file's current hash — if it doesn't match, the edit is rejected. This prevents stale/blind writes.

## Feature Requirements

### read_file modification:
- Return SHA256 hash of file content along with existing fields
- Add `sha256` field to ReadFileResult

### text_replace modification:
- Accept optional `expected_hash` parameter
- If provided, compute current hash before editing
- If hash mismatch, return error: "Hash mismatch — file may have changed since last read."
- Return both `sha256_before` and `sha256_after` in TextReplaceResult on success

## API Flow
Agent reads file hash → gets sha256 in result
Agent edits file (passes expected_hash) → validates hash before edit
- If match: success with sha256_before and sha256_after
- If mismatch: error "HashMismatch"

## Subtasks
- [x] 1. Modify read_file.zig to compute and return SHA256 hash
- [x] 2. Add test for read_file returning SHA256
- [x] 3. Modify text_replace.zig to accept expected_hash parameter
- [x] 4. Add hash validation in text_replace before editing
- [x] 5. Return sha256_before and sha256_after in TextReplaceResult
- [x] 6. Add tests for hash mismatch detection
- [x] 7. Update tool definitions (JSON schema) to reflect new parameters
- [x] 8. Run all tests and verify build passes

## Test Results
- read_file tests: 13 passed
- text_replace tests: 9 passed  
- hash guard tests: 7 passed
- Total: 29 tests passed
