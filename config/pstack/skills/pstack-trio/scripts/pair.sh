#!/usr/bin/env bash
# Trio store and Herdr channel helper for the pstack-trio skill: a master, a
# sidekick that owns the working tree, and a consultant that advises. The
# shared commands live in pstack-pair's pair-core.sh; this file adds the
# consultant: its spawn, plan rounds, consults, and scratch worktrees.
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

usage() {
	cat <<'USAGE'
usage: pair.sh <command> [args]

  init <slug> [--store DIR]                 create or re-register the trio store; prints its path
  spawn <store> --sidekick KIND --consultant KIND [--only sidekick|consultant] [--permission MODE|none]
        [--consultant-permission MODE|none] [--timeout MS] [-- agent-args...]
                                            split panes beside the master, start both agents with the master's
                                            permission mode (default auto), bootstrap them. Refuses a trio whose
                                            three kinds are all the same. --only respawns one role.
  permission                                print the master's detected permission mode
  new-plan <store> <slug>                   create plans/NNN-<slug>.md from the template; prints its path
  discuss <store> <plan-path> [--timeout MS]
                                            send PLAN to the sidekick and the consultant at once and wait for
                                            both responses: the sidekick's report and the consultant's advice
  new-consult <store> <NNN> --kind design|finding|objection|review [--force]
                                            create consults/NNN-<slug>-c<k>.md for unit NNN; three per unit
  consult <store> <consult-path> [--force] [--timeout MS]
                                            send CONSULT to the consultant and wait for its advice; finding and
                                            review kinds refuse while the sidekick is working unless --force
  advice <store> [NNN]                      print the latest (or NNN) advice path
  scratch <store> <consult-id> [--remove]   consultant: create (or remove) a throwaway worktree under
                                            <store>/scratch/<consult-id> at HEAD with the live diff applied
  new-brief <store> <slug>                  create briefs/NNN-<slug>.md from the template; prints its path
  dispatch <store> <brief-path> [--timeout MS | --every MIN]
                                            send BRIEF to the sidekick and wait for it to settle;
                                            implementation playbooks require an agreed plan
  wait <store> [--timeout MS | --every MIN] wait for the sidekick to settle; prints the report path,
                                            or a check-in digest when the interval passes first
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
  status <store>                            table of units, reports, advice, reviews, agent states, open scratch
  log <store> <phase> <decision> <why> <evidence> <result>
                                            append a decisions.tsv row (show-me-your-work format)
  metrics <store>                           where the time went, from events.tsv: busy and idle per agent,
                                            master wakes, review latency, verdicts

exit codes: 0 ok, 1 usage or precondition, 2 herdr error, 3 agent blocked, 4 no report or advice yet,
            5 agent busy, 6 plan not agreed or consultant advice missing, 7 steer or consult cap reached,
            8 agent kinds not diverse
USAGE
}

# A trio plan also needs the consultant's advice on file.
plan_gate_extra() {
	local store="$1" plan="$2" seq="$4" advice
	advice="$(latest_advice "$store" "$seq")" || die "plan $plan has no consultant advice under advice/$seq-*; run pair.sh discuss so both agents respond" 6
	[ -n "$advice" ] || die "plan $plan has no consultant advice under advice/$seq-*; run pair.sh discuss so both agents respond" 6
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
	[ $# -ge 1 ] || die "usage: pair.sh spawn <store> --sidekick KIND --consultant KIND [--only sidekick|consultant] [--permission MODE|none] [--consultant-permission MODE|none] [--timeout MS] [-- agent-args...]"
	local store="$1" sidekick_kind="" consultant_kind="" only="" permission="" cpermission="" timeout=60000
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--sidekick) sidekick_kind="$2"; shift 2 ;;
		--consultant) consultant_kind="$2"; shift 2 ;;
		--kind) sidekick_kind="$2"; consultant_kind="${consultant_kind:-$2}"; shift 2 ;;
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
	local master_mode master_pane
	master_mode="$(detect_permission_mode)"
	master_pane="$(field "$store" .master.pane_id)"
	[ -n "$permission" ] || permission="$master_mode"
	[ -n "$cpermission" ] || cpermission="$permission"
	local rc=0
	if [ "$only" != consultant ]; then
		spawn_role "$store" sidekick "$sidekick_kind" "$permission" "$master_pane" "$timeout" "" "" "$@" || rc=$?
		[ "$rc" -eq 0 ] || exit "$rc"
	fi
	if [ "$only" != sidekick ]; then
		# The consultant splits from the sidekick's pane so the master keeps its height.
		local anchor
		anchor="$(field "$store" '.sidekick.pane_id // empty')"
		[ -n "$anchor" ] && herdr pane get "$anchor" >/dev/null 2>&1 || anchor="$master_pane"
		spawn_role "$store" consultant "$consultant_kind" "$cpermission" "$anchor" "$timeout" "" "" "$@" || rc=$?
		[ "$rc" -eq 0 ] || exit "$rc"
	fi
	printf 'kinds: master %s, sidekick %s, consultant %s\n' "$master_kind" "$(field "$store" '.sidekick.kind // "absent"')" "$(field "$store" '.consultant.kind // "absent"')"
}

