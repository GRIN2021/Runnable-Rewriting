# Runnable Linear / Symphony Context

Repo-specific defaults extracted from `WORKFLOW.md`:

- Tracker kind: `linear`
- Tracker project slug: `runnable-e97c680b3b79`
- Active states:
  - `Todo`
  - `In Progress`
  - `Human Review`
  - `Merging`
  - `Rework`
- Terminal states:
  - `Closed`
  - `Cancelled`
  - `Canceled`
  - `Duplicate`
  - `Done`

Issue creation defaults:

- Use `Todo` for fresh work intended for Symphony execution.
- Use `Backlog` for follow-up or deferred work.
- Keep issue body concise and reviewer-oriented.
- Include explicit `Acceptance Criteria` and `Validation`.

If creating a follow-up from an active issue:

- keep it in the same project,
- add `related` / `blockedBy` relations only when the available Linear tool exposes a verified relation operation,
- otherwise record the intended linkage explicitly in the issue body or workpad,
- do not expand the current ticket just because related work was discovered.
