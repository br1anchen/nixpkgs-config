---
name: github-child-issue-loop
description: Resolves every open GitHub child issue of a parent issue through implementation, required structural review, optional Connected Review, jj commits, and issue closure with resumable handoffs. Use when asked to work through a parent GitHub issue's child or sub-issues, execute an issue-resolution loop, or finish all child tickets.
---

# GitHub Child-Issue Loop

Use this workflow for one parent GitHub issue at a time. Treat GitHub's explicit
child/sub-issue relationship as authoritative; do not infer children from prose
or task-list checkboxes. Work sequentially so each child has an isolated jj
change, review history, and ticket update.

## Prerequisites

- Start with the parent issue URL or `owner/repo#number`, a checked-out repo, and
  authenticated GitHub access.
- Use the GitHub integration or `gh` only to read, assign, update, and close
  issues. Confirm the repository and parent before mutating issues.
- Require a jj-managed repository (`.jj/`); use `onevcat-jj` for every local VCS
  operation. Do not use Git staging, commits, stashes, or checkouts.

## Context guard

Before starting **every** numbered step below, inspect the session's available
context indicator. If usage exceeds 70%, do not begin that step. Create a
redacted, repository-local continuation document at
`.agent/handoffs/child-issue-loop/<parent>-<child-or-next>.md`, then end or
delegate to a fresh session.

The document must record: parent and child URLs, current numbered step, jj
change ID and status, files/diff and validation status, open review findings,
the next exact action, and suggested skills (`github-child-issue-loop`,
`onevcat-jj`, and any review skill still needed). Reference existing artifacts
instead of copying them and exclude secrets/PII. This intentionally adapts the
`handoff` format for a repo-local artifact; commit it only when project policy
calls for durable operational artifacts.

If context usage is unavailable, continue but prepare this same handoff before
any voluntary session transition. Never silently abandon an incomplete child.

## Loop

1. **Discover and claim a child.** Fetch the parent and its open child issues.
   Select one open child in the parent-defined priority/order. Refresh it before
   acting; assign it to the authenticated user only if it is unassigned or
   already assigned to that user. If someone else owns it, skip it and record
   why. Read its acceptance criteria, linked context, and repository guidance.

2. **Implement.** Create a dedicated jj change from the intended base and give
   it a descriptive message. Inspect relevant code and tests, implement the
   child fully, and run the smallest relevant validation. Keep unrelated working
   tree changes out of the child change; do not overwrite another agent's work.

3. **Thermo-nuclear review loop.** Invoke
   `thermo-nuclear-code-quality-review` against the current child change. Treat
   structural findings as blockers: fix them, rerun relevant validation, and
   review again. Repeat until a fresh review has no actionable findings. Do not
   dismiss a finding merely to finish the loop; record a justified non-actionable
   result when applicable.

4. **Optional Connected Review loop.** When used, invoke `connected-review` in
   the current parent session—never in a spawned coding agent. Resolve `joo-dev`
   before `joo`, then run Connected Review over the current **working tree**,
   using the tool's supported equivalent of `connected review context
   --working-tree --fresh --json`. Allow the CLI to inspect uncommitted changes.
   Give each JOO session a hard five-minute wall-clock limit. If it times out,
   terminate it, create or update the handoff artifact with the timeout and the
   next retry, then skip Connected Review for this iteration; do not treat the
   timeout as a clean review or a blocker. Attempt it again in the next
   iteration. If it completes, follow `context.guidance` and resolve every stable
   actionable finding. After fixes, rerun validation and a fresh working-tree
   review. Stop only when the fresh completed session has no actionable stable
   findings.

5. **Commit.** Recheck the child acceptance criteria, validation, the clean
   thermo-nuclear review outcome, and any completed Connected Review outcome.
   Use `jj describe`/`jj commit` to finalize one focused change for the child.
   Inspect `jj log` and `jj diff` to verify it contains neither unrelated changes
   nor an empty implementation.

6. **Update and close.** Update the child GitHub issue with a concise completion
   note: implemented behavior, jj change/commit reference when available, and
   validation. Close it only when its acceptance criteria are satisfied and it
   has no unresolved blockers. If not done, leave it open with the precise
   blocker and do not claim success.

7. **Continue or finish.** Refresh the parent’s child list. If any child remains
   open, start the loop again at step 1 or report the owner/blocker; never treat
   a skipped or blocked child as complete. When every discovered child is closed,
   post a concise aggregate completion note on the parent and close it
   automatically. Report every child and the parent closure.

## Review evidence

For each completed child, retain enough durable issue/handoff evidence to answer:
what changed, which validations ran, what each review concluded or why optional
Connected Review was skipped, and why the issue was closed. A required review
that cannot run is a blocker, not a pass.