# A plan round goes to the sidekick and the consultant at once; each answers
# in its own file and the master merges. Both must be free to take input.
cmd_discuss() {
	in_herdr
	[ $# -ge 2 ] || die "usage: pair.sh discuss <store> <plan-path> [--timeout MS]"
	local store="$1" plan="$2" timeout=540000
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	[ -f "$plan" ] || die "plan not found: $plan"
	plan="$(readlink -f "$plan")"
	require_filled "$plan"
	local role name status seq
	seq="$(basename "$plan" | cut -c1-3)"
	for role in sidekick consultant; do
		name="$(field "$store" ".$role.name")"
		status="$(agent_status "$name")"
		case "$status" in
		idle | done) ;;
		absent) die "$role $name is not live; run: pair.sh spawn $store --only $role --$role <kind>" 2 ;;
		blocked) die "$role $name is blocked; inspect: herdr agent read $name --source visible --lines 60" 3 ;;
		*) die "$role $name is $status; wait for it before a plan round" 5 ;;
		esac
	done
	for role in sidekick consultant; do
		name="$(field "$store" ".$role.name")"
		herdr agent prompt "$name" "$PAIR_SKILL PLAN $plan" >/dev/null || die "herdr prompt failed for $name" 2
		event "$store" master send-plan "$plan" "$role"
		printf 'sent PLAN %s to %s %s\n' "$(basename "$plan")" "$role" "$name"
	done
	local rc=0 out err code file
	for role in sidekick consultant; do
		name="$(field "$store" ".$role.name")"
		code=0
		out="$(herdr agent wait "$name" --timeout "$timeout" 2>/dev/null)" || code=$?
		status="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // "settled"' 2>/dev/null || printf 'settled')"
		[ "$code" -eq 0 ] || status="$(agent_status "$name")"
		printf '%s_state: %s\n' "$role" "$status"
		file=""
		case "$role" in
		sidekick) file="$(latest_report "$store" "$seq" || true)" ;;
		consultant) file="$(latest_advice "$store" "$seq" || true)" ;;
		esac
		if [ -z "$file" ] && [ "$status" != blocked ]; then
			printf '%s settled without a response; polling for the file\n' "$role"
			case "$role" in
			sidekick) await_file "$store/reports/$seq-$(basename "$plan" .md | cut -c5-).md" "$timeout" && file="$(latest_report "$store" "$seq" || true)" ;;
			consultant) await_file "$store/advice/$seq-$(basename "$plan" .md | cut -c5-).md" "$timeout" && file="$(latest_advice "$store" "$seq" || true)" ;;
			esac
		fi
		if [ -n "$file" ]; then
			printf '%s_response: %s\n' "$role" "$file"
			printf '%s_status: %s\n' "$role" "$(header_field "$file" status)"
			event "$store" master wake "$plan" "$role:$(header_field "$file" status)"
		else
			printf '%s_response: missing\n' "$role"
			rc=4
		fi
		[ "$status" = blocked ] && rc=3
	done
	exit "$rc"
}

cmd_stop() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh stop <store> [--only sidekick|consultant] [--timeout MS]"
	local store="$1" timeout=300000 only=""
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--only) only="$2"; shift 2 ;;
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	checkin_interval_m=$((timeout / 60000))
	local role name status rc=0 code out
	for role in sidekick consultant; do
		[ -z "$only" ] || [ "$only" = "$role" ] || continue
		name="$(field "$store" ".$role.name")"
		status="$(agent_status "$name")"
		case "$status" in
		absent) printf '%s %s is not live\n' "$role" "$name"; continue ;;
		blocked) printf '%s %s is blocked; inspect it before stopping\n' "$role" "$name" >&2; rc=3; continue ;;
		esac
		code=0
		event "$store" master send-stop - "$role"
		out="$(herdr agent prompt "$name" "$PAIR_SKILL STOP $store" --wait --timeout "$timeout" 2>/dev/null)" || code=$?
		status="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // "settled"' 2>/dev/null || printf 'settled')"
		[ "$code" -eq 0 ] || status="$(agent_status "$name")"
		printf '%s_state: %s\n' "$role" "$status"
		[ "$status" = blocked ] && rc=3
	done
	local report advice
	if report="$(latest_report "$store")"; then printf 'report: %s (%s)\n' "$report" "$(header_field "$report" status)"; fi
	if advice="$(latest_advice "$store")"; then printf 'advice: %s (%s)\n' "$advice" "$(header_field "$advice" status)"; fi
	exit "$rc"
}

