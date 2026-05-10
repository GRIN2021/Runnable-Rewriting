---
name: runnable-symphony-issue
description: Create, submit, or refine Runnable Linear issues intended to be executed through Symphony. Use when the user wants to file or 提交 a new issue, rewrite an issue draft, or standardize ticket content so Runnable work can be picked up cleanly by the current Symphony workflow in `WORKFLOW.md`.
---

# Runnable Symphony Issue

Use this skill when the task is to write a new Runnable issue for the Symphony + Linear workflow, not to implement the issue itself.

This repo's issue workflow is defined in `WORKFLOW.md`. Follow that contract instead of inventing a generic ticket format.

## Default Goal

Produce issue text that is immediately usable by the current Runnable Symphony flow:

- scoped narrowly enough for one agent run,
- concrete enough to reproduce,
- explicit about acceptance criteria,
- explicit about validation,
- safe to start from `Todo` and move through `In Progress` -> `Human Review` -> `Merging` -> `Done`.

When the user asks to actually create the issue in Linear, prefer doing that in-session if a Linear MCP tool or Symphony `linear_graphql` tool is available.

## Runnable-Specific Rules

- Prefer one issue per concrete outcome. Do not pack multiple experiments or refactors into one ticket.
- Write for this repo's real workflows: `scripts/`, `docs/exp/`, `docs/reference/`, `tests/`, `openspec/changes/`, and libcrypto validation/eval paths.
- If the task is exploratory, define the expected artifact clearly: for example a report under `docs/exp/...`, a script under `scripts/...`, or a bounded code change plus validation.
- If the task could sprawl, split it now and keep the current issue to the smallest reviewable slice.
- If the task is discovered while doing other work and is out of scope, prefer the follow-up skill `runnable-symphony-followup`.

## Required Structure

Unless the user asks for a different format, draft the issue with these sections:

```md
## Summary

<1 short paragraph describing the problem and intended outcome>

## Problem

- <concrete current behavior or gap>
- <why it matters>
- <reproduction signal or evidence path, if known>

## Scope

- In scope: <bounded list>
- Out of scope: <bounded list>

## Acceptance Criteria

- [ ] <observable outcome 1>
- [ ] <observable outcome 2>

## Validation

- [ ] <exact command, script, or document check>
- [ ] <second proof item when needed>

## Notes

- <optional constraints, file hints, prior runs, issue links>
```

## Writing Guidance

- `Summary` should say what will be true after the issue is complete.
- `Problem` should describe the current failure mode, missing capability, or quality gap.
- `Scope` should constrain the execution so Symphony does not grow the task during implementation.
- `Acceptance Criteria` must be reviewer-visible outcomes, not implementation steps.
- `Validation` must name concrete commands, scripts, or doc artifacts whenever possible.
- `Notes` is optional and should hold paths, run IDs, comparison baselines, or dependencies.

## State Guidance

- New work intended for immediate execution should usually be created in `Todo`.
- Follow-up work discovered during implementation should usually be created in `Backlog`.
- Do not tell Symphony to start from `Backlog`; `WORKFLOW.md` explicitly treats it as out of scope until a human moves it.

## Submission Mode

If the user asks to "submit", "create", or "file" the issue:

1. Draft the final title and body first.
2. If a Linear tool is available, create the issue instead of stopping at prose.
3. If no Linear tool is available, return a ready-to-paste title/body/state package.

Prefer these target states:

- `Todo` for new work intended to be executed soon by Symphony.
- `Backlog` only when the user explicitly wants deferred work or the task is an out-of-scope follow-up.

## Linear / Symphony Guardrails

- Treat Runnable's tracker project slug as `runnable-e97c680b3b79`.
- If you are already inside a Symphony issue session, prefer reusing the current issue's `project.id` and `team.id` when creating a sibling or follow-up issue.
- If you have the current issue context, use the verified `ResolveStateId` and `CreateIssue` GraphQL patterns from `WORKFLOW.md`.
- `WORKFLOW.md` does not define a verified GraphQL mutation for issue relations, so treat `related` / `blockedBy` creation as best-effort via trusted tooling only.
- If you do not have current issue context and do not have a trusted project/team lookup helper in-session, do not invent unknown GraphQL schema fields just to force submission. Fall back to a ready-to-submit draft.
- If the user asks for links or dependencies between issues, add the relation only when the available Linear tooling already exposes a verified way to do it in-session.

## Good Runnable Issue Shapes

- Tight code fix plus a targeted test.
- One bounded experiment run plus a report artifact.
- One metrics or validation improvement with explicit before/after proof.
- One documentation or workflow correction tied to a concrete misleading behavior.

## Avoid

- Multi-week epics disguised as one issue.
- Acceptance criteria like "investigate" with no artifact.
- Validation like "make sure it works" with no command or output path.
- Mixing implementation, benchmark campaign, paper-writing, and cleanup into one ticket.
- Telling the future agent to ask humans for missing details unless there is a real auth or permission blocker.

## Runnable Defaults

When the user gives only a rough intent, bias toward:

- clear file/path anchors,
- reproducible commands,
- explicit output artifacts,
- narrow scope that can plausibly complete in one Symphony ticket cycle.

If helpful, also read:

- `WORKFLOW.md` for the active state machine and workpad rules.
- [issue-templates.md](references/issue-templates.md) for ready-to-use Runnable ticket templates.
- [runnable-linear-context.md](references/runnable-linear-context.md) for repo-specific Linear/Symphony defaults.
