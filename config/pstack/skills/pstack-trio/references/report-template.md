# Report NNN: <slug>

status: done | partial | blocked | failed
brief: <store>/briefs/NNN-<slug>.md
playbook: <playbook you ran>
branch: <branch>
head: <sha of the unit's commit, or HEAD when the brief says commit: no>
tree: clean | dirty

## Changed

<`git diff --stat` against the head recorded in the brief's context, or "none">

## Ran

<one block per VERIFY command: the command, then its output verbatim or the
relevant excerpt with the omitted line count>

## Self-check

<required for done, one line each:
figures: every number above comes from Ran or a file it names
acceptance: each Acceptance line and the Ran block that shows it
callers: each changed shared symbol, the search for its callers, and the count
fresh: the checks ran on fresh caches, or which ones might not have
gate: the landing gate's fast checks (format, lint, typecheck) pass on the
commit, or which were skipped and why>

## Deviations

<where you departed from the brief or playbook and why, each steer received
and what it changed, or "none">

## Questions

<required when status is blocked: the question, the options you see, what you
would pick without an answer>

## Follow-ups

<out-of-scope findings, one line each, or "none">
