#!/usr/bin/env bash
# Pair store and Herdr channel helper for the pstack-pair skill.
# Every subcommand is idempotent and prints what it did. JSON from herdr is
# parsed with jq; identifiers are never guessed.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
skill_root="$(dirname "$here")"
log_helper="$skill_root/../show-me-your-work/scripts/log.sh"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/pstack/pair"

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
  notify <store> <report-path>              sidekick -> master: prompt the master if it is idle
  stop <store> [--timeout MS]               send STOP; the sidekick pauses safely and reports
  status <store>                            table of briefs, reports, reviews, and live agent states
  log <store> <phase> <decision> <why> <evidence> <result>
                                            append a decisions.tsv row (show-me-your-work format)

exit codes: 0 ok, 1 usage or precondition, 2 herdr error, 3 sidekick blocked, 4 no report yet, 5 sidekick busy, 6 plan not agreed, 7 steer cap reached
USAGE
}

die() {
	printf 'pair.sh: %s\n' "$*" >&2
	exit "${2:-1}"
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "$1 is required on PATH"
}

need herdr
need jq

in_herdr() {
	[ "${HERDR_ENV:-}" = 1 ] || die "not running inside Herdr (HERDR_ENV != 1)"
}

pair_file() {
	local store="$1"
	[ -f "$store/pair.json" ] || die "no pair.json in $store; run: pair.sh init <slug>"
	printf '%s\n' "$store/pair.json"
}

field() {
	jq -r "$2" "$(pair_file "$1")"
}

agent_status() {
	# Prints idle|working|blocked|done|unknown, or "absent" when herdr has no such agent.
	local out
	if out="$(herdr agent get "$1" 2>/dev/null)"; then
		printf '%s\n' "$out" | jq -r '.result.agent.agent_status // "unknown"'
	else
		printf 'absent\n'
	fi
}

