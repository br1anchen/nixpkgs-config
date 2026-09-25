# Shared store and Herdr channel core for pstack-pair, pstack-pair-guided, and
# pstack-trio. Each skill's scripts/pair.sh sets the variables below, sources
# this file, defines usage and any command it adds or overrides, then calls
# pair_main "$@". A command is any function named cmd_<name>, with dashes in
# the name as underscores. Every command is idempotent and prints what it did.
# JSON from herdr is parsed with jq; identifiers are never guessed.
#
# Set by the caller before sourcing:
#   skill_root    the calling skill's directory (templates live under it)
#   PAIR_SKILL    skill name; prefixes every prompt ("$PAIR_SKILL BRIEF <path>")
#   state_root    default parent directory of stores
#   store_label   "Pair" or "Trio", for the bootstrap prompt and status title
#   roles         agents the master spawns, in pane order: (sidekick [consultant])
#   store_dirs    directories init creates under the store
#   slug_max      longest slug tail, so <slug>-<longest role> fits Herdr's 32 chars
#   unfilled_re   optional ERE for header lines that still list alternatives

log_helper="$skill_root/../show-me-your-work/scripts/log.sh"
: "${unfilled_re:=}"

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

# pair.json has two writers once a brief is queued (the master, and the
# sidekick through next), so every write takes a short mkdir lock and replaces
# the file atomically. $1 store, rest: jq arguments ending in the filter.
json_update() {
	local store="$1" i=0 rc=0
	shift
	until mkdir "$store/.pair.lock" 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -lt 100 ] || die "pair.json lock held for 10s; remove $store/.pair.lock if no pair.sh is running"
		sleep 0.1
	done
	jq "$@" "$store/pair.json" >"$store/pair.json.tmp" && mv "$store/pair.json.tmp" "$store/pair.json" || rc=$?
	rmdir "$store/.pair.lock"
	return "$rc"
}

has_role() {
	local r
	for r in "${roles[@]}"; do [ "$r" = "$1" ] && return 0; done
	return 1
}

# herdr's state detection can miss a Devin agent in a narrow pane for a whole
# run, reporting done while it works. Every agent kind shows "esc to
# interrupt" (Devin: "esc twice to interrupt") in its status line while it
# works, so a settled state is checked against the bottom of the pane.
pane_busy() {
	herdr agent read "$1" --source visible --lines 15 2>/dev/null | grep -qiE 'esc (twice )?to interrupt'
}

agent_status() {
	# Prints idle|working|blocked|done|unknown, or "absent" when herdr has no such agent.
	local out state
	if out="$(herdr agent get "$1" 2>/dev/null)"; then
		state="$(printf '%s\n' "$out" | jq -r '.result.agent.agent_status // "unknown"')"
		case "$state" in
		idle | done) pane_busy "$1" && state=working ;;
		esac
		printf '%s\n' "$state"
	else
		printf 'absent\n'
	fi
}

