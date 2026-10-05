# Devin task sessions

Use this lifecycle whenever the sidekick is Devin. Pair, trio, and guided
pair share the helper. Other agent kinds keep their existing queue pickup.

New Devin spawns default to bypass permissions (`--permission-mode dangerous`).
An explicit `--permission` or native permission flag overrides that default.
Rotation preserves the recorded launch arguments, including explicit overrides.

## Complete a task, then rotate

One Devin conversation owns one brief, including its steps, steers, objections,
and fixups. Keep that conversation for a partial or blocked brief. Split a brief
that keeps growing into verified units rather than relying on repeated
compaction to carry the whole project.

After a `done` brief report, `finish` sets `sidekick.rotation_required` and ends
the turn. The queued brief stays in the store. `dispatch` and `discuss` refuse
another task until the master rotates the session. Devin queue pickup belongs
to the master's `dispatch`; `next` refuses same-turn pickup for Devin.

The master:

1. Wait for the report and the sidekick's turn to end. Write
   `<store>/session-handoff.md` with cwd, HEAD, working-tree state, the completed
   report, next brief or plan, agreed plan and review amendments, standing
   orders, open notes, follow-ups, and verification evidence paths. Reference
   these files; omit the full conversation and unrelated completed briefs.
2. Run `pair.sh rotate <store>`. It exits the idle Devin process, reuses its
   pane, and starts a fresh conversation with the recorded model and permission
   arguments. It preserves the store, queue, reports, and session history.
   Existing stores without recorded arguments need one manual exit and
   `spawn` with the original arguments. Confirm those arguments from the live
   process before exiting, including the selected model and effort.
3. Read the new `reports/000-ready.md`. Verify cwd, HEAD, tree state, and
   generation against `pair.json`, then dispatch the queued brief or send the
   next plan. Review the previous task at its reported commit while the new
   task runs. A `revise` becomes a new brief with the findings in Context.

Bootstrap is read-only. Read the explicit handoff, standing orders, and the
dispatched brief's report and step log when recovering partial work. Identify
completed, partial, and merely queued tasks separately. Write READY and wait
for a PLAN or BRIEF; bootstrap does not authorize implementation.

The helper increments `sidekick.generation`, records startup arguments and the
dispatch generation, and archives the previous ready report under `sessions/`.
A ready report left by the previous process cannot satisfy a new bootstrap.
If bootstrap returns before the fresh READY report arrives, inspect the pane
and retry `spawn` after the report appears. It acknowledges the pending
bootstrap in the same generation without restarting the live agent.
Report your generation and native session ID when available. Keep transcript
exports and timing evidence with that generation so late messages can be traced.

## Retention and storage maintenance

Rotation creates a new conversation. It does not purge old Devin sessions.
Keep the old session through review. Once accepted, retain its report, commit,
verification evidence, and an exported transcript before making the session
eligible for cleanup. Delete sessions only under the human's retention policy
or explicit cleanup request. Preserve unrelated sessions.

For coordinated cleanup or a skill upgrade:

1. Pause every affected store. Ask each master to record a recovery handoff and
   stop its sidekick at a safe point. Keep the queued brief recorded even if a
   STOP command clears the queue. Preserve dirty files and pending review notes.
2. Have the masters exit their idle Devin processes and acknowledge that they
   are gone. Verify all processes using the shared database have exited,
   including Devin Desktop and agents outside these stores. Use a targeted
   process termination only when the human authorized it and a graceful exit
   failed. Keep panes available for reuse. No master respawns before the
   coordinator releases the maintenance hold.
3. Make a recoverable SQLite backup of the database before deleting sessions.
   Use `devin rm <session-id>` for retired sessions in the authorized scope.
   Checkpoint through SQLite with `PRAGMA wal_checkpoint(TRUNCATE)` and inspect
   its result. Use offline `VACUUM` when deleted pages need to be reclaimed.
   The WAL contains database transactions, not model context; never remove or
   truncate it directly. A large WAL can include already checkpointed space.
4. After cleanup succeeds, release the hold. Each master reloads the updated
   skill and role, respawns its Devin sidekick with the saved arguments, checks
   the fresh READY report, then resumes from its handoff. Resume a paused brief
   from its next unrecorded step. Dispatch a queued brief only after deciding
   the preceding report's verdict.

Confirm the installed CLI syntax before maintenance. Devin documents
[`/clear`, exports, and session deletion](https://docs.devin.ai/cli/reference/commands).
SQLite documents [WAL checkpointing](https://www.sqlite.org/wal.html) and
[disk reclamation](https://www.sqlite.org/lang_vacuum.html). Run checkpoints
with a bounded busy timeout; a busy result is a reason to find the remaining
connection, not permission to discard the WAL.

## Measure the change

Compare similar briefs at the same model and effort. Record generation,
bootstrap and queue pickup latency, task duration, request count, input and
cached tokens, compactor request time, persistence latency when available,
message bytes added, WAL growth, and revise rate. `pair.sh metrics` measures
protocol intervals, which include tool waits and human downtime. Compactor
request duration can overlap other work; report it separately from added
critical-path delay. Treat session rotation as a testable improvement, not a
proven speedup or proof of a model context limit.
