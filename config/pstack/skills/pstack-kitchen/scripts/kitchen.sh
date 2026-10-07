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
skills_dir="$(dirname "$skill_root")"
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
  verify <store> <NNN>... [--covers NNN]... [--base REV] [--every MIN] [--timeout MIN] [--kind KIND]
                                            verify one unit, or several as a batch, or a fix with the unit it
                                            fixes (--covers): gates only, or a fresh verifier in a scratch
                                            worktree at the head; returns at the interval with its progress
                                            (exit 4), and with the verdict and whether to audit when it lands.
                                            A verifier stopped by its provider is retried on the sidekick's
                                            fallback; the deadline defaults to 3x the measured gate time
  verify <store> --landing [--base REV]     a fresh verifier at the stack tip: every behavioral gate the stack
                                            touches, from where it leaves trunk (or --base)
  verify <store> --wait [--every MIN]       wait again for the open verification: exit 4 while it runs, 5 when none
                                            is open
  revise <store> <verdict-path>             draft the fix brief for a rejected verdict
  review <store> <NNN>... [--base REV] | --landing [--base REV]
                                            Judge of Owls on the units' range, or for landing on the stack from
                                            where it leaves trunk (or --base); prints blocking findings unresolved
  resolve <store> <finding-id> fixed|followup|dismissed <note>
                                            record the master's decision on a finding
  land-check <store>                        every accepted unit verified and every blocking finding resolved
  catch <store> <layer> <text>              record a miss found later (audit, human review): layer is
                                            gate, policy, self, verify, review, triage, or escalation
  retro <store>                             where the master was needed, and what repeated, from this run
                                            and the repo's ledger
  feedback <store> <file>                   file the master's kitchen gaps (see references/feedback-template.md)
                                            into the host inbox; tells the registered maintainer, else the human
  feedback --inbox                          open reports, oldest first
  feedback --close <id> <commit|none> <note>
                                            retire a report (closing twice is harmless)
  maintainer on [--pane ID] | off | status  register this session to receive FEEDBACK pointers
  fleet [--since YYYY-MM-DD] [--runs DIR] [--json]
                                            one row per run on the host (verified units, wakes, failovers,
                                            provider stops, catches, open feedback), then one per skills build;
                                            read-only, no store needed

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

# The repo's trunk: origin's default branch, else main or master; never the
# checked-out branch itself. Prints the ref, or nothing.
trunk_ref() {
	local root="$1" ref current candidates
	current="$(git -C "$root" symbolic-ref --quiet HEAD 2>/dev/null || true)"
	candidates="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
	for ref in $candidates refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
		[ "$ref" != "$current" ] || continue
		git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null && { printf '%s\n' "$ref"; return 0; }
	done
}