agent_kind() {
	# Prints the Herdr agent kind hosting $1 (a name or pane id), or empty.
	herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent // empty' || true
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

# One row per channel event, so a run's timing is measured rather than guessed
# from file times. $1 store, $2 actor, $3 event, $4 unit (a file's basename
# without .md, or -), $5 detail. Never fails the command it records.
event() {
	local log="$1/events.tsv" unit="${4:-}"
	unit="$(basename "${unit:--}" .md)"
	{
		[ -f "$log" ] || printf 'ts\tepoch\tactor\tevent\tunit\tdetail\n'
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$2" "$3" "$unit" "${5:-}"
	} >>"$log" 2>/dev/null || true
}

header_field() {
	# $1 file, $2 key: the value of a "key: value" header line, or empty.
	grep -m1 -E "^$2:" "$1" | sed -E "s/^$2:[[:space:]]*//" || true
}

# Refuse a message file that still holds template text.
require_filled() {
	if grep -q '{{' "$1" || { [ -n "$unfilled_re" ] && grep -qE "$unfilled_re" "$1"; }; then
		die "$1 still has unfilled placeholders"
	fi
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
	json_update "$store" --arg brief "$brief" --arg now "$now" --arg head "$head" \
		--argjson epoch "$(date +%s)" \
		'.dispatch = {brief: $brief, at: $now, head: $head} | .sent = {file: $brief, kind: "BRIEF", at: $now, epoch: $epoch}
		 | .pending = ((.pending // []) + [$brief] | unique)'
}

# Briefs whose report the master has not been shown yet. A wait surfaces the
# oldest one whose report exists, whichever brief the sidekick is on by then,
# so a report written while the master was busy is never skipped.
pending_report() {
	local b r
	while IFS= read -r b; do
		[ -n "$b" ] || continue
		r="$(expected_report "$1" "$b")"
		[ -f "$r" ] && { printf '%s\n' "$r"; return 0; }
	done < <(jq -r '.pending // [] | .[]' "$1/pair.json")
	return 1
}

# $1 store, $2 a report the master has now seen: drop its brief from pending.
mark_seen() {
	local b keep=()
	while IFS= read -r b; do
		[ -n "$b" ] || continue
		[ "$(expected_report "$1" "$b")" = "$2" ] || keep+=("$b")
	done < <(jq -r '.pending // [] | .[]' "$1/pair.json")
	local list='[]'
	[ "${#keep[@]}" -eq 0 ] || list="$(printf '%s\n' "${keep[@]}" | jq -R . | jq -sc .)"
	json_update "$1" --argjson keep "$list" '.pending = $keep'
}

# The message the sidekick is answering: its report is the one a wait looks
# for, even when a newer brief already sits in the queue.
record_sent() {
	json_update "$1" --arg file "$2" --arg kind "$3" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson epoch "$(date +%s)" \
		'.sent = {file: $file, kind: $kind, at: $now, epoch: $epoch}'
}

file_mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# The sidekick's reply to the last message sent: the newest report for that
# unit written since the send, whether the unit's report, a plan response, a
# steer objection, or an ask. An older report for the unit is not the reply.
fresh_reply() {
	local sent epoch r
	sent="$(field "$1" '.sent.file // empty')"
	[ -n "$sent" ] || return 1
	epoch="$(field "$1" '.sent.epoch // 0')"
	r="$(latest_report "$1" "$(basename "$sent" | cut -c1-3)")" || return 1
	[ "$(file_mtime "$r")" -ge "$epoch" ] || return 1
	printf '%s\n' "$r"
}

# The report a message asks for: reports/<NNN-slug>.md, where an answer's
# -a<k> suffix names the brief it answers.
expected_report() {
	printf '%s/reports/%s.md\n' "$1" "$(basename "$2" .md | sed -E 's/-a[0-9]+$//')"
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

# Variant hook: further gates on an agreed plan, called with the store, the
# plan path, its review path, and its sequence number. Exit 6 on a refusal.
plan_gate_extra() { :; }

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
	plan_gate_extra "$store" "$plan" "$review" "$seq"
}

queued_brief() {
	# $1 store: the brief waiting in the queue, or empty.
	[ -f "$1/queue" ] && cat "$1/queue" || true
}

# After a report: say whether the sidekick already moved on to the queued
# brief, and whether a queued brief still waits for an idle sidekick.
queue_note() {
	local store="$1" report="$2" running queued
	running="$(field "$store" '.dispatch.brief // empty')"
	if [ -n "$running" ] && [ "$(basename "$running" | cut -c1-3)" != "$(basename "$report" | cut -c1-3)" ]; then
		printf 'running: %s\n' "$running"
	fi
	queued="$(queued_brief "$store")"
	[ -n "$queued" ] && printf 'queued: %s\n' "$queued"
	return 0
}

finish_wait() {
	# $1 store, $2 herdr exit code, $3 herdr stdout, $4 herdr stderr,
	# $5 "reply" (the report in $6, empty when none landed) or "any" (the
	# newest report at all)
	local store="$1" code="$2" out="$3" err="$4" mode="$5" report="${6:-}" state
	if [ "$code" -ne 0 ]; then
		state="$(printf '%s' "$err" | jq -r '.error.code // .error // "herdr_error"' 2>/dev/null || printf 'herdr_error')"
		printf 'state: %s\n' "$state"
		printf '%s\n' "$err" >&2
	else
		state="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // "settled"' 2>/dev/null || printf 'settled')"
		printf 'state: %s\n' "$state"
	fi
	if [ -n "$report" ] || { [ "$mode" = any ] && report="$(latest_report "$store")"; }; then
		mark_seen "$store" "$report"
		printf 'report: %s\n' "$report"
		printf 'report_status: %s\n' "$(header_field "$report" status)"
		event "$store" master wake "$report" "report:$(header_field "$report" status)"
		queue_note "$store" "$report"
		[ "$state" = blocked ] && exit 3
		exit 0
	fi
	printf 'report: missing\n'
	local running
	running="$(field "$store" '.dispatch.brief // empty')"
	case "$state" in
	blocked) event "$store" master wake "$running" blocked; exit 3 ;;
	esac
	if [ "$(agent_status "$(field "$store" .sidekick.name)")" = working ]; then
		event "$store" master wake "$running" checkin
		checkin "$store" "$checkin_interval_m"
	else
		event "$store" master wake "$running" missing
	fi
	exit 4
}

cmd_init() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh init <slug> [--store DIR]"
	local slug="$1" store="" longest="${roles[${#roles[@]}-1]}"
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--store) store="$2"; shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	[[ "$slug" =~ ^[a-z][a-z0-9_-]{0,$slug_max}$ ]] || die "slug must match [a-z][a-z0-9_-]{0,$slug_max} (so <slug>-$longest fits Herdr's 32-char name limit)"
	[ -n "$store" ] || store="$state_root/$slug"
	[ -n "${HERDR_PANE_ID:-}" ] || die "HERDR_PANE_ID is unset; run from a Herdr-managed pane"
	local d
	for d in "${store_dirs[@]}"; do mkdir -p "$store/$d"; done
	local master="$slug-master" now cwd git_root
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	cwd="$PWD"
	git_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
	herdr agent rename "$HERDR_PANE_ID" "$master" >/dev/null
	if [ -f "$store/pair.json" ]; then
		json_update "$store" --arg pane "$HERDR_PANE_ID" --arg ws "${HERDR_WORKSPACE_ID:-}" --arg tab "${HERDR_TAB_ID:-}" --arg now "$now" \
			'.master.pane_id = $pane | .master.workspace_id = $ws | .master.tab_id = $tab | .master.registered_at = $now'
		printf 'store: %s (re-registered master %s in %s)\n' "$store" "$master" "$HERDR_PANE_ID"
	else
		jq -n --arg slug "$slug" --arg store "$store" --arg now "$now" --arg cwd "$cwd" --arg git_root "$git_root" \
			--arg master "$master" --arg pane "$HERDR_PANE_ID" \
			--arg ws "${HERDR_WORKSPACE_ID:-}" --arg tab "${HERDR_TAB_ID:-}" --args \
			'{slug: $slug, store: $store, created_at: $now, cwd: $cwd, git_root: $git_root,
			  master: {name: $master, pane_id: $pane, workspace_id: $ws, tab_id: $tab, registered_at: $now}}
			 | reduce $ARGS.positional[] as $r (.; .[$r] = {name: "\($slug)-\($r)", pane_id: null, kind: null, started_at: null})
			 | if has("consultant") then .scratch = [] else . end' \
			"${roles[@]}" >"$store/pair.json"
		printf 'store: %s (master %s in %s)\n' "$store" "$master" "$HERDR_PANE_ID"
	fi
	event "$store" master init - "$PAIR_SKILL"
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

