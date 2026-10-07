#!/usr/bin/env bash
# Kitchen store and Herdr channel helper for the pstack-kitchen skill: the
# pair's master and sidekick, a consultant started only when a unit
# escalates, and a short-lived verifier pane per verification. The shared
# commands live in pstack-pair's pair-core.sh and the consultant's in
# pstack-trio's consultant-core.sh; the repo's rules are read through
# kitchen.py from .agents/kitchen.toml.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
skill_root="$(dirname "$here")"
PAIR_SKILL=pstack-kitchen
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/pstack/kitchen/runs"
store_label=Kitchen
roles=(sidekick verifier consultant)
store_dirs=(plans briefs reports reviews progress steers consults advice scratch verdicts joo)
slug_max=20
# shellcheck source-path=SCRIPTDIR source=../../pstack-pair/scripts/pair-core.sh
. "$skill_root/../pstack-pair/scripts/pair-core.sh"
# shellcheck source-path=SCRIPTDIR source=../../pstack-trio/scripts/consultant-core.sh
. "$skill_root/../pstack-trio/scripts/consultant-core.sh"

usage() {
	cat <<'USAGE'
usage: kitchen.sh <command> [args]

The pair's commands (pstack-pair's pair.sh help) work unchanged: init, rotate, failover, permission,
new-plan, new-brief, wait, queue, notes, new-note, note, finish, next, progress, new-steer, steer,
report, notify, stop, scratch, pause, resume, status, log, metrics, and the consultant's new-consult,
consult, advice. These differ or are new:

  spawn <store> [--kind KIND] [--fallback KIND [--fallback-arg ARG]...] [--tab | --split] [--permission MODE|none] [-- args...]
                                            start the sidekick; kind, args, and fallback default to the
                                            host roster (~/.config/pstack/kitchen.toml); --tab gives every role
                                            (sidekick, consultant, verifier) its own tab instead of a split
  consultant <store> --reason TEXT [--kind KIND] [-- args...]
                                            start the consultant for an escalated unit (roster kind by default)
  classify <store> <brief-path>             map the brief's may-write Scope to profiles and a risk class and
                                            stamp risk:, profiles:, verify: into its header
  discuss <store> <plan-path>               a routine plan goes to the sidekick; risk: escalated to both
  dispatch <store> <brief-path> [...] [--max MIN] [--send-only]
                                            classify, then the pair's dispatch; escalated units need an agreed
                                            plan with advice, landing units need land-check to pass; waits quietly,
                                            or returns once the brief is delivered with --send-only
  wait <store> [...] [--max MIN]            the pair's wait, quiet through check-ins with nothing flagged; returns
                                            for a report, steps, a block, a flagged check-in, or after --max (60)
  step <store> <sha> <summary> [--resolves n1,n2]
                                            sidekick: run the touched profiles' fast gates and policy on the
                                            step's commits, then record it; exit 2 when they fail. The checks run
                                            detached: exit 4 "still running" after ~2 minutes, run it again to wait
  verify <store> <NNN>... [--covers NNN]... [--every MIN] [--timeout MIN] [--kind KIND]
                                            verify one unit, or several as a batch, or a fix with the unit it
                                            fixes (--covers): gates only, or a fresh verifier in a scratch
                                            worktree at the head; returns at the interval with its progress
                                            (exit 4), and with the verdict and whether to audit when it lands.
                                            A verifier stopped by its provider is retried on the sidekick's
                                            fallback; the deadline defaults to 3x the measured gate time
  verify <store> --wait [--every MIN]       wait again for the open verification: exit 4 while it runs, 5 when none
                                            is open
  revise <store> <verdict-path>             draft the fix brief for a rejected verdict
  review <store> <NNN>... | --landing [--base REV]
                                            Judge of Owls on the units' range, or for landing on the stack from
                                            where it leaves trunk (or --base); prints blocking findings unresolved
  resolve <store> <finding-id> fixed|followup|dismissed <note>
                                            record the master's decision on a finding
  land-check <store>                        every accepted unit verified and every blocking finding resolved
  catch <store> <layer> <text>              record a miss found later (audit, human review): layer is
                                            gate, policy, self, verify, review, triage, or escalation
  retro <store>                             where the master was needed, and what repeated, from this run
                                            and the repo's ledger

exit codes: the pair's, plus 2 for a failed gate, a rejected or invalid verdict, or a failed land-check
USAGE
}

copy_fn() {
	# Keeps the shared definition of $1 callable as $2 before this file
	# replaces $1.
	eval "$2() $(declare -f "$1" | tail -n +2)"
}
copy_fn cmd_init core_init
copy_fn cmd_spawn core_spawn
copy_fn cmd_dispatch core_dispatch
copy_fn cmd_wait core_wait
copy_fn cmd_queue core_queue
copy_fn cmd_discuss core_discuss
copy_fn cmd_step core_step
copy_fn steps_due core_steps_due
copy_fn require_agreed_plan core_require_agreed_plan
copy_fn plan_gate_extra advice_gate

kpy() {
	# kitchen.py against the store's repo: $1 store, rest: its arguments.
	local store="$1"
	shift
	python3 "$here/kitchen.py" --repo "$(field "$store" .git_root)" "$@"
}

set_header() {
	# $1 file, $2 key, $3 value: replace the key's header line, or add it
	# after the plan: line.
	if grep -q "^$2:" "$1"; then
		KEY="$2" VAL="$3" perl -i -pe 's/^\Q$ENV{KEY}\E:.*$/$ENV{KEY}: $ENV{VAL}/ if !$done && /^\Q$ENV{KEY}\E:/ && ($done = 1)' "$1"
	else
		KEY="$2" VAL="$3" perl -i -pe '$_ .= "$ENV{KEY}: $ENV{VAL}\n" if !$done && /^plan:/ && ($done = 1)' "$1"
	fi
}