next_seq() {
	local store="$1" max=0 n
	for f in "$store"/briefs/[0-9][0-9][0-9]-*.md "$store"/plans/[0-9][0-9][0-9]-*.md "$store"/reports/[0-9][0-9][0-9]-*.md; do
		[ -e "$f" ] || continue
		n=$((10#$(basename "$f" | cut -c1-3)))
		[ "$n" -gt "$max" ] && max=$n
	done
	printf '%03d\n' $((max + 1))
}

latest_report() {
	local store="$1" want="${2:-}" f
	if [ -n "$want" ]; then
		f="$(ls -t "$store"/reports/"$want"-*.md 2>/dev/null | head -1 || true)"
	else
		f="$(ls -t "$store"/reports/[0-9][0-9][0-9]-*.md 2>/dev/null | head -1 || true)"
	fi
	[ -n "$f" ] && printf '%s\n' "$f"
}

# Report path for the newest brief or plan, by sequence number.
settle_report() {
	local store="$1" f seq="" n
	for f in "$store"/briefs/[0-9][0-9][0-9]-*.md "$store"/plans/[0-9][0-9][0-9]-*.md; do
		[ -e "$f" ] || continue
		n="$(basename "$f" | cut -c1-3)"
		if [ -z "$seq" ] || [ "$n" \> "$seq" ]; then seq="$n"; fi
	done
	[ -n "$seq" ] || return 1
	latest_report "$store" "$seq"
}

header_field() {
	# $1 file, $2 key: the value of a "key: value" header line, or empty.
	grep -m1 -E "^$2:" "$1" | sed -E "s/^$2:[[:space:]]*//" || true
}

# Minutes a dispatch or wait blocks before printing a check-in. Set from
# --every or --timeout by the command; nine minutes stays under the shell cap.
checkin_interval_m=9

# Recorded at dispatch so a check-in can measure elapsed time, commits, and
# files touched against this brief.
record_dispatch() {
	local store="$1" brief="$2" cwd now head
	cwd="$(field "$store" .cwd)"
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	head="$(git -C "$cwd" rev-parse HEAD 2>/dev/null || printf '')"
	jq --arg brief "$brief" --arg now "$now" --arg head "$head" \
		'.dispatch = {brief: $brief, at: $now, head: $head}' \
		"$store/pair.json" >"$store/pair.json.tmp"
	mv "$store/pair.json.tmp" "$store/pair.json"
}

progress_path() {
	# $1 store: the progress log of the dispatched brief, or empty.
	local brief
	brief="$(field "$1" '.dispatch.brief // empty')"
	[ -n "$brief" ] || return 1
	printf '%s/progress/%s.md\n' "$1" "$(basename "$brief" .md)"
}

# Check-in digest for a sidekick still working at the interval: elapsed against
# the timebox, progress lines not yet shown, files touched against the brief's
# Scope, commits since dispatch, and steer counts. Bounded, so the master can
# poll it cheaply instead of reading the pane. $2 is the interval in minutes.
checkin() {
	local store="$1" interval="${2:-9}" brief at head cwd seq slug prog total seen new age_m stale timebox elapsed_m now
	brief="$(field "$store" '.dispatch.brief // empty')"
	[ -n "$brief" ] && [ -f "$brief" ] || return 0
	at="$(field "$store" '.dispatch.at // empty')"
	head="$(field "$store" '.dispatch.head // empty')"
	cwd="$(field "$store" .cwd)"
	seq="$(basename "$brief" | cut -c1-3)"
	now="$(date +%s)"
	timebox="$(header_field "$brief" timebox | grep -oE '^[0-9]+' || true)"
	elapsed_m=$(( (now - $(date -d "$at" +%s)) / 60 ))
	printf 'check-in: %s  elapsed %dm of %sm\n' "$(basename "$brief")" "$elapsed_m" "${timebox:-?}"
	prog="$(progress_path "$store")"
	if [ -f "$prog" ]; then
		total="$(wc -l <"$prog")"
		seen=0
		[ -f "$prog.seen" ] && seen="$(cat "$prog.seen")"
		[ "$seen" -le "$total" ] || seen=0
		new=$((total - seen))
		age_m=$(( (now - $(stat -c %Y "$prog")) / 60 ))
		stale=""
		[ "$age_m" -ge "$interval" ] && stale="  STALE"
		printf 'progress: +%d lines (last %dm ago)%s\n' "$new" "$age_m" "$stale"
		tail -n "+$((seen + 1))" "$prog" | tail -n 20 | sed 's/^/  /'
		printf '%s\n' "$total" >"$prog.seen"
	else
		printf 'progress: none yet\n'
	fi
	local -a touched=() may=() outside=()
	mapfile -t touched < <({
		git -C "$cwd" status --porcelain=v1 --untracked-files=all 2>/dev/null | cut -c4- | sed 's/.* -> //'
		[ -n "$head" ] && git -C "$cwd" diff --name-only "$head"..HEAD 2>/dev/null
	} | sort -u)
	local commits=0
	[ -n "$head" ] && commits="$(git -C "$cwd" rev-list --count "$head"..HEAD 2>/dev/null || printf 0)"
	printf 'touched: %d files, %d commits since dispatch\n' "${#touched[@]}" "$commits"
	[ "${#touched[@]}" -gt 0 ] && printf '  %s\n' "${touched[@]:0:30}"
	mapfile -t may < <(awk '/^may write:/{f=1;next} /^must not write:|^## /{f=0} f && /^- /{sub(/^- /,""); print}' "$brief")
	local f p ok
	for f in "${touched[@]}"; do
		ok=0
		for p in "${may[@]}"; do
			# shellcheck disable=SC2254
			case "$f" in $p) ok=1; break ;; esac
		done
		[ "$ok" -eq 1 ] || outside+=("$f")
	done
	if [ "${#outside[@]}" -gt 0 ]; then
		printf 'outside scope: %d\n' "${#outside[@]}"
		printf '  %s\n' "${outside[@]:0:30}"
	fi
	local sent=0 applied=0 objected=0
	sent="$(ls "$store"/steers/"$seq"-*-s[0-9]*.md 2>/dev/null | wc -l || true)"
	objected="$(ls "$store"/reports/"$seq"-*-s[0-9]*.md 2>/dev/null | wc -l || true)"
	[ -f "$prog" ] && applied="$(grep -cE ' steer s[0-9]+ applied' "$prog" || true)"
	printf 'steers: %d sent, %d applied, %d objected\n' "$sent" "${applied:-0}" "$objected"
}

# Implementation playbooks may only run against a plan the sidekick agreed to
# and the master marked agreed. Exit 6 names what is missing.
require_agreed_plan() {
	local store="$1" brief="$2" playbook plan seq review verdict
	playbook="$(header_field "$brief" playbook)"
	case "$playbook" in
	feature | bug-fix | refactoring | perf-issue | pstack-tdd) ;;
	*) return 0 ;;
	esac
	plan="$(header_field "$brief" plan)"
	[ -n "$plan" ] && [ "$plan" != none ] || die "playbook $playbook needs an agreed plan; brief has plan: ${plan:-<missing>}" 6
	[ -f "$plan" ] || die "plan not found: $plan" 6
	seq="$(basename "$plan" | cut -c1-3)"
	review="$(ls "$store"/reviews/"$seq"-*.md 2>/dev/null | head -1 || true)"
	[ -n "$review" ] || die "plan $plan has no review; run pair.sh discuss and write reviews/$seq-<slug>.md with verdict: agreed" 6
	verdict="$(header_field "$review" verdict)"
	[ "$verdict" = agreed ] || die "plan $plan review verdict is '${verdict:-missing}', not agreed" 6
}