# Native arguments that give an agent of KIND the permission MODE. Empty for
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

# Start one role, record it in pair.json, and bootstrap it. It reuses $pane,
# or the role's previous pane when that is back at a shell prompt, and
# otherwise splits $anchor in $direction (picked from the anchor's shape when
# empty). $1 store, $2 role, $3 kind, $4 permission mode, $5 anchor pane,
# $6 timeout, $7 direction, $8 pane, rest: native agent args. Returns 3 when
# the bootstrap did not settle and 4 when it settled without the ready file.
spawn_role() {
	local store="$1" role="$2" kind="$3" permission="$4" anchor="$5" timeout="$6" direction="$7" pane="$8"
	shift 8
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
	local name cwd status
	name="$(field "$store" ".$role.name")"
	cwd="$(field "$store" .cwd)"
	status="$(agent_status "$name")"
	if [ "$status" != absent ]; then
		printf '%s %s already live (%s) in %s\n' "$role" "$name" "$status" "$(field "$store" ".$role.pane_id")"
		return 0
	fi
	if [ -z "$pane" ]; then
		local previous
		previous="$(field "$store" ".$role.pane_id // empty")"
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
		[ -n "$direction" ] || direction="$(pick_direction "$anchor")"
		pane="$(herdr pane split --pane "$anchor" --direction "$direction" --cwd "$cwd" --no-focus | jq -r '.result.pane.pane_id')"
		[ -n "$pane" ] && [ "$pane" != null ] || die "pane split returned no pane id" 2
		printf 'split %s %s -> %s\n' "$anchor" "$direction" "$pane"
		herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$timeout" -- "$@" >/dev/null || die "agent start failed in $pane; inspect: herdr pane read $pane --source visible" 2
	fi
	local now
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	json_update "$store" --arg role "$role" --arg pane "$pane" --arg kind "$kind" --arg now "$now" --arg perm "$permission" --arg mperm "$master_mode" \
		'.[$role].pane_id = $pane | .[$role].kind = $kind | .[$role].started_at = $now
		 | .[$role].permission_mode = $perm | .master.permission_mode = $mperm'
	printf '%s %s (%s) started in %s with permission %s (master: %s)\n' "$role" "$name" "$kind" "$pane" "$permission" "$master_mode"
	local ready bootstrap
	case "$role" in
	consultant) ready="advice/000-ready.md" ;;
	*) ready="reports/000-ready.md" ;;
	esac
	bootstrap="Load the $PAIR_SKILL skill from ~/.agents/skills/$PAIR_SKILL/SKILL.md and take the $role role. $store_label store: $store. Follow its bootstrap steps, write $ready, and reply READY."
	local out err code=0 errfile
	errfile="$(mktemp)"
	out="$(herdr agent prompt "$name" "$bootstrap" --wait --timeout 240000 2>"$errfile")" || code=$?
	err="$(cat "$errfile")"
	rm -f "$errfile"
	if [ "$code" -ne 0 ] && printf '%s' "$err" | grep -q agent_prompt_stalled; then
		# State detection can lag on a narrow pane (Devin's status line wraps)
		# while the agent is in fact working. The ready file is the real signal.
		printf '%s prompt looked stalled; waiting for %s instead\n' "$role" "$ready"
		await_file "$store/$ready" 240000 && code=0
	fi
	if [ "$code" -ne 0 ]; then
		printf '%s bootstrap did not settle: %s\n' "$role" "$err" >&2
		printf 'inspect: herdr agent read %s --source visible --lines 60\n' "$name" >&2
		event "$store" "$role" spawn - "$kind:failed"
		return 3
	fi
	if [ -f "$store/$ready" ]; then
		printf 'ready: %s\n' "$store/$ready"
		event "$store" "$role" spawn - "$kind:ready"
	else
		printf '%s settled but %s is missing; state=%s. Read the pane before prompting again.\n' "$role" "$ready" "$(agent_status "$name")" >&2
		return 4
	fi
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
	[ -n "$permission" ] || permission="$(detect_permission_mode)"
	local rc=0
	spawn_role "$store" sidekick "$kind" "$permission" "$(field "$store" .master.pane_id)" "$timeout" "$direction" "$pane" "$@" || rc=$?
	exit "$rc"
}