# Where a stack at $2 leaves trunk, in $landing_base_rev; call it directly,
# not in a command substitution, so its refusals end the command.
landing_base() {
	local root="$1" head="$2" trunk
	trunk="$(trunk_ref "$root")"
	[ -n "$trunk" ] || die "cannot tell this repo's trunk; pass --base <trunk ref or commit>"
	landing_base_rev="$(git -C "$root" merge-base "$trunk" "$head")" || die "no merge-base between $trunk and HEAD; pass --base"
	[ "$landing_base_rev" != "$head" ] || die "HEAD is already on ${trunk#refs/}, so the landing range is empty; pass --base <where the stack starts>"
	printf 'landing base: merge-base of %s and HEAD (%s)\n' "${trunk#refs/}" "${landing_base_rev:0:9}"
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
	local root mb tmb trunk
	root="$(field "$store" .git_root)"
	head="$(git -C "$root" rev-parse --verify --quiet "$head^{commit}")" || die "unit $last's head is not a commit"
	if [ -n "${range_base:-}" ]; then
		base="$(git -C "$root" rev-parse --verify --quiet "$range_base^{commit}")" || die "--base $range_base is not a commit"
	else
		# A unit is never measured from before where its branch leaves trunk:
		# one dispatched before a landing (a squash, a rebase) keeps a base
		# that trunk has since replaced, and its merge-base with the head is
		# the old trunk, which would take the whole landed stack in.
		mb="$(git -C "$root" merge-base "$base" "$head" 2>/dev/null || printf '%s' "$base")"
		trunk="$(trunk_ref "$root")"
		if [ -n "$trunk" ] && tmb="$(git -C "$root" merge-base "$trunk" "$head" 2>/dev/null)" &&
			[ "$tmb" != "$head" ] && [ "$tmb" != "$mb" ] && git -C "$root" merge-base --is-ancestor "$mb" "$tmb"; then
			printf 'note: unit %s'"'"'s recorded base %s is behind where its branch leaves %s; measuring from %s\n' \
				"$first" "${base:0:9}" "${trunk#refs/}" "${tmb:0:9}" >&2
			base="$tmb"
		fi
	fi
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
# The flake rev that built a skills directory, from the switch's builds.tsv
# ("unknown" for a path no switch recorded, such as a working checkout).
build_rev() {
	local rev
	rev="$(awk -F '\t' -v p="$1" '$3 == p {r = $2} END {print r}' "${XDG_STATE_HOME:-$HOME/.local/state}/pstack/builds.tsv" 2>/dev/null || true)"
	printf '%s\n' "${rev:-unknown}"
}

# A run stamped at init lists the skills directories its commands ran from; a
# command from a different one adds a row. A run from before stamps stays unstamped.
record_skill_build() {
	[ "$(field "$1" '.skill_builds // empty | length')" != "" ] || return 0
	[ "$(field "$1" '.skill_builds[-1].path')" != "$skills_dir" ] || return 0
	json_update "$1" --arg p "$skills_dir" --arg a "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.skill_builds += [{path: $p, at: $a}]'
}

cmd_init() {
	local out store json orders
	out="$(core_init "$@")"
	printf '%s\n' "$out"
	orders="$(sed -n 's/^standing orders: //p' <<<"$out")"
	store="$(dirname "$orders")"
	json_update "$store" --arg p "$skills_dir" --arg a "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.skill_builds = [{path: $p, at: $a}]'
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
	set_header "$brief" verify "$(jq -r '"\(.verify.mode) by \(.verify.kind) verifier"' <<<"$json")"
	printf 'risk: %s\n' "$risk"
	jq -r '"profiles: \(.profiles | join(", "))", "verify: \(.verify.mode) by \(.verify.kind) verifier", (.escalate[] | "escalate: \(.)"),
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
		# A pass that needed a rerun under load is recorded, so retro shows
		# which suites flake on a loaded machine.
		local flaky
		flaky="$(sed -n 's/^flaky under load: \([^ ]*\) .*/\1/p' "$job/out" | sort -u | paste -sd, -)"
		if [ -n "$flaky" ]; then
			printf 'flaky under load: %s failed, then passed on a rerun (see %s)\n' "$flaky" "$job/out"
			event "$store" sidekick gate-flaky "$brief" "$flaky"
		fi
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
	[ $# -ge 2 ] || die "usage: kitchen.sh verify <store> <NNN>... [--covers NNN]... [--base REV] [--every MIN] [--timeout MIN] [--kind KIND] | kitchen.sh verify <store> --landing [--base REV] [...] | kitchen.sh verify <store> --wait [--every MIN]"
	local store="$1" timeout_m="" every_m=9 wait=0 units=() kind_override="" landing=0 retry_entry=""
	range_base=""
	local -a argv=("${@:2}")
	covered=()
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout_m="$2"; shift 2 ;;
		--kind) kind_override="$2"; shift 2 ;;
		--retry-entry) retry_entry="$2"; shift 2 ;;
		--every) every_m="$2"; shift 2 ;;
		--covers) covered+=("$2"); shift 2 ;;
		--base) range_base="$2"; shift 2 ;;
		--landing) landing=1; shift ;;
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
	[ "$landing" -eq 1 ] || [ "${#units[@]}" -gt 0 ] || die "name at least one unit NNN, or --landing"
	[ "$landing" -eq 0 ] || [ "${#units[@]}" -eq 0 ] || die "--landing verifies the whole stack; name no units"
	[ -z "$(field "$store" '.verifying.verdict // empty')" ] || die "a verification is open ($(field "$store" '.verifying.units')); kitchen.sh verify $store --wait" 5
	local -a all=("${covered[@]}" "${units[@]}")
	local root base head json last brief slug k verdict packet mode class risk
	root="$(field "$store" .git_root)"
	if [ "$landing" -eq 1 ]; then
		# The stack tip, from where it leaves trunk, by a fresh verifier of
		# the escalated class: a squash or rebase step touches no profile, so
		# the units' own verdicts never saw the stack as it lands.
		head="$(git -C "$root" rev-parse HEAD)"
		if [ -n "$range_base" ]; then
			base="$(git -C "$root" rev-parse --verify --quiet "$range_base^{commit}")" || die "--base $range_base is not a commit"
		else
			landing_base "$root" "$head"
			base="$landing_base_rev"
		fi
		json="$(kpy "$store" --at "$head" --json classify --base "$base" --head "$head")"
		risk=landing
		mode=unit
		class=escalated
	else
		read -r base head <<<"$(unit_range "$store" "${all[@]}")"
		json="$(kpy "$store" --at "$head" --json classify --base "$base" --head "$head")"
		risk="$(jq -r .risk <<<"$json")"
		mode="$(jq -r .verify.mode <<<"$json")"
		class="$(jq -r .verify.kind <<<"$json")"
	fi
	# A batch of independent units has a size cap; a fix verified with the
	# unit it fixes does not, since splitting it would re-reject the first.
	if [ "${#covered[@]}" -eq 0 ] && [ "${#units[@]}" -gt 1 ] && [ "$(jq '.diff_lines > .max_batch_diff' <<<"$json")" = true ]; then
		die "batch of $(jq .diff_lines <<<"$json") diff lines is over review.max_batch_diff; verify each unit" 2
	fi
	if [ "$landing" -eq 1 ]; then
		last=landing
		brief=-
		k="$(next_index "$store/verdicts" landing v)"
		verdict="$store/verdicts/landing-v$k.md"
		packet="$store/verdicts/landing-v$k-packet.md"
	else
		last="${all[-1]}"
		brief="$(unit_brief "$store" "$last")"
		slug="$(basename "$brief" .md | cut -c5-)"
		k="$(next_index "$store/verdicts" "$last-$slug" v)"
		verdict="$store/verdicts/$last-$slug-v$k.md"
		packet="$store/verdicts/$last-$slug-v$k-packet.md"
	fi
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
	local kind name pane anchor scratch_id scratch new_pane_id entry
	local -a args=()
	entry="$(verifier_entry "$store" "$class")"
	if [ -n "$retry_entry" ]; then
		kind="$(jq -r .kind <<<"$retry_entry")"
		mapfile -t args < <(verifier_args "$kind" "$(jq -c '{kind, args}' <<<"$retry_entry")")
	elif [ -n "$kind_override" ]; then
		kind="$kind_override"
		mapfile -t args < <(verifier_args "$kind" "$(jq -c --arg k "$kind" '[., .fallback][] | select(. != null and .kind == $k) | {kind, args}' <<<"$entry" | head -1)")
	else
		kind="$(jq -r .kind <<<"$entry")"
		mapfile -t args < <(verifier_args "$kind" "$entry")
	fi
	[ -n "$kind" ] && [ "$kind" != null ] || die "cannot tell which agent kind verifies ($class)"
	if [ "$landing" -eq 1 ]; then scratch_id="000-landing-verify"; else scratch_id="$last-$slug-verify"; fi
	scratch="$(cmd_scratch "$store" "$scratch_id" --at "$head" | tail -1)"
	{
		local u b
		if [ "$landing" -eq 1 ]; then
			printf '# Verify landing: the stack at %s\n\nverdict: %s\ntemplate: %s\nscratch: %s\nrange: %s..%s\nrisk: landing\nunits: landing\n\n' \
				"${head:0:9}" "$verdict" "$skill_root/references/verdict-template.md" "$scratch" "$base" "$head"
			printf '## Stack\n\nEach unit below was verified on its own. Prove that together, at this tip,\nthey still hold: run every Prove command, then drive the main flows the\nbriefs describe, and try the seams between units. Read a brief only for\nthe flow you are driving.\n\n'
			for b in "$store"/briefs/[0-9][0-9][0-9]-*.md; do
				[ -e "$b" ] && [ "$(header_field "$(expected_report "$store" "$b")" status 2>/dev/null)" = "done" ] || continue
				is_landing "$b" && continue
				printf -- '- %s\n' "$b"
			done
			printf '\n'
		else
			printf '# Verify %s: %s\n\nverdict: %s\ntemplate: %s\nscratch: %s\nrange: %s..%s\nrisk: %s\nunits: %s\n\n' \
				"$last" "$slug" "$verdict" "$skill_root/references/verdict-template.md" "$scratch" "$base" "$head" "$risk" "${all[*]}"
			[ "${#covered[@]}" -eq 0 ] || printf 'Unit %s fixes unit %s: prove every unit'"'"'s Acceptance at this one head.\n\n' "${units[*]}" "${covered[*]}"
			for u in "${all[@]}"; do
				b="$(unit_brief "$store" "$u")"
				printf '## Unit %s\n\nbrief: %s\n\n' "$u" "$b"
				awk '/^## (Goal|Acceptance)/{p=1; print; next} /^## /{p=0} p' "$b"
				printf '\n'
			done
		fi
		printf '## Changed\n\n```\n%s\n```\n\n' "$(git -C "$root" diff --stat "$base...$head" | tail -40)"
		printf '## Prove\n\nYou share this machine with the sidekick. Run every repo command with\n`PSTACK_KITCHEN_ROLE=verifier` exported, so the repo'"'"'s scripts give you\nyour own ports, emulators, and data, and stop everything you start before\nyou end. Run these in the scratch worktree, then drive what they cannot reach:\n\n```bash\nexport PSTACK_KITCHEN_ROLE=verifier\n'
		jq -r --arg k "$here/kitchen.py" --arg s "$scratch" 'if (.scratch_setup | length) > 0 then "python3 \($k) --repo \($s) setup" else empty end' <<<"$json"
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
		--arg brief "$brief" --arg scratch "$scratch_id" --arg units "${all[*]:-landing}" --arg risk "$risk" \
		--argjson sample "$(if [ "$landing" -eq 1 ]; then echo 0; else jq .sample <<<"$json"; fi)" \
		--arg unit "$(if [ "$landing" -eq 1 ]; then echo landing; else echo "$last-$slug"; fi)" \
		--argjson started "$(date +%s)" --argjson deadline "$(( $(date +%s) + timeout_m * 60 ))" \
		--arg class "$class" --argjson entry "$entry" --argjson retried "$(if [ -n "$retry_entry" ]; then echo true; else echo false; fi)" \
		--argjson argv "$(jq -cn '$ARGS.positional' --args -- "${argv[@]}")" \
		'.verifier.pane_id = $pane | .verifier.kind = $kind
		 | .verifying = {verdict: $verdict, packet: $packet, brief: $brief, scratch: $scratch, units: $units,
		                 risk: $risk, sample: $sample, unit: $unit, started: $started, deadline: $deadline,
		                 class: $class, entry: $entry, retried: $retried, argv: $argv}'
	event "$store" master send-verify "$brief" "$kind:${all[*]:-landing}"
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

# The verifier for a class: the host roster's entry, with the sidekick marker
# resolved from the run (so after a failover it is the agent now implementing)
# and the master sentinel resolved to the master's own kind. One JSON object:
# kind, args, fallback (kind and args, or null), and where it came from.
verifier_entry() {
	local store="$1" class="$2" entry kind
	entry="$(python3 "$here/kitchen.py" --json roster | jq -c --arg c "$class" '.verifier[$c]')"
	kind="$(jq -r .kind <<<"$entry")"
	case "$kind" in
	sidekick)
		jq -c '{kind: .sidekick.kind, args: (.sidekick.start_args // []), source: "sidekick",
			fallback: (if .sidekick.fallback.kind then {kind: .sidekick.fallback.kind, args: (.sidekick.fallback.args // [])} else null end)}' "$store/pair.json" ;;
	master)
		jq -c --arg k "$(agent_kind "$(field "$store" .master.pane_id)")" '.kind = $k | .args = [] | .source = "master"' <<<"$entry" ;;
	*) printf '%s\n' "$entry" ;;
	esac
}

# A verifier starts with its entry's arguments, then its kind's permission
# default and trust flag when they are missing; $2 is the entry (or an empty
# string for a kind the class does not name).
verifier_args() {
	local kind="$1" entry="$2" permission
	local -a args=()
	[ -z "$entry" ] || mapfile -t args < <(jq -r '.args[]?' <<<"$entry")
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
	if [ -z "$line" ]; then
		local cwd=""
		[ "$(field "$store" .verifier.kind)" != pi ] ||
			cwd="$(readlink -f "$store/scratch/$(field "$store" .verifying.scratch)" 2>/dev/null || true)"
		line="$(agent_session_error "$session" "$cwd")"
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
	local provider="" fallback="" retried
	local -a argv=()
	[ -f "$verdict" ] || provider="$(verifier_provider_error "$store" "$name")"
	fallback="$(field "$store" '.verifying.entry.fallback // empty' | jq -c . 2>/dev/null || true)"
	retried="$(field "$store" '.verifying.retried // false')"
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
		if [ "$retried" = false ] && [ -n "$fallback" ] && [ "$(jq -r .kind <<<"$fallback")" != "$kind" ] && [ "${#argv[@]}" -gt 0 ]; then
			printf 'retry: verifying again on the fallback, %s\n' "$(jq -r .kind <<<"$fallback")"
			exec "$here/kitchen.sh" verify "$store" "${argv[@]}" --retry-entry "$fallback"
		fi
		# A retried call carries its entry; the advice is for the master's own call.
		local -a shown=()
		local i
		for ((i = 0; i < ${#argv[@]}; i++)); do
			if [ "${argv[i]}" = --retry-entry ]; then i=$((i + 1)); else shown+=("${argv[i]}"); fi
		done
		printf 'next: wait for the limit, or kitchen.sh verify %s %s --kind <another kind>\n' "$store" "${shown[*]}"
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
		if [ "$unit" = landing ]; then
			printf 'next: brief a fix for each finding, then kitchen.sh verify %s --landing again\n' "$store"
		elif [ "$rejects" -ge 2 ]; then
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

# The latest round of each review: joo/<label>-r<k>.json, highest k. A
# re-review supersedes the round before it, whose findings no longer block.
latest_reviews() {
	local f b
	for f in "$1"/joo/*.json; do
		[ -e "$f" ] || continue
		b="$(basename "$f" .json)"
		printf '%s\t%s\t%s\n' "${b%-r*}" "${b##*-r}" "$f"
	done | sort -t "$(printf '\t')" -k1,1 -k2,2n | awk -F '\t' '{last[$1] = $3} END {for (k in last) print last[k]}' | sort
}

blocking_findings() {
	# Every critical or high actionable finding in the latest round of each
	# review that has no resolution: id, severity, place, summary, artifact.
	local store="$1" f
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		jq -r --arg a "$f" '.findings[]? | select((.severity == "critical" or .severity == "high") and .status == "actionable")
			| [.id, .severity, "\(.filePath):\(.line)", (.summary // .rationale // "" | gsub("[\t\n]"; " ") | .[0:120]), $a] | @tsv' "$f"
	done < <(latest_reviews "$store") | awk -F '\t' -v r="$store/resolutions.tsv" 'BEGIN{while ((getline l < r) > 0) {split(l, x, "\t"); done[x[2]] = 1}} !done[$1] && !seen[$1]++'
}

cmd_review() {
	[ $# -ge 2 ] || die "usage: kitchen.sh review <store> <NNN>... [--base REV] | kitchen.sh review <store> --landing [--base REV]"
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
			landing_base "$root" "$head"
			base="$landing_base_rev"
		fi
		base="$(git -C "$root" rev-parse --verify --quiet "$base^{commit}")" || die "--base is not a commit"
		label=landing
	else
		[ "${#units[@]}" -gt 0 ] || die "name the units, or --landing"
		range_base="$base"
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
	# A landing verification is reported, not required.
	local landing_verdict="" lk best=0
	for f in "$store"/verdicts/landing-v[0-9]*.md; do
		[ -e "$f" ] && [[ "$f" != *-packet.md ]] || continue
		lk="${f##*-v}"
		lk="${lk%.md}"
		[ "$lk" -le "$best" ] || { best="$lk"; landing_verdict="$f"; }
	done
	if [ -n "$landing_verdict" ]; then
		printf 'landing verification: %s (%s)\n' "$(header_field "$landing_verdict" status)" "$landing_verdict"
	else
		printf 'landing verification: none; kitchen.sh verify %s --landing proves the stack tip with a fresh verifier\n' "$store"
	fi
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

# The run's counts, read-only and from the same function fleet uses: sets
# the rc_* globals. retro prints them and feedback quotes the same line.
retro_counts() {
	local c
	c="$(python3 "$here/kitchen.py" counters "$1")"
	rc_units="$(jq .done_units <<<"$c")"
	rc_verified="$(jq .verified_units <<<"$c")"
	rc_clean_first="$(jq .clean_first_try <<<"$c")"
	rc_wakes="$(jq .wakes <<<"$c")"
	rc_escalations="$(jq .escalations <<<"$c")"
	rc_failovers="$(jq .failovers <<<"$c")"
	rc_repo="$(jq -r .repo <<<"$c")"
}

retro_line() {
	printf 'run %s: %s unit reports, %s verified units (%s clean verdicts on the first try), %s master wakes, %s escalations, %s failovers\n' \
		"$(field "$1" .slug)" "$rc_units" "$rc_verified" "$rc_clean_first" "$rc_wakes" "$rc_escalations" "$rc_failovers"
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
		[ -f "$store/events.tsv" ] && awk -F '\t' -v t="$now" -v r="$run" '$4 == "gate-flaky" {printf "%s\t%s\tgate-flaky\t%s\t%s\n", t, r, $6, $5}' "$store/events.tsv"
	} >>"$ledger"
	retro_counts "$store"
	retro_line "$store"
	[ "$rc_verified" -eq 0 ] || printf 'master wakes per verified unit: %s\n' "$(awk -v w="$rc_wakes" -v v="$rc_verified" 'BEGIN{printf "%.1f", w / v}')"
	printf 'repeated across runs (the kitchen should catch these, not the master):\n'
	awk -F '\t' 'NR > 1 {k = $3 "\t" $4; n[k]++; if (!((k, $2) in seen)) {seen[k, $2] = 1; runs[k]++}}
		END {for (k in n) if (n[k] >= 2) {split(k, p, "\t"); printf "  %3d %-10s %-24s in %d runs\n", n[k], p[1], p[2], runs[k]}}' "$ledger" | sort -rn || true
	cat <<'HINT'
encode a repeated class at the highest level that works (the correct skill):
  gate-fail <profile>  a sharper brief, or a lint whose error names the fix
  gate-flaky <profile> a suite that fails under load: related tests per step, the full suite in behavioral
  finding <category>   a lint or type for the pattern; joo reviewer skills for repo-specific taste
  dismissed review     joo is wrong here repeatedly: tune its reviewer skills or config
  reject verify        acceptance the gates do not cover: add a behavioral command or test
  steer brief          briefs miss a decision the master keeps making: a standing order or plan template line
  catch <layer>        the layer that should have caught it gets the check
HINT
}

# The host's feedback inbox: gaps in the kitchen itself, filed by masters
# and read by whoever maintains pstack on this host.
fb_root() {
	printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/pstack/feedback"
}

# One short lock around allocating an id and moving a report between
# directories, so concurrent filings and closures never share a name.
fb_lock() {
	local lock="$1/.lock" tries=0
	while ! mkdir "$lock" 2>/dev/null; do
		# A lock left by a killed command is older than any filing takes.
		[ -z "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || { rmdir "$lock" 2>/dev/null || true; continue; }
		tries=$((tries + 1))
		[ "$tries" -lt 100 ] || die "the feedback inbox is locked ($lock)"
		sleep 0.1
	done
}

fb_unlock() {
	rmdir "$1/.lock" 2>/dev/null || true
}

# Why the registered maintainer cannot take a pointer, or nothing when it can.
maintainer_problem() {
	local file="$1/maintainer.json" name pane session info
	[ -f "$file" ] || { printf 'no maintainer is registered'; return 0; }
	name="$(jq -r .name "$file")"
	pane="$(jq -r .pane "$file")"
	session="$(jq -r '.session // empty' "$file")"
	info="$(herdr agent get "$name" 2>/dev/null)" || { printf 'agent %s is gone' "$name"; return 0; }
	[ "$(jq -r '.result.agent.pane_id // empty' <<<"$info")" = "$pane" ] || { printf 'agent %s moved off pane %s' "$name" "$pane"; return 0; }
	if [ -n "$session" ] && [ "$(jq -r '.result.agent.agent_session.value // empty' <<<"$info")" != "$session" ]; then
		printf 'agent %s is a different session than the one registered' "$name"
		return 0
	fi
	[ "$(jq -r '.result.agent.agent_status // empty' <<<"$info")" != blocked ] || printf 'agent %s is blocked on a dialog' "$name"
}

# Open reports, oldest first: id, run, repo, build, gaps, age.
fb_inbox() {
	local fb f now filed secs age rows=""
	fb="$(fb_root)"
	now="$(date +%s)"
	for f in "$fb"/inbox/*.md; do
		[ -e "$f" ] || continue
		[ ! -e "$fb/done/$(basename "$f")" ] || continue
		filed="$(header_field "$f" filed)"
		secs="$(date -u -d "$filed" +%s 2>/dev/null || stat -c %Y "$f")"
		age=$(( (now - secs) / 60 ))
		if [ "$age" -ge 2880 ]; then age="$((age / 1440))d"; elif [ "$age" -ge 120 ]; then age="$((age / 60))h"; else age="${age}m"; fi
		rows+="$secs	$(header_field "$f" id)	$(sed -n 's/^run: \([^ ]*\) .*/\1/p' "$f" | head -1)	$(head -1 "$f" | sed -n 's/^.*(\(.*\))$/\1/p')	$(header_field "$f" build | cut -d' ' -f1)	$(grep -c '^### ' "$f")	$age
"
	done
	if [ -z "$rows" ]; then
		printf 'feedback inbox: empty\n'
		return 0
	fi
	printf '%s' "$rows" | sort -n | cut -f2- | column -t -s "$(printf '\t')"
}

# Move a report to done/ with a Closed block. Closing a closed id prints its
# block and succeeds.
fb_close() {
	[ $# -eq 3 ] || die "usage: kitchen.sh feedback --close <id> <commit|none> <note>"
	local fb id="${1%.md}" commit="$2" note="$3" tmp
	fb="$(fb_root)"
	[ -f "$fb/inbox/$id.md" ] || [ -f "$fb/done/$id.md" ] || die "no feedback report $id in $fb"
	fb_lock "$fb"
	if [ -f "$fb/inbox/$id.md" ] && [ ! -f "$fb/done/$id.md" ]; then
		tmp="$(mktemp "$fb/.closing-XXXXXX")"
		{
			sed 's/^status: open$/status: closed/' "$fb/inbox/$id.md"
			printf '\n## Closed\n\nclosed: %s\ncommit: %s\nnote: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$commit" "$(printf '%s' "$note" | tr '\n' ' ')"
		} >"$tmp"
		mv "$tmp" "$fb/done/$id.md"
		rm -f "$fb/inbox/$id.md"
		fb_unlock "$fb"
		printf 'closed: %s (commit %s)\n' "$id" "$commit"
		return 0
	fi
	fb_unlock "$fb"
	rm -f "$fb/inbox/$id.md"
	printf 'already closed: %s\n' "$id"
	sed -n '/^## Closed/,$p' "$fb/done/$id.md"
}

# File a report: the master's text behind a header this command writes.
cmd_feedback() {
	[ $# -ge 1 ] || die "usage: kitchen.sh feedback <store> <file> | --inbox | --close <id> <commit|none> <note>"
	case "$1" in
	--inbox) shift; fb_inbox "$@"; return ;;
	--close) shift; fb_close "$@"; return ;;
	esac
	[ $# -eq 2 ] || die "usage: kitchen.sh feedback <store> <file>"
	local store="$1" src="$2" fb run repo stem k name tmp retro path problem first
	pair_file "$store" >/dev/null
	[ -f "$src" ] || die "no such file: $src"
	awk '/^## Gaps/ {g = 1; next} /^## / {g = 0} g && /^### / {found = 1} END {exit !found}' "$src" ||
		die "$src has no gap: a \`### <n>. <title>\` heading under \`## Gaps\` (see $skill_root/references/feedback-template.md)"
	fb="$(fb_root)"
	mkdir -p "$fb/inbox" "$fb/done"
	run="$(field "$store" .slug)"
	retro_counts "$store"
	repo="$rc_repo"
	[ -n "$repo" ] || repo="$(basename "$(field "$store" .git_root)")"
	retro="$(retro_line "$store")"
	stem="$(date -u +%Y%m%d)-$repo-$run"
	tmp="$(mktemp "$fb/.filing-XXXXXX")"
	fb_lock "$fb"
	k=1
	name="$stem"
	while [ -e "$fb/inbox/$name.md" ] || [ -e "$fb/done/$name.md" ]; do
		k=$((k + 1))
		name="$stem-$k"
	done
	{
		printf '# Kitchen feedback: %s (%s)\n' "$run" "$repo"
		printf 'id: %s\n' "$name"
		printf 'run: %s   store: %s   repo: %s   master: %s (%s)\n' "$run" "$store" "$(field "$store" .git_root)" \
			"$(field "$store" '.master.name // "unknown"')" "$(field "$store" '.master.pane_id // "unknown"')"
		first="$(field "$store" '.skill_builds[0].path // empty')"
		printf 'build: %s (%s)\n' "$([ -n "$first" ] && build_rev "$first" || echo unknown)" "${first:-unknown}"
		[ -z "$first" ] || [ "$first" = "$skills_dir" ] || printf 'filed with: %s (%s)\n' "$(build_rev "$skills_dir")" "$skills_dir"
		printf 'retro: %s\n' "$retro"
		printf 'filed: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'status: open\n\n'
		cat "$src"
	} >"$tmp"
	mv "$tmp" "$fb/inbox/$name.md"
	fb_unlock "$fb"
	path="$fb/inbox/$name.md"
	event "$store" master feedback - "$name"
	printf 'filed: %s\n' "$path"
	problem="$(maintainer_problem "$fb")"
	if [ -z "$problem" ] && herdr agent prompt "$(jq -r .name "$fb/maintainer.json")" "pstack-kitchen FEEDBACK $path" >/dev/null 2>&1; then
		printf 'delivered: to maintainer %s\n' "$(jq -r .name "$fb/maintainer.json")"
		return 0
	fi
	[ -n "$problem" ] || problem="the prompt to the maintainer failed"
	herdr notification show "pstack-kitchen: feedback filed" --body "$path" --sound request >/dev/null 2>&1 || true
	printf 'delivered: notification for the human (%s); read it with: cat %s\n' "$problem" "$path"
}

# Every run on the host and each skills build; read-only and repo-free.
cmd_fleet() {
	python3 "$here/kitchen.py" fleet "$@"
}

cmd_maintainer() {
	[ $# -ge 1 ] || die "usage: kitchen.sh maintainer on [--pane ID] | off | status"
	local fb file sub="$1" pane="" info tmp problem
	shift
	fb="$(fb_root)"
	file="$fb/maintainer.json"
	case "$sub" in
	on)
		while [ $# -gt 0 ]; do
			case "$1" in
			--pane) pane="$2"; shift 2 ;;
			*) die "unknown option $1" ;;
			esac
		done
		[ "${HERDR_ENV:-}" = 1 ] || die "maintainer on needs Herdr (HERDR_ENV=1)"
		[ -n "$pane" ] || pane="${HERDR_PANE_ID:-}"
		[ -n "$pane" ] || die "no pane: pass --pane ID"
		info="$(herdr agent get "$pane" 2>/dev/null)" || die "herdr has no agent on pane $pane"
		mkdir -p "$fb"
		tmp="$(mktemp "$fb/.maintainer-XXXXXX")"
		jq -n --argjson i "$info" --arg since "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			'{name: $i.result.agent.name, pane: $i.result.agent.pane_id, session: ($i.result.agent.agent_session.value // null), since: $since}' >"$tmp"
		[ "$(jq -r '.name // empty' "$tmp")" != "" ] || { rm -f "$tmp"; die "herdr reports no name for the agent on pane $pane; name it first"; }
		mv "$tmp" "$file"
		printf 'maintainer: %s on %s\n' "$(jq -r .name "$file")" "$(jq -r .pane "$file")"
		;;
	off)
		rm -f "$file"
		printf 'maintainer: none\n'
		;;
	status)
		[ -f "$file" ] || { printf 'maintainer: none\n'; return 0; }
		problem="$(maintainer_problem "$fb")"
		printf 'maintainer: %s on %s since %s: %s\n' "$(jq -r .name "$file")" "$(jq -r .pane "$file")" "$(jq -r .since "$file")" "${problem:-live}"
		;;
	*) die "usage: kitchen.sh maintainer on [--pane ID] | off | status" ;;
	esac
}

if [ $# -ge 2 ] && [ -f "$2/pair.json" ]; then record_skill_build "$2"; fi
pair_main "$@"