finish_wait() {
	# $1 store, $2 herdr exit code, $3 herdr stdout, $4 herdr stderr,
	# $5 "brief" (report for the newest brief) or "any" (newest report at all)
	local store="$1" code="$2" out="$3" err="$4" mode="${5:-brief}" state report
	if [ "$code" -ne 0 ]; then
		state="$(printf '%s' "$err" | jq -r '.error.code // .error // "herdr_error"' 2>/dev/null || printf 'herdr_error')"
		printf 'state: %s\n' "$state"
		printf '%s\n' "$err" >&2
	else
		state="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // "settled"' 2>/dev/null || printf 'settled')"
		printf 'state: %s\n' "$state"
	fi
	if { [ "$mode" = any ] && report="$(latest_report "$store")"; } || { [ "$mode" = brief ] && report="$(settle_report "$store")"; }; then
		printf 'report: %s\n' "$report"
		printf 'report_status: %s\n' "$(header_field "$report" status)"
		[ "$state" = blocked ] && exit 3
		exit 0
	fi
	printf 'report: missing\n'
	case "$state" in
	blocked) exit 3 ;;
	esac
	if [ "$(agent_status "$(field "$store" .sidekick.name)")" = working ]; then
		checkin "$store" "$checkin_interval_m"
	fi
	exit 4
}

cmd_init() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh init <slug> [--store DIR]"
	local slug="$1" store=""
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--store) store="$2"; shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	[[ "$slug" =~ ^[a-z][a-z0-9_-]{0,21}$ ]] || die "slug must match [a-z][a-z0-9_-]{0,21} (so <slug>-sidekick fits Herdr's 32-char name limit)"
	[ -n "$store" ] || store="$state_root/$slug"
	[ -n "${HERDR_PANE_ID:-}" ] || die "HERDR_PANE_ID is unset; run from a Herdr-managed pane"
	mkdir -p "$store"/{plans,briefs,reports,reviews,progress,steers}
	local master="$slug-master" sidekick="$slug-sidekick" now cwd git_root
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	cwd="$PWD"
	git_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
	herdr agent rename "$HERDR_PANE_ID" "$master" >/dev/null
	if [ -f "$store/pair.json" ]; then
		jq --arg pane "$HERDR_PANE_ID" --arg ws "${HERDR_WORKSPACE_ID:-}" --arg tab "${HERDR_TAB_ID:-}" --arg now "$now" \
			'.master.pane_id = $pane | .master.workspace_id = $ws | .master.tab_id = $tab | .master.registered_at = $now' \
			"$store/pair.json" >"$store/pair.json.tmp"
		mv "$store/pair.json.tmp" "$store/pair.json"
		printf 'store: %s (re-registered master %s in %s)\n' "$store" "$master" "$HERDR_PANE_ID"
	else
		jq -n --arg slug "$slug" --arg store "$store" --arg now "$now" --arg cwd "$cwd" --arg git_root "$git_root" \
			--arg master "$master" --arg sidekick "$sidekick" --arg pane "$HERDR_PANE_ID" \
			--arg ws "${HERDR_WORKSPACE_ID:-}" --arg tab "${HERDR_TAB_ID:-}" \
			'{slug: $slug, store: $store, created_at: $now, cwd: $cwd, git_root: $git_root,
			  master: {name: $master, pane_id: $pane, workspace_id: $ws, tab_id: $tab, registered_at: $now},
			  sidekick: {name: $sidekick, pane_id: null, kind: null, started_at: null}}' >"$store/pair.json"
		printf 'store: %s (master %s in %s)\n' "$store" "$master" "$HERDR_PANE_ID"
	fi
	# The template comes from a read-only install, so give the copy its own mode.
	[ -f "$store/standing-orders.md" ] || { cp "$skill_root/references/standing-orders-template.md" "$store/standing-orders.md" && chmod u+w "$store/standing-orders.md"; }
	[ -f "$store/gates.md" ] || printf '# Gates\n\nOne entry per open question for the human: question, options, default on no answer.\n' >"$store/gates.md"
	[ -f "$store/decisions.tsv" ] || printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' >"$store/decisions.tsv"
	printf 'standing orders: %s\n' "$store/standing-orders.md"
}