new_from_template() {
	# $1 store, $2 slug, $3 directory (plans|briefs), $4 template name
	local store="$1" slug="$2" dir="$3" seq path
	pair_file "$store" >/dev/null
	[[ "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "${dir%s} slug must be lowercase [a-z0-9_-]"
	seq="$(next_seq "$store")"
	path="$store/$dir/$seq-$slug.md"
	sed -e "s|{{SEQ}}|$seq|g" -e "s|{{SLUG}}|$slug|g" -e "s|{{STORE}}|$store|g" \
		"$skill_root/references/$4" >"$path"
	printf '%s\n' "$path"
}

cmd_new_plan() {
	[ $# -eq 2 ] || die "usage: pair.sh new-plan <store> <slug>"
	new_from_template "$1" "$2" plans plan-template.md
}

cmd_new_brief() {
	[ $# -eq 2 ] || die "usage: pair.sh new-brief <store> <slug>"
	new_from_template "$1" "$2" briefs brief-template.md
}

# Shared by discuss, dispatch, and answer: refuse unfilled files and a sidekick
# that cannot take input, then prompt and wait.
send_and_wait() {
	# $1 store, $2 file, $3 message kind (PLAN|BRIEF|ANSWER), $4 timeout
	local store="$1" file="$2" kind="$3" timeout="$4" name status out err code=0
	require_filled "$file"
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	idle | done) ;;
	absent) die "sidekick $name is not live; run: pair.sh spawn $store --kind <kind>" 2 ;;
	blocked) die "sidekick $name is blocked; inspect: herdr agent read $name --source visible --lines 60" 3 ;;
	*) die "sidekick $name is $status; run: pair.sh wait $store" 5 ;;
	esac
	if [ "$kind" = BRIEF ]; then
		[ "$(queued_brief "$store")" = "$file" ] && rm -f "$store/queue"
		record_dispatch "$store" "$file"
	else
		record_sent "$store" "$file" "$kind"
	fi
	event "$store" master "send-${kind,,}" "$file"
	prompt_sidekick "$name" "$PAIR_SKILL $kind $file"
	local ready
	wait_for_reply "$store" "$name" "$timeout"
	finish_wait "$store" "$code" "$out" "$err" reply "$ready"
}

# Parse the options every waiting command shares; sets $timeout and the
# check-in interval, and leaves any other flag in $rest for the caller.
wait_opts() {
	rest=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		*) rest+=("$1"); shift ;;
		esac
	done
	checkin_interval_m=$((timeout / 60000))
}

no_extra_opts() {
	[ "${#rest[@]}" -eq 0 ] || die "unknown option ${rest[0]}"
}

cmd_discuss() {
	in_herdr
	[ $# -ge 2 ] || die "usage: pair.sh discuss <store> <plan-path> [--timeout MS]"
	local store="$1" plan="$2" timeout=540000 rest
	shift 2
	wait_opts "$@"
	no_extra_opts
	[ -f "$plan" ] || die "plan not found: $plan"
	send_and_wait "$store" "$(readlink -f "$plan")" PLAN "$timeout"
}

cmd_dispatch() {
	in_herdr
	[ $# -ge 2 ] || die "usage: pair.sh dispatch <store> <brief-path> [--timeout MS | --every MIN]"
	local store="$1" brief="$2" timeout=540000 rest
	shift 2
	wait_opts "$@"
	no_extra_opts
	[ -f "$brief" ] || die "brief not found: $brief"
	brief="$(readlink -f "$brief")"
	require_agreed_plan "$store" "$brief"
	local queued
	queued="$(queued_brief "$store")"
	[ -z "$queued" ] || [ "$queued" = "$brief" ] || die "the queue holds $queued; dispatch that first, or: pair.sh queue $store --clear" 5
	send_and_wait "$store" "$brief" BRIEF "$timeout"
}

# Seconds a settle must hold, with no reply, before a wait believes it, and
# between checks while herdr says settled but the pane shows the agent busy.
settle_hold_s="${PAIR_SETTLE_HOLD:-60}"
busy_poll_s="${PAIR_BUSY_POLL:-10}"

# Blocks until the sidekick's reply lands or the interval ends, in short
# slices so a report is seen the moment it is written, even after the
# sidekick took the queued brief and never settles. A settle from herdr is a
# hint, not proof: a Devin sidekick left in done flips to idle as a prompt
# arrives, and shows idle between steps. So a settle without a reply is
# rechecked, and only one that holds for settle_hold_s ends the wait. Sets
# code, out, err, and ready (the report, or empty) for finish_wait.
wait_for_reply() {
	local store="$1" name="$2" timeout="$3" deadline slice settled_at="" errfile state
	deadline=$(( $(date +%s) + timeout / 1000 ))
	errfile="$(mktemp)"
	while :; do
		if ready="$(pending_report "$store")" || ready="$(fresh_reply "$store")"; then
			code=0
			out="$(herdr agent get "$name" 2>/dev/null || true)"
			: >"$errfile"
			break
		fi
		ready=""
		slice=$(( (deadline - $(date +%s)) * 1000 ))
		[ "$slice" -le 30000 ] || slice=30000
		[ "$slice" -ge 1000 ] || slice=1000
		code=0
		out="$(herdr agent wait "$name" --timeout "$slice" 2>"$errfile")" || code=$?
		if [ "$code" -eq 0 ]; then
			state="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)"
			[ "$state" != blocked ] || break
			{ pending_report "$store" >/dev/null || fresh_reply "$store" >/dev/null; } && continue
			if pane_busy "$name"; then
				# herdr says settled, the pane says working: believe the pane.
				settled_at=""
				sleep "$busy_poll_s"
				[ "$(date +%s)" -lt "$deadline" ] || break
				continue
			fi
			[ -n "$settled_at" ] || settled_at="$(date +%s)"
			[ $(( $(date +%s) - settled_at )) -lt "$settle_hold_s" ] || break
			[ "$(date +%s)" -lt "$deadline" ] || break
			sleep 5
			continue
		fi
		settled_at=""
		[ "$(jq -r '.error.code // empty' "$errfile" 2>/dev/null || true)" = timeout ] || break
		[ "$(date +%s)" -lt "$deadline" ] || break
	done
	err="$(cat "$errfile")"
	rm -f "$errfile"
}

# Sends one message and confirms the sidekick took it. A narrow pane can hide
# the working state, so a timeout or stall here is not an error; the wait that
# follows looks for the reply file either way.
prompt_sidekick() {
	local name="$1" text="$2" errfile rc=0
	errfile="$(mktemp)"
	herdr agent prompt "$name" "$text" --wait --until working --timeout 30000 >/dev/null 2>"$errfile" || rc=$?
	if [ "$rc" -ne 0 ]; then
		case "$(jq -r '.error.code // empty' "$errfile" 2>/dev/null || true)" in
		timeout | agent_prompt_stalled) ;;
		*) cat "$errfile" >&2; rm -f "$errfile"; die "herdr prompt failed for $name" 2 ;;
		esac
	fi
	rm -f "$errfile"
}