scope_globs() {
	# The brief's may-write lines, without their notes.
	awk '/^## Scope/{s=1; next} /^## /{s=0} s && /^may write:/{m=1; next} s && /^must not write:/{m=0}
		s && m && /^- /{sub(/^- /, ""); sub(/ — .*/, ""); gsub(/`/, ""); if ($0 != "") print}' "$1"
}

unit_brief() {
	# $1 store, $2 NNN: the unit's brief path.
	local f
	f="$(ls "$1"/briefs/"$2"-*.md 2>/dev/null | head -1 || true)"
	[ -n "$f" ] || die "no brief for unit $2"
	printf '%s\n' "$f"
}

unit_range() {
	# $1 store, rest: NNN...; prints "base head" for the units, first to
	# last, from their dispatch heads and done reports. A unit named in the
	# global covered list needs no done report: a later fix unit carries it.
	local store="$1" first="$2" last="${*: -1}" brief report base head unit
	brief="$(unit_brief "$store" "$first")"
	base="$(jq -r --arg u "$(basename "$brief" .md)" '.heads[$u] // empty' "$store/pair.json")"
	[ -n "$base" ] || die "unit $first was never dispatched"
	# A partial or blocked unit can still be verified or reviewed at the head
	# its report names; the master is told it is not a done unit.
	for unit in "${@:2}"; do
		[[ " ${covered[*]:-} " != *" $unit "* ]] || continue
		report="$(expected_report "$store" "$(unit_brief "$store" "$unit")")"
		[ -f "$report" ] || die "unit $unit has no report"
		case "$(header_field "$report" status)" in
		"done") ;;
		partial | blocked | failed) printf 'note: unit %s'"'"'s report is %s; checking the head it names\n' "$unit" "$(header_field "$report" status)" >&2 ;;
		*) die "unit $unit's report is $(header_field "$report" status), not done, partial, or blocked" ;;
		esac
	done
	head="$(header_field "$(expected_report "$store" "$(unit_brief "$store" "$last")")" head)"
	[ -n "$head" ] || die "unit $last's report has no head:"
	head="$(git -C "$(field "$store" .git_root)" rev-parse --verify --quiet "$head^{commit}")" || die "unit $last's head is not a commit"
	printf '%s %s\n' "$base" "$head"
}

next_index() {
	# $1 dir, $2 prefix, $3 letter: the next k for files <prefix>-<letter><k>.*
	local k=0 f n
	for f in "$1/$2-$3"[0-9]*; do
		[ -e "$f" ] || continue
		n="$(basename "$f" | sed -E "s/^.*-$3([0-9]+).*$/\1/")"
		[ "$n" -gt "$k" ] && k="$n"
	done
	printf '%s\n' "$((k + 1))"
}

# The repo's kitchen speaks through the standing orders too: the review
# skills the sidekick runs before done, and how far landing goes.
cmd_init() {
	local out store json orders
	out="$(core_init "$@")"
	printf '%s\n' "$out"
	orders="$(sed -n 's/^standing orders: //p' <<<"$out")"
	store="$(dirname "$orders")"
	json="$(kpy "$store" --json validate 2>/dev/null)" || { printf 'kitchen: none valid in this repo; run pstack-kitchen-setup before dispatching\n' >&2; return 0; }
	grep -q 'kitchen.toml review.self' "$orders" || [ "$(jq '.self | length' <<<"$json")" -eq 0 ] ||
		printf '16. Before reporting done, the sidekick runs these skills on its diff and fixes what they find: %s (kitchen.toml review.self).\n' \
			"$(jq -r '.self | join(", ")' <<<"$json")" >>"$orders"
	grep -q 'kitchen.toml landing.mode' "$orders" ||
		printf '17. Landing goes as far as `%s` (kitchen.toml landing.mode) and never merges.\n' "$(jq -r .landing <<<"$json")" >>"$orders"
}

cmd_spawn() {
	in_herdr
	[ $# -ge 1 ] || die "usage: kitchen.sh spawn <store> [--kind KIND] [--fallback KIND [--fallback-arg ARG]...] [-- agent-args...]"
	local store="$1" kind="" fallback="" roster rest=() native=() fb_args=() a
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--kind) kind="$2"; shift 2 ;;
		--fallback) fallback="$2"; shift 2 ;;
		--) shift; native=("$@"); break ;;
		*) rest+=("$1"); shift ;;
		esac
	done
	roster="$(python3 "$here/kitchen.py" --json roster)"
	if [ -z "$kind" ]; then
		kind="$(jq -r '.sidekick.kind' <<<"$roster")"
		[ -n "$kind" ] || die "no --kind and no [sidekick] kind in the host roster (~/.config/pstack/kitchen.toml)"
		[ "${#native[@]}" -gt 0 ] || mapfile -t native < <(jq -r '.sidekick.args[]' <<<"$roster")
	fi
	if [ -z "$fallback" ] && [ "$kind" = "$(jq -r '.sidekick.kind' <<<"$roster")" ]; then
		fallback="$(jq -r '.sidekick.fallback.kind' <<<"$roster")"
		mapfile -t fb_args < <(jq -r '.sidekick.fallback.args[]' <<<"$roster")
	fi
	[ -z "$fallback" ] || rest+=(--fallback "$fallback")
	for a in "${fb_args[@]}"; do rest+=(--fallback-arg "$a"); done
	core_spawn "$store" --kind "$kind" "${rest[@]}" -- "${native[@]}"
}

# The consultant joins only when a unit escalates: the scarcest quota is
# spent on design questions that warrant it.
cmd_consultant() {
	in_herdr
	[ $# -ge 1 ] || die "usage: kitchen.sh consultant <store> --reason TEXT [--kind KIND] [--permission MODE|none] [-- agent-args...]"
	local store="$1" reason="" kind="" permission="" native=()
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--reason) reason="$2"; shift 2 ;;
		--kind) kind="$2"; shift 2 ;;
		--permission) permission="$2"; shift 2 ;;
		--) shift; native=("$@"); break ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	[ -n "$reason" ] || die "--reason is required: the escalation that warrants the consultant"
	if [ -z "$kind" ]; then
		local roster
		roster="$(python3 "$here/kitchen.py" --json roster)"
		kind="$(jq -r '.consultant.kind' <<<"$roster")"
		[ "${#native[@]}" -gt 0 ] || mapfile -t native < <(jq -r '.consultant.args[]' <<<"$roster")
	fi
	[ -n "$kind" ] || die "no --kind and no [consultant] kind in the host roster"
	json_update "$store" --arg why "$reason" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'.escalations = ((.escalations // []) + [{reason: $why, at: $now}])'
	event "$store" master escalate - "$reason"
	spawn_consultant "$store" "$kind" "$permission" 60000 "${native[@]}"
}

classify_brief() {
	# $1 store, $2 brief: stamp risk, profiles, verify; print the summary.
	local store="$1" brief="$2" json risk
	local -a globs
	mapfile -t globs < <(scope_globs "$brief")
	[ "${#globs[@]}" -gt 0 ] || die "$brief lists nothing under Scope's may write:"
	json="$(kpy "$store" --json classify --paths "${globs[@]}")" || die "kitchen.py classify failed; run kitchen.py validate in the repo"
	risk="$(jq -r .risk <<<"$json")"
	set_header "$brief" risk "$risk"
	set_header "$brief" profiles "$(jq -r '.profiles | join(", ") | if . == "" then "none" else . end' <<<"$json")"
	set_header "$brief" verify "$(jq -r '"\(.verify.mode) by \(.verify.kind)"' <<<"$json")"
	printf 'risk: %s\n' "$risk"
	jq -r '"profiles: \(.profiles | join(", "))", "verify: \(.verify.mode) by \(.verify.kind)", (.escalate[] | "escalate: \(.)"),
		(if .bookkeeping then "bookkeeping: the Scope is outside the repo; gates only, nothing to escalate" else empty end)' <<<"$json"
	if [ "$risk" = escalated ] && [ "$(agent_status "$(field "$store" .consultant.name)")" = absent ]; then
		printf 'next: kitchen.sh consultant %s --reason "%s", then a plan round with it\n' "$store" "$(jq -r '.escalate[0]' <<<"$json")"
	fi
}

cmd_classify() {
	[ $# -eq 2 ] || die "usage: kitchen.sh classify <store> <brief-path>"
	pair_file "$1" >/dev/null
	[ -f "$2" ] || die "brief not found: $2"
	classify_brief "$1" "$2"
}

# Routine units run on the brief alone; an escalated one needs the agreed
# plan with the consultant's advice, as in the trio. A routine brief that
# names a plan still needs it agreed.
require_agreed_plan() {
	local store="$1" brief="$2" plan
	if [ "$(header_field "$brief" risk)" = escalated ]; then
		kitchen_escalated=1 core_require_agreed_plan "$@"
		return
	fi
	plan="$(header_field "$brief" plan)"
	case "$plan" in "" | none) return 0 ;; esac
	kitchen_escalated=0 core_require_agreed_plan "$@"
}

plan_gate_extra() {
	[ "${kitchen_escalated:-0}" = 1 ] || return 0
	advice_gate "$@"
}

is_landing() {
	case "$(header_field "$1" playbook)" in
	opening-a-pr | shipping) return 0 ;;
	esac
	[ "$(header_field "$1" landing)" = yes ]
}

# A routine check-in is a wake with nothing to act on, so a kitchen wait
# stays quiet through it: it returns for a report, a steps wake, a blocked
# sidekick, or a check-in that carries a flag (a stale log, a write outside
# Scope, an objection, an open blocking note, a timebox overrun, a pause),
# or after --max minutes (KITCHEN_QUIET_MAX_S; default an hour) with the
# latest digest. Run it in the harness's background mode where there is one.
quiet_flagged() {
	grep -qE 'STALE|^outside scope: [1-9]|[1-9][0-9]* objected|[1-9][0-9]* blocking notes open|^paused:' <<<"$1" && return 0
	local spent box
	read -r spent box < <(sed -nE 's/^check-in: .*elapsed ([0-9]+)m of ([0-9]+)m.*/\1 \2/p' <<<"$1") || true
	[ -n "${spent:-}" ] && [ -n "${box:-}" ] && [ "$spent" -gt "$box" ]
}

quiet_wait() {
	local store="$1" max="${KITCHEN_QUIET_MAX_S:-3600}" start out rc
	shift
	local -a args=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--max) max=$(( $2 * 60 )); shift 2 ;;
		*) args+=("$1"); shift ;;
		esac
	done
	start="$(date +%s)"
	while :; do
		rc=0
		out="$(core_wait "$store" "${args[@]}")" || rc=$?
		if [ "$rc" -eq 4 ] && grep -q '^check-in:' <<<"$out" && ! quiet_flagged "$out" && [ $(( $(date +%s) - start )) -lt "$max" ]; then
			sleep 1
			continue
		fi
		[ "$rc" -ne 4 ] || ! grep -q '^check-in:' <<<"$out" || quiet_flagged "$out" ||
			printf 'quiet: %sm with nothing flagged; the sidekick works on\n' "$(( ($(date +%s) - start) / 60 ))"
		printf '%s\n' "$out"
		exit "$rc"
	done
}

cmd_wait() {
	[ $# -ge 1 ] || die "usage: kitchen.sh wait <store> [--timeout MS | --every MIN] [--max MIN]"
	quiet_wait "$@"
}

cmd_dispatch() {
	[ $# -ge 2 ] || die "usage: kitchen.sh dispatch <store> <brief-path> [--timeout MS | --every MIN] [--max MIN]"
	[ -f "$2" ] || die "brief not found: $2"
	if is_landing "$2"; then
		land_check "$1" >/dev/null || die "landing refused: kitchen.sh land-check $1 fails" 2
	else
		classify_brief "$1" "$2"
	fi
	local -a waitargs=() sendargs=()
	local a rc=0 out
	# A sidekick that starts fresh per brief (pi, devin) is rotated here once
	# its last unit is done, so the rotation costs the master no extra wake.
	# Partial or blocked work never sets rotation_required and keeps its session.
	if fresh_per_brief "$(field "$1" .sidekick.kind)" && [ "$(field "$1" '.sidekick.rotation_required // false')" = true ]; then
		# The report lands a moment before the sidekick's turn ends.
		herdr agent wait "$(field "$1" .sidekick.name)" --until idle --until "done" --timeout 60000 >/dev/null 2>&1 || true
		out="$(cmd_rotate "$1" 2>&1)" || rc=$?
		[ "$rc" -eq 0 ] || die "rotating the sidekick before this brief failed:
$out" "$rc"
		printf 'rotated: the %s sidekick starts this brief in a fresh session\n' "$(field "$1" .sidekick.kind)"
	fi
	for a in "${@:3}"; do waitargs+=("$a"); done
	# --max belongs to the quiet wait, not to the pair's dispatch.
	set -- "$1" "$2"
	local i=0
	while [ "$i" -lt "${#waitargs[@]}" ]; do
		if [ "${waitargs[$i]}" = --max ]; then i=$((i + 2)); else sendargs+=("${waitargs[$i]}"); i=$((i + 1)); fi
	done
	out="$(core_dispatch "$@" "${sendargs[@]}")" || rc=$?
	if [ "$rc" -eq 4 ] && grep -q '^check-in:' <<<"$out" && ! quiet_flagged "$out"; then
		printf '%s\n' "$(grep -v -e '^check-in:' -e '^progress:' -e '^touched:' -e '^  ' -e '^steers:' -e '^steps:' -e '^report: missing' <<<"$out")"
		quiet_wait "$1" "${waitargs[@]}"
	fi
	printf '%s\n' "$out"
	exit "$rc"
}

cmd_queue() {
	if [ $# -ge 2 ] && [ "$2" != --clear ] && [ -f "$2" ] && ! is_landing "$2"; then
		classify_brief "$1" "$2" >/dev/null
	fi
	core_queue "$@"
}

cmd_discuss() {
	[ $# -ge 2 ] || die "usage: kitchen.sh discuss <store> <plan-path> [--timeout MS]"
	[ -f "$2" ] || die "plan not found: $2"
	if [ "$(header_field "$2" risk)" = escalated ]; then
		[ "$(agent_status "$(field "$1" .consultant.name)")" != absent ] || die "an escalated plan goes to the consultant too; start it: kitchen.sh consultant $1 --reason TEXT" 5
		discuss_with_consultant "$@"
	else
		core_discuss "$@"
	fi
}

# The master reads every step of an escalated unit; a routine unit's steps
# are proved by their gates, and the master reads the unit once, at review.
steps_due() {
	local brief
	brief="$(field "$1" '.dispatch.brief // empty')"
	[ -n "$brief" ] && [ "$(header_field "$brief" risk)" = escalated ] || return 1
	core_steps_due "$@"
}

# A step is recorded only once the touched profiles' fast gates and the
# policy check pass on it. Two failures in a row are an exception for the
# master, reported as blocked. The checks run detached and step returns
# within KITCHEN_STEP_SLICE_S seconds (default 100): an agent harness moves a
# longer command to the background and can sit idle on it, so a step still
# checking says so, and running the same step command again waits on.
cmd_step() {
	[ $# -ge 3 ] || die "usage: kitchen.sh step <store> <sha> <summary> [--resolves n1,n2]"
	local store="$1" sha="$2" brief root base full json p fails file unit job slice
	pair_file "$store" >/dev/null
	brief="$(field "$store" '.dispatch.brief // empty')"
	[ -n "$brief" ] || die "no brief dispatched; a step belongs to a running brief"
	unit="$(basename "$brief" .md)"
	root="$(field "$store" .git_root)"
	full="$(git -C "$root" rev-parse --verify --quiet "$sha^{commit}")" || die "not a commit: $sha; commit the step first"
	file="$(steps_file "$store" "$brief")"
	base="$( { [ -s "$file" ] && tail -1 "$file" | cut -f2; } || jq -r --arg u "$unit" '.heads[$u] // empty' "$store/pair.json")"
	[ -n "$base" ] || die "no base for $unit; was it dispatched?"
	# A commit made before this brief was dispatched (a resumed unit) is the
	# brief's own base, which leaves an empty range; check its own diff.
	if [ "$(git -C "$root" rev-list --count "$base..$full" 2>/dev/null || printf 0)" -eq 0 ]; then
		base="$(git -C "$root" rev-parse --verify --quiet "$full~1")" || die "$sha has no parent to check it against"
	fi
	# A rewritten base (a squash, an amend) is measured from where the
	# histories fork, so the step covers every change it carries.
	base="$(git -C "$root" merge-base "$base" "$full" 2>/dev/null || printf '%s' "$base")"
	job="$store/steps/jobs/$unit-${full:0:12}"
	if [ ! -d "$job" ] || [ -f "$job/consumed" ]; then
		rm -rf "$job"
		mkdir -p "$job"
		json="$(kpy "$store" --json classify --base "$base" --head "$full")"
		printf '%s\n' "$json" >"$job/classify.json"
		jq -r '.profiles[]' <<<"$json" >"$job/profiles"
		printf '%s\n' "$base" >"$job/base"
		# shellcheck disable=SC2016
		setsid bash -c '
			cd "$1" || exit 1
			rc=0
			while IFS= read -r p; do
				[ -n "$p" ] || continue
				python3 "$2" --repo "$1" gate "$p" fast --role sidekick --base "$4" || rc=2
			done <"$3/profiles"
			python3 "$2" --repo "$1" policy --base "$4" --head "$5" || rc=2
			printf "%s\n" "$rc" >"$3/rc"
		' kitchen-step "$root" "$here/kitchen.py" "$job" "$base" "$full" >"$job/out" 2>&1 </dev/null &
		disown 2>/dev/null || true
	fi
	slice="${KITCHEN_STEP_SLICE_S:-100}"
	local deadline=$(( $(date +%s) + slice ))
	until [ -f "$job/rc" ]; do
		if [ "$(date +%s)" -ge "$deadline" ]; then
			printf 'gates: still running for %s (%ss so far; log: %s)\n' "${full:0:9}" "$(( $(date +%s) - $(file_mtime "$job/base") ))" "$job/out"
			printf 'next: run the same command again to keep waiting: kitchen.sh step %s %s "%s"\n' "$store" "$sha" "$3"
			exit 4
		fi
		sleep 2
	done
	: >"$job/consumed"
	local rc state
	rc="$(cat "$job/rc")"
	json="$(cat "$job/classify.json")"
	local -a profiles
	mapfile -t profiles <"$job/profiles"
	# A step with no profile ran no gate: it is recorded as none, never pass.
	if [ "$rc" -ne 0 ]; then state=fail
	elif [ "${#profiles[@]}" -eq 0 ]; then state=none
	else state=pass; fi
	mkdir -p "$store/steps"
	printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$unit" "${full:0:9}" "$state" "$(IFS=,; printf '%s' "${profiles[*]}")" >>"$store/gates.tsv"
	if [ "$rc" -ne 0 ]; then
		cat "$job/out"
		event "$store" sidekick gate-fail "$brief" "${full:0:9}"
		fails="$(awk -F '\t' -v u="$unit" '$2 == u {n = ($4 == "fail") ? n + 1 : 0} END {print n + 0}' "$store/gates.tsv")"
		if [ "$fails" -ge 2 ]; then
			printf 'next: %s failed checks in a row; write the report as blocked with the logs under Questions, then kitchen.sh finish\n' "$fails"
		else
			printf 'next: fix it in a new commit and run kitchen.sh step %s <new-sha> "%s" again\n' "$store" "$3"
		fi
		exit 2
	fi
	if [ "$state" = none ]; then
		printf 'gates: none ran; no profile covers %s\n' "$(jq -r '.unmapped | join(", ") | if . == "" then "these changes" else . end' <<<"$json")"
	else
		printf 'gates: pass (%s)\n' "$(IFS=,; printf '%s' "${profiles[*]}")"
	fi
	core_step "$@"
}

verdict_problem() {
	# $1 verdict: empty when it is well formed, else what is wrong.
	case "$(header_field "$1" status)" in
	clean | reject | inconclusive) ;;
	*) printf 'status is not clean, reject, or inconclusive'; return ;;
	esac
	awk '/^## Evidence/{e=1; next} /^## /{e=0} e && /^```/{n++} END{exit !(n >= 2)}' "$1" || printf 'no command output under Evidence'
}

audit_due() {
	# $1 unit id, $2 sample rate: a stable draw per unit.
	local h
	h="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
	awk -v h="$h" -v s="$2" 'BEGIN{exit !((h % 1000) < s * 1000)}'
}

# verify starts a verification and waits for it in slices of --every
# minutes, so one call never outlasts a master's shell limit; the verifier
# keeps working between calls, and `verify <store> --wait` picks it up. The
# open verification lives in pair.json .verifying, one at a time.
cmd_verify() {
	in_herdr
	[ $# -ge 2 ] || die "usage: kitchen.sh verify <store> <NNN>... [--covers NNN]... [--every MIN] [--timeout MIN] [--kind KIND] | kitchen.sh verify <store> --wait [--every MIN]"
	local store="$1" timeout_m="" every_m=9 wait=0 units=() kind_override=""
	local -a argv=("${@:2}")
	covered=()
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout_m="$2"; shift 2 ;;
		--kind) kind_override="$2"; shift 2 ;;
		--every) every_m="$2"; shift 2 ;;
		--covers) covered+=("$2"); shift 2 ;;
		--wait) wait=1; shift ;;
		[0-9][0-9][0-9]) units+=("$1"); shift ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	if [ "$wait" -eq 1 ]; then
		[ -n "$(field "$store" '.verifying.verdict // empty')" ] || die "no verification is open; start one with kitchen.sh verify $store <NNN>" 5
		verify_wait "$store" "$every_m"
	fi
	[ "${#units[@]}" -gt 0 ] || die "name at least one unit NNN"
	[ -z "$(field "$store" '.verifying.verdict // empty')" ] || die "a verification is open ($(field "$store" '.verifying.units')); kitchen.sh verify $store --wait" 5
	local -a all=("${covered[@]}" "${units[@]}")
	local root base head json last brief slug k verdict packet mode role risk
	root="$(field "$store" .git_root)"
	read -r base head <<<"$(unit_range "$store" "${all[@]}")"
	json="$(kpy "$store" --at "$head" --json classify --base "$base" --head "$head")"
	risk="$(jq -r .risk <<<"$json")"
	mode="$(jq -r .verify.mode <<<"$json")"
	role="$(jq -r .verify.kind <<<"$json")"
	# A batch of independent units has a size cap; a fix verified with the
	# unit it fixes does not, since splitting it would re-reject the first.
	if [ "${#covered[@]}" -eq 0 ] && [ "${#units[@]}" -gt 1 ] && [ "$(jq '.diff_lines > .max_batch_diff' <<<"$json")" = true ]; then
		die "batch of $(jq .diff_lines <<<"$json") diff lines is over review.max_batch_diff; verify each unit" 2
	fi
	last="${all[-1]}"
	brief="$(unit_brief "$store" "$last")"
	slug="$(basename "$brief" .md | cut -c5-)"
	k="$(next_index "$store/verdicts" "$last-$slug" v)"
	verdict="$store/verdicts/$last-$slug-v$k.md"
	packet="$store/verdicts/$last-$slug-v$k-packet.md"
	if [ "$mode" = gates ]; then
		{
			printf '# Verdict %s: %s\n\nstatus: clean\nunits: %s\nrange: %s..%s\nverifier: gates\n\n' "$last" "$slug" "${all[*]}" "${base:0:9}" "${head:0:9}"
			printf '## Findings\n\nnone\n\n## Evidence\n\nEvery step passed its profiles'"'"' fast gates and the policy check:\n\n```\n'
			local u
			for u in "${all[@]}"; do
				awk -F '\t' -v u="$(basename "$(unit_brief "$store" "$u")" .md)" '$2 == u' "$store/gates.tsv" 2>/dev/null || true
			done
			printf '```\n'
		} >"$verdict"
		event "$store" master verify "$brief" "gates:clean"
		printf 'verdict: %s\nstatus: clean (gates only; mode gates)\n' "$verdict"
		exit 0
	fi
	# The default deadline is three times the slowest recent passing run of
	# the profiles' behavioral gates, and never under 45 minutes.
	if [ -z "$timeout_m" ]; then
		local measured
		# shellcheck disable=SC2046
		measured="$(kpy "$store" --json timing --stage behavioral $(jq -r '.behavioral[]' <<<"$json") | jq '.seconds | ceil')"
		timeout_m=$(( (measured * 3 + 59) / 60 ))
		[ "$timeout_m" -ge 45 ] || timeout_m=45
	fi
	local kind name pane anchor scratch_id scratch new_pane_id
	local -a args=()
	if [ -n "$kind_override" ]; then
		kind="$kind_override"
		mapfile -t args < <(verifier_args "$store" "$kind")
	elif [ "$role" = sidekick ]; then
		kind="$(field "$store" .sidekick.kind)"
		mapfile -t args < <(jq -r '.sidekick.start_args[]?' "$store/pair.json")
	else
		kind="$(agent_kind "$(field "$store" .master.pane_id)")"
		mapfile -t args < <(permission_args "$kind" "$(detect_permission_mode)"; trust_args "$kind")
	fi
	[ -n "$kind" ] && [ "$kind" != null ] || die "cannot tell which agent kind verifies ($role)"
	scratch_id="$last-$slug-verify"
	scratch="$(cmd_scratch "$store" "$scratch_id" --at "$head" | tail -1)"
	{
		printf '# Verify %s: %s\n\nverdict: %s\ntemplate: %s\nscratch: %s\nrange: %s..%s\nrisk: %s\nunits: %s\n\n' \
			"$last" "$slug" "$verdict" "$skill_root/references/verdict-template.md" "$scratch" "$base" "$head" "$risk" "${all[*]}"
		[ "${#covered[@]}" -eq 0 ] || printf 'Unit %s fixes unit %s: prove every unit'"'"'s Acceptance at this one head.\n\n' "${units[*]}" "${covered[*]}"
		local u b
		for u in "${all[@]}"; do
			b="$(unit_brief "$store" "$u")"
			printf '## Unit %s\n\nbrief: %s\n\n' "$u" "$b"
			awk '/^## (Goal|Acceptance)/{p=1; print; next} /^## /{p=0} p' "$b"
			printf '\n'
		done
		printf '## Changed\n\n```\n%s\n```\n\n' "$(git -C "$root" diff --stat "$base...$head" | tail -40)"
		printf '## Prove\n\nYou share this machine with the sidekick. Run every repo command with\n`PSTACK_KITCHEN_ROLE=verifier` exported, so the repo'"'"'s scripts give you\nyour own ports, emulators, and data, and stop everything you start before\nyou end. Run these in the scratch worktree, then drive what they cannot reach:\n\n```bash\nexport PSTACK_KITCHEN_ROLE=verifier\n'
		jq -r --arg k "$here/kitchen.py" --arg s "$scratch" --arg b "$(git -C "$root" merge-base "$base" "$head" 2>/dev/null || printf '%s' "$base")" \
			'.behavioral[] | "python3 \($k) --repo \($s) gate \(.) behavioral --role verifier --base \($b)"' <<<"$json"
		printf '```\n\nfeature map: %s\n' "$(jq -r '.features | if length == 0 then "none listed" else join(", ") end' <<<"$json")"
		printf 'verification skill: %s\n' "$(ls -d "$root"/.agents/skills/verify-*/ 2>/dev/null | tr '\n' ' ' || true)"
	} >"$packet"
	name="$(field "$store" .verifier.name)"
	anchor="$(field "$store" '.sidekick.pane_id // empty')"
	[ -n "$anchor" ] && herdr pane get "$anchor" >/dev/null 2>&1 || anchor="$(field "$store" .master.pane_id)"
	new_pane "$store" verifier "$anchor" "" "$scratch" >/dev/null
	pane="$new_pane_id"
	if ! herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout 60000 -- "${args[@]}" >/dev/null; then
		local why="verifier start failed in $pane"
		if grep -qiE "$trust_re" <<<"$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null | tr -s '\n\t ' ' ')"; then
			why="$kind asks whether to trust $scratch, and that decision is yours: open $kind in the repo once and trust it, or verify with another kind"
			herdr pane send-keys "$pane" esc >/dev/null 2>&1 || true
		fi
		herdr pane close "$pane" >/dev/null 2>&1 || true
		cmd_scratch "$store" "$scratch_id" --remove >/dev/null
		die "$why" 5
	fi
	json_update "$store" --arg pane "$pane" --arg kind "$kind" --arg verdict "$verdict" --arg packet "$packet" \
		--arg brief "$brief" --arg scratch "$scratch_id" --arg units "${all[*]}" --arg risk "$risk" \
		--argjson sample "$(jq .sample <<<"$json")" --arg unit "$last-$slug" \
		--argjson started "$(date +%s)" --argjson deadline "$(( $(date +%s) + timeout_m * 60 ))" \
		--arg role "$role" --argjson argv "$(jq -cn '$ARGS.positional' --args -- "${argv[@]}")" \
		'.verifier.pane_id = $pane | .verifier.kind = $kind
		 | .verifying = {verdict: $verdict, packet: $packet, brief: $brief, scratch: $scratch, units: $units,
		                 risk: $risk, sample: $sample, unit: $unit, started: $started, deadline: $deadline,
		                 role: $role, argv: $argv}'
	event "$store" master send-verify "$brief" "$kind:${all[*]}"
	record_verifier_session "$store" "$name"
	printf 'verifier %s (%s) in %s on %s..%s\n' "$name" "$kind" "$pane" "${base:0:9}" "${head:0:9}"
	# A just-started agent can take the text before it takes the Enter (pi
	# drawing its startup screen), so the prompt must be seen working; an
	# idle agent gets one more Enter, which submits the typed text.
	herdr agent prompt "$name" "Load the $PAIR_SKILL skill from ~/.agents/skills/$PAIR_SKILL/SKILL.md and take the verifier role. $PAIR_SKILL VERIFY $packet" \
		--wait --until working --timeout 30000 >/dev/null 2>&1 || true
	submit_typed "$name" "$(basename "$packet")"
	record_verifier_session "$store" "$name"
	verify_wait "$store" "$every_m"
}

