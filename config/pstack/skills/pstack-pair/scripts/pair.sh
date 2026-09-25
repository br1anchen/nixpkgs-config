#!/usr/bin/env bash
# Pair store and Herdr channel helper for the pstack-pair skill. The commands
# live in pair-core.sh, shared with pstack-pair-guided and pstack-trio.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
skill_root="$(dirname "$here")"
PAIR_SKILL=pstack-pair
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/pstack/pair"
store_label=Pair
roles=(sidekick)
store_dirs=(plans briefs reports reviews progress steers)
slug_max=21
# shellcheck source-path=SCRIPTDIR source=pair-core.sh
. "$here/pair-core.sh"

usage() {
	cat <<'USAGE'
usage: pair.sh <command> [args]

  init <slug> [--store DIR]                 create or re-register the pair store; prints its path
  spawn <store> --kind KIND [--permission MODE|none] [--direction right|down] [--pane ID] [--timeout MS] [-- agent-args...]
                                            split from the master pane, start the sidekick with the master's
                                            permission mode (default auto), bootstrap it
  permission                                print the master's detected permission mode
  new-plan <store> <slug>                   create plans/NNN-<slug>.md from the template; prints its path
  discuss <store> <plan-path> [--timeout MS]
                                            send PLAN to the sidekick and wait for its agree/object response
  new-brief <store> <slug>                  create briefs/NNN-<slug>.md from the template; prints its path
  dispatch <store> <brief-path> [--timeout MS | --every MIN]
                                            send BRIEF to the sidekick and wait for it to settle;
                                            implementation playbooks require an agreed plan
  wait <store> [--timeout MS | --every MIN] wait for the report of the unit the sidekick is on; prints its path
                                            (and any queued or now-running brief), or a check-in digest when the
                                            interval passes first
  queue <store> <brief-path> [--replace]    hold the next brief for a working sidekick; it takes it the moment its
                                            current report is written. One slot. queue <store> --clear empties it
  finish <store> <report-path>              sidekick, after writing any report: notify the master, then print
                                            the queued brief to start (after a done report) or the line to end on
  next <store>                              sidekick: take the queued brief after writing a report; exit 4 when empty
  progress <store> <text>                   sidekick: append one timestamped line to the running brief's progress log
  new-steer <store> <NNN> [--supersedes STEER | --force]
                                            create steers/NNN-<slug>-s<k>.md; prints its path. --supersedes answers
                                            an objection; two fresh steers per brief
  steer <store> <steer-path> [--interrupt] [--force] [--timeout MS | --every MIN]
                                            send STEER: to a working sidekick, return at once (its harness hands it
                                            over between tool calls; --interrupt cancels the running one first);
                                            to one paused on an objection, wait for it to settle
  report <store> [NNN]                      print the latest (or NNN) report path
  notify <store> <report-path>              sidekick -> master: prompt the master if it is idle
  stop <store> [--timeout MS]               send STOP; the sidekick pauses safely and reports
  scratch <store> <id> [--at SHA] [--remove]
                                            a throwaway worktree under <store>/scratch/<id>: at HEAD with the live
                                            diff applied, or exactly at SHA to recheck a unit while the sidekick works
  status <store>                            table of briefs, reports, reviews, and live agent states
  log <store> <phase> <decision> <why> <evidence> <result>
                                            append a decisions.tsv row (show-me-your-work format)
  metrics <store>                           where the time went, from events.tsv: busy and idle per agent,
                                            master wakes, review latency, verdicts

exit codes: 0 ok, 1 usage or precondition, 2 herdr error, 3 sidekick blocked, 4 no report yet or queue empty, 5 sidekick in the wrong state or queue taken, 6 plan not agreed, 7 steer cap reached
USAGE
}

pair_main "$@"