cmd_wait() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh wait <store> [--timeout MS | --every MIN]"
	local store="$1" timeout=540000 rest code out err ready
	shift
	wait_opts "$@"
	no_extra_opts
	wait_for_reply "$store" "$(field "$store" .sidekick.name)" "$timeout"
	finish_wait "$store" "$code" "$out" "$err" reply "$ready"
}

# The master's next brief, held for the sidekick to take the moment its
# current report is written. One slot: more than one queued brief is a plan.
cmd_queue() {
	[ $# -ge 2 ] || die "usage: pair.sh queue <store> <brief-path> [--replace] | pair.sh queue <store> --clear"
	local store="$1" brief="$2" replace=0 queued name status
	pair_file "$store" >/dev/null
	if [ "$brief" = --clear ]; then
		rm -f "$store/queue"
		event "$store" master queue - cleared
		printf 'queue cleared\n'
		return 0
	fi
	case "${3:-}" in
	--replace) replace=1 ;;
	"") ;;
	*) die "unknown option $3" ;;
	esac
	[ -f "$brief" ] || die "brief not found: $brief"
	brief="$(readlink -f "$brief")"
	require_filled "$brief"
	require_agreed_plan "$store" "$brief"
	queued="$(queued_brief "$store")"
	[ -z "$queued" ] || [ "$queued" = "$brief" ] || [ "$replace" -eq 1 ] || die "the queue holds $queued; pass --replace to swap it" 5
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	working) ;;
	idle | done) die "sidekick $name is $status; dispatch instead: pair.sh dispatch $store $brief" 5 ;;
	*) die "sidekick $name is $status; resolve that before queueing" 3 ;;
	esac
	printf '%s\n' "$brief" >"$store/queue.tmp"
	mv "$store/queue.tmp" "$store/queue"
	event "$store" master queue "$brief"
	printf 'queued %s; the sidekick takes it when its current report is written\n' "$brief"
}

# Takes the queued brief, if any: records its dispatch and prints its path.
take_queued() {
	local store="$1" taken brief
	taken="$store/queue.taken.$$"
	mv "$store/queue" "$taken" 2>/dev/null || return 1
	brief="$(cat "$taken")"
	rm -f "$taken"
	[ -f "$brief" ] || die "queued brief is gone: $brief"
	record_dispatch "$store" "$brief"
	event "$store" sidekick send-brief "$brief" queued
	printf '%s\n' "$brief"
}

