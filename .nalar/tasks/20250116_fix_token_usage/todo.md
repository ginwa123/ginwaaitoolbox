# Task: Fix token usage not saved in database for callStreaming
Created: 2025-01-16
Status: completed

## Description
The response total tokens from `callStreaming` was never saved in the database properly because intermediate chunks could have zero usage values which would overwrite the final correct usage.

## Root Cause
In `StreamingAggregator.processChunk()`, usage was stored with direct assignment (`self.usage = usage`) which overwrites any previous value. If the LLM API sends usage in chunks (intermediate + final), intermediate zeros can overwrite the final correct values.

## Fix Applied
Modified `processChunk` in `src/modules/agent/agent.zig` to only update usage if `total_tokens > 0`, preventing zero values from overwriting the final correct usage data.

## Changes
- File: `src/modules/agent/agent.zig`
- Lines: ~416-422 (processChunk function)
- Change: Added check `if (usage.total_tokens > 0)` before updating `self.usage`

## Verification
- ✅ Build passes