# The master's permission mode, in Claude Code vocabulary:
# auto | acceptEdits | bypassPermissions | manual | dontAsk | plan.
# Sources in order: the launching command line of the agent process above this
# shell, the current Claude session transcript (a mode toggled at runtime lands
# there), settings defaultMode, then auto.
detect_permission_mode() {
	local pid=$$ ppid comm args depth=0 mode=""
	while [ "$pid" -gt 1 ] && [ "$depth" -lt 12 ]; do
		ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" || break
		[ -n "$ppid" ] || break
		comm="$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)")"
		args="$(ps -o args= -p "$pid" 2>/dev/null)"
		# Match the agent executable itself, never a shell whose command text
		# happens to mention a flag.
		case "$comm" in
		node | bun) case "$args" in *claude*) comm=claude ;; *codex*) comm=codex ;; esac ;;
		esac
		case "$comm" in
		claude)
			case "$args" in
			*--dangerously-skip-permissions*) mode=bypassPermissions ;;
			*--permission-mode*) mode="$(printf '%s' "$args" | sed -nE 's/.*--permission-mode[= ]([A-Za-z]+).*/\1/p')" ;;
			esac
			break
			;;
		codex)
			case "$args" in
			*--dangerously-bypass-approvals-and-sandbox*) mode=bypassPermissions ;;
			*"-a never"* | *"--ask-for-approval never"* | *"--ask-for-approval=never"*) mode=dontAsk ;;
			*"-a on-request"* | *"--ask-for-approval on-request"* | *"--ask-for-approval=on-request"*) mode=auto ;;
			esac
			break
			;;
		esac
		pid="$ppid"
		depth=$((depth + 1))
	done
	if [ -z "$mode" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
		local slug transcript
		slug="$(printf '%s' "$PWD" | sed 's#[/.]#-#g')"
		transcript="$HOME/.claude/projects/$slug/$CLAUDE_CODE_SESSION_ID.jsonl"
		if [ -f "$transcript" ]; then
			mode="$(grep -o '"permissionMode":"[A-Za-z]*"' "$transcript" | tail -1 | sed -E 's/.*:"([A-Za-z]+)"/\1/')"
		fi
	fi
	if [ -z "$mode" ]; then
		local f
		for f in "$PWD/.claude/settings.local.json" "$PWD/.claude/settings.json" "$HOME/.claude/settings.local.json" "$HOME/.claude/settings.json"; do
			[ -f "$f" ] || continue
			mode="$(jq -r '.permissions.defaultMode // empty' "$f" 2>/dev/null)"
			[ -n "$mode" ] && break
		done
	fi
	printf '%s\n' "${mode:-auto}"
}

# Native arguments that give a sidekick of KIND the permission MODE. Empty for
# kinds without a known translation; pass native flags after -- for those.
permission_args() {
	local kind="$1" mode="$2"
	case "$kind" in
	claude) printf -- '--permission-mode\n%s\n' "$mode" ;;
	devin)
		# devin: auto approves read-only tools, smart lets a fast model judge the rest.
		case "$mode" in
		bypassPermissions | dontAsk) printf -- '--permission-mode\ndangerous\n' ;;
		acceptEdits) printf -- '--permission-mode\naccept-edits\n' ;;
		plan) printf -- '--permission-mode\nauto\n' ;;
		*) printf -- '--permission-mode\nsmart\n' ;;
		esac
		;;
	codex)
		case "$mode" in
		bypassPermissions) printf -- '--dangerously-bypass-approvals-and-sandbox\n' ;;
		dontAsk) printf -- '-a\nnever\n-s\nworkspace-write\n' ;;
		plan) printf -- '-a\non-request\n-s\nread-only\n' ;;
		*) printf -- '-a\non-request\n-s\nworkspace-write\n' ;;
		esac
		;;
	esac
}

# True when the caller's native arguments already set a permission policy.
has_permission_arg() {
	local arg
	for arg in "$@"; do
		case "$arg" in
		--permission-mode | --permission-mode=* | --dangerously-skip-permissions | --allow-dangerously-skip-permissions | \
			-a | --ask-for-approval | --ask-for-approval=* | -s | --sandbox | --sandbox=* | --dangerously-bypass-approvals-and-sandbox)
			return 0
			;;
		esac
	done
	return 1
}

cmd_permission() {
	detect_permission_mode
}

pick_direction() {
	# Cells are about twice as tall as wide: a pane is visually wider than tall
	# when width >= 2 * height. Split wide panes right and tall panes down.
	local pane="$1" w h
	read -r w h < <(herdr pane layout --pane "$pane" | jq -r --arg p "$pane" '.result.layout.panes[] | select(.pane_id == $p) | "\(.rect.width) \(.rect.height)"')
	if [ "${w:-0}" -ge $((2 * ${h:-0})) ]; then printf 'right\n'; else printf 'down\n'; fi
}