# The sidekick's pickup after writing a report: prints the queued brief's
# message to act on. Exit 4 when the queue is empty, so the turn ends.
cmd_next() {
	[ $# -eq 1 ] || die "usage: pair.sh next <store>"
	local brief
	pair_file "$1" >/dev/null
	brief="$(take_queued "$1")" || { printf 'queue: empty\n'; exit 4; }
	printf '%s BRIEF %s\n' "$PAIR_SKILL" "$brief"
}

# The one command a sidekick runs after writing any report: tells the master,
# then says what to do next. A done report takes the queued brief; anything
# else, and an empty queue, ends the turn.
cmd_finish() {
	in_herdr
	[ $# -eq 2 ] || die "usage: pair.sh finish <store> <report-path>"
	local store="$1" report status brief
	report="$(readlink -f "$2")"
	[ -f "$report" ] || die "report not found: $report; write it first"
	status="$(header_field "$report" status)"
	cmd_notify "$store" "$report"
	if [ "$status" = done ] && brief="$(take_queued "$store")"; then
		printf 'next: the master queued %s BRIEF %s\n' "$PAIR_SKILL" "$brief"
		printf 'Start that brief now, in this turn, as if the message had just arrived.\n'
	else
		printf 'next: end the turn with the single line: %s REPORT %s\n' "$PAIR_SKILL" "$report"
	fi
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
	event "$store" "$([ "$word" = ADVICE ] && echo consultant || echo sidekick)" "${word,,}" "$file" "$(header_field "$file" status)"
	master="$(field "$store" .master.name)"
	status="$(agent_status "$master")"
	case "$status" in
	idle | done)
		herdr agent prompt "$master" "$PAIR_SKILL $word $file" >/dev/null
		printf 'prompted master %s (was %s) with %s %s\n' "$master" "$status" "$word" "$file"
		;;
	*)
		printf 'master %s is %s; left %s for its next wait or status check\n' "$master" "$status" "$file"
		;;
	esac
}

cmd_stop() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh stop <store> [--timeout MS]"
	local store="$1" timeout=300000 rest
	shift
	wait_opts "$@"
	no_extra_opts
	local name status out err code=0 errfile
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	absent) die "sidekick $name is not live" 2 ;;
	blocked) die "sidekick $name is blocked; inspect it before stopping" 3 ;;
	esac
	rm -f "$store/queue"
	json_update "$store" '.pending = []'
	event "$store" master send-stop - sidekick
	errfile="$(mktemp)"
	out="$(herdr agent prompt "$name" "$PAIR_SKILL STOP $store" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
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
	event "$store" sidekick progress "$path"
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
	local store="$1" steer force=0 interrupt=0 timeout=540000 rest name status seq slug objection out err code=0 errfile opt
	steer="$(readlink -f "$2")"
	shift 2
	wait_opts "$@"
	for opt in "${rest[@]}"; do
		case "$opt" in
		--force) force=1 ;;
		--interrupt) interrupt=1 ;;
		*) die "unknown option $opt" ;;
		esac
	done
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
		herdr agent prompt "$name" "$PAIR_SKILL STEER $steer" >/dev/null || die "herdr prompt failed for $name" 2
		event "$store" master send-steer "$steer" working
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
		event "$store" master send-steer "$steer" objection
		# The reply to this steer is any report on the unit written from now.
		json_update "$store" --argjson epoch "$(date +%s)" '.sent.epoch = $epoch'
		prompt_sidekick "$name" "$PAIR_SKILL STEER $steer"
		local ready
		wait_for_reply "$store" "$name" "$timeout"
		finish_wait "$store" "$code" "$out" "$err" reply "$ready"
		;;
	unknown)
		[ "$force" -eq 1 ] || die "sidekick $name is unknown; read the pane, then pass --force to steer anyway" 5
		herdr agent prompt "$name" "$PAIR_SKILL STEER $steer" >/dev/null || die "herdr prompt failed for $name" 2
		printf 'steered %s with %s\n' "$name" "$steer"
		;;
	absent) die "sidekick $name is not live" 2 ;;
	blocked) die "sidekick $name is blocked; inspect: herdr agent read $name --source visible --lines 60" 3 ;;
	esac
}