# A verifier of the fallback kind (or of any kind named with --kind) starts
# with the fallback's recorded arguments, its kind's permission default, and
# the trust flag; never with the sidekick's own model arguments.
verifier_args() {
	local store="$1" kind="$2" permission
	local -a args=()
	[ "$kind" != "$(field "$store" '.sidekick.fallback.kind // empty')" ] ||
		mapfile -t args < <(jq -r '.sidekick.fallback.args[]?' "$store/pair.json")
	if ! has_permission_arg "${args[@]}"; then
		case "$kind" in devin) permission=bypassPermissions ;; *) permission="$(detect_permission_mode)" ;; esac
		permission_args "$kind" "$permission"
	fi
	has_trust_arg "${args[@]}" || trust_args "$kind"
	[ "${#args[@]}" -eq 0 ] || printf '%s\n' "${args[@]}"
}

# The agent's own session log (pi writes one per session), so a verifier that
# died on its provider can still say why after its pane is gone.
record_verifier_session() {
	local session
	session="$(herdr agent get "$2" 2>/dev/null | jq -r '.result.agent.agent_session | select(.kind == "path") | .value' 2>/dev/null || true)"
	[ -z "$session" ] || json_update "$1" --arg s "$session" '.verifying.session = $s'
}

# The verifier's latest provider error: from its screen while it is up, else
# from the error stop its session log recorded. Empty when there is none.
verifier_provider_error() {
	local store="$1" name="$2" line="" session
	[ "$(agent_status "$name")" = absent ] ||
		line="$(grep -oiE ".{0,60}($provider_error_re).{0,100}" <<<"$(pane_text "$name")" | tail -1 || true)"
	session="$(field "$store" '.verifying.session // empty')"
	if [ -z "$line" ] && [ -n "$session" ] && [ -f "$session" ]; then
		line="$(tail -n 200 "$session" | jq -r 'select(.message.stopReason? == "error") | .message.errorMessage // empty' 2>/dev/null | tail -1 || true)"
	fi
	printf '%s' "${line:0:240}"
}