cmd_spawn() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh spawn <store> --kind KIND [--direction right|down] [--pane ID] [--timeout MS] [-- agent-args...]"
	local store="$1" kind="" direction="" pane="" timeout=60000 permission=""
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--kind) kind="$2"; shift 2 ;;
		--permission) permission="$2"; shift 2 ;;
		--direction) direction="$2"; shift 2 ;;
		--pane) pane="$2"; shift 2 ;;
		--timeout) timeout="$2"; shift 2 ;;
		--) shift; break ;;
		*) die "unknown option $1" ;;
		esac
	done
	[ -n "$kind" ] || die "--kind is required (run: herdr agent, for the kind list)"
	local master_mode
	master_mode="$(detect_permission_mode)"
	[ -n "$permission" ] || permission="$master_mode"
	local -a agent_args=()
	if [ "$permission" = none ] || has_permission_arg "$@"; then
		permission="native-args"
	else
		mapfile -t agent_args < <(permission_args "$kind" "$permission")
		if [ "${#agent_args[@]}" -eq 0 ]; then
			printf 'no permission translation for kind %s; pass native flags after -- to match the master (%s)\n' "$kind" "$master_mode" >&2
			permission="untranslated"
		fi
	fi
	set -- "${agent_args[@]}" "$@"
	local name master_pane cwd status
	name="$(field "$store" .sidekick.name)"
	master_pane="$(field "$store" .master.pane_id)"
	cwd="$(field "$store" .cwd)"
	status="$(agent_status "$name")"
	if [ "$status" != absent ]; then
		printf 'sidekick %s already live (%s) in %s\n' "$name" "$status" "$(field "$store" .sidekick.pane_id)"
		return 0
	fi
	if [ -z "$pane" ]; then
		local previous
		previous="$(field "$store" '.sidekick.pane_id // empty')"
		if [ -n "$previous" ] && herdr pane get "$previous" >/dev/null 2>&1; then
			pane="$previous"
		fi
	fi
	local started=""
	if [ -n "$pane" ]; then
		if started="$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$timeout" -- "$@" 2>&1)"; then
			printf 'reused pane %s\n' "$pane"
		else
			printf 'pane %s unavailable for agent start: %s\n' "$pane" "$started" >&2
			pane=""
		fi
	fi
	if [ -z "$pane" ]; then
		[ -n "$direction" ] || direction="$(pick_direction "$master_pane")"
		pane="$(herdr pane split --pane "$master_pane" --direction "$direction" --cwd "$cwd" --no-focus | jq -r '.result.pane.pane_id')"
		[ -n "$pane" ] && [ "$pane" != null ] || die "pane split returned no pane id" 2
		printf 'split %s %s -> %s\n' "$master_pane" "$direction" "$pane"
		herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$timeout" -- "$@" >/dev/null || die "agent start failed in $pane; inspect: herdr pane read $pane --source visible" 2
	fi
	local now
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	jq --arg pane "$pane" --arg kind "$kind" --arg now "$now" --arg perm "$permission" --arg mperm "$master_mode" \
		'.sidekick.pane_id = $pane | .sidekick.kind = $kind | .sidekick.started_at = $now
		 | .sidekick.permission_mode = $perm | .master.permission_mode = $mperm' \
		"$store/pair.json" >"$store/pair.json.tmp"
	mv "$store/pair.json.tmp" "$store/pair.json"
	printf 'sidekick %s (%s) started in %s with permission %s (master: %s)\n' "$name" "$kind" "$pane" "$permission" "$master_mode"
	local bootstrap="Load the pstack-pair skill from ~/.agents/skills/pstack-pair/SKILL.md and take the sidekick role. Pair store: $store. Follow its bootstrap steps, write reports/000-ready.md, and reply READY."
	local out err code=0
	out="$(herdr agent prompt "$name" "$bootstrap" --wait --timeout 240000 2>/tmp/pair-spawn-err.$$)" || code=$?
	err="$(cat /tmp/pair-spawn-err.$$ 2>/dev/null || true)"
	rm -f /tmp/pair-spawn-err.$$
	if [ "$code" -ne 0 ]; then
		printf 'bootstrap did not settle: %s\n' "$err" >&2
		printf 'inspect: herdr agent read %s --source visible --lines 60\n' "$name" >&2
		exit 3
	fi
	if [ -f "$store/reports/000-ready.md" ]; then
		printf 'ready: %s\n' "$store/reports/000-ready.md"
	else
		printf 'settled but reports/000-ready.md is missing; state=%s. Read the pane before prompting again.\n' "$(agent_status "$name")" >&2
		exit 4
	fi
}