cmd_status() {
	[ $# -eq 1 ] || die "usage: pair.sh status <store>"
	local store="$1" f seq slug kind report advice review rstatus astatus verdict units role name k n
	local consultant=0
	has_role consultant && consultant=1
	{
		printf '# %s status\n\n' "$store_label"
		printf 'generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		name="$(field "$store" .master.name)"
		printf 'master: %s (%s) %s\n' "$name" "$(field "$store" .master.pane_id)" "$(agent_status "$name")"
		for role in "${roles[@]}"; do
			name="$(field "$store" ".$role.name")"
			printf '%s: %s (%s) %s\n' "$role" "$name" "$(field "$store" ".$role.pane_id // \"unassigned\"")" "$(agent_status "$name")"
		done
		printf '\n'
		if [ "$consultant" -eq 1 ]; then
			printf '| seq | kind | unit | report | advice | review |\n|---|---|---|---|---|---|\n'
		else
			printf '| seq | kind | unit | report | review |\n|---|---|---|---|---|\n'
		fi
		units=()
		for f in "$store"/plans/[0-9][0-9][0-9]-*.md "$store"/briefs/[0-9][0-9][0-9]-*.md; do
			[ -e "$f" ] || continue
			case "$f" in *.direction.md) continue ;; esac
			units+=("$(basename "$f")	$f")
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
			verdict="none"
			review="$(ls "$store"/reviews/"$seq"-*.md 2>/dev/null | head -1 || true)"
			if [ -n "$review" ]; then
				verdict="$(header_field "$review" verdict)"
				[ -n "$verdict" ] || verdict="unlabelled"
			fi
			if [ "$consultant" -eq 1 ]; then
				astatus="none"
				if advice="$(latest_advice "$store" "$seq")"; then
					astatus="$(header_field "$advice" status)"
					[ -n "$astatus" ] || astatus="unlabelled"
					n="$(ls "$store"/advice/"$seq"-*-c[0-9]*.md 2>/dev/null | wc -l || true)"
					[ "${n:-0}" -gt 0 ] && astatus="$astatus (c$n)"
				fi
				printf '| %s | %s | %s | %s | %s | %s |\n' "$seq" "$kind" "$slug" "$rstatus" "$astatus" "$verdict"
			else
				printf '| %s | %s | %s | %s | %s |\n' "$seq" "$kind" "$slug" "$rstatus" "$verdict"
			fi
		done < <(printf '%s\n' "${units[@]}" | sort)
		if report="$(latest_report "$store")"; then
			printf '\nlatest report: %s\n' "$report"
		fi
		if [ "$consultant" -eq 1 ] && advice="$(latest_advice "$store")"; then
			printf 'latest advice: %s\n' "$advice"
		fi
		if [ -f "$store/queue" ]; then
			printf 'queued: %s\n' "$(queued_brief "$store")"
		fi
		local open
		open="$(jq -r '.scratch // [] | .[]' "$store/pair.json" 2>/dev/null || true)"
		if [ -n "$open" ]; then
			printf '\nopen scratch worktrees (remove with pair.sh scratch <store> <id> --remove):\n'
			printf '  %s\n' $open
		fi
		if [ -d "$store/answers" ]; then
			local asks=0
			for f in "$store"/reports/[0-9][0-9][0-9]-*-q[0-9]*.md; do
				[ -e "$f" ] || continue
				seq="$(basename "$f" | cut -c1-3)"
				k="$(basename "$f" .md | sed -E 's/.*-q([0-9]+)$/\1/')"
				ls "$store"/answers/"$seq"-*-a"$k".md >/dev/null 2>&1 || asks=$((asks + 1))
			done
			if [ "$asks" -gt 0 ]; then printf 'unanswered asks: %s\n' "$asks"; fi
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
	event "$store" master log - "$1: $2"
}

# A throwaway worktree beside the shared tree. Default: detached at HEAD with
# the sidekick's uncommitted diff applied, so a prototype or build starts from
# the live state. With --at SHA: exactly that commit, so the master can rerun
# a unit's checks, or the consultant read it, while the sidekick keeps working.
# Removed when done; status lists the open ones.
cmd_scratch() {
	[ $# -ge 2 ] || die "usage: pair.sh scratch <store> <id> [--at SHA] [--remove]"
	local store="$1" id="$2" remove=0 at="" cwd path
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--remove) remove=1; shift ;;
		--at) at="$2"; shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	[[ "$id" =~ ^[0-9]{3}-[a-z0-9_-]+$ ]] || die "scratch id must look like NNN-<slug>, e.g. NNN-<slug>-c<k> or NNN-<slug>-review"
	cwd="$(field "$store" .git_root)"
	[ -n "$cwd" ] && [ "$cwd" != null ] || die "the store's cwd is not inside a git repository"
	path="$store/scratch/$id"
	if [ "$remove" -eq 1 ]; then
		if [ -d "$cwd/.jj" ]; then
			jj -R "$cwd" workspace forget "scratch-$id" >/dev/null 2>&1 || true
			rm -rf "$path"
		else
			git -C "$cwd" worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path"
			git -C "$cwd" worktree prune >/dev/null 2>&1 || true
		fi
		json_update "$store" --arg id "$id" '.scratch = ((.scratch // []) - [$id])'
		printf 'removed %s\n' "$path"
		return 0
	fi
	if [ -d "$path" ]; then
		printf '%s\n' "$path"
		return 0
	fi
	mkdir -p "$store/scratch"
	if [ -n "$at" ]; then
		git -C "$cwd" rev-parse --verify --quiet "$at^{commit}" >/dev/null || die "not a commit: $at"
		if [ -d "$cwd/.jj" ]; then
			jj -R "$cwd" workspace add --name "scratch-$id" -r "$at" "$path" >/dev/null || die "jj workspace add failed" 2
		else
			git -C "$cwd" worktree add --detach "$path" "$at" >/dev/null || die "git worktree add failed" 2
		fi
	elif [ -d "$cwd/.jj" ]; then
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
	json_update "$store" --arg id "$id" '.scratch = ((.scratch // []) + [$id] | unique)'
	printf '%s\n' "$path"
}