# Consults on a unit are capped at three; a fourth means the design is wrong
# and belongs in a plan round.
cmd_new_consult() {
	[ $# -ge 2 ] || die "usage: pair.sh new-consult <store> <NNN> --kind design|finding|objection|review [--force]"
	local store="$1" seq="$2" kind="" force=0 unit slug k f path
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--kind) kind="$2"; shift 2 ;;
		--force) force=1; shift ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	case "$kind" in
	design | finding | objection | review) ;;
	*) die "--kind must be design, finding, objection, or review" ;;
	esac
	unit="$(ls "$store"/briefs/"$seq"-*.md "$store"/plans/"$seq"-*.md 2>/dev/null | head -1 || true)"
	[ -n "$unit" ] || die "no plan or brief for unit $seq"
	slug="$(basename "$unit" .md | cut -c5-)"
	k=0
	for f in "$store"/consults/"$seq"-"$slug"-c[0-9]*.md; do
		[ -e "$f" ] && k=$((k + 1))
	done
	if [ "$k" -ge 3 ] && [ "$force" -eq 0 ]; then
		die "unit $seq already has three consults; take the question to a plan round, or pass --force" 7
	fi
	k=$((k + 1))
	mkdir -p "$store/consults"
	path="$store/consults/$seq-$slug-c$k.md"
	sed -e "s|{{SEQ}}|$seq|g" -e "s|{{SLUG}}|$slug|g" -e "s|{{K}}|$k|g" -e "s|{{STORE}}|$store|g" \
		-e "s|{{KIND}}|$kind|g" -e "s|{{UNIT}}|$unit|g" \
		"$skill_root/references/consult-template.md" >"$path"
	printf '%s\n' "$path"
}

# A consult reaches the consultant while the sidekick may be working. Design
# questions are safe at any time; finding and review kinds read the live tree,
# so they wait for a quiet sidekick unless forced.
cmd_consult() {
	in_herdr
	[ $# -ge 2 ] || die "usage: pair.sh consult <store> <consult-path> [--force] [--timeout MS]"
	local store="$1" consult force=0 timeout=900000
	consult="$(readlink -f "$2")"
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--force) force=1; shift ;;
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	[ -f "$consult" ] || die "consult not found: $consult"
	grep -q '^## Question' "$consult" || die "not a consult file: $consult"
	local kind sidekick sstatus name status seq slug k out err code=0 errfile advice
	kind="$(header_field "$consult" kind)"
	sidekick="$(field "$store" .sidekick.name)"
	sstatus="$(agent_status "$sidekick")"
	# The one header line the script owns: the sidekick's state and the head
	# at send time, so the consultant knows how live the tree it reads is.
	sed -i -E "s|^sidekick state at send:.*|sidekick state at send: $sstatus at $(git -C "$(field "$store" .cwd)" rev-parse --short HEAD 2>/dev/null || printf '?')|" "$consult"
	if grep -q '{{' "$consult" || grep -qE '^kind: .*\|' "$consult"; then
		die "$consult still has unfilled placeholders"
	fi
	case "$kind" in
	finding | review)
		if [ "$sstatus" = working ] && [ "$force" -eq 0 ]; then
			die "sidekick $sidekick is working; a $kind consult reads the live tree, so wait for a check-in or report, or pass --force" 5
		fi
		;;
	esac
	name="$(field "$store" .consultant.name)"
	status="$(agent_status "$name")"
	case "$status" in
	idle | done) ;;
	absent) die "consultant $name is not live; run: pair.sh spawn $store --only consultant --consultant <kind>" 2 ;;
	blocked) die "consultant $name is blocked; inspect: herdr agent read $name --source visible --lines 60" 3 ;;
	*) die "consultant $name is $status; wait for its current advice first" 5 ;;
	esac
	local cwd head
	cwd="$(field "$store" .cwd)"
	head="$(git -C "$cwd" rev-parse HEAD 2>/dev/null || printf '')"
	jq --arg consult "$consult" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg head "$head" --arg sk "$sstatus" \
		'.consult = {file: $consult, at: $now, head: $head, sidekick_state: $sk}' \
		"$store/pair.json" >"$store/pair.json.tmp"
	mv "$store/pair.json.tmp" "$store/pair.json"
	event "$store" master send-consult "$consult" "$kind"
	errfile="$(mktemp)"
	out="$(herdr agent prompt "$name" "$PAIR_SKILL CONSULT $consult" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
	err="$(cat "$errfile")"
	rm -f "$errfile"
	if [ "$code" -ne 0 ]; then
		status="$(printf '%s' "$err" | jq -r '.error.code // .error // "herdr_error"' 2>/dev/null || printf 'herdr_error')"
		printf '%s\n' "$err" >&2
	else
		status="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // "settled"' 2>/dev/null || printf 'settled')"
	fi
	printf 'state: %s\n' "$status"
	seq="$(basename "$consult" | cut -c1-3)"
	slug="$(basename "$consult" .md | sed -E 's/^[0-9]{3}-//; s/-c[0-9]+$//')"
	k="$(basename "$consult" .md | sed -E 's/.*-c([0-9]+)$/\1/')"
	advice="$store/advice/$seq-$slug-c$k.md"
	if [ ! -f "$advice" ] && [ "$status" != blocked ]; then
		printf 'consultant settled without advice; polling for the file\n'
		await_file "$advice" "$timeout" || true
	fi
	if [ -f "$advice" ]; then
		printf 'advice: %s\n' "$advice"
		printf 'advice_status: %s\n' "$(header_field "$advice" status)"
		event "$store" master wake "$advice" "advice:$(header_field "$advice" status)"
		[ "$status" = blocked ] && exit 3
		exit 0
	fi
	printf 'advice: missing\n'
	[ "$status" = blocked ] && exit 3
	exit 4
}