cmd_new_plan() {
	[ $# -eq 2 ] || die "usage: pair.sh new-plan <store> <slug>"
	local store="$1" slug="$2" seq path
	pair_file "$store" >/dev/null
	[[ "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "plan slug must be lowercase [a-z0-9_-]"
	seq="$(next_seq "$store")"
	path="$store/plans/$seq-$slug.md"
	sed -e "s|{{SEQ}}|$seq|g" -e "s|{{SLUG}}|$slug|g" -e "s|{{STORE}}|$store|g" \
		"$skill_root/references/plan-template.md" >"$path"
	printf '%s\n' "$path"
}

# Shared by discuss and dispatch: refuse unfilled files and a sidekick that
# cannot take input, then prompt and wait.
send_and_wait() {
	# $1 store, $2 file, $3 message kind (PLAN|BRIEF), $4 timeout
	local store="$1" file="$2" kind="$3" timeout="$4" name status out err code=0 errfile
	if grep -q '{{' "$file"; then
		die "$file still has unfilled {{placeholders}}"
	fi
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	idle | done) ;;
	absent) die "sidekick $name is not live; run: pair.sh spawn $store --kind <kind>" 2 ;;
	blocked) die "sidekick $name is blocked; inspect: herdr agent read $name --source visible --lines 60" 3 ;;
	*) die "sidekick $name is $status; run: pair.sh wait $store" 5 ;;
	esac
	[ "$kind" = BRIEF ] && record_dispatch "$store" "$file"
	errfile="$(mktemp)"
	out="$(herdr agent prompt "$name" "pstack-pair $kind $file" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
	err="$(cat "$errfile")"
	rm -f "$errfile"
	finish_wait "$store" "$code" "$out" "$err"
}

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
	checkin_interval_m=$((timeout / 60000))
	[ -f "$plan" ] || die "plan not found: $plan"
	send_and_wait "$store" "$(readlink -f "$plan")" PLAN "$timeout"
}

cmd_new_brief() {
	[ $# -eq 2 ] || die "usage: pair.sh new-brief <store> <slug>"
	local store="$1" slug="$2" seq path
	pair_file "$store" >/dev/null
	[[ "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "brief slug must be lowercase [a-z0-9_-]"
	seq="$(next_seq "$store")"
	path="$store/briefs/$seq-$slug.md"
	sed -e "s|{{SEQ}}|$seq|g" -e "s|{{SLUG}}|$slug|g" -e "s|{{STORE}}|$store|g" \
		"$skill_root/references/brief-template.md" >"$path"
	printf '%s\n' "$path"
}

cmd_dispatch() {
	in_herdr
	[ $# -ge 2 ] || die "usage: pair.sh dispatch <store> <brief-path> [--timeout MS | --every MIN]"
	local store="$1" brief="$2" timeout=540000
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	checkin_interval_m=$((timeout / 60000))
	[ -f "$brief" ] || die "brief not found: $brief"
	brief="$(readlink -f "$brief")"
	require_agreed_plan "$store" "$brief"
	send_and_wait "$store" "$brief" BRIEF "$timeout"
}

cmd_wait() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh wait <store> [--timeout MS | --every MIN]"
	local store="$1" timeout=540000
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	checkin_interval_m=$((timeout / 60000))
	local name out err code=0 errfile
	name="$(field "$store" .sidekick.name)"
	errfile="$(mktemp)"
	out="$(herdr agent wait "$name" --timeout "$timeout" 2>"$errfile")" || code=$?
	err="$(cat "$errfile")"
	rm -f "$errfile"
	finish_wait "$store" "$code" "$out" "$err"
}

cmd_report() {
	[ $# -ge 1 ] || die "usage: pair.sh report <store> [NNN]"
	local path
	if path="$(latest_report "$1" "${2:-}")"; then
		printf '%s\n' "$path"
	else
		die "no report found" 4
	fi
}

cmd_notify() {
	in_herdr
	[ $# -eq 2 ] || die "usage: pair.sh notify <store> <report-path>"
	local store="$1" report status master
	report="$(readlink -f "$2")"
	[ -f "$report" ] || die "report not found: $report"
	master="$(field "$store" .master.name)"
	status="$(agent_status "$master")"
	case "$status" in
	idle | done)
		herdr agent prompt "$master" "pstack-pair REPORT $report" >/dev/null
		printf 'prompted master %s (was %s) with %s\n' "$master" "$status" "$report"
		;;
	*)
		printf 'master %s is %s; left %s for its next wait or status check\n' "$master" "$status" "$report"
		;;
	esac
}

cmd_stop() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh stop <store> [--timeout MS]"
	local store="$1" timeout=300000
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	checkin_interval_m=$((timeout / 60000))
	local name status out err code=0 errfile
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	absent) die "sidekick $name is not live" 2 ;;
	blocked) die "sidekick $name is blocked; inspect it before stopping" 3 ;;
	esac
	errfile="$(mktemp)"
	out="$(herdr agent prompt "$name" "pstack-pair STOP $store" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
	err="$(cat "$errfile")"
	rm -f "$errfile"
	finish_wait "$store" "$code" "$out" "$err" any
}

