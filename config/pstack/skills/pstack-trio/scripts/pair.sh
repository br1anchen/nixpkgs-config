#!/usr/bin/env bash
# Trio store and Herdr channel helper for the pstack-trio skill: a master, a
# sidekick that owns the working tree, and a consultant that advises. The
# shared commands live in pstack-pair's pair-core.sh and the consultant's in
# consultant-core.sh; this file adds the trio's spawn and kind rule.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
skill_root="$(dirname "$here")"
PAIR_SKILL=pstack-trio
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/pstack/trio"
store_label=Trio
roles=(sidekick consultant)
store_dirs=(plans briefs reports reviews progress steers consults advice scratch)
slug_max=20
# shellcheck source-path=SCRIPTDIR source=../../pstack-pair/scripts/pair-core.sh
. "$skill_root/../pstack-pair/scripts/pair-core.sh"
# shellcheck source-path=SCRIPTDIR source=consultant-core.sh
. "$here/consultant-core.sh"

usage() {
	cat <<'USAGE'
usage: pair.sh <command> [args]

  init <slug> [--store DIR]                 create or re-register the trio store; prints its path
  spawn <store> --sidekick KIND --consultant KIND [--only sidekick|consultant] [--permission MODE|none]
        [--consultant-permission MODE|none] [--fallback KIND [--fallback-arg ARG]...] [--timeout MS] [-- agent-args...]
                                            split panes beside the master, start and bootstrap both agents;
                                            Devin defaults to bypass, other kinds inherit the master's mode. Refuses a trio whose
                                            three kinds are all the same. --only respawns one role. A pi sidekick first proves
                                            its model answers; on failure the --fallback kind starts instead.
  rotate <store>                            exit an idle Devin or pi sidekick after a done brief, respawn with recorded
                                            arguments, and bootstrap a fresh session; preserve the queue and history
  failover <store> [--reason TEXT] [--force]
                                            replace a failing sidekick with its recorded fallback in the same pane;
                                            the fallback picks up from the store, and the run stays on it
  permission                                print the master's detected permission mode
  new-plan <store> <slug>                   create plans/NNN-<slug>.md from the template; prints its path
  discuss <store> <plan-path> [--timeout MS]
                                            send PLAN to the sidekick and the consultant at once and wait for
                                            both responses: the sidekick's report and the consultant's advice
  new-consult <store> <NNN> --kind design|finding|objection|review|glance [--force]
                                            create consults/NNN-<slug>-c<k>.md for unit NNN; three per unit, plus
                                            one glance (a five-minute diff read at a check-in)
  consult <store> <consult-path> [--timeout MS]
                                            send CONSULT to the consultant and wait for its advice; it may run while
                                            the sidekick works, reading committed state or a scratch snapshot
  advice <store> [NNN]                      print the latest (or NNN) advice path
  new-brief <store> <slug>                  create briefs/NNN-<slug>.md from the template; prints its path
  dispatch <store> <brief-path> [--timeout MS | --every MIN]
                                            send BRIEF to the sidekick and wait for it to settle;
                                            implementation playbooks require an agreed plan
  wait <store> [--timeout MS | --every MIN] wait for the report of the unit the sidekick is on; prints its path
                                            (and any queued or now-running brief), or a check-in digest when the
                                            interval passes first
  queue <store> <brief-path> [--replace]    hold the next brief for a working sidekick; it takes it the moment its
                                            current report is written (Devin and pi wait for rotation and dispatch). One slot. queue <store> --clear empties it
  step <store> <sha> <summary> [--resolves n1,n2]
                                            sidekick: record a committed step of the running brief and go on;
                                            the master's wait picks it up for review
  notes <store>                             sidekick, at each step boundary: print blocking review notes still open
  new-note <store> <NNN>                    create the draft note reviewing unit NNN's steps since the last note
  note <store> <note-draft-path>            publish a filled note to the sidekick; its follow-ups go to followups.md
  finish <store> <report-path>              sidekick, after writing any report: notify the master, then print
                                            the queued brief to start for other kinds, or the REPORT line; a done Devin or pi brief requires rotation
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
  notify <store> <path>                     sidekick or consultant -> master: prompt the master if it is idle
                                            (REPORT for a report path, ADVICE for an advice path)
  stop <store> [--only sidekick|consultant] [--timeout MS]
                                            send STOP; each agent pauses safely and reports
  scratch <store> <id> [--at SHA] [--remove]
                                            a throwaway worktree under <store>/scratch/<id>: at HEAD with the live
                                            diff applied, or exactly at SHA to recheck a unit while the sidekick works
  pause <store> [--reason TEXT]             pause at the next safe point: the sidekick stops at its next step or
                                            progress boundary; dispatch, queue, discuss, consult, answer refuse
  resume <store>                            lift the pause; re-dispatch the paused brief to continue it
  status <store>                            table of units, reports, advice, reviews, agent states, open scratch
  log <store> <phase> <decision> <why> <evidence> <result>
                                            append a decisions.tsv row (show-me-your-work format)
  metrics <store>                           where the time went, from events.tsv: busy and idle per agent,
                                            master wakes, review latency, verdicts

exit codes: 0 ok, 1 usage or precondition, 2 herdr error, 3 agent blocked, 4 no report or advice yet or queue empty,
            5 agent in the wrong state or queue taken, 6 plan not agreed or consultant advice missing, 7 steer or consult cap reached,
            8 agent kinds not diverse
USAGE
}

