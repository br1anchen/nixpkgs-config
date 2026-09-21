#!/usr/bin/env bash
# Trio store and Herdr channel helper for the pstack-trio skill: a master, a
# sidekick that owns the working tree, and a consultant that advises.
# Every subcommand is idempotent and prints what it did. JSON from herdr is
# parsed with jq; identifiers are never guessed.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
skill_root="$(dirname "$here")"
log_helper="$skill_root/../show-me-your-work/scripts/log.sh"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/pstack/trio"

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

exit codes: 0 ok, 1 usage or precondition, 2 herdr error, 3 agent blocked, 4 no report or advice yet,
            5 agent busy, 6 plan not agreed or consultant advice missing, 7 steer or consult cap reached,
            8 agent kinds not diverse
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

latest_advice() {
	# $1 store, $2 optional NNN: the newest advice file, by mtime.
	local store="$1" want="${2:-}" f
	if [ -n "$want" ]; then
		f="$(ls -t "$store"/advice/"$want"-*.md 2>/dev/null | head -1 || true)"
	else
		f="$(ls -t "$store"/advice/[0-9][0-9][0-9]-*.md 2>/dev/null | head -1 || true)"
	fi
	[ -n "$f" ] && printf '%s\n' "$f"
}

agent_kind() {
	# Prints the Herdr agent kind hosting $1 (a name or pane id), or empty.
	herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent // empty'
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

# Herdr's state detection can lag or miss a turn on a narrow pane, so a
# settled agent with no file yet is polled for the file, not trusted. $1
# path, $2 timeout in ms. Returns 0 when the file appears.
await_file() {
	local path="$1" timeout_ms="$2" waited=0
	while [ ! -f "$path" ] && [ "$waited" -lt "$timeout_ms" ]; do
		sleep 5
		waited=$((waited + 5000))
	done
	[ -f "$path" ]
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
	local advice
	advice="$(latest_advice "$store" "$seq")" || die "plan $plan has no consultant advice under advice/$seq-*; run pair.sh discuss so both agents respond" 6
	[ -n "$advice" ] || die "plan $plan has no consultant advice under advice/$seq-*; run pair.sh discuss so both agents respond" 6
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
	[[ "$slug" =~ ^[a-z][a-z0-9_-]{0,20}$ ]] || die "slug must match [a-z][a-z0-9_-]{0,20} (so <slug>-consultant fits Herdr's 32-char name limit)"
	[ -n "$store" ] || store="$state_root/$slug"
	[ -n "${HERDR_PANE_ID:-}" ] || die "HERDR_PANE_ID is unset; run from a Herdr-managed pane"
	mkdir -p "$store"/{plans,briefs,reports,reviews,progress,steers,consults,advice,scratch}
	local master="$slug-master" sidekick="$slug-sidekick" consultant="$slug-consultant" now cwd git_root
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
			--arg master "$master" --arg sidekick "$sidekick" --arg consultant "$consultant" --arg pane "$HERDR_PANE_ID" \
			--arg ws "${HERDR_WORKSPACE_ID:-}" --arg tab "${HERDR_TAB_ID:-}" \
			'{slug: $slug, store: $store, created_at: $now, cwd: $cwd, git_root: $git_root,
			  master: {name: $master, pane_id: $pane, workspace_id: $ws, tab_id: $tab, registered_at: $now},
			  sidekick: {name: $sidekick, pane_id: null, kind: null, started_at: null},
			  consultant: {name: $consultant, pane_id: null, kind: null, started_at: null},
			  scratch: []}' >"$store/pair.json"
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

# Start one role in a pane split from $anchor, record it in pair.json, and
# bootstrap it. $1 role (sidekick|consultant), $2 kind, $3 permission mode,
# $4 anchor pane, $5 timeout, rest: native agent args.
spawn_role() {
	local store="$1" role="$2" kind="$3" permission="$4" anchor="$5" timeout="$6"
	shift 6
	local master_mode
	master_mode="$(detect_permission_mode)"
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
	local name cwd status pane="" direction
	name="$(field "$store" ".$role.name")"
	cwd="$(field "$store" .cwd)"
	status="$(agent_status "$name")"
	if [ "$status" != absent ]; then
		printf '%s %s already live (%s) in %s\n' "$role" "$name" "$status" "$(field "$store" ".$role.pane_id")"
		return 0
	fi
	local previous started=""
	previous="$(field "$store" ".$role.pane_id // empty")"
	if [ -n "$previous" ] && herdr pane get "$previous" >/dev/null 2>&1; then
		if started="$(herdr agent start "$name" --kind "$kind" --pane "$previous" --timeout "$timeout" -- "$@" 2>&1)"; then
			pane="$previous"
			printf 'reused pane %s\n' "$pane"
		else
			printf 'pane %s unavailable for agent start: %s\n' "$previous" "$started" >&2
		fi
	fi
	if [ -z "$pane" ]; then
		direction="$(pick_direction "$anchor")"
		pane="$(herdr pane split --pane "$anchor" --direction "$direction" --cwd "$cwd" --no-focus | jq -r '.result.pane.pane_id')"
		[ -n "$pane" ] && [ "$pane" != null ] || die "pane split returned no pane id" 2
		printf 'split %s %s -> %s\n' "$anchor" "$direction" "$pane"
		herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$timeout" -- "$@" >/dev/null || die "agent start failed in $pane; inspect: herdr pane read $pane --source visible" 2
	fi
	local now
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	jq --arg role "$role" --arg pane "$pane" --arg kind "$kind" --arg now "$now" --arg perm "$permission" --arg mperm "$master_mode" \
		'.[$role].pane_id = $pane | .[$role].kind = $kind | .[$role].started_at = $now
		 | .[$role].permission_mode = $perm | .master.permission_mode = $mperm' \
		"$store/pair.json" >"$store/pair.json.tmp"
	mv "$store/pair.json.tmp" "$store/pair.json"
	printf '%s %s (%s) started in %s with permission %s (master: %s)\n' "$role" "$name" "$kind" "$pane" "$permission" "$master_mode"
	local ready bootstrap
	case "$role" in
	sidekick) ready="reports/000-ready.md" ;;
	consultant) ready="advice/000-ready.md" ;;
	esac
	bootstrap="Load the pstack-trio skill from ~/.agents/skills/pstack-trio/SKILL.md and take the $role role. Trio store: $store. Follow its bootstrap steps, write $ready, and reply READY."
	local out err code=0
	out="$(herdr agent prompt "$name" "$bootstrap" --wait --timeout 240000 2>/tmp/pair-spawn-err.$$)" || code=$?
	err="$(cat /tmp/pair-spawn-err.$$ 2>/dev/null || true)"
	rm -f /tmp/pair-spawn-err.$$
	if [ "$code" -ne 0 ] && printf '%s' "$err" | grep -q agent_prompt_stalled; then
		# State detection can lag on a narrow pane (Devin's status line wraps)
		# while the agent is in fact working. The ready file is the real signal.
		printf '%s prompt looked stalled; waiting for %s instead\n' "$role" "$ready"
		await_file "$store/$ready" 240000 && code=0
	fi
	if [ "$code" -ne 0 ]; then
		printf '%s bootstrap did not settle: %s\n' "$role" "$err" >&2
		printf 'inspect: herdr agent read %s --source visible --lines 60\n' "$name" >&2
		return 3
	fi
	if [ -f "$store/$ready" ]; then
		printf 'ready: %s\n' "$store/$ready"
	else
		printf '%s settled but %s is missing; state=%s. Read the pane before prompting again.\n' "$role" "$ready" "$(agent_status "$name")" >&2
		return 4
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
		spawn_role "$store" sidekick "$sidekick_kind" "$permission" "$master_pane" "$timeout" "$@" || rc=$?
		[ "$rc" -eq 0 ] || exit "$rc"
	fi
	if [ "$only" != sidekick ]; then
		# The consultant splits from the sidekick's pane so the master keeps its height.
		local anchor
		anchor="$(field "$store" '.sidekick.pane_id // empty')"
		[ -n "$anchor" ] && herdr pane get "$anchor" >/dev/null 2>&1 || anchor="$master_pane"
		spawn_role "$store" consultant "$consultant_kind" "$cpermission" "$anchor" "$timeout" "$@" || rc=$?
		[ "$rc" -eq 0 ] || exit "$rc"
	fi
	printf 'kinds: master %s, sidekick %s, consultant %s\n' "$master_kind" "$(field "$store" '.sidekick.kind // "absent"')" "$(field "$store" '.consultant.kind // "absent"')"
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
	out="$(herdr agent prompt "$name" "pstack-trio $kind $file" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
	err="$(cat "$errfile")"
	rm -f "$errfile"
	finish_wait "$store" "$code" "$out" "$err"
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
	grep -q '{{' "$plan" && die "$plan still has unfilled {{placeholders}}"
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
		herdr agent prompt "$name" "pstack-trio PLAN $plan" >/dev/null || die "herdr prompt failed for $name" 2
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
		else
			printf '%s_response: missing\n' "$role"
			rc=4
		fi
		[ "$status" = blocked ] && rc=3
	done
	exit "$rc"
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
	[ $# -eq 2 ] || die "usage: pair.sh notify <store> <report-or-advice-path>"
	local store="$1" file status master word
	file="$(readlink -f "$2")"
	[ -f "$file" ] || die "file not found: $file"
	case "$file" in
	"$store"/advice/*) word=ADVICE ;;
	*) word=REPORT ;;
	esac
	master="$(field "$store" .master.name)"
	status="$(agent_status "$master")"
	case "$status" in
	idle | done)
		herdr agent prompt "$master" "pstack-trio $word $file" >/dev/null
		printf 'prompted master %s (was %s) with %s %s\n' "$master" "$status" "$word" "$file"
		;;
	*)
		printf 'master %s is %s; left %s for its next wait or status check\n' "$master" "$status" "$file"
		;;
	esac
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
		out="$(herdr agent prompt "$name" "pstack-trio STOP $store" --wait --timeout "$timeout" 2>/dev/null)" || code=$?
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
		herdr agent prompt "$name" "pstack-trio STEER $steer" >/dev/null || die "herdr prompt failed for $name" 2
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
		out="$(herdr agent prompt "$name" "pstack-trio STEER $steer" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
		err="$(cat "$errfile")"
		rm -f "$errfile"
		finish_wait "$store" "$code" "$out" "$err"
		;;
	unknown)
		[ "$force" -eq 1 ] || die "sidekick $name is unknown; read the pane, then pass --force to steer anyway" 5
		herdr agent prompt "$name" "pstack-trio STEER $steer" >/dev/null || die "herdr prompt failed for $name" 2
		printf 'steered %s with %s\n' "$name" "$steer"
		;;
	absent) die "sidekick $name is not live" 2 ;;
	blocked) die "sidekick $name is blocked; inspect: herdr agent read $name --source visible --lines 60" 3 ;;
	esac
}

cmd_status() {
	[ $# -eq 1 ] || die "usage: pair.sh status <store>"
	local store="$1" master sidekick consultant f seq slug kind report advice review rstatus astatus verdict units
	master="$(field "$store" .master.name)"
	sidekick="$(field "$store" .sidekick.name)"
	consultant="$(field "$store" .consultant.name)"
	{
		printf '# Trio status\n\n'
		printf 'generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'master: %s (%s) %s\n' "$master" "$(field "$store" .master.pane_id)" "$(agent_status "$master")"
		printf 'sidekick: %s (%s) %s\n' "$sidekick" "$(field "$store" '.sidekick.pane_id // "unassigned"')" "$(agent_status "$sidekick")"
		printf 'consultant: %s (%s) %s\n\n' "$consultant" "$(field "$store" '.consultant.pane_id // "unassigned"')" "$(agent_status "$consultant")"
		printf '| seq | kind | unit | report | advice | review |\n|---|---|---|---|---|---|\n'
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
				rstatus="$(header_field "$report" status)"
				[ -n "$rstatus" ] || rstatus="unlabelled"
			fi
			astatus="none"
			if advice="$(latest_advice "$store" "$seq")"; then
				astatus="$(header_field "$advice" status)"
				[ -n "$astatus" ] || astatus="unlabelled"
				local n
				n="$(ls "$store"/advice/"$seq"-*-c[0-9]*.md 2>/dev/null | wc -l || true)"
				[ "${n:-0}" -gt 0 ] && astatus="$astatus (c$n)"
			fi
			verdict="none"
			review="$(ls "$store"/reviews/"$seq"-*.md 2>/dev/null | head -1 || true)"
			if [ -n "$review" ]; then
				verdict="$(header_field "$review" verdict)"
				[ -n "$verdict" ] || verdict="unlabelled"
			fi
			printf '| %s | %s | %s | %s | %s | %s |\n' "$seq" "$kind" "$slug" "$rstatus" "$astatus" "$verdict"
		done < <(printf '%s\n' "${units[@]}" | sort)
		if report="$(latest_report "$store")"; then
			printf '\nlatest report: %s\n' "$report"
		fi
		if advice="$(latest_advice "$store")"; then
			printf 'latest advice: %s\n' "$advice"
		fi
		local open
		open="$(jq -r '.scratch // [] | .[]' "$store/pair.json" 2>/dev/null || true)"
		if [ -n "$open" ]; then
			printf '\nopen scratch worktrees (remove with pair.sh scratch <store> <id> --remove):\n'
			printf '  %s\n' $open
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
	errfile="$(mktemp)"
	out="$(herdr agent prompt "$name" "pstack-trio CONSULT $consult" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
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

[ $# -ge 1 ] || { usage; exit 1; }
cmd="$1"
shift
case "$cmd" in
init) cmd_init "$@" ;;
spawn) cmd_spawn "$@" ;;
permission) cmd_permission ;;
new-plan) cmd_new_plan "$@" ;;
discuss) cmd_discuss "$@" ;;
new-consult) cmd_new_consult "$@" ;;
consult) cmd_consult "$@" ;;
advice) cmd_advice "$@" ;;
scratch) cmd_scratch "$@" ;;
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
