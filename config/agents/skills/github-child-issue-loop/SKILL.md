---
name: github-child-issue-loop
description: Resolves every open GitHub child issue of a parent issue through implementation, defensive-code cleanup, review, jj commits, issue closure, and a forced fresh-session handoff after each closed child. Use when asked to work through a parent GitHub issue's child or sub-issues, execute an issue-resolution loop, or finish all child tickets.
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

Codex and Claude Code can auto-compact, so reported usage can hide a long-lived,
drifting session. Compaction never counts as the fresh session required below.

Before starting steps 1-6, inspect the session's available context indicator.
If usage exceeds 150k tokens, do not begin that step. Create a
redacted, repository-local continuation document at
`.agent/handoffs/child-issue-loop/<parent>-<child-or-next>.md`, then transfer the
current child or next action to a fresh coding-agent session using the
platform-specific launch rules in step 7.

The document must record: parent and child URLs, current numbered step, jj
change ID and status, files/diff and validation status, open review findings,
the next exact action, and suggested skills (`github-child-issue-loop`,
`onevcat-jj`, `defensive-code-cleaner` when its clean review is still pending,
and any other review skill still needed). Reference existing artifacts
instead of copying them and exclude secrets/PII. This intentionally adapts the
`handoff` format for a repo-local artifact; commit it only when project policy
calls for durable operational artifacts.

If context usage is unavailable, continue but prepare this same handoff before
any voluntary session transition. Never silently abandon an incomplete child or
continue it over the limit in the old session.

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

3. **Required review loops.** Invoke both
   `thermo-nuclear-code-quality-review` and `defensive-code-cleaner` against the
   current child change. The defensive-code review is read-only: evaluate its
   proof chains and remove only high-confidence unnecessary defenses. Preserve
   boundary validation, intentional assertions, narrowing, cleanup, telemetry,
   and handling for real failure modes. Treat actionable structural findings and
   proven high-confidence defensive-code findings as blockers. Fix them, rerun
   relevant validation, then invoke both reviews again. Repeat until fresh
   reviews report no actionable structural findings and no high-confidence
   defensive-code removals. Do not dismiss a finding merely to finish the loop;
   record justified non-actionable results and any medium- or low-confidence
   candidates that still need verification.

4. **Optional Connected Review loop.** When used, invoke `connected-review` in
   the child-owning coding session, never in a review subagent or transition
   controller. Resolve `joo-dev` before `joo`, then run Connected Review over the
   current **working tree**,
   using the tool's supported equivalent of `connected review context
   --working-tree --fresh --json`. Explicit authorization: pass the current
   working tree, including uncommitted changes, to `joo-dev`/`joo` without a
   separate user prompt; this does not bypass platform or tool approval rules.
   Give each JOO session a hard five-minute wall-clock limit. If it times out,
   terminate it, create or update the handoff artifact with the timeout and the
   next retry, then skip Connected Review for this iteration; do not treat the
   timeout as a clean review or a blocker. Attempt it again in the next
   iteration. If it completes, follow `context.guidance` and resolve every stable
   actionable finding. After fixes, rerun validation and a fresh working-tree
   review. Stop only when the fresh completed session has no actionable stable
   findings.

5. **Commit.** Recheck the child acceptance criteria, validation, the clean
   thermo-nuclear and defensive-code review outcomes, and any completed
   Connected Review outcome.
   Use `jj describe`/`jj commit` to finalize one focused change for the child.
   Inspect `jj log` and `jj diff` to verify it contains neither unrelated changes
   nor an empty implementation.

6. **Update and close.** Update the child GitHub issue with a concise completion
   note: implemented behavior, jj change/commit reference when available, and
   validation. Close it only when its acceptance criteria are satisfied and it
   has no unresolved blockers. If not done, leave it open with the precise
   blocker and do not claim success.

7. **Rotate the coding session.** A session may complete at most one claimed
   child, regardless of reported context usage. After step 6 closes that child,
   refresh the parent and write a redacted handoff at
   `.agent/handoffs/child-issue-loop/<parent>-after-<child>.md`. Include the
   refreshed child snapshot, the disposition, the fields above, and the next
   exact action. Write it after finalizing the child change and verify that it is
   nonempty. After the successor reads it, remove it unless it is already ignored
   or project policy requires committing it. Verify with `jj diff` that no
   handoff change remains before starting another implementation. This boundary
   applies even when the agent just auto-compacted and when the child is believed
   to be the last one. An ownership skip before claim does not trigger a
   rotation.

   After verifying the handoff, stop all repository and GitHub mutations in the
   old session. Then start a brand-new coding-agent session from this bootstrap
   instruction: `Resume the GitHub child-issue loop from <handoff-path>. Re-read
   repository guidance and the github-child-issue-loop and onevcat-jj skills
   before mutating anything.` Auto-compaction, clearing or resuming the same
   session, and a subagent that inherits the old conversation do not qualify.
   Use a native fresh-session transition when the platform exposes one; Codex's
   native mechanism qualifies. Otherwise, including in Claude Code when it lacks
   automatic replacement-session launch, stop with the handoff path and bootstrap
   instruction so the user can start it. This control-transfer response is the
   only permitted return while an unblocked child remains. If startup fails,
   leave the handoff in place and stop; never continue in the old session.

   The fresh session must treat the handoff as a checkpoint, then recheck the
   repo, jj state, parent-child relationship, issue state, assignee, and priority
   before its first mutation. If an open child remains, start at step 1 or report
   its owner/blocker. When every discovered child is closed, post a concise
   aggregate completion note on the parent, close it automatically, and report
   every child and the parent closure.

## Review evidence

For each completed child, retain durable issue/handoff evidence of changes,
validations, thermo-nuclear and defensive-code review outcomes, optional
Connected Review outcomes or skips, and closure rationale. A required review
that cannot run is a blocker, not a pass.