# Waits up to $2 minutes for the open verification's verdict. A verifier
# still working at the interval leaves the verification open (exit 4, with
# its progress); a verdict, a gone verifier, or the deadline closes it:
# the pane is closed, the scratch removed, and the verdict read.
verify_wait() {
	local store="$1" every_m="$2" verdict name kind until state="" now
	verdict="$(field "$store" .verifying.verdict)"
	name="$(field "$store" .verifier.name)"
	kind="$(field "$store" .verifier.kind)"
	until=$(( $(date +%s) + every_m * 60 ))
	while :; do
		[ -f "$verdict" ] && [ -n "$(header_field "$verdict" status)" ] && break
		state="$(agent_status "$name")"
		now="$(date +%s)"
		[ "$state" != absent ] && [ "$now" -lt "$(field "$store" .verifying.deadline)" ] || break
		if [ "$now" -ge "$until" ]; then
			printf 'verifying: units %s by %s, %sm of %sm, verifier %s\n' "$(field "$store" .verifying.units)" "$kind" \
				"$(( (now - $(field "$store" .verifying.started)) / 60 ))" "$(( ($(field "$store" .verifying.deadline) - $(field "$store" .verifying.started)) / 60 ))" "$state"
			printf 'next: other work, then kitchen.sh verify %s --wait\n' "$store"
			exit 4
		fi
		# A verifier that ended its turn on a provider error will not write.
		case "$state" in
		idle | "done") [ -z "$(verifier_provider_error "$store" "$name")" ] || break ;;
		esac
		sleep 10
	done
	[ -f "$verdict" ] && sleep 3
	local brief risk sample unit pane
	brief="$(field "$store" .verifying.brief)"
	risk="$(field "$store" .verifying.risk)"
	sample="$(field "$store" .verifying.sample)"
	unit="$(field "$store" .verifying.unit)"
	pane="$(field "$store" .verifier.pane_id)"
	local provider="" role
	local -a argv=()
	[ -f "$verdict" ] || provider="$(verifier_provider_error "$store" "$name")"
	role="$(field "$store" '.verifying.role // empty')"
	mapfile -t argv < <(jq -r '.verifying.argv[]?' "$store/pair.json")
	herdr agent prompt "$name" "$(exit_command "$kind")" >/dev/null 2>&1 || true
	local gone=$(( $(date +%s) + 15 ))
	while [ "$(agent_status "$name")" != absent ] && [ "$(date +%s)" -lt "$gone" ]; do sleep 1; done
	herdr pane close "$pane" >/dev/null 2>&1 || true
	cmd_scratch "$store" "$(field "$store" .verifying.scratch)" --remove >/dev/null
	json_update "$store" 'del(.verifying)'
	if [ ! -f "$verdict" ] && [ -n "$provider" ]; then
		event "$store" master wake "$brief" "verify:provider"
		printf 'verdict: none\nstatus: inconclusive (the verifier hit its provider, not the work)\nprovider_error: %s\n' "$provider"
		local fallback
		fallback="$(field "$store" '.sidekick.fallback.kind // empty')"
		if [ "$role" = sidekick ] && [ -n "$fallback" ] && [ "$fallback" != "$kind" ] && [ "${#argv[@]}" -gt 0 ]; then
			printf 'retry: verifying again on the fallback, %s\n' "$fallback"
			exec "$here/kitchen.sh" verify "$store" "${argv[@]}" --kind "$fallback"
		fi
		printf 'next: wait for the limit, or kitchen.sh verify %s %s --kind <another kind>\n' "$store" "${argv[*]}"
		exit 2
	fi
	if [ ! -f "$verdict" ]; then
		event "$store" master wake "$brief" "verify:missing"
		die "no verdict at $verdict (verifier ${state:-gone}); read the packet and verify by hand, or rerun" 4
	fi
	local problem status
	problem="$(verdict_problem "$verdict")"
	status="$(header_field "$verdict" status)"
	[ -z "$problem" ] || status=invalid
	event "$store" master verify "$brief" "$status"
	printf 'verdict: %s\nstatus: %s%s\n' "$verdict" "$status" "${problem:+ ($problem)}"
	case "$status" in
	clean)
		if [ "$risk" = routine ] && audit_due "$unit" "$sample"; then
			printf 'audit: yes; read the review-delta yourself before accepting, and kitchen.sh catch what the kitchen missed\n'
		else
			printf 'audit: no\n'
		fi
		exit 0 ;;
	reject)
		awk '/^## Findings/{p=1; next} /^## /{p=0} p' "$verdict" | sed '/^$/d' | head -20
		local rejects
		rejects="$(grep -l '^status: reject' "$store/verdicts/$unit"-v[0-9]*.md 2>/dev/null | grep -vc packet || true)"
		if [ "$rejects" -ge 2 ]; then
			printf 'next: second rejection of %s; read the verdict and the unit yourself before another fix\n' "$unit"
		else
			printf 'next: kitchen.sh revise %s %s, then verify the fix with --covers %s\n' "$store" "$verdict" "${unit:0:3}"
		fi
		exit 2 ;;
	*)
		printf 'next: read the verdict; an inconclusive or invalid one is the master'"'"'s to settle\n'
		exit 2 ;;
	esac
}