cmd_progress() {
	[ $# -eq 2 ] || die "usage: pair.sh progress <store> <text>"
	local store="$1" text="$2" path
	pair_file "$store" >/dev/null
	path="$(progress_path "$store")" || die "no brief dispatched yet; progress belongs to a running brief"
	mkdir -p "$store/progress"
	printf '%s %s\n' "$(date +%H:%M)" "$text" >>"$path"
	printf '%s\n' "$path"
}

# Fresh steers on a unit are capped at two; a steer that supersedes an objected
# one is a discussion round and does not count.
cmd_new_steer() {
	[ $# -ge 2 ] || die "usage: pair.sh new-steer <store> <NNN> [--supersedes STEER | --force]"
	local store="$1" seq="$2" force=0 supersedes=none brief slug k f fresh=0 path
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--force) force=1; shift ;;
		--supersedes) supersedes="$(readlink -f "$2")"; shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	brief="$(ls "$store"/briefs/"$seq"-*.md 2>/dev/null | head -1 || true)"
	[ -n "$brief" ] || die "no brief for unit $seq"
	slug="$(basename "$brief" .md | cut -c5-)"
	k=0
	for f in "$store"/steers/"$seq"-"$slug"-s[0-9]*.md; do
		[ -e "$f" ] || continue
		k=$((k + 1))
		[ "$(header_field "$f" supersedes)" = none ] && fresh=$((fresh + 1))
	done
	k=$((k + 1))
	if [ "$supersedes" != none ]; then
		[ -f "$supersedes" ] || die "superseded steer not found: $supersedes"
		[ "$(header_field "$(ls -t "$store"/reports/"$seq"-"$slug"-s[0-9]*.md 2>/dev/null | head -1 || true)" status 2>/dev/null)" = object ] \
			|| die "no open objection on unit $seq to answer; send a fresh steer instead"
	elif [ "$fresh" -ge 2 ] && [ "$force" -eq 0 ]; then
		die "unit $seq already has two fresh steers; stop the unit and re-brief, or pass --force" 7
	fi
	mkdir -p "$store/steers"
	path="$store/steers/$seq-$slug-s$k.md"
	sed -e "s|{{SEQ}}|$seq|g" -e "s|{{SLUG}}|$slug|g" -e "s|{{K}}|$k|g" -e "s|{{STORE}}|$store|g" \
		-e "s|{{SUPERSEDES}}|$supersedes|g" \
		"$skill_root/references/steer-template.md" >"$path"
	printf '%s\n' "$path"
}

# A steer is the one message that may reach a working sidekick. It lands in
# the agent's input queue, handed over between tool calls; the ack is a
# progress line, so there is nothing to wait for. A sidekick paused on an
# objection is idle, so a steer that answers it is sent with a wait instead.
cmd_steer() {
	in_herdr
	[ $# -ge 2 ] || die "usage: pair.sh steer <store> <steer-path> [--interrupt] [--force] [--timeout MS | --every MIN]"
	local store="$1" steer force=0 interrupt=0 timeout=540000 name status seq slug objection out err code=0 errfile
	steer="$(readlink -f "$2")"
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--force) force=1; shift ;;
		--interrupt) interrupt=1; shift ;;
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	checkin_interval_m=$((timeout / 60000))
	[ -f "$steer" ] || die "steer not found: $steer"
	grep -q '^## Direction' "$steer" || die "not a steer file: $steer"
	if grep -q '{{' "$steer" || grep -qE '^(kind|scope effect): .*\|' "$steer"; then
		die "$steer still has unfilled placeholders"
	fi
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	working)
		if [ "$interrupt" -eq 1 ]; then
			# Esc cancels the running tool call so the steer is read now, not after it.
			herdr agent send-keys "$name" esc >/dev/null || die "herdr send-keys failed for $name" 2
			herdr agent wait "$name" --until idle --until "done" --until blocked --timeout 15000 >/dev/null \
				|| die "sidekick $name did not settle after esc; inspect: herdr agent read $name --source visible --lines 60" 3
		fi
		herdr agent prompt "$name" "pstack-pair STEER $steer" >/dev/null || die "herdr prompt failed for $name" 2
		# Devin parks a mid-turn message as "queued" until Enter is pressed again;
		# Claude Code and Codex inject it between tool calls on their own.
		[ "$(field "$store" .sidekick.kind)" = devin ] && { sleep 1; herdr agent send-keys "$name" enter >/dev/null; }
		printf 'steered %s with %s; its harness hands it over between tool calls and the ack lands in the progress log\n' "$name" "$steer"
		;;
	idle | done)
		seq="$(basename "$steer" | cut -c1-3)"
		slug="$(basename "$steer" .md | sed -E 's/^[0-9]{3}-//; s/-s[0-9]+$//')"
		objection="$(ls -t "$store"/reports/"$seq"-"$slug"-s[0-9]*.md 2>/dev/null | head -1 || true)"
		[ -n "$objection" ] && [ "$(header_field "$objection" status)" = object ] \
			|| die "sidekick $name is $status and no objection is open on unit $seq; fold the steer into the next brief instead" 5
		[ "$(header_field "$steer" supersedes)" != none ] || die "$steer answers $objection but its supersedes: line says none"
		errfile="$(mktemp)"
		out="$(herdr agent prompt "$name" "pstack-pair STEER $steer" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
		err="$(cat "$errfile")"
		rm -f "$errfile"
		finish_wait "$store" "$code" "$out" "$err"
		;;
	unknown)
		[ "$force" -eq 1 ] || die "sidekick $name is unknown; read the pane, then pass --force to steer anyway" 5
		herdr agent prompt "$name" "pstack-pair STEER $steer" >/dev/null || die "herdr prompt failed for $name" 2
		printf 'steered %s with %s\n' "$name" "$steer"
		;;
	absent) die "sidekick $name is not live" 2 ;;
	blocked) die "sidekick $name is blocked; inspect: herdr agent read $name --source visible --lines 60" 3 ;;
	esac
}