# The trio needs at least two distinct agent kinds, so the consultant is a
# second perspective and not the master's echo. Exit 8 names the three kinds.
require_diverse_kinds() {
	local master="$1" sidekick="$2" consultant="$3"
	[ -n "$master" ] || die "cannot read the master's agent kind from herdr; run pair.sh init first" 2
	if [ "$master" = "$sidekick" ] && [ "$master" = "$consultant" ]; then
		die "all three agents would be $master; pstack-trio needs at least two distinct kinds (master $master, sidekick $sidekick, consultant $consultant). Restart with a different --sidekick or --consultant kind, or use pstack-pair" 8
	fi
}

cmd_spawn() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh spawn <store> --sidekick KIND --consultant KIND [--fallback KIND [--fallback-arg ARG]...] [--only sidekick|consultant] [--permission MODE|none] [--consultant-permission MODE|none] [--timeout MS] [-- agent-args...]"
	local store="$1" sidekick_kind="" consultant_kind="" only="" permission="" cpermission="" timeout=60000 fallback=""
	local -a fallback_args=()
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--sidekick) sidekick_kind="$2"; shift 2 ;;
		--consultant) consultant_kind="$2"; shift 2 ;;
		--kind) sidekick_kind="$2"; consultant_kind="${consultant_kind:-$2}"; shift 2 ;;
		--fallback) fallback="$2"; shift 2 ;;
		--fallback-arg) fallback_args+=("$2"); shift 2 ;;
		--only) only="$2"; shift 2 ;;
		--permission) permission="$2"; shift 2 ;;
		--consultant-permission) cpermission="$2"; shift 2 ;;
		--timeout) timeout="$2"; shift 2 ;;
		--) shift; break ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	case "$only" in
	"" | sidekick | consultant) ;;
	*) die "--only takes sidekick or consultant" ;;
	esac
	# A role not being spawned keeps the kind recorded for it.
	[ -n "$sidekick_kind" ] || sidekick_kind="$(field "$store" '.sidekick.kind // empty')"
	[ -n "$consultant_kind" ] || consultant_kind="$(field "$store" '.consultant.kind // empty')"
	[ "$only" = consultant ] || [ -n "$sidekick_kind" ] || die "--sidekick KIND is required (run: herdr agent, for the kind list)"
	[ "$only" = sidekick ] || [ -n "$consultant_kind" ] || die "--consultant KIND is required (run: herdr agent, for the kind list)"
	local master_kind
	master_kind="$(agent_kind "$(field "$store" .master.pane_id)")"
	require_diverse_kinds "$master_kind" "${sidekick_kind:-$master_kind}" "${consultant_kind:-$master_kind}"
	local master_pane
	master_pane="$(field "$store" .master.pane_id)"
	[ -n "$cpermission" ] || cpermission="$permission"
	local rc=0
	if [ "$only" != consultant ]; then
		record_fallback "$store" "$fallback" "${fallback_args[@]}"
		spawn_sidekick "$store" "$sidekick_kind" "$permission" "$master_pane" "$timeout" "" "" "$@" || rc=$?
		[ "$rc" -eq 0 ] || exit "$rc"
	fi
	if [ "$only" != sidekick ]; then
		spawn_consultant "$store" "$consultant_kind" "$cpermission" "$timeout" "$@" || rc=$?
		[ "$rc" -eq 0 ] || exit "$rc"
	fi
	printf 'kinds: master %s, sidekick %s, consultant %s\n' "$master_kind" "$(field "$store" '.sidekick.kind // "absent"')" "$(field "$store" '.consultant.kind // "absent"')"
}

# A trio plan round goes to the sidekick and the consultant at once.
cmd_discuss() { discuss_with_consultant "$@"; }

pair_main "$@"