# Where a run's time went, from events.tsv. A sidekick is busy from a brief,
# plan, answer, or objection steer until its report for that unit, a new
# send, or now if it is still running; idle from a report to the next send.
# The same holds for the consultant between a plan or consult and its advice.
# Review latency runs from a brief's report to the master's next review log
# row. PAIR_METRICS_NOW fixes "now", for a view as of an earlier time.
cmd_metrics() {
	[ $# -eq 1 ] || die "usage: pair.sh metrics <store>"
	local store="$1"
	[ -s "$store/events.tsv" ] || die "no events.tsv in $store; it is written from the first command on"
	awk -F '\t' -v now="${PAIR_METRICS_NOW:-$(date +%s)}" '
	function median(a, n,    i, j, t) {
		for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
		return n ? a[int((n + 1) / 2)] : 0
	}
	function m(s) { return sprintf("%.0fm", s / 60) }
	function seq(u) { return substr(u, 1, 3) }
	function sk_start(t, u, kind) {
		# A send while the sidekick still holds a unit means that unit stopped.
		if (sk_on) sk_close(t, " (stopped)")
		else if (sk_free != "") { sk_idle += t - sk_free; sk_gaps++; if (t == sk_free) pickups++ }
		sk_on = 1; sk_since = t; sk_unit = u; sk_kind = kind
	}
	function sk_close(t, note) {
		sk_on = 0; sk_busy += t - sk_since; sk_free = t
		if (sk_kind == "brief") { nb++; bd[nb] = t - sk_since; bl = bl sprintf("  %s %s%s\n", sk_unit, m(t - sk_since), note); if (note == "") review_from = t }
		else { np++; plan_sk += t - sk_since }
	}
	# Only a report for the unit the sidekick holds ends it; a late wake on
	# the previous unit does not end the queued one it already took.
	function sk_end(t, u) { if (sk_on && seq(u) == seq(sk_unit)) sk_close(t, u ~ /-[sq][0-9]+$/ ? " (paused)" : "") }
	function co_start(t, kind) { if (!co_on) { co_on = 1; co_since = t; co_kind = kind } }
	function co_end(t) {
		if (!co_on) return
		co_on = 0; co_busy += t - co_since
		if (co_kind == "plan") plan_co += t - co_since; else { nc++; consult_t += t - co_since }
	}
	NR == 1 { next }
	{
		t = $2; actor = $3; ev = $4; u = $5; d = $6
		if (first == "") first = t
		last = t
		if (ev == "send-brief" || ev == "send-answer") { sk_start(t, u, "brief"); if (d == "queued") taken++ }
		else if (ev == "send-plan" && d != "consultant") sk_start(t, u, "plan")
		else if (ev == "send-plan" && d == "consultant") co_start(t, "plan")
		else if (ev == "send-consult") co_start(t, "consult")
		else if (ev == "send-steer" && d == "objection") sk_start(t, u, "brief")
		else if (ev == "queue" && u != "-") queued[u] = 1
		else if (actor == "sidekick" && ev == "report") sk_end(t, u)
		else if (actor == "consultant" && ev == "advice") co_end(t)
		else if (ev == "wake") {
			wakes++
			if (d == "checkin") checkins++
			if (d ~ /^report:/ || d ~ /^sidekick:/) sk_end(t, u)
			if (d ~ /^advice:/ || d ~ /^consultant:/) co_end(t)
		}
		else if (ev == "log" && (d ~ /^review:/ || d ~ /^plan:/)) {
			# The decision is free text; its verdict is the first verdict word.
			n = split(tolower(d), w, /[^a-z]+/)
			for (i = 1; i <= n; i++) {
				v = w[i]; sub(/ed$/, "", v); if (v == "accept" || v == "reject") { verdicts[v]++; break }
				if (w[i] == "agreed" || w[i] == "revise") { verdicts[w[i]]++; break }
			}
			if (d ~ /^review:/ && review_from != "") { nr++; rl[nr] = t - review_from; review_from = "" }
		}
	}
	END {
		end = (sk_on || co_on) && now >= last ? now : last
		if (sk_on) { running = sprintf("running: %s for %s\n", sk_unit, m(end - sk_since)); sk_busy += end - sk_since }
		wall = end - first
		printf "wall: %s from first event to %s\n", m(wall), sk_on || co_on ? "now" : "last"
		printf "sidekick: busy %s (%d%% of wall), idle %s across %d gaps; %d briefs (median %s), %d plan responses (%s)\n", \
			m(sk_busy), wall ? 100 * sk_busy / wall : 0, m(sk_idle), sk_gaps, nb, m(median(bd, nb)), np, m(plan_sk)
		q = 0; for (k in queued) q++
		if (q || taken) printf "queue: %d briefs queued, %d taken by the sidekick; %d started the moment a report landed\n", q, taken, pickups
		if (co_busy || nc || co_on) printf "consultant: busy %s (%d%% of wall); %d consults (%s), plan advice %s\n", \
			m(co_busy), wall ? 100 * co_busy / wall : 0, nc, m(consult_t), m(plan_co)
		printf "master: %d wakes, %d of them check-ins; review latency median %s over %d reviews\n", wakes, checkins, m(median(rl, nr)), nr
		v = ""; n = split("agreed accept revise reject", order, " ")
		for (i = 1; i <= n; i++) if (order[i] in verdicts) v = v sprintf(" %s %d", order[i], verdicts[order[i]])
		printf "verdicts:%s\n", v == "" ? " none" : v
		if (nb || running != "") printf "briefs:\n%s%s", bl, running == "" ? "" : "  " running
	}' "$store/events.tsv"
}

pair_main() {
	[ $# -ge 1 ] || { usage; exit 1; }
	local cmd="$1" fn
	shift
	case "$cmd" in
	help | -h | --help) usage; return 0 ;;
	esac
	fn="cmd_${cmd//-/_}"
	if [[ "$cmd" =~ ^[a-z][a-z-]*$ ]] && declare -F "$fn" >/dev/null; then
		"$fn" "$@"
	else
		usage
		die "unknown command: $cmd"
	fi
}
