---
name: runnable-symphony-followup
description: Draft or submit Runnable follow-up or backlog Linear issues discovered during implementation under the current Symphony workflow. Use when the main task reveals out-of-scope work that should become a separate Runnable issue with clear title, description, acceptance criteria, and validation.
---

# Runnable Symphony Follow-Up

Use this skill when a new issue should be split out from current work instead of expanding the active ticket.

This repo's `WORKFLOW.md` explicitly requires out-of-scope findings to become separate `Backlog` issues with clear scope. This skill standardizes that split.

## Default Goal

Create a follow-up issue draft that:

- is clearly separate from the current ticket,
- is small enough to be executed independently,
- is suitable for `Backlog` by default,
- explains why it was split out instead of handled now.

## Default Behavior

- Default target state: `Backlog`.
- Default relationship intent: mark it as related to the current issue when the available Linear tool supports verified relation creation.
- If the follow-up cannot proceed until the current issue lands, note that it should also be linked with `blockedBy` when the available tool supports it.
- Keep the issue narrowly scoped to one concrete gap.

If a Linear tool is available in-session, prefer creating the follow-up issue instead of only drafting it, but only create `related` / `blockedBy` links when the tool exposes a verified relation operation.

## Required Structure

```md
Title: <concise outcome-oriented title>

Reason for split:
- <why this is out of scope for the current issue>

## Summary

<short paragraph>

## Problem

- <concrete gap>
- <how it was discovered>
- <why it should not be folded into the current ticket>

## Scope

- In scope: <bounded work>
- Out of scope: <what remains excluded>

## Acceptance Criteria

- [ ] <observable outcome 1>
- [ ] <observable outcome 2>

## Validation

- [ ] <proof item>
```

## When To Use

- During implementation you notice a real bug or missing capability not required to complete the current issue.
- The current issue would become much harder to review if the new work were included.
- A cleanup, metrics extension, robustness pass, or doc correction deserves separate tracking.

## When Not To Use

- The new work is required to satisfy the current issue's acceptance criteria.
- The problem is only speculative and has no concrete evidence yet.
- The issue is so large that it should be split into multiple follow-ups instead of one.

## Runnable-Specific Guidance

- Mention concrete evidence paths when available: run directories, docs, scripts, tests, logs.
- For experiment-related follow-ups, specify the expected report artifact path.
- For code follow-ups, specify the likely code/test/doc surfaces but keep implementation flexibility.
- If you know the current issue identifier, mention that the new issue should be linked as `related` when supported by the available Linear tool.
- If the dependency is real, explicitly say the new issue should be linked as `blockedBy` the current issue when supported by the available Linear tool.
- If you are inside a Symphony issue session, prefer creating the follow-up under the same project/team as the current issue.
- If relation creation is not supported by the available Linear tool in-session, still create or draft the issue and report the intended `related` / `blockedBy` linkage explicitly instead of guessing mutation syntax.

## Output Style

Prefer returning:

1. a final proposed title,
2. the draft issue body,
3. a one-line note saying `Suggested initial state: Backlog`.

Do not bloat the follow-up with execution plans that belong in the future workpad comment.
