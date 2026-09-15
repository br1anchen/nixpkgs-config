# Report NNN: <slug>

status: done | partial | blocked | failed
brief: <store>/briefs/NNN-<slug>.md
playbook: <playbook you ran>
branch: <branch>
head: <sha>
tree: clean | dirty

## Changed

<`git diff --stat` against the head recorded in the brief's context, or "none">

## Ran

<one block per VERIFY command: the command, then its output verbatim or the
relevant excerpt with the omitted line count>

## Deviations

<where you departed from the brief or playbook and why, or "none">

## Questions

<required when status is blocked: the question, the options you see, what you
would pick without an answer>

## Follow-ups

<out-of-scope findings, one line each, or "none">
