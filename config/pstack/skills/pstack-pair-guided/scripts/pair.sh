#!/usr/bin/env bash
# Pair store and Herdr channel helper for the pstack-pair-guided skill. The
# shared commands live in pstack-pair's pair-core.sh; this file adds the
# direction summary, the ask channel, and the scale-scaled approval gate.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
skill_root="$(dirname "$here")"
PAIR_SKILL=pstack-pair-guided
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/pstack/pair-guided"
store_label=Pair
roles=(sidekick)
store_dirs=(plans briefs reports reviews answers progress steers)
slug_max=21
unfilled_re='^(decided by|status): .*\|'
# shellcheck source-path=SCRIPTDIR source=../../pstack-pair/scripts/pair-core.sh
. "$skill_root/../pstack-pair/scripts/pair-core.sh"

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
  new-direction <store> <plan-path>         create plans/NNN-<slug>.direction.md, the human's summary; prints its path
  new-answer <store> <NNN> [--force]        create answers/NNN-<slug>-a<k>.md for the newest ask on unit NNN
  answer <store> <answer-path> [--timeout MS | --every MIN]
                                            send ANSWER to the sidekick and wait for it to settle
  new-brief <store> <slug>                  create briefs/NNN-<slug>.md from the template; prints its path
  dispatch <store> <brief-path> [--timeout MS | --every MIN]
                                            send BRIEF to the sidekick and wait for it to settle;
                                            implementation playbooks require an agreed plan whose
                                            review approval matches the plan's scale
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

exit codes: 0 ok, 1 usage or precondition, 2 herdr error, 3 sidekick blocked, 4 no report yet or queue empty, 5 sidekick in the wrong state or queue taken, 6 plan not agreed or not approved, 7 ask or steer cap reached
USAGE
}

# An agreed plan also needs the human approval its scale calls for.
plan_gate_extra() {
	local plan="$2" review="$3"
	local scale approval
	scale="$(header_field "$plan" scale)"
	approval="$(header_field "$review" approval)"
	case "$scale" in
	small) ;;
	medium) [ "$approval" = posted ] || [ "$approval" = human ] || die "medium plan needs approval: posted or human in $review (found '${approval:-missing}')" 6 ;;
	large) [ "$approval" = human ] || die "large plan needs approval: human in $review (found '${approval:-missing}'); post the direction summary and wait for the human" 6 ;;
	*) die "plan $plan has scale '${scale:-missing}'; set small, medium, or large" 6 ;;
	esac
}

cmd_new_direction() {
	[ $# -eq 2 ] || die "usage: pair.sh new-direction <store> <plan-path>"
	local store="$1" plan seq slug path
	pair_file "$store" >/dev/null
	plan="$(readlink -f "$2")"
	[ -f "$plan" ] || die "plan not found: $plan"
	seq="$(basename "$plan" | cut -c1-3)"
	slug="$(basename "$plan" .md | cut -c5-)"
	path="$store/plans/$seq-$slug.direction.md"
	[ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
	local scale
	scale="$(header_field "$plan" scale)"
	[ -n "$scale" ] || scale='{{small | medium | large}}'
	sed -e "s|{{SLUG}}|$slug|g" -e "s|{{PLAN}}|$plan|g" -e "s|{{STORE}}|$store|g" \
		-e "s#^scale: .*#scale: $scale#" \
		"$skill_root/references/direction-template.md" >"$path"
	printf '%s\n' "$path"
}

cmd_new_answer() {
	[ $# -ge 2 ] || die "usage: pair.sh new-answer <store> <NNN> [--force]"
	local store="$1" seq="$2" force=0 ask slug k path
	shift 2
	[ "${1:-}" = --force ] && force=1
	pair_file "$store" >/dev/null
	ask="$(ls -t "$store"/reports/"$seq"-*-q[0-9]*.md 2>/dev/null | head -1 || true)"
	[ -n "$ask" ] || die "no ask report for unit $seq (expected reports/$seq-<slug>-q<k>.md)"
	[ "$(header_field "$ask" status)" = asking ] || die "$ask is not status: asking"
	slug="$(basename "$ask" .md | sed -E 's/^[0-9]{3}-//; s/-q[0-9]+$//')"
	k="$(basename "$ask" .md | sed -E 's/.*-q([0-9]+)$/\1/')"
	path="$store/answers/$seq-$slug-a$k.md"
	[ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
	if [ "$k" -gt 2 ] && [ "$force" -eq 0 ]; then
		die "ask $k exceeds the two-ask cap for unit $seq; re-plan the unit, or pass --force to answer anyway" 7
	fi
	sed -e "s|NNN-<k>|$seq-$k|g" -e "s|NNN|$seq|g" -e "s|<slug>|$slug|g" -e "s|<k>|$k|g" -e "s|<store>|$store|g" \
		"$skill_root/references/answer-template.md" >"$path"
	printf '%s\n' "$path"
}

cmd_answer() {
	in_herdr
	[ $# -ge 2 ] || die "usage: pair.sh answer <store> <answer-path> [--timeout MS | --every MIN]"
	local store="$1" answer="$2" timeout=540000
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	checkin_interval_m=$((timeout / 60000))
	[ -f "$answer" ] || die "answer not found: $answer"
	grep -q '^## Answer' "$answer" || die "not an answer file: $answer"
	send_and_wait "$store" "$(readlink -f "$answer")" ANSWER "$timeout"
}

pair_main "$@"