cmd_revise() {
	[ $# -eq 2 ] || die "usage: kitchen.sh revise <store> <verdict-path>"
	local store="$1" verdict="$2" last brief slug path
	[ -f "$verdict" ] || die "verdict not found: $verdict"
	[ "$(header_field "$verdict" status)" = reject ] || die "only a rejected verdict needs a fix brief"
	last="$(header_field "$verdict" units | awk '{print $NF}')"
	brief="$(unit_brief "$store" "$last")"
	slug="$(basename "$brief" .md | cut -c5- | sed -E 's/-fix[0-9]*$//')-fix"
	path="$(new_from_template "$store" "$slug" briefs brief-template.md)"
	VERDICT="$verdict" BRIEF="$brief" python3 - "$path" <<'PY'
import os, re, sys
path, verdict, brief = sys.argv[1], os.environ['VERDICT'], os.environ['BRIEF']
old, new = open(brief).read(), open(path).read()
def section(text, name):
    m = re.search(rf'^## {name}\n(.*?)(?=^## |\Z)', text, re.M | re.S)
    return m.group(1) if m else ''
def header(text, key):
    m = re.search(rf'^{key}: (.*)$', text, re.M)
    return m.group(1) if m else ''
new = re.sub(r'^playbook: .*$', 'playbook: bug-fix', new, count=1, flags=re.M)
for key in ('timebox', 'commit', 'plan'):
    new = re.sub(rf'^{key}: .*$', f'{key}: {header(old, key)}', new, count=1, flags=re.M)
fills = {
    'Goal': f'\nFix every finding in the verifier\'s verdict {verdict}, so a fresh verification of the same acceptance passes.\n\n',
    'Steps': '\n1. One commit per finding in the verdict: the change, and the check that shows the finding is gone.\n\n',
    'Context': f'\n- verdict: {verdict}\n- original brief: {brief}\n\n',
}
for name in ('Scope', 'Acceptance', 'Verify', 'Forbidden'):
    fills[name] = section(old, name)
for name, body in fills.items():
    new = re.sub(rf'(^## {name}\n)(.*?)(?=^## |\Z)', lambda m, b=body: m.group(1) + b, new, count=1, flags=re.M | re.S)
open(path, 'w').write(new)
PY
	printf '%s\n' "$path"
}

joo_bin() {
	command -v joo-dev || command -v joo || die "review.engine is joo, but neither joo-dev nor joo is on PATH" 1
}

blocking_findings() {
	# Every critical or high actionable finding across the run's artifacts
	# that has no resolution: id, severity, place, summary, artifact.
	local store="$1" f
	for f in "$store"/joo/*.json; do
		[ -e "$f" ] || continue
		jq -r --arg a "$f" '.findings[]? | select((.severity == "critical" or .severity == "high") and .status == "actionable")
			| [.id, .severity, "\(.filePath):\(.line)", (.summary // .rationale // "" | gsub("[\t\n]"; " ") | .[0:120]), $a] | @tsv' "$f"
	done | awk -F '\t' -v r="$store/resolutions.tsv" 'BEGIN{while ((getline l < r) > 0) {split(l, x, "\t"); done[x[2]] = 1}} !done[$1] && !seen[$1]++'
}

cmd_review() {
	[ $# -ge 2 ] || die "usage: kitchen.sh review <store> <NNN>... | kitchen.sh review <store> --landing"
	local store="$1" landing=0 units=() root base="" head json cls engine joo out k label tmp
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--landing) landing=1; shift ;;
		--base) base="$2"; shift 2 ;;
		[0-9][0-9][0-9]) units+=("$1"); shift ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	root="$(field "$store" .git_root)"
	if [ "$landing" -eq 1 ]; then
		head="$(git -C "$root" rev-parse HEAD)"
		# The stack is reviewed from where it leaves trunk. The run's first
		# dispatch head is stale once the stack is rebased, and reviewing from
		# it took trunk's own commits into the landing review.
		if [ -z "$base" ]; then
			# The checked-out branch is never its own trunk.
			local trunk="" ref current candidates
			current="$(git -C "$root" symbolic-ref --quiet HEAD 2>/dev/null || true)"
			candidates="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
			for ref in $candidates refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
				[ "$ref" != "$current" ] || continue
				git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null && { trunk="$ref"; break; }
			done
			[ -n "$trunk" ] || die "cannot tell this repo's trunk; pass --base <trunk ref or commit>"
			base="$(git -C "$root" merge-base "$trunk" "$head")" || die "no merge-base between $trunk and HEAD; pass --base"
			[ "$base" != "$head" ] || die "HEAD is already on ${trunk#refs/}, so the landing range is empty; pass --base <where the stack starts>"
			printf 'landing base: merge-base of %s and HEAD (%s)\n' "${trunk#refs/}" "${base:0:9}"
		fi
		base="$(git -C "$root" rev-parse --verify --quiet "$base^{commit}")" || die "--base is not a commit"
		label=landing
	else
		[ "${#units[@]}" -gt 0 ] || die "name the units, or --landing"
		read -r base head <<<"$(unit_range "$store" "${units[@]}")"
		label="${units[-1]}-$(basename "$(unit_brief "$store" "${units[-1]}")" .md | cut -c5-)"
	fi
	json="$(kpy "$store" --at "$head" --json classify --base "$base" --head "$head")"
	if [ "$landing" -eq 1 ]; then cls=landing; else cls="$(jq -r .risk <<<"$json")"; fi
	engine="$(jq -r .review.engine <<<"$json")"
	if [ "$engine" != joo ]; then
		printf 'review: engine none; read %s..%s yourself (the review-delta for a unit with steps)\n' "${base:0:9}" "${head:0:9}"
		exit 0
	fi
	local style budget second walk
	joo="$(joo_bin)"
	k="$(next_index "$store/joo" "$label" r)"
	out="$store/joo/$label-r$k.json"
	tmp="$(mktemp)"
	read -r style budget second walk <<<"$(kpy "$store" --at "$head" --json review-settings "$cls")"
	local -a flags=(--review-style "$style" --review-execution-budget "$budget")
	[ "$second" = true ] || flags+=(--no-second-reviewer)
	if [ "$walk" = true ]; then flags+=(--walkthrough); else flags+=(--no-walkthrough); fi
	event "$store" master send-review - "$label:$cls"
	printf 'joo %s review of %s..%s (%s, budget %s)\n' "$cls" "${base:0:9}" "${head:0:9}" "$style" "$budget"
	"$joo" engine review --repo "$root" --range "$base..$head" --json "${flags[@]}" >"$tmp" 2>"$tmp.err" ||
		{ cat "$tmp.err" >&2; rm -f "$tmp" "$tmp.err"; die "joo engine review failed" 2; }
	jq -e '.ok == true and .result.kind == "review-artifact"' "$tmp" >/dev/null || { rm -f "$tmp" "$tmp.err"; die "joo returned no review artifact" 2; }
	jq '.result' "$tmp" >"$out"
	rm -f "$tmp" "$tmp.err"
	printf 'artifact: %s\n' "$out"
	jq -r '"findings: \(.findings | length) (" + ([.findings[] | .severity] | group_by(.) | map("\(.[0]) \(length)") | join(", ")) + ")"' "$out"
	local open
	open="$(blocking_findings "$store")"
	if [ -n "$open" ]; then
		printf 'blocking without a resolution:\n'
		awk -F '\t' '{printf "  %s %s %s %s\n", $1, $2, $3, $4}' <<<"$open"
		printf 'next: read each (joo connected review context --artifact %s --finding <id> --json), then kitchen.sh resolve %s <id> fixed|followup|dismissed "<why>"\n' "$out" "$store"
		exit 2
	fi
	printf 'blocking: none open\n'
}

cmd_resolve() {
	[ $# -eq 4 ] || die "usage: kitchen.sh resolve <store> <finding-id> fixed|followup|dismissed <note>"
	local store="$1" id="$2" kind="$3" note="$4" f found=""
	case "$kind" in fixed | followup | dismissed) ;; *) die "resolution must be fixed, followup, or dismissed" ;; esac
	[ -n "$note" ] || die "a resolution needs its reason: the fixing commit, the follow-up, or why it is wrong"
	for f in "$store"/joo/*.json; do
		[ -e "$f" ] && jq -e --arg id "$id" 'any(.findings[]?; .id == $id)' "$f" >/dev/null && found="$f"
	done
	[ -n "$found" ] || die "no finding $id in $store/joo"
	[ -f "$store/resolutions.tsv" ] || printf 'ts\tfinding\tresolution\tnote\tartifact\n' >"$store/resolutions.tsv"
	printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$kind" "$(printf '%s' "$note" | tr '\t\n' '  ')" "$(basename "$found")" >>"$store/resolutions.tsv"
	[ "$kind" != followup ] || printf -- '- %s (joo %s): %s\n' "$(jq -r --arg id "$id" '.findings[] | select(.id == $id) | .summary // .rationale' "$found" | head -1)" "$id" "$note" >>"$store/followups.md"
	event "$store" master resolve - "$id:$kind"
	printf 'resolved %s: %s\n' "$id" "$kind"
}

land_check() {
	# Prints one line per problem; returns 1 when there is any.
	local store="$1" r seq brief verdict f problems=0 engine=none open
	for r in "$store"/reviews/[0-9][0-9][0-9]-*.md; do
		[ -e "$r" ] || continue
		[ "$(header_field "$r" verdict)" = accept ] || continue
		seq="$(basename "$r" | cut -c1-3)"
		brief="$(ls "$store"/briefs/"$seq"-*.md 2>/dev/null | head -1 || true)"
		[ -n "$brief" ] && [ "$(header_field "$brief" commit | cut -c1-3)" = yes ] || continue
		is_landing "$brief" && continue
		verdict=""
		for f in "$store"/verdicts/*-v[0-9]*.md; do
			[ -e "$f" ] && [[ "$f" != *-packet.md ]] || continue
			grep -qE "^units:(.* )?$seq( |$)" "$f" && [ "$(header_field "$f" status)" = clean ] && verdict="$f"
		done
		if [ -z "$verdict" ]; then
			printf 'unverified: unit %s has no clean verdict (kitchen.sh verify %s %s)\n' "$seq" "$store" "$seq"
			problems=$((problems + 1))
		fi
	done
	if ls "$store"/joo/*.json >/dev/null 2>&1; then engine=joo; fi
	open="$(blocking_findings "$store")"
	if [ -n "$open" ]; then
		awk -F '\t' '{printf "unresolved: %s %s %s %s\n", $1, $2, $3, $4}' <<<"$open"
		problems=$((problems + $(grep -c . <<<"$open")))
	fi
	[ "$problems" -eq 0 ] || return 1
	printf 'land-check: pass (review engine: %s)\n' "$engine"
}

cmd_land_check() {
	[ $# -eq 1 ] || die "usage: kitchen.sh land-check <store>"
	pair_file "$1" >/dev/null
	land_check "$1" || exit 2
}

cmd_catch() {
	[ $# -eq 3 ] || die "usage: kitchen.sh catch <store> <layer> <text>"
	local store="$1" layer="$2" text="$3" ledger
	case "$layer" in gate | policy | self | verify | review | triage | escalation) ;; *) die "layer is gate, policy, self, verify, review, triage, or escalation: the one that should have caught it" ;; esac
	pair_file "$store" >/dev/null
	ledger="$(kpy "$store" statedir)/ledger.tsv"
	[ -f "$ledger" ] || printf 'ts\trun\tkind\tclass\tdetail\n' >"$ledger"
	printf '%s\t%s\tcatch\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(field "$store" .slug)" "$layer" "$(printf '%s' "$text" | tr '\t\n' '  ')" >>"$ledger"
	event "$store" master catch - "$layer"
	printf 'caught at %s: %s\n' "$layer" "$text"
}

# Where the master was needed, and what repeated. Each repeated class is a
# candidate for the kitchen: a rule, a lint, a profile command, a sharper
# brief. Appends this run's classes to the repo's ledger, then counts across
# runs.
cmd_retro() {
	[ $# -eq 1 ] || die "usage: kitchen.sh retro <store>"
	local store="$1" ledger run now
	pair_file "$store" >/dev/null
	ledger="$(kpy "$store" statedir)/ledger.tsv"
	run="$(field "$store" .slug)"
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	[ -f "$ledger" ] || printf 'ts\trun\tkind\tclass\tdetail\n' >"$ledger"
	# This run's rows replace any it wrote before, so retro can run again.
	awk -F '\t' -v r="$run" 'NR == 1 || $2 != r || $3 == "catch"' "$ledger" >"$ledger.tmp" && mv "$ledger.tmp" "$ledger"
	{
		[ -f "$store/gates.tsv" ] && awk -F '\t' -v t="$now" -v r="$run" '$4 == "fail" {printf "%s\t%s\tgate-fail\t%s\t%s %s\n", t, r, $5, $2, $3}' "$store/gates.tsv"
		for f in "$store"/verdicts/*-v[0-9]*.md; do
			[ -e "$f" ] && [[ "$f" != *packet* ]] && [ "$(header_field "$f" status)" = reject ] && printf '%s\t%s\treject\tverify\t%s\n' "$now" "$run" "$(basename "$f" .md)"
		done
		for f in "$store"/joo/*.json; do
			[ -e "$f" ] && jq -r --arg t "$now" --arg r "$run" '.findings[]? | select(.status == "actionable") | [$t, $r, "finding", (.category // "uncategorized"), .severity] | @tsv' "$f"
		done
		[ -f "$store/resolutions.tsv" ] && awk -F '\t' -v t="$now" -v r="$run" 'NR > 1 && $3 == "dismissed" {printf "%s\t%s\tdismissed\treview\t%s\n", t, r, $2}' "$store/resolutions.tsv"
		for f in "$store"/steers/*-s[0-9]*.md; do [ -e "$f" ] && printf '%s\t%s\tsteer\tbrief\t%s\n' "$now" "$run" "$(basename "$f" .md)"; done
	} >>"$ledger"
	local f units verified clean_first wakes escalations failovers
	units=0
	for f in "$store"/briefs/[0-9][0-9][0-9]-*.md; do
		[ -e "$f" ] && [ "$(header_field "$(expected_report "$store" "$f")" status 2>/dev/null)" = "done" ] && units=$((units + 1))
	done
	verified="$(grep -l '^status: clean' "$store"/verdicts/*-v[0-9]*.md 2>/dev/null | grep -vc packet || true)"
	clean_first="$(grep -l '^status: clean' "$store"/verdicts/*-v1.md 2>/dev/null | grep -vc packet || true)"
	wakes="$(awk -F '\t' '$3 == "master" && $4 == "wake"' "$store/events.tsv" 2>/dev/null | grep -c . || true)"
	escalations="$(awk -F '\t' '$4 == "escalate"' "$store/events.tsv" 2>/dev/null | grep -c . || true)"
	failovers="$(awk -F '\t' '$4 == "failover"' "$store/events.tsv" 2>/dev/null | grep -c . || true)"
	printf 'run %s: %s unit reports, %s clean verdicts (%s on the first try), %s master wakes, %s escalations, %s failovers\n' \
		"$run" "$units" "$verified" "$clean_first" "$wakes" "$escalations" "$failovers"
	[ "$verified" -eq 0 ] || printf 'master wakes per verified unit: %s\n' "$(awk -v w="$wakes" -v v="$verified" 'BEGIN{printf "%.1f", w / v}')"
	printf 'repeated across runs (the kitchen should catch these, not the master):\n'
	awk -F '\t' 'NR > 1 {k = $3 "\t" $4; n[k]++; if (!((k, $2) in seen)) {seen[k, $2] = 1; runs[k]++}}
		END {for (k in n) if (n[k] >= 2) {split(k, p, "\t"); printf "  %3d %-10s %-24s in %d runs\n", n[k], p[1], p[2], runs[k]}}' "$ledger" | sort -rn || true
	cat <<'HINT'
encode a repeated class at the highest level that works (the correct skill):
  gate-fail <profile>  a sharper brief, or a lint whose error names the fix
  finding <category>   a lint or type for the pattern; joo reviewer skills for repo-specific taste
  dismissed review     joo is wrong here repeatedly: tune its reviewer skills or config
  reject verify        acceptance the gates do not cover: add a behavioral command or test
  steer brief          briefs miss a decision the master keeps making: a standing order or plan template line
  catch <layer>        the layer that should have caught it gets the check
HINT
}

pair_main "$@"