cmd_advice() {
	[ $# -ge 1 ] || die "usage: pair.sh advice <store> [NNN]"
	local path
	if path="$(latest_advice "$1" "${2:-}")"; then
		printf '%s\n' "$path"
	else
		die "no advice found" 4
	fi
}

# The consultant's throwaway worktree: detached at HEAD with the sidekick's
# uncommitted diff applied, so a prototype or build starts from the live
# state without touching the shared tree. Removed before the advice is sent.
cmd_scratch() {
	[ $# -ge 2 ] || die "usage: pair.sh scratch <store> <consult-id> [--remove]"
	local store="$1" id="$2" remove=0 cwd path
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--remove) remove=1; shift ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	[[ "$id" =~ ^[0-9]{3}-[a-z0-9_-]+-c[0-9]+$ ]] || die "consult-id must look like NNN-<slug>-c<k>"
	cwd="$(field "$store" .git_root)"
	[ -n "$cwd" ] && [ "$cwd" != null ] || die "the trio's cwd is not inside a git repository"
	path="$store/scratch/$id"
	if [ "$remove" -eq 1 ]; then
		if [ -d "$cwd/.jj" ]; then
			jj -R "$cwd" workspace forget "scratch-$id" >/dev/null 2>&1 || true
			rm -rf "$path"
		else
			git -C "$cwd" worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path"
			git -C "$cwd" worktree prune >/dev/null 2>&1 || true
		fi
		jq --arg id "$id" '.scratch = ((.scratch // []) - [$id])' "$store/pair.json" >"$store/pair.json.tmp"
		mv "$store/pair.json.tmp" "$store/pair.json"
		printf 'removed %s\n' "$path"
		return 0
	fi
	if [ -d "$path" ]; then
		printf '%s\n' "$path"
		return 0
	fi
	mkdir -p "$store/scratch"
	if [ -d "$cwd/.jj" ]; then
		jj -R "$cwd" workspace add --name "scratch-$id" "$path" >/dev/null || die "jj workspace add failed" 2
	else
		git -C "$cwd" worktree add --detach "$path" HEAD >/dev/null || die "git worktree add failed" 2
		# Tracked changes as a patch; untracked files copied as they are.
		local patch
		patch="$(mktemp)"
		git -C "$cwd" diff HEAD --binary >"$patch"
		if [ -s "$patch" ]; then
			git -C "$path" apply --index "$patch" 2>/dev/null || { printf 'live diff did not apply cleanly; scratch is at HEAD only\n' >&2; git -C "$path" checkout -- . >/dev/null 2>&1 || true; }
		fi
		rm -f "$patch"
		git -C "$cwd" ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
			mkdir -p "$path/$(dirname "$f")"
			cp -p "$cwd/$f" "$path/$f"
		done
	fi
	jq --arg id "$id" '.scratch = ((.scratch // []) + [$id] | unique)' "$store/pair.json" >"$store/pair.json.tmp"
	mv "$store/pair.json.tmp" "$store/pair.json"
	printf '%s\n' "$path"
}

pair_main "$@"
