# Runnable Symphony Issue Templates

Use these templates when the user wants a draft quickly. Adapt them to the specific task; do not leave placeholders vague.

## 1. Code Fix

```md
## Summary

Fix <bug> in `<path-or-subsystem>` so that <desired outcome>.

## Problem

- Current behavior: <what fails>
- Evidence: <command / file / run / log path>
- Impact: <why this matters>

## Scope

- In scope: fix the behavior in `<path>`
- In scope: add or update targeted coverage for the regression
- Out of scope: unrelated refactors or broader optimization

## Acceptance Criteria

- [ ] <observable fixed behavior>
- [ ] regression coverage exists for the failure mode

## Validation

- [ ] `<exact test or script command>`
- [ ] `<secondary spot-check if needed>`

## Notes

- Related paths: `<path1>`, `<path2>`
```

## 2. Experiment / Validation Run

```md
## Summary

Run a bounded experiment for <hypothesis> and record the result in `<artifact path>`.

## Problem

- We currently do not know whether <hypothesis / comparison> holds.
- Existing evidence: <run dir / doc / metric snapshot>

## Scope

- In scope: run <specific script or workflow>
- In scope: summarize metrics and interpretation in `<artifact path>`
- Out of scope: unrelated repair work unless required to complete the planned run

## Acceptance Criteria

- [ ] experiment completes or fails with a clearly documented blocker
- [ ] resulting metrics are written to `<artifact path>`
- [ ] summary states whether the hypothesis was supported

## Validation

- [ ] `<exact run command>`
- [ ] `test -f <artifact path>` or equivalent artifact existence check
```

## 3. Documentation / Workflow Fix

```md
## Summary

Correct `<doc-or-workflow>` so it matches the current Runnable behavior for <topic>.

## Problem

- Current documentation or workflow text is misleading in `<path>`
- Evidence: <mismatch between code, scripts, and docs>

## Scope

- In scope: update the relevant docs or workflow text
- In scope: align example commands and expected artifacts
- Out of scope: changing runtime behavior unless required for correctness

## Acceptance Criteria

- [ ] the corrected doc/workflow matches current commands and paths
- [ ] stale or misleading guidance is removed or replaced

## Validation

- [ ] review `<doc path>` against `<code/script path>`
- [ ] if commands are changed, run the command with a safe dry-run or equivalent proof
```

## 4. Issue Rewrite

Use when the user already has a rough draft and wants it cleaned up:

1. Keep the original intent.
2. Replace vague verbs with observable outcomes.
3. Move implementation details out of `Acceptance Criteria` and into `Scope` or `Notes`.
4. Add concrete `Validation` items.
5. Split the issue if it still contains more than one independently reviewable outcome.