cmd_status() {
	[ $# -eq 1 ] || die "usage: pair.sh status <store>"
	local store="$1" master sidekick f seq slug kind report review rstatus verdict units
	master="$(field "$store" .master.name)"
	sidekick="$(field "$store" .sidekick.name)"
	{
		printf '# Pair status\n\n'
		printf 'generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'master: %s (%s) %s\n' "$master" "$(field "$store" .master.pane_id)" "$(agent_status "$master")"
		printf 'sidekick: %s (%s) %s\n\n' "$sidekick" "$(field "$store" '.sidekick.pane_id // "unassigned"')" "$(agent_status "$sidekick")"
		printf '| seq | kind | unit | report | review |\n|---|---|---|---|---|\n'
		units=()
		for f in "$store"/plans/[0-9][0-9][0-9]-*.md "$store"/briefs/[0-9][0-9][0-9]-*.md; do
			[ -e "$f" ] && units+=("$(basename "$f")	$f")
		done
		while IFS=$'\t' read -r _ f; do
			[ -n "$f" ] || continue
			seq="$(basename "$f" | cut -c1-3)"
			slug="$(basename "$f" .md | cut -c5-)"
			kind="$(basename "$(dirname "$f")" | sed 's/s$//')"
			rstatus="none"
			if report="$(latest_report "$store" "$seq")"; then
				rstatus="$(grep -m1 -E '^status:' "$report" | sed 's/^status:[[:space:]]*//' || printf 'unlabelled')"
				[ -n "$rstatus" ] || rstatus="unlabelled"
			fi
			verdict="none"
			review="$(ls "$store"/reviews/"$seq"-*.md 2>/dev/null | head -1 || true)"
			if [ -n "$review" ]; then
				verdict="$(grep -m1 -E '^verdict:' "$review" | sed 's/^verdict:[[:space:]]*//' || printf 'unlabelled')"
				[ -n "$verdict" ] || verdict="unlabelled"
			fi
			printf '| %s | %s | %s | %s | %s |\n' "$seq" "$kind" "$slug" "$rstatus" "$verdict"
		done < <(printf '%s\n' "${units[@]}" | sort)
		if report="$(latest_report "$store")"; then
			printf '\nlatest report: %s\n' "$report"
		fi
		if [ -s "$store/gates.md" ] && grep -qE '^- ' "$store/gates.md"; then
			printf '\nopen gates: %s\n' "$(grep -cE '^- ' "$store/gates.md")"
		fi
	} | tee "$store/status.md"
}

cmd_log() {
	[ $# -eq 6 ] || die "usage: pair.sh log <store> <phase> <decision> <why> <evidence> <result>"
	local store="$1"
	shift
	[ -x "$log_helper" ] || die "show-me-your-work log helper not found at $log_helper"
	"$log_helper" "$store/decisions.tsv" "$@"
}

[ $# -ge 1 ] || { usage; exit 1; }
cmd="$1"
shift
case "$cmd" in
init) cmd_init "$@" ;;
spawn) cmd_spawn "$@" ;;
permission) cmd_permission ;;
new-plan) cmd_new_plan "$@" ;;
discuss) cmd_discuss "$@" ;;
new-brief) cmd_new_brief "$@" ;;
dispatch) cmd_dispatch "$@" ;;
wait) cmd_wait "$@" ;;
progress) cmd_progress "$@" ;;
new-steer) cmd_new_steer "$@" ;;
steer) cmd_steer "$@" ;;
report) cmd_report "$@" ;;
notify) cmd_notify "$@" ;;
stop) cmd_stop "$@" ;;
status) cmd_status "$@" ;;
log) cmd_log "$@" ;;
help | -h | --help) usage ;;
*) usage; die "unknown command: $cmd" ;;
esac
