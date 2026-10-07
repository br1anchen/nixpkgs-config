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
# works, so a settled state is checked against the pane's visible screen,
# never scrollback, where an old frame could linger. Devin shows two more
# signs of a running turn: its input placeholder "Guide Devin while it works",
# and, while a message is queued, "send queued messages now" or "↵ send now".
# In an 11-row pane the queued block pushes the interrupt hint off screen, so
# each sign counts on its own. A narrow pane wraps them, so lines are joined.
pane_busy() {
	grep -qiE 'esc (twice )?to interrupt|guide devin while it works|send queued messages now|↵ send now|ctrl\+enter to send now' <<<"$(pane_text "$1")"
}

# The pane's visible screen as one line. Callers match it with a here-string:
# under pipefail, `cmd | grep -q` fails when grep exits early and cmd takes
# SIGPIPE, which turned matches into misses at random.
pane_text() {
	herdr agent read "$1" --source visible --lines 40 2>/dev/null | tr -s '\n\t ' ' ' || true
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
		'.dispatch = {brief: $brief, at: $now, head: $head, generation: (.sidekick.generation // 0)} | .sent = {file: $brief, kind: "BRIEF", at: $now, epoch: $epoch}
		 | .heads[$brief | split("/") | last | rtrimstr(".md")] //= $head
		 | .pending = ((.pending // []) + [$brief] | unique)'
}

# Briefs whose report the master has not been shown yet. A wait surfaces the
# oldest one whose report exists, whichever brief the sidekick is on by then,
# so a report written while the master was busy is never skipped.
pending_report() {
	local b r
	while IFS= read -r b; do
		[ -n "$b" ] || continue
		# A unit the master already reviewed was seen, however it was read.
		ls "$1"/reviews/"$(basename "$b" | cut -c1-3)"-*.md >/dev/null 2>&1 && continue
		r="$(expected_report "$1" "$b")"
		[ -f "$r" ] && report_ready "$1" "$r" && { printf '%s\n' "$r"; return 0; }
	done < <(jq -r '.pending // [] | .[]' "$1/pair.json")
	return 1
}

# Before the master dispatches, the sidekick is idle and every earlier brief
# has ended: drop those whose report or review exists, since the master read
# them by some path, and only a brief still owed a report stays pending.
prune_pending() {
	local b keep=() list='[]'
	while IFS= read -r b; do
		[ -n "$b" ] || continue
		[ -f "$(expected_report "$1" "$b")" ] && continue
		ls "$1"/reviews/"$(basename "$b" | cut -c1-3)"-*.md >/dev/null 2>&1 && continue
		keep+=("$b")
	done < <(jq -r '.pending // [] | .[]' "$1/pair.json")
	[ "${#keep[@]}" -eq 0 ] || list="$(printf '%s\n' "${keep[@]}" | jq -R . | jq -sc .)"
	json_update "$1" --argjson keep "$list" '.pending = $keep'
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

# The sidekick's reply to the last message sent: the newest report written
# since the send that answers it: the unit's report or plan response
# (reports/<unit>.md), a steer objection (-s<k>), or an ask (-q<k>). A stop
# report shares the unit's number but answers a STOP, and one written late,
# after a re-dispatch, is not the reply to the brief.
fresh_reply() {
	local sent unit epoch f r="" best=-1 t rank key
	sent="$(field "$1" '.sent.file // empty')"
	[ -n "$sent" ] || return 1
	unit="$(basename "$sent" .md | sed -E 's/-a[0-9]+$//')"
	epoch="$(field "$1" '.sent.epoch // 0')"
	# Mtimes are whole seconds, so a tie goes to the unit's own report, then to
	# the highest-numbered objection or ask: the one written last.
	for f in "$1/reports/$unit.md" "$1/reports/$unit"-[sq][0-9]*.md; do
		[ -f "$f" ] || continue
		t="$(file_mtime "$f")"
		[ "$t" -ge "$epoch" ] || continue
		report_ready "$1" "$f" || continue
		rank="$(basename "$f" .md | sed -nE 's/.*-[sq]([0-9]+)$/\1/p')"
		key=$(( t * 1000 + ${rank:-999} ))
		[ "$key" -gt "$best" ] && { best="$key"; r="$f"; }
	done
	[ -n "$r" ] || return 1
	# A reply already shown to the master does not wake it again.
	[ "$r:$(file_mtime "$r")" != "$(field "$1" '.sent.seen // empty')" ] || return 1
	printf '%s\n' "$r"
}

# The reply the master was already shown for the last message, if it still exists.
seen_reply() {
	local seen
	seen="$(field "$1" '.sent.seen // empty')"
	[ -n "$seen" ] && [ -f "${seen%:*}" ] && printf '%s\n' "${seen%:*}"
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

# A quiet progress log is not stale while a command the sidekick started
# after its last line still runs (a ten-minute test suite). The sidekick's
# processes are the ones carrying its pane's HERDR_PANE_ID, which a detached
# gate inherits too; the master's own commands carry the master's. Prints the
# longest-running one, preferring a command over the shell that runs it, and
# its age; or nothing. Linux only.
busy_command() {
	local pane="$1" since="$2" now pid et comm best="" best_et=0 shell="" shell_et=0
	[ -n "$pane" ] && [ -d /proc ] || return 0
	now="$(date +%s)"
	while read -r pid et comm; do
		[ $((now - et)) -gt "$since" ] || continue
		grep -qxF "HERDR_PANE_ID=$pane" < <(tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ") || continue
		case "$comm" in
		bash | sh | zsh | dash | fish) [ "$et" -le "$shell_et" ] || { shell_et="$et"; shell="$comm"; } ;;
		*) [ "$et" -le "$best_et" ] || { best_et="$et"; best="$comm"; } ;;
		esac
	done < <(ps -u "$(id -u)" -o pid=,etimes=,comm= 2>/dev/null)
	[ -n "$best" ] || { best="$shell"; best_et="$shell_et"; }
	[ -z "$best" ] || printf '%s for %dm' "$best" $((best_et / 60))
}

# A brief's Scope entries, one path or glob per line, for `may` (the
# may write: list) or `mustnot` (must not write:). An entry is the text after
# "- ", without a " — " annotation or a trailing "(...)" note; one pair of
# surrounding backquotes is removed and what is inside is kept whole, commas and
# spaces included. Braces are literal, as in kitchen.py's glob language. Every
# consumer (the digest, the kitchen's classifier) reads Scope through this.
scope_entries() {
	awk -v want="$2" '
		/^may write:/ { f = (want == "may"); next }
		/^must not write:/ { f = (want == "mustnot"); next }
		/^## / { f = 0 }
		f && /^- / {
			sub(/^- /, "")
			if (substr($0, 1, 1) == "`") {
				e = substr($0, 2); i = index(e, "`")
				if (i > 0) e = substr(e, 1, i - 1)
			} else {
				e = $0; sub(/ +(—|–|--) .*$/, "", e); sub(/ +\(.*\)$/, "", e)
			}
			if (e != "") print e
		}' "$1"
}

# Refuses a brief whose Scope has an unquoted entry listing several paths
# ("a, b"): a guessed split could widen the Scope silently. Warns, without
# refusing, on an entry that matches nothing in the repo, the usual sign of
# a path written relative to its neighbour. $1 the brief, $2 the repo root.
check_scope() {
	local brief="$1" root="$2" bad e tracked
	bad="$(awk '
		/^may write:|^must not write:/ { f = 1; next }
		/^## / { f = 0 }
		f && /^- / {
			sub(/^- /, "")
			if (substr($0, 1, 1) == "`") next
			e = $0; sub(/ +(—|–|--) .*$/, "", e); sub(/ +\(.*\)$/, "", e)
			if (e ~ /, /) print "- " e
		}' "$brief")"
	[ -z "$bad" ] || die "$(basename "$brief"): Scope takes one path or glob per line; split these (a path with a comma goes in backquotes):
$bad"
	tracked="$(git -C "$root" ls-files -co --exclude-standard 2>/dev/null || true)"
	while IFS= read -r e; do
		[ -n "$e" ] || continue
		scope_entry_exists "$root" "$e" "$tracked" ||
			printf 'warning: Scope entry "%s" matches no file or directory in %s; is it relative to a neighbouring entry?\n' "$e" "$root" >&2
	done < <(scope_entries "$brief" may)
}

# Whether a may-write entry names something that exists, or a new file in a
# directory that does. A glob matches when a file does or its fixed directory
# prefix exists.
scope_entry_exists() {
	local root="$1" e="$2" tracked="$3" prefix dir f
	case "$e" in
	*[*?[]*)
		prefix="${e%%[*?[]*}"
		dir="${prefix%/*}"
		[ "$dir" != "$prefix" ] || dir=""
		[ -z "$dir" ] || [ -d "$root/$dir" ] || return 1
		while IFS= read -r f; do
			# shellcheck disable=SC2254
			case "$f" in $e) return 0 ;; esac
		done <<<"$tracked"
		[ -n "$dir" ] ;;
	*/) [ -d "$root/$e" ] || [ -d "$root/$(dirname "${e%/}")" ] ;;
	*) [ -e "$root/$e" ] || [ -d "$root/$(dirname "$e")" ] ;;
	esac
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
	return 0
}

# Where a unit's range should start: never from before the point its branch
# leaves trunk. A unit dispatched before a landing, or rebased onto a moved
# trunk, keeps a recorded base that trunk has since replaced, and measuring
# from it takes trunk's commits in. $2 is the recorded base, $3 the range's
# tip. Sets range_floor_rev (the base to use) and range_floor_note (why it
# moved, or empty); call it directly, not in a command substitution. The floor
# moves only when merge-base(base, tip) is an ancestor of merge-base(trunk,
# tip), and, for a verification range that must not be empty, never to the tip
# itself. A digest passes --allow-head: zero own commits after a rebase is a
# real state there. With no trunk ref the base stays as it was.
range_floor() {
	local root="$1" base="$2" tip="$3" allow="${4:-}" mb trunk tmb
	range_floor_rev="$base"
	range_floor_note=""
	trunk="$(trunk_ref "$root")"
	[ -n "$trunk" ] || return 0
	mb="$(git -C "$root" merge-base "$base" "$tip" 2>/dev/null || printf '%s' "$base")"
	tmb="$(git -C "$root" merge-base "$trunk" "$tip" 2>/dev/null)" || return 0
	[ "$tmb" != "$mb" ] || return 0
	[ "$tmb" != "$tip" ] || [ "$allow" = --allow-head ] || return 0
	git -C "$root" merge-base --is-ancestor "$mb" "$tmb" 2>/dev/null || return 0
	range_floor_note="recorded base ${base:0:9} is behind where its branch leaves ${trunk#refs/}; measuring from ${tmb:0:9}"
	range_floor_rev="$tmb"
}

# Paths git status lists, one per line, unquoted (NUL-delimited, so a name
# with a space or comma is a real path); a rename counts at its new path.
status_paths() {
	local entry skip=0
	while IFS= read -r -d '' entry; do
		if [ "$skip" -eq 1 ]; then skip=0; continue; fi
		case "${entry:0:2}" in R* | C*) skip=1 ;; esac
		printf '%s\n' "${entry:3}"
	done < <(git -C "$1" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
}

# The newest sign of work in the sidekick's tree, as an epoch: the mtime of
# each file git status lists (NUL-delimited, so names are real paths; a rename
# counts at its new path, a deleted file is skipped) and the committer time of
# HEAD when it moved since dispatch. Nothing when the tree is quiet. A
# future mtime within a minute counts as now; a later one is ignored.
tree_activity() {
	local cwd="$1" head="$2" now newest=0 entry path t skip=0 commits=0
	now="$(date +%s)"
	while IFS= read -r -d '' entry; do
		if [ "$skip" -eq 1 ]; then skip=0; continue; fi
		case "${entry:0:2}" in R* | C*) skip=1 ;; esac
		path="${entry:3}"
		t="$(stat -c %Y "$cwd/$path" 2>/dev/null)" || continue
		# A clock skew of a minute counts as now; a stamp further ahead is no evidence.
		[ "$t" -le $(( now + 60 )) ] || continue
		[ "$t" -le "$now" ] || t="$now"
		[ "$t" -le "$newest" ] || newest="$t"
	done < <(git -C "$cwd" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
	[ -z "$head" ] || commits="$(git -C "$cwd" rev-list --count "$head"..HEAD 2>/dev/null || printf 0)"
	if [ "$commits" -gt 0 ]; then
		t="$(git -C "$cwd" log -1 --format=%ct 2>/dev/null || printf 0)"
		[ "$t" -le "$now" ] || t="$now"
		[ "$t" -le "$newest" ] || newest="$t"
	fi
	[ "$newest" -eq 0 ] || printf '%s\n' "$newest"
}

# Check-in digest for a sidekick still working at the interval: elapsed against
# the timebox, progress lines not yet shown, files touched against the brief's
# Scope, commits since dispatch, and steer counts. Bounded, so the master can
# poll it cheaply instead of reading the pane. $2 is the interval in minutes.
checkin() {
	local store="$1" interval="${2:-9}" brief at head cwd seq slug prog total seen new age_m stale busy active timebox elapsed_m now
	brief="$(field "$store" '.dispatch.brief // empty')"
	[ -n "$brief" ] && [ -f "$brief" ] || return 0
	at="$(field "$store" '.dispatch.at // empty')"
	head="$(field "$store" '.dispatch.head // empty')"
	cwd="$(field "$store" .cwd)"
	local floor_note="" tip
	tip="$(git -C "$cwd" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
	if [ -n "$head" ] && [ -n "$tip" ]; then
		range_floor "$cwd" "$head" "$tip" --allow-head
		head="$range_floor_rev"
		floor_note="$range_floor_note"
	fi
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
		if [ "$age_m" -ge "$interval" ]; then
			busy="$(busy_command "$(field "$store" '.sidekick.pane_id // empty')" "$(stat -c %Y "$prog")")"
			if [ -n "$busy" ]; then
				stale="  running: $busy"
			else
				# Edits and commits are activity, not advancement: the timebox still fires.
				active="$(tree_activity "$cwd" "$head")"
				if [ -n "$active" ] && [ $(( now - active )) -lt $(( (interval > 0 ? interval : 1) * 60 )) ]; then
					stale="  editing: last change $(( (now - active) / 60 ))m ago"
				else
					stale="  STALE"
				fi
			fi
		fi
		printf 'progress: +%d lines (last %dm ago)%s\n' "$new" "$age_m" "$stale"
		tail -n "+$((seen + 1))" "$prog" | tail -n 20 | sed 's/^/  /'
		printf '%s\n' "$total" >"$prog.seen"
	else
		printf 'progress: none yet\n'
	fi
	local -a touched=() may=() outside=()
	mapfile -t touched < <({
		status_paths "$cwd"
		[ -n "$head" ] && git -C "$cwd" diff --name-only "$head"..HEAD 2>/dev/null
	} | sort -u)
	local commits=0
	[ -n "$head" ] && commits="$(git -C "$cwd" rev-list --count "$head"..HEAD 2>/dev/null || printf 0)"
	[ -z "$floor_note" ] || printf 'note: %s\n' "$floor_note"
	printf 'touched: %d files, %d commits since dispatch\n' "${#touched[@]}" "$commits"
	[ "${#touched[@]}" -gt 0 ] && printf '  %s\n' "${touched[@]:0:30}"
	mapfile -t may < <(scope_entries "$brief" may | sed 's#/$#/*#')
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
	local sfile
	sfile="$(steps_file "$store" "$brief")"
	if [ -s "$sfile" ]; then
		printf 'steps: %d committed, reviewed through %s, %d blocking notes open\n' "$(grep -c . "$sfile")" \
			"$(noted_through "$store" "$brief")" "$(open_notes "$store" "$brief" | grep -c . || true)"
	fi
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

# A pause asked for at the next safe point: the sidekick stops at its next
# step or progress boundary with its work committed, and the master starts
# nothing new. $store/paused holds the reason; pair.sh resume removes it.
paused_reason() {
	[ -f "$1/paused" ] && head -1 "$1/paused"
}

require_not_paused() {
	local reason
	reason="$(paused_reason "$1")" || return 0
	die "the store is paused ($reason): start nothing new; record where the work stands and end your turn, or run pair.sh resume $1" 5
}

# Printed by the sidekick's step, notes, progress, and finish commands, so a
# pause reaches it at the next boundary without a message.
pause_notice() {
	local reason
	reason="$(paused_reason "$1")" || return 0
	printf 'PAUSE: %s. This is your safe point: commit what is verified, write the report as partial with where you stopped and the next step under Deviations, run pair.sh finish, and end the turn.\n' "$reason"
}

# Steers left for the sidekick in the store (pair.sh steer to a working
# Devin) on the running brief, not yet acknowledged: no progress line "steer
# s<k> applied|withdrawn|late" and no objection report. A draft new-steer
# wrote, or a steer delivered as a message, is never listed.
open_steers() {
	local brief unit prog f k
	brief="$(field "$1" '.dispatch.brief // empty')"
	[ -n "$brief" ] || return 0
	unit="$(basename "$brief" .md)"
	prog="$1/progress/$unit.md"
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		case "$(basename "$f")" in "$unit"-s[0-9]*.md) ;; *) continue ;; esac
		k="$(basename "$f" .md | sed -E 's/.*-s([0-9]+)$/\1/')"
		[ -f "$prog" ] && grep -qE "steer s$k (applied|withdrawn|late)" "$prog" && continue
		[ -f "$1/reports/$unit-s$k.md" ] && continue
		printf '%s\n' "$f"
	done < <(jq -r '.notice_steers // [] | .[]' "$1/pair.json")
}

# Printed by the sidekick's step, notes, progress, and finish commands. This is
# how a steer reaches a working Devin: Enter would deliver a queued message
# now, but it cancels the command Devin is running.
steer_notice() {
	local f
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		printf 'STEER: read %s now, before your next tool call. Agree: apply it and run pair.sh progress %s "steer s%s applied: <what changed>". Object: write the steer response and run pair.sh finish on it.\n' \
			"$f" "$1" "$(basename "$f" .md | sed -E 's/.*-s([0-9]+)$/\1/')"
	done < <(open_steers "$1")
}

cmd_pause() {
	[ $# -ge 1 ] || die "usage: pair.sh pause <store> [--reason TEXT]"
	local store="$1" reason="paused by the human"
	shift
	case "${1:-}" in
	--reason) reason="$2" ;;
	"") ;;
	*) die "unknown option $1" ;;
	esac
	pair_file "$store" >/dev/null
	printf '%s\n' "$reason" >"$store/paused"
	event "$store" master pause - "$reason"
	printf 'paused %s: the sidekick stops at its next step or progress boundary, and dispatch, queue, discuss, consult, and answer refuse until pair.sh resume\n' "$store"
}

cmd_resume() {
	[ $# -eq 1 ] || die "usage: pair.sh resume <store>"
	pair_file "$1" >/dev/null
	rm -f "$1/paused"
	event "$1" master resume -
	printf 'resumed %s\n' "$1"
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

# Draft-PR review. The sidekick commits each step of a brief and records it
# with pair.sh step, then goes on without waiting. A wait returns each step
# the master has not reviewed; the master reviews that diff and publishes a
# note: blocking items the sidekick resolves at its next step boundary, and
# follow-ups that go to followups.md instead of widening the unit. The final
# review then reads only the diff since the last note.

# steps/<unit>.tsv, one row per step: k, sha, epoch, notes it resolves, summary.
steps_file() {
	printf '%s/steps/%s.tsv\n' "$1" "$(basename "$2" .md)"
}

# The step a unit's notes have reviewed through: the highest n<k> published.
noted_through() {
	local f k max=0
	for f in "$1"/notes/"$(basename "$2" .md)"-n[0-9]*.md; do
		[ -e "$f" ] || continue
		k="$(basename "$f" .md | sed -E 's/.*-n([0-9]+)$/\1/')"
		[ "$k" -gt "$max" ] && max="$k"
	done
	printf '%s\n' "$max"
}

# The commit a unit's next review starts from: the last noted step, or the
# head the unit was first dispatched at. The running dispatch head is not it:
# next and a re-dispatch after a pause overwrite that.
review_base() {
	local through file unit
	unit="$(basename "$2" .md)"
	through="$(noted_through "$1" "$unit")"
	file="$(steps_file "$1" "$unit")"
	if [ "$through" -gt 0 ] && [ -f "$file" ]; then
		awk -F '\t' -v k="$through" '$1 == k {print $2}' "$file"
	else
		local base tip root
		base="$(jq -r --arg u "$unit" '.heads[$u] // .dispatch.head // empty' "$(pair_file "$1")")"
		root="$(field "$1" '.git_root // .cwd')"
		tip="$( { [ -s "$file" ] && tail -1 "$file" | cut -f2; } || git -C "$root" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
		if [ -n "$base" ] && [ -n "$tip" ]; then
			range_floor "$root" "$base" "$tip"
			base="$range_floor_rev"
		fi
		printf '%s\n' "$base"
	fi
}

# Steps of the running brief past the last note, as "k<TAB>sha<TAB>summary".
# Once the unit reports after its last step, the final review reads those
# steps through review-delta, so none are due: a finished unit never holds a
# wait on steps. A unit resumed after a partial report has steps newer than
# the report, and those are due again.
unreviewed_steps() {
	local brief file through report
	brief="$(field "$1" '.dispatch.brief // empty')"
	[ -n "$brief" ] || return 1
	file="$(steps_file "$1" "$brief")"
	[ -s "$file" ] || return 1
	report="$(expected_report "$1" "$brief")"
	if [ -f "$report" ] && [ "$(file_mtime "$report")" -ge "$(tail -1 "$file" | cut -f3)" ] && report_ready "$1" "$report"; then
		return 1
	fi
	through="$(noted_through "$1" "$brief")"
	awk -F '\t' -v k="$through" '$1 > k {print $1 "\t" $2 "\t" $5}' "$file" | grep . || return 1
}

# True when a step landed that neither a note nor an earlier steps wake has
# covered: once shown, a range does not wake the master again while it reviews.
steps_due() {
	local brief file shown noted last
	unreviewed_steps "$1" >/dev/null || return 1
	brief="$(field "$1" '.dispatch.brief // empty')"
	file="$(steps_file "$1" "$brief")"
	shown="$(jq -r --arg u "$(basename "$brief" .md)" '.shown[$u] // 0' "$1/pair.json")"
	noted="$(noted_through "$1" "$brief")"
	last="$(grep -c . "$file")"
	[ "$last" -gt "$shown" ] && [ "$last" -gt "$noted" ]
}

# Blocking notes on a unit that no step has resolved yet, one path per line.
open_notes() {
	local unit f id file
	unit="$(basename "$2" .md)"
	file="$(steps_file "$1" "$unit")"
	for f in "$1"/notes/"$unit"-n[0-9]*.md; do
		[ -e "$f" ] || continue
		[ "$(header_field "$f" status)" = blocking ] || continue
		id="$(basename "$f" .md | sed -E 's/.*-(n[0-9]+)$/\1/')"
		if [ -f "$file" ] && awk -F '\t' -v id="$id" '{n = split($4, r, ","); for (i = 1; i <= n; i++) if (r[i] == id) found = 1} END {exit !found}' "$file"; then
			continue
		fi
		printf '%s\n' "$f"
	done
}

# Whether a report may be shown to the master as a reply. Sets report_open
# (the open note paths) and report_why (the reason it is withheld). Only a
# done unit report can be withheld: partial, blocked and failed reports, plan
# responses, asks (-q<k>) and objections (-s<k>) are ready as soon as written.
# A done report waits while its own unit has open blocking notes, and, when
# the unit has recorded steps and the report's head resolves to a commit, until
# that head contains the last recorded step, so a step that resolves the last
# note does not expose the report written before it. A unit with no steps, or a
# head that does not resolve (older stores, fixtures), is judged on notes alone.
# It judges the report's own unit, whichever brief is running now.
report_ready() {
	local store="$1" report="$2" base file head root last k
	report_open=""
	report_why=""
	[ "$(header_field "$report" status)" = "done" ] || return 0
	base="$(basename "$report" .md)"
	case "$base" in *-[sq][0-9]*) return 0 ;; esac
	report_open="$(open_notes "$store" "$report")"
	if [ -n "$report_open" ]; then
		report_why="open blocking notes $(printf '%s\n' "$report_open" | sed -E 's/.*-(n[0-9]+)\.md$/\1/' | paste -sd, -)"
		return 1
	fi
	file="$(steps_file "$store" "$base")"
	[ -s "$file" ] || return 0
	head="$(header_field "$report" head | grep -oE '^[0-9a-f]{7,40}' || true)"
	[ -n "$head" ] || return 0
	root="$(field "$store" '.git_root // .cwd')"
	git -C "$root" rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1 || return 0
	k="$(tail -1 "$file" | cut -f1)"
	last="$(tail -1 "$file" | cut -f2)"
	git -C "$root" rev-parse --verify --quiet "$last^{commit}" >/dev/null 2>&1 || return 0
	git -C "$root" merge-base --is-ancestor "$last" "$head" 2>/dev/null && return 0
	report_why="the report's head ${head:0:9} predates step $k ${last:0:9}"
	return 1
}

# The sent unit's report when it is written but withheld: "path<TAB>reason".
withheld_report() {
	local sent unit r
	sent="$(field "$1" '.sent.file // empty')"
	[ -n "$sent" ] || return 1
	unit="$(basename "$sent" .md | sed -E 's/-a[0-9]+$//')"
	r="$1/reports/$unit.md"
	[ -f "$r" ] && [ "$(file_mtime "$r")" -ge "$(field "$1" '.sent.epoch // 0')" ] || return 1
	report_ready "$1" "$r" && return 1
	printf '%s\t%s\n' "$r" "$report_why"
}

# With a report on a unit that has steps: the one diff the final review reads.
review_delta() {
	local store="$1" report="$2" unit file head
	unit="$(basename "$report" .md)"
	file="$(steps_file "$store" "$unit")"
	[ -s "$file" ] || return 0
	head="$(header_field "$report" head | grep -oE '^[0-9a-f]{7,40}' || true)"
	[ -n "$head" ] || head="$(tail -1 "$file" | cut -f2)"
	printf 'review-delta: %s..%s (steps reviewed through %s)\n' "$(review_base "$store" "$unit" | cut -c1-9)" "${head:0:9}" "$(noted_through "$store" "$unit")"
}

finish_wait() {
	# $1 store, $2 herdr exit code, $3 herdr stdout, $4 herdr stderr,
	# $5 "reply" (the report in $6, empty when none landed), "steps" (steps
	# to review, none landed yet), or "any" (the newest report at all)
	local store="$1" code="$2" out="$3" err="$4" mode="$5" report="${6:-}" state
	if [ "$code" -ne 0 ]; then
		state="$(printf '%s' "$err" | jq -r '.error.code // .error // "herdr_error"' 2>/dev/null || printf 'herdr_error')"
		# A wait that ran out its interval is not an error: report the
		# sidekick's state, without herdr's timeout payload.
		if [ "$state" = timeout ]; then
			state="$(agent_status "$(field "$store" .sidekick.name)")"
		else
			printf '%s\n' "$err" >&2
		fi
		printf 'state: %s\n' "$state"
	else
		state="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // "settled"' 2>/dev/null || printf 'settled')"
		printf 'state: %s\n' "$state"
	fi
	paused_reason "$store" >/dev/null && printf 'paused: %s (start nothing new; record the next step in gates.md and end your turn)\n' "$(paused_reason "$store")"
	if [ -n "$report" ] || { [ "$mode" = any ] && report="$(latest_report "$store")"; }; then
		mark_seen "$store" "$report"
		# Only a reply to the message last sent is marked shown; a queued
		# brief's earlier report is not the reply to what runs now.
		if [ "$(basename "$report" | cut -c1-3)" = "$(basename "$(field "$store" '.sent.file // "---"')" | cut -c1-3)" ]; then
			json_update "$store" --arg s "$report:$(file_mtime "$report")" '.sent.seen = $s'
		fi
		printf 'report: %s\n' "$report"
		printf 'report_status: %s\n' "$(header_field "$report" status)"
		event "$store" master wake "$report" "report:$(header_field "$report" status)"
		queue_note "$store" "$report"
		review_delta "$store" "$report"
		[ "$state" = blocked ] && exit 3
		exit 0
	fi
	local running
	running="$(field "$store" '.dispatch.brief // empty')"
	if [ "$mode" = steps ]; then
		local rows first
		rows="$(unreviewed_steps "$store")"
		first="$(printf '%s\n' "$rows" | head -1 | cut -f1)"
		printf 'steps: %s to review on %s\n' "$(printf '%s\n' "$rows" | grep -c .)" "$(basename "$running" .md)"
		printf '%s\n' "$rows" | awk -F '\t' '{printf "  %s %s %s\n", $1, substr($2, 1, 9), $3}'
		printf 'range: %s..%s\n' "$(review_base "$store" "$running" | cut -c1-9)" "$(printf '%s\n' "$rows" | tail -1 | cut -f2 | cut -c1-9)"
		printf 'next: review the range, then pair.sh new-note %s %s\n' "$store" "$(basename "$running" | cut -c1-3)"
		json_update "$store" --arg u "$(basename "$running" .md)" --argjson k "$(printf '%s\n' "$rows" | tail -1 | cut -f1)" '.shown[$u] = $k'
		event "$store" master wake "$running" "steps:$first"
		exit 0
	fi
	local shown withheld="" why=""
	withheld="$(withheld_report "$store" || true)"
	if shown="$(seen_reply "$store")" && [ -z "$withheld" ] && [ "$code" -eq 0 ] && [ "$(agent_status "$(field "$store" .sidekick.name)")" != working ]; then
		printf 'idle: the reply to %s was already shown (%s); send the next message\n' "$(basename "$(field "$store" '.sent.file // "-"')")" "$shown"
		event "$store" master wake "$(field "$store" '.sent.file // "-"')" idle
		exit 4
	fi
	if [ -n "$withheld" ]; then
		printf 'report: %s written but not ready: %s\n' "${withheld%%$'\t'*}" "${withheld#*$'\t'}"
		why=report:unready
	else
		printf 'report: missing\n'
	fi
	case "$state" in
	blocked) event "$store" master wake "$running" "${why:-blocked}"; exit 3 ;;
	esac
	if [ "$(agent_status "$(field "$store" .sidekick.name)")" = working ]; then
		event "$store" master wake "$running" "${why:-checkin}"
		checkin "$store" "$checkin_interval_m"
	else
		event "$store" master wake "$running" "${why:-missing}"
		provider_hint "$store"
	fi
	exit 4
}

provider_error_re='capacity issues|no api providers|no api key found|unauthorized|forbidden|rate.?limit|too many requests|overloaded|fetch failed|econnreset|econnrefused|etimedout|socket hang up'

# The error a pi agent stopped on, from its own session log: $1 the log herdr
# reported, else the newest log in pi's session directory for cwd $2. Printed
# only when the session's last assistant turn ended in an error, so a limit
# pi recovered from is not reported. A pane that is gone still says why.
agent_session_error() {
	local f="$1" dir
	if [ -z "$f" ] || [ ! -f "$f" ]; then
		[ -n "${2:-}" ] || return 0
		dir="$HOME/.pi/agent/sessions/--$(printf '%s' "${2#/}" | tr '/' '-')--"
		f="$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1 || true)"
	fi
	[ -n "$f" ] && [ -f "$f" ] || return 0
	tail -n 200 "$f" | jq -r 'select(.message.role? == "assistant") | [.message.stopReason // "", .message.errorMessage // ""] | @tsv' 2>/dev/null |
		tail -1 | awk -F '\t' '$1 == "error" && $2 != "" {print substr($2, 1, 240)}' || true
}

# A sidekick that settles without a report may have hit its model provider,
# not the task: a capacity or auth error on screen, or an agent that exited.
# Prints the evidence and the way out, failover when a fallback is recorded.
provider_hint() {
	local store="$1" name kind fallback line
	name="$(field "$store" .sidekick.name)"
	kind="$(field "$store" .sidekick.kind)"
	fallback="$(field "$store" '.sidekick.fallback.kind // empty')"
	[ -n "$fallback" ] && [ "$fallback" != "$kind" ] || fallback=""
	local logged=""
	[ "$kind" != pi ] || logged="$(agent_session_error "" "$(field "$store" .cwd)")"
	if [ "$(agent_status "$name")" = absent ]; then
		if [ -n "$logged" ]; then
			printf 'provider_error: the %s sidekick exited on: %s\n' "$kind" "$logged"
		else
			printf 'provider_error: the %s sidekick exited\n' "$kind"
		fi
		[ -z "$fallback" ] || printf 'next: pair.sh failover %s --reason exited\n' "$store"
		return 0
	fi
	line="$(grep -oiE ".{0,60}($provider_error_re).{0,60}" <<<"$(pane_text "$name")" | tail -1 || true)"
	[ -n "$line" ] || line="$logged"
	[ -n "$line" ] || return 0
	printf 'provider_error: %s\n' "$line"
	[ -z "$fallback" ] || printf 'next: prompt the sidekick once to continue; on a second provider error, pair.sh failover %s --reason provider-error\n' "$store"
}

cmd_init() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh init <slug> [--store DIR] [--pane ID]"
	local slug="$1" store="" longest="${roles[${#roles[@]}-1]}" pane_id="${HERDR_PANE_ID:-}"
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--store) store="$2"; shift 2 ;;
		--pane) pane_id="$2"; shift 2 ;;
		*) die "unknown option $1" ;;
		esac
	done
	[[ "$slug" =~ ^[a-z][a-z0-9_-]{0,$slug_max}$ ]] || die "slug must match [a-z][a-z0-9_-]{0,$slug_max} (so <slug>-$longest fits Herdr's 32-char name limit)"
	[ -n "$store" ] || store="$state_root/$slug"
	[ -n "$pane_id" ] || die "HERDR_PANE_ID is unset; run from a Herdr-managed pane, or pass --pane ID"
	local d
	for d in "${store_dirs[@]}"; do mkdir -p "$store/$d"; done
	local master="$slug-master" now cwd git_root
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	cwd="$PWD"
	git_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
	# HERDR_PANE_ID can be stale: Codex runs every session's commands through
	# one shared app-server daemon, which keeps the pane it was started in.
	herdr agent rename "$pane_id" "$master" >/dev/null 2>&1 ||
		die "pane $pane_id is not a live Herdr pane; HERDR_PANE_ID is stale when a harness runs commands through a shared daemon (Codex's app-server). Pass your pane with --pane ID (herdr agent list shows each agent's pane)" 2
	if [ -f "$store/pair.json" ]; then
		json_update "$store" --arg pane "$pane_id" --arg ws "${HERDR_WORKSPACE_ID:-}" --arg tab "${HERDR_TAB_ID:-}" --arg now "$now" \
			'.master.pane_id = $pane | .master.workspace_id = $ws | .master.tab_id = $tab | .master.registered_at = $now'
		printf 'store: %s (re-registered master %s in %s)\n' "$store" "$master" "$pane_id"
	else
		jq -n --arg slug "$slug" --arg store "$store" --arg now "$now" --arg cwd "$cwd" --arg git_root "$git_root" \
			--arg master "$master" --arg pane "$pane_id" \
			--arg ws "${HERDR_WORKSPACE_ID:-}" --arg tab "${HERDR_TAB_ID:-}" --args \
			'{slug: $slug, store: $store, created_at: $now, cwd: $cwd, git_root: $git_root,
			  master: {name: $master, pane_id: $pane, workspace_id: $ws, tab_id: $tab, registered_at: $now}}
			 | reduce $ARGS.positional[] as $r (.; .[$r] = {name: "\($slug)-\($r)", pane_id: null, kind: null, started_at: null})
			 | if has("consultant") then .scratch = [] else . end' \
			"${roles[@]}" >"$store/pair.json"
		printf 'store: %s (master %s in %s)\n' "$store" "$master" "$pane_id"
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

# pi asks before no tool call, so it needs no permission arguments; it cannot
# run read-only, so plan stays untranslated for it.
asks_no_approvals() {
	[ "$1" = pi ] && [ "$2" != plan ]
}

# Native arguments that skip the kind's prompt to trust the working folder.
# The prompt appears in any folder the agent has not seen (pi: any repo with
# .agents/skills), would hang an unattended agent, and eats the bootstrap's
# Enter. The master already works in that folder.
trust_args() {
	case "$1" in
	pi) printf -- '--approve\n' ;;
	devin) printf -- '--respect-workspace-trust\nfalse\n' ;;
	esac
}

# True when the native arguments already decide folder trust.
has_trust_arg() {
	local arg
	for arg in "$@"; do
		case "$arg" in
		--approve | --no-approve | -na | --respect-workspace-trust | --respect-workspace-trust=*) return 0 ;;
		esac
	done
	return 1
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

# A dialog asking to trust the working folder (Claude, Codex) blocks an
# agent at startup. Trusting a repo is the human's decision, never the
# script's: decline it, which returns the pane to its shell, and stop with
# what to do. Claude's dialog defaults to "No, exit", so an Enter would quit.
trust_re='trust this folder|project you created or one you trust|do you trust the (files|contents)'
refuse_untrusted() {
	local pane="$1" kind="$2" dir="$3"
	grep -qiE "$trust_re" <<<"$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null | tr -s '\n\t ' ' ')" || return 0
	herdr pane send-keys "$pane" esc >/dev/null 2>&1 || true
	die "$kind asks whether to trust $dir, and that decision is yours: open $kind there once and trust the folder (or pick another kind), then rerun the spawn" 5
}

# A new pane for a role: a split beside the anchor, or, with placement tab
# (spawn --tab, or PSTACK_PLACEMENT=tab), a tab of its own in the master's
# workspace, labelled with the role. Sets new_pane_id. $1 store, $2 role,
# $3 anchor, $4 direction (empty picks one), $5 cwd.
new_pane() {
	local store="$1" role="$2" anchor="$3" direction="$4" cwd="$5" master
	if [ "$(field "$store" '.placement // empty')" = tab ]; then
		master="$(field "$store" .master.pane_id)"
		new_pane_id="$(herdr tab create --workspace "${master%%:*}" --cwd "$cwd" --label "$(field "$store" .slug)-$role" --no-focus |
			jq -r '.result.root_pane.pane_id')"
		[ -n "$new_pane_id" ] && [ "$new_pane_id" != null ] || die "tab create returned no pane id" 2
		printf 'tab %s-%s -> %s\n' "$(field "$store" .slug)" "$role" "$new_pane_id"
	else
		[ -n "$direction" ] || direction="$(pick_direction "$anchor")"
		new_pane_id="$(herdr pane split --pane "$anchor" --direction "$direction" --cwd "$cwd" --no-focus | jq -r '.result.pane.pane_id')"
		[ -n "$new_pane_id" ] && [ "$new_pane_id" != null ] || die "pane split returned no pane id" 2
		printf 'split %s %s -> %s\n' "$anchor" "$direction" "$new_pane_id"
	fi
}

# Records how roles get their panes: --tab or --split from spawn, else what
# the store already has, else PSTACK_PLACEMENT, else split.
set_placement() {
	local store="$1" want="${2:-}"
	[ -n "$want" ] || [ -n "$(field "$store" '.placement // empty')" ] || want="${PSTACK_PLACEMENT:-split}"
	[ -n "$want" ] || return 0
	case "$want" in split | tab) ;; *) die "placement must be split or tab, not $want" ;; esac
	json_update "$store" --arg p "$want" '.placement = $p'
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
	if [ -z "$permission" ]; then
		case "$kind" in
		devin) permission=bypassPermissions ;;
		*) permission="$master_mode" ;;
		esac
	fi
	local -a agent_args=()
	if [ "$permission" = none ] || has_permission_arg "$@"; then
		permission="native-args"
	else
		mapfile -t agent_args < <(permission_args "$kind" "$permission")
		if [ "${#agent_args[@]}" -eq 0 ] && ! asks_no_approvals "$kind" "$permission"; then
			printf 'no permission translation for kind %s; pass native flags after -- to match the master (%s)\n' "$kind" "$master_mode" >&2
			permission="untranslated"
		fi
	fi
	has_trust_arg "$@" || mapfile -t -O "${#agent_args[@]}" agent_args < <(trust_args "$kind")
	set -- "${agent_args[@]}" "$@"
	if fresh_per_brief "$kind"; then
		local arg
		for arg in "$@"; do
			case "$arg" in -c | --continue | -r | --resume | --resume=* | --session | --session=* | --session-id | --fork)
				die "$kind task sessions start fresh; recover partial work from the store instead of passing $arg" 5 ;;
			esac
		done
	fi
	local name cwd status ready
	case "$role" in
	consultant) ready="advice/000-ready.md" ;;
	*) ready="reports/000-ready.md" ;;
	esac
	name="$(field "$store" ".$role.name")"
	cwd="$(field "$store" .cwd)"
	status="$(agent_status "$name")"
	if [ "$status" != absent ]; then
		if [ "$(field "$store" ".$role.bootstrap_pending // false")" = true ]; then
			[ -f "$store/$ready" ] || { printf '%s bootstrap still pending: %s is missing\n' "$role" "$ready" >&2; return 4; }
			json_update "$store" --arg role "$role" '.[$role].rotation_required = false | .[$role].bootstrap_pending = false'
			printf 'ready: %s\n' "$store/$ready"
			event "$store" "$role" spawn - "$(field "$store" ".$role.kind"):ready"
		fi
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
			refuse_untrusted "$pane" "$kind" "$cwd"
			printf 'pane %s unavailable for agent start: %s\n' "$pane" "$started" >&2
			pane=""
		fi
	fi
	if [ -z "$pane" ]; then
		new_pane "$store" "$role" "$anchor" "$direction" "$cwd"
		pane="$new_pane_id"
		herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout "$timeout" -- "$@" >/dev/null ||
			{ refuse_untrusted "$pane" "$kind" "$cwd"; die "agent start failed in $pane; inspect: herdr pane read $pane --source visible" 2; }
	fi
	local now
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local args_json
	args_json="$(jq -cn --args '$ARGS.positional' -- "$@")"
	json_update "$store" --arg role "$role" --arg pane "$pane" --arg kind "$kind" --arg now "$now" --arg perm "$permission" --arg mperm "$master_mode" \
		--argjson args "$args_json" \
		'.[$role].pane_id = $pane | .[$role].kind = $kind | .[$role].started_at = $now
		 | .[$role].start_args = $args | .[$role].generation = ((.[$role].generation // 0) + 1)
		 | .[$role].bootstrap_pending = true
		 | .[$role].permission_mode = $perm | .master.permission_mode = $mperm'
	printf '%s %s (%s) started in %s with permission %s (master: %s)\n' "$role" "$name" "$kind" "$pane" "$permission" "$master_mode"
	local bootstrap
	if [ -f "$store/$ready" ]; then
		mkdir -p "$store/sessions"
		mv "$store/$ready" "$store/sessions/$role-$(field "$store" ".$role.generation")-previous-ready.md"
	fi
	bootstrap="Load the $PAIR_SKILL skill from ~/.agents/skills/$PAIR_SKILL/SKILL.md and take the $role role (generation $(field "$store" ".$role.generation"), pane $pane). $store_label store: $store. Follow its bootstrap steps, write $ready, and reply READY."
	local out err code=0 errfile
	errfile="$(mktemp)"
	out="$(herdr agent prompt "$name" "$bootstrap" --wait --timeout 240000 2>"$errfile")" || code=$?
	err="$(cat "$errfile")"
	rm -f "$errfile"
	if [ ! -f "$store/$ready" ]; then
		submit_typed "$name" "$(basename "$ready")"
		[ "$submitted" -eq 0 ] || [ "$code" -ne 0 ] || await_file "$store/$ready" 240000 || true
	fi
	if [ "$code" -ne 0 ] && grep -q agent_prompt_stalled <<<"$err"; then
		# A first-run screen (pi's changelog after an update, a trust prompt)
		# can take the Enter that submits the bootstrap, leaving it typed in
		# the input of an idle agent: one more Enter submits it, and an empty
		# input ignores it. Otherwise state detection lagged on a narrow pane
		# while the agent works. Either way the ready file is the real signal.
		if [ "$(agent_status "$name")" != working ]; then
			herdr agent send-keys "$name" enter >/dev/null 2>&1 || true
		fi
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
		json_update "$store" --arg role "$role" '.[$role].rotation_required = false | .[$role].bootstrap_pending = false'
		printf 'ready: %s\n' "$store/$ready"
		event "$store" "$role" spawn - "$kind:ready"
	else
		printf '%s settled but %s is missing; state=%s. Read the pane before prompting again.\n' "$role" "$ready" "$(agent_status "$name")" >&2
		return 4
	fi
}

# Kinds whose sidekick starts a fresh conversation for each completed brief:
# Devin, and pi, whose one compacted conversation would otherwise carry every
# earlier brief into the next. The master rotates them; the queue waits.
fresh_per_brief() {
	case "$1" in devin | pi) return 0 ;; esac
	return 1
}

require_fresh_session() {
	local kind
	kind="$(field "$1" '.sidekick.kind')"
	if fresh_per_brief "$kind" && [ "$(field "$1" '(.sidekick.rotation_required // false) or (.sidekick.bootstrap_pending // false)')" = true ]; then
		die "the $kind sidekick needs a fresh session or a successful bootstrap before another task; inspect READY and run pair.sh rotate $1 after a completed task. The queue is preserved." 5
	fi
}

preflight_timeout_s="${PAIR_PREFLIGHT_TIMEOUT:-90}"

has_preflight() {
	[ "$1" = pi ]
}

# Proves a kind's model answers before a pane starts. pi reaches some models
# through community provider packages that can break or run out of capacity,
# so it gets one print-mode prompt, without the repo's resources. Other kinds
# have no check here. $1 kind, rest: the native args the agent starts with.
# Prints the last lines of a failure on stderr.
preflight_kind() {
	local kind="$1" out arg
	shift
	has_preflight "$kind" || return 0
	local -a args=()
	for arg in "$@"; do
		case "$arg" in --approve | -a | --no-approve | -na) ;; *) args+=("$arg") ;; esac
	done
	# A provider can fail one request and answer the next, so a failure is
	# retried once before it counts.
	local attempt rc=0
	for attempt in 1 2; do
		rc=0
		out="$(timeout "$preflight_timeout_s" pi --no-session --no-approve --no-context-files --no-skills -p "${args[@]}" 'Reply with exactly: OK' 2>&1)" || rc=$?
		[ "$rc" -eq 0 ] && grep -q OK <<<"$out" && return 0
		[ "$attempt" -eq 2 ] || sleep "${PAIR_PREFLIGHT_RETRY_S:-3}"
	done
	# The master's PATH can hold an older pi than the pane's, so name it.
	printf 'pi %s at %s, twice: ' "$(pi --version 2>/dev/null || printf '?')" "$(command -v pi)" >&2
	case "$rc" in
	124) printf 'timed out after %ss ' "$preflight_timeout_s" >&2 ;;
	0) printf 'answered without OK ' >&2 ;;
	*) printf 'exit %s ' "$rc" >&2 ;;
	esac
	printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ' ' >&2
	[ -n "$(tr -d '[:space:]' <<<"$out")" ] || printf '(no output)' >&2
	return 1
}

record_failover() {
	# $1 store, $2 from kind, $3 to kind, $4 reason
	json_update "$1" --arg from "$2" --arg to "$3" --arg why "$4" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'.sidekick.failovers = ((.sidekick.failovers // []) + [{from: $from, to: $to, reason: $why, at: $now}])'
	event "$1" master failover - "$2:$3"
	printf 'failover: %s -> %s (%s)\n' "$2" "$3" "$4"
}

# Starts the sidekick, or its recorded fallback when the kind's preflight
# fails. The fallback starts with its own recorded arguments and its kind's
# default permission. A live sidekick skips the preflight. Arguments as
# spawn_role, without the role.
spawn_sidekick() {
	local store="$1" kind="$2" permission="$3" anchor="$4" timeout="$5" direction="$6" pane="$7" reason fallback
	shift 7
	if has_preflight "$kind" && [ "$(agent_status "$(field "$store" .sidekick.name)")" = absent ]; then
		if ! reason="$(preflight_kind "$kind" "$@" 2>&1)"; then
			reason="preflight: ${reason:-no answer}"
			printf '%s failed %s\n' "$kind" "$reason" >&2
			fallback="$(field "$store" '.sidekick.fallback.kind // empty')"
			[ -n "$fallback" ] && [ "$fallback" != "$kind" ] || die "no fallback recorded for a failed $kind; pass --fallback KIND or fix the agent" 2
			record_failover "$store" "$kind" "$fallback" "$reason"
			local -a args=()
			mapfile -t args < <(jq -r '.sidekick.fallback.args[]?' "$store/pair.json")
			spawn_role "$store" sidekick "$fallback" "" "$anchor" "$timeout" "$direction" "$pane" "${args[@]}"
			return
		fi
	fi
	spawn_role "$store" sidekick "$kind" "$permission" "$anchor" "$timeout" "$direction" "$pane" "$@"
}

# Records the sidekick's fallback from the spawn options: $1 store, $2 kind
# (empty keeps any recorded one), rest: its native arguments.
record_fallback() {
	local store="$1" kind="$2"
	shift 2
	[ -n "$kind" ] || return 0
	json_update "$store" --arg kind "$kind" --argjson args "$(jq -cn --args '$ARGS.positional' -- "$@")" \
		'.sidekick.fallback = {kind: $kind, args: $args}'
}

exit_command() {
	case "$1" in
	pi | codex) printf '/quit\n' ;;
	*) printf '/exit\n' ;;
	esac
}

# Replaces a failing sidekick with its recorded fallback in the same pane.
# The new agent picks up from the store: the step log, progress, and the
# brief it was on; every committed step survives. A run stays on the
# fallback, since failover never switches back.
cmd_failover() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh failover <store> [--reason TEXT] [--force]"
	local store="$1" reason=requested force=0
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--reason) reason="$2"; shift 2 ;;
		--force) force=1; shift ;;
		*) die "unknown option $1" ;;
		esac
	done
	pair_file "$store" >/dev/null
	local kind fallback name status deadline rc=0
	kind="$(field "$store" .sidekick.kind)"
	fallback="$(field "$store" '.sidekick.fallback.kind // empty')"
	[ -n "$fallback" ] || die "no fallback recorded; spawn the sidekick with --fallback KIND" 5
	[ "$kind" != "$fallback" ] || die "the sidekick already runs the fallback ($fallback)" 5
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	if [ "$status" = working ]; then
		[ "$force" -eq 1 ] || die "sidekick $name is working; pair.sh stop $store first, or pass --force to interrupt it" 5
		herdr agent send-keys "$name" esc >/dev/null 2>&1 || true
		sleep 2
	fi
	if [ "$status" != absent ]; then
		herdr agent prompt "$name" "$(exit_command "$kind")" >/dev/null 2>&1 || true
		deadline=$(($(date +%s) + 15))
		while [ "$(agent_status "$name")" != absent ]; do
			[ "$(date +%s)" -lt "$deadline" ] || die "$kind sidekick has not exited; close it by hand, then rerun failover" 5
			sleep 1
		done
	fi
	record_failover "$store" "$kind" "$fallback" "$reason"
	local -a args=()
	mapfile -t args < <(jq -r '.sidekick.fallback.args[]?' "$store/pair.json")
	spawn_role "$store" sidekick "$fallback" "" "$(field "$store" .master.pane_id)" 60000 "" "$(field "$store" .sidekick.pane_id)" "${args[@]}" || rc=$?
	local running
	running="$(field "$store" '.dispatch.brief // empty')"
	if [ "$rc" -eq 0 ] && [ -n "$running" ] && [ ! -f "$(expected_report "$store" "$running")" ]; then
		printf 'next: re-dispatch %s with "resumed after failover from %s" in its Context\n' "$running" "$kind"
	fi
	exit "$rc"
}

# Rotation exits the idle sidekick and reuses its pane with the same native
# arguments. It preserves the store and never deletes a Devin session.
cmd_rotate() {
	in_herdr
	[ $# -eq 1 ] || die "usage: pair.sh rotate <store>"
	local store="$1" name status err code=0 deadline
	pair_file "$store" >/dev/null
	require_not_paused "$store"
	local kind
	kind="$(field "$store" '.sidekick.kind')"
	fresh_per_brief "$kind" || die "rotate is for a sidekick that starts fresh per brief (devin, pi), not $kind" 5
	[ "$(field "$store" '.sidekick.rotation_required // false')" = true ] || die "rotation requires a completed task; partial or blocked work keeps its session" 5
	jq -e '.sidekick.start_args | type == "array"' "$store/pair.json" >/dev/null || die "no recorded startup arguments; exit the idle sidekick and spawn it with its original model and permission flags" 5
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	idle | "done")
		err="$(herdr agent prompt "$name" "$(exit_command "$kind")" 2>&1)" || code=$?
		if [ "$code" -ne 0 ] && ! grep -qE 'agent_prompt_stalled|agent_not_found|not_found' <<<"$err"; then
			die "$kind exit failed: $err" 2
		fi
		deadline=$(($(date +%s) + 15))
		while [ "$(agent_status "$name")" != absent ]; do
			[ "$(date +%s)" -lt "$deadline" ] || die "$kind has not exited; inspect $name before retrying rotate" 5
			sleep 1
		done
		;;
	absent) ;;
	*) die "sidekick $name is $status; wait for its report and turn to end before rotating" 5 ;;
	esac
	local -a args
	mapfile -t args < <(jq -r '.sidekick.start_args[]' "$store/pair.json")
	event "$store" master rotate - "generation:$(field "$store" .sidekick.generation)"
	spawn_role "$store" sidekick "$kind" none "$(field "$store" .master.pane_id)" 60000 "" "$(field "$store" .sidekick.pane_id)" "${args[@]}"
}

cmd_spawn() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh spawn <store> --kind KIND [--fallback KIND [--fallback-arg ARG]...] [--direction right|down] [--pane ID] [--timeout MS] [-- agent-args...]"
	local store="$1" kind="" direction="" pane="" timeout=60000 permission="" fallback="" placement=""
	local -a fallback_args=()
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--kind) kind="$2"; shift 2 ;;
		--fallback) fallback="$2"; shift 2 ;;
		--fallback-arg) fallback_args+=("$2"); shift 2 ;;
		--tab) placement="tab"; shift ;;
		--split) placement="split"; shift ;;
		--permission) permission="$2"; shift 2 ;;
		--direction) direction="$2"; shift 2 ;;
		--pane) pane="$2"; shift 2 ;;
		--timeout) timeout="$2"; shift 2 ;;
		--) shift; break ;;
		*) die "unknown option $1" ;;
		esac
	done
	[ -n "$kind" ] || die "--kind is required (run: herdr agent, for the kind list)"
	pair_file "$store" >/dev/null
	set_placement "$store" "$placement"
	record_fallback "$store" "$fallback" "${fallback_args[@]}"
	local rc=0
	spawn_sidekick "$store" "$kind" "$permission" "$(field "$store" .master.pane_id)" "$timeout" "$direction" "$pane" "$@" || rc=$?
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
	[ "$kind" != BRIEF ] || check_scope "$file" "$(field "$store" '.git_root // .cwd')"
	require_fresh_session "$store"
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	idle | done) ;;
	absent) die "sidekick $name is not live; run: pair.sh spawn $store --kind <kind>" 2 ;;
	blocked) die "sidekick $name is blocked; inspect: herdr agent read $name --source visible --lines 60" 3 ;;
	*) die "sidekick $name is $status; run: pair.sh wait $store" 5 ;;
	esac
	# Delivery is not interruptible: a dispatch wrapped in a short timeout was
	# killed after recording a brief and before sending it, and the store
	# waited on a sidekick that never got it. TERM, INT and HUP wait until the
	# message is in; the wait that follows may be cut short safely.
	trap '' TERM INT HUP
	if [ "$kind" = BRIEF ]; then
		[ "$(queued_brief "$store")" = "$file" ] && rm -f "$store/queue"
		prune_pending "$store"
		record_dispatch "$store" "$file"
	else
		record_sent "$store" "$file" "$kind"
	fi
	event "$store" master "send-${kind,,}" "$file"
	prompt_sidekick "$name" "$PAIR_SKILL $kind $file"
	trap - TERM INT HUP
	if [ "${send_only:-0}" = 1 ]; then
		printf 'sent: %s %s; follow it with the wait command\n' "$kind" "$file"
		exit 0
	fi
	local ready
	wait_for_reply "$store" "$name" "$timeout"
	finish_wait "$store" "$code" "$out" "$err" "$(reply_mode)" "$ready"
}

# Parse the options every waiting command shares; sets $timeout and the
# check-in interval, and leaves any other flag in $rest for the caller.
wait_opts() {
	rest=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--timeout) timeout="$2"; shift 2 ;;
		--every) timeout=$(($2 * 60000)); shift 2 ;;
		--send-only) send_only=1; shift ;;
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
	require_not_paused "$store"
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
	require_not_paused "$store"
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
	steps_due=0
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
		if steps_due "$store"; then
			steps_due=1
			code=0
			out="$(herdr agent get "$name" 2>/dev/null || true)"
			: >"$errfile"
			break
		fi
		slice=$(( (deadline - $(date +%s)) * 1000 ))
		[ "$slice" -le 30000 ] || slice=30000
		[ "$slice" -ge 1000 ] || slice=1000
		code=0
		out="$(herdr agent wait "$name" --timeout "$slice" 2>"$errfile")" || code=$?
		if [ "$code" -eq 0 ]; then
			state="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)"
			[ "$state" != blocked ] || break
			{ pending_report "$store" >/dev/null || fresh_reply "$store" >/dev/null || steps_due "$store"; } && continue
			if ! pane_busy "$name" && seen_reply "$store" >/dev/null; then
				# Idle, and its reply to the last message was already shown:
				# nothing is coming until the master sends the next one.
				break
			fi
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

reply_mode() {
	if [ -z "$ready" ] && [ "${steps_due:-0}" = 1 ]; then printf 'steps\n'; else printf 'reply\n'; fi
}

# Herdr can report a fresh agent working while a prompt still sits typed in
# its input (a new Claude pane; pi after an update), so the pane is read too:
# while its last lines still show the message's marker, Enter submits it, up
# to three times. An Enter on an empty input does nothing; a working Devin is
# left alone, since there Enter cancels the running command. $1 agent name,
# $2 marker (a word of the message with no spaces, such as a file's name).
# Sets submitted to the number of Enters it sent.
submit_typed() {
	local name="$1" marker="$2" kind tries=0
	submitted=0
	kind="$(agent_kind "$name")"
	while [ "$tries" -lt 3 ]; do
		sleep "${PAIR_SUBMIT_CHECK_S:-5}"
		grep -qF "$marker" <<<"$(herdr agent read "$name" --source visible --lines 12 2>/dev/null | tr -d '\n │')" || return 0
		[ "$kind" != devin ] || [ "$(agent_status "$name")" != working ] || return 0
		herdr agent send-keys "$name" enter >/dev/null 2>&1 || true
		tries=$((tries + 1))
		submitted="$tries"
	done
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
	submit_typed "$name" "$(basename "${text##* }")"
}

cmd_wait() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh wait <store> [--timeout MS | --every MIN]"
	local store="$1" timeout=540000 rest code out err ready
	shift
	wait_opts "$@"
	no_extra_opts
	wait_for_reply "$store" "$(field "$store" .sidekick.name)" "$timeout"
	finish_wait "$store" "$code" "$out" "$err" "$(reply_mode)" "$ready"
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
	require_not_paused "$store"
	require_filled "$brief"
	check_scope "$brief" "$(field "$store" '.git_root // .cwd')"
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

# The sidekick records a committed step and goes straight on; the master's
# wait picks it up for review. --resolves names the notes the step fixes.
cmd_step() {
	[ $# -ge 3 ] || die "usage: pair.sh step <store> <sha> <summary> [--resolves n1,n2]"
	local store="$1" sha="$2" summary="$3" resolves="" brief file full k
	shift 3
	case "${1:-}" in
	--resolves) resolves="$2" ;;
	"") ;;
	*) die "unknown option $1" ;;
	esac
	[[ "$resolves" =~ ^(n[0-9]+(,n[0-9]+)*)?$ ]] || die "--resolves takes note ids like n2,n3"
	pair_file "$store" >/dev/null
	brief="$(field "$store" '.dispatch.brief // empty')"
	[ -n "$brief" ] || die "no brief dispatched; a step belongs to a running brief"
	full="$(git -C "$(field "$store" .cwd)" rev-parse --verify --quiet "$sha^{commit}")" || die "not a commit: $sha; commit the step first"
	local id
	for id in ${resolves//,/ }; do
		[ -f "$store/notes/$(basename "$brief" .md)-$id.md" ] || die "--resolves $id: no published note $id on $(basename "$brief" .md); resolve only notes pair.sh notes printed"
	done
	mkdir -p "$store/steps" "$store/progress"
	file="$(steps_file "$store" "$brief")"
	k=1
	[ -f "$file" ] && k=$(( $(grep -c . "$file") + 1 ))
	printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$full" "$(date +%s)" "$resolves" "$(printf '%s' "$summary" | tr '\t\n' '  ')" >>"$file"
	printf '%s step %s %s: %s\n' "$(date +%H:%M)" "$k" "${full:0:9}" "$summary" >>"$(progress_path "$store")"
	event "$store" sidekick step "$brief" "$k:${full:0:9}"
	if paused_reason "$store" >/dev/null; then
		printf 'step %s recorded at %s.\n' "$k" "${full:0:9}"
		pause_notice "$store"
	else
		printf 'step %s recorded at %s; go on with the next step. At the next step boundary: pair.sh notes %s\n' "$k" "${full:0:9}" "$store"
	fi
	steer_notice "$store"
}

# The master's review of a unit's steps: a draft note covering the steps since
# the last note, through the last step a wait showed (or --through k), so a
# step that lands while the master reviews is left for the next note.
# Published with pair.sh note once filled.
cmd_new_note() {
	[ $# -ge 2 ] || die "usage: pair.sh new-note <store> <NNN> [--through K]"
	local store="$1" seq="$2" brief unit file k base to path through=""
	shift 2
	case "${1:-}" in
	--through) through="$2" ;;
	"") ;;
	*) die "unknown option $1" ;;
	esac
	pair_file "$store" >/dev/null
	brief="$(ls "$store"/briefs/"$seq"-*.md 2>/dev/null | head -1 || true)"
	[ -n "$brief" ] || die "no brief for unit $seq"
	unit="$(basename "$brief" .md)"
	file="$(steps_file "$store" "$unit")"
	[ -s "$file" ] || die "unit $seq has no steps recorded"
	if [ -z "$through" ]; then
		# The last range a wait showed, unless the notes already cover it:
		# steps recorded without a wake then default to the latest.
		through="$(jq -r --arg u "$unit" '.shown[$u] // empty' "$store/pair.json")"
		[ -n "$through" ] && [ "$through" -gt "$(noted_through "$store" "$unit")" ] || through=""
	fi
	k="${through:-$(grep -c . "$file")}"
	[[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -le "$(grep -c . "$file")" ] || die "unit $seq has no step $k"
	[ "$k" -gt "$(noted_through "$store" "$unit")" ] || die "unit $seq is reviewed through step $k already; wait for the next steps"
	base="$(review_base "$store" "$unit")"
	to="$(awk -F '\t' -v k="$k" '$1 == k {print $2}' "$file")"
	mkdir -p "$store/notes"
	path="$store/notes/$unit-n$k.md.draft"
	sed -e "s|{{UNIT}}|$unit|g" -e "s|{{K}}|$k|g" -e "s|{{RANGE}}|${base:0:9}..${to:0:9}|g" \
		"$skill_root/references/note-template.md" >"$path"
	printf '%s\n' "$path"
}

# Publishes a filled note: the sidekick sees it at its next step boundary,
# and its follow-ups go to followups.md rather than into the unit.
cmd_note() {
	[ $# -eq 2 ] || die "usage: pair.sh note <store> <note-draft-path>"
	local store="$1" draft="$2" path status k unit
	[ -f "$draft" ] || die "note not found: $draft"
	case "$draft" in *.md.draft) ;; *) die "publish the .md.draft file new-note printed" ;; esac
	require_filled "$draft"
	status="$(header_field "$draft" status)"
	case "$status" in
	blocking | clear) ;;
	*) die "$draft needs status: blocking or clear" ;;
	esac
	path="${draft%.draft}"
	mv "$draft" "$path"
	unit="$(basename "$path" .md | sed -E 's/-n[0-9]+$//')"
	k="$(basename "$path" .md | sed -E 's/.*-n([0-9]+)$/\1/')"
	awk -v tag="$unit n$k" '/^## Follow-ups/{f=1;next} /^## /{f=0} f && /^- / && !/^- none$/ {sub(/^- /, ""); print "- [" tag "] " $0}' "$path" >>"$store/followups.md"
	event "$store" master note "$unit" "$k:$status"
	printf 'published %s (%s)\n' "$path" "$status"
}

# The sidekick's check at each step boundary: blocking notes still open on
# the running brief, printed in full so they can be fixed without another read.
cmd_notes() {
	[ $# -eq 1 ] || die "usage: pair.sh notes <store>"
	local store="$1" brief open f
	pair_file "$store" >/dev/null
	brief="$(field "$store" '.dispatch.brief // empty')"
	[ -n "$brief" ] || { printf 'notes: none open\n'; return 0; }
	pause_notice "$store"
	steer_notice "$store"
	open="$(open_notes "$store" "$brief")"
	if [ -z "$open" ]; then
		printf 'notes: none open; go on with the next step\n'
		return 0
	fi
	printf 'notes: %s open. Fix each Blocking item as a fixup commit before the next step, then record it: pair.sh step %s <sha> "<summary>" --resolves <n-ids>\n' "$(printf '%s\n' "$open" | grep -c .)" "$store"
	while IFS= read -r f; do
		printf '\n=== %s (%s)\n' "$(basename "$f" .md | sed -E 's/.*-(n[0-9]+)$/\1/')" "$f"
		awk '/^## Blocking/{p=1;next} /^## /{p=0} p' "$f"
	done <<<"$open"
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
	! fresh_per_brief "$(field "$1" .sidekick.kind)" || die "a $(field "$1" .sidekick.kind) sidekick leaves the queue for the master to dispatch after a fresh session" 5
	require_fresh_session "$1"
	if paused_reason "$1" >/dev/null; then
		printf 'queue: paused\n'
		exit 4
	fi
	brief="$(take_queued "$1")" || { printf 'queue: empty\n'; exit 4; }
	printf '%s BRIEF %s\n' "$PAIR_SKILL" "$brief"
}

# The one command a sidekick runs after writing any report: tells the master,
# then says what to do next. Devin ends the turn for master-owned rotation;
# other kinds may take a queued brief after a done report.
cmd_finish() {
	in_herdr
	[ $# -eq 2 ] || die "usage: pair.sh finish <store> <report-path>"
	local store="$1" report status brief
	report="$(readlink -f "$2")"
	[ -f "$report" ] || die "report not found: $report; write it first"
	status="$(header_field "$report" status)"
	# A done report the master cannot verify costs a whole brief to repair,
	# so its header is checked while the sidekick is still in this turn.
	if [ "$status" = done ] && [ "$report" = "$(expected_report "$store" "$(field "$store" '.dispatch.brief // "-"')")" ]; then
		case "$(header_field "$report" head)" in
		"" | "<"*) die "$(basename "$report"): a done report needs the report template's header, with head: <the unit's commit> (HEAD when the brief says commit: no); add it and run finish again" 1 ;;
		esac
	fi
	if [ "$status" = done ]; then
		report_ready "$store" "$report" || {
			[ -z "$report_open" ] || die "blocking review notes are still open on $(basename "$report" .md):
$report_open
Resolve each as a fixup commit, record it with pair.sh step $store <sha> <summary> --resolves <n-ids>, then finish again" 7
			die "$(basename "$report" .md): $report_why; rewrite the report at the unit's last commit (head:), then finish again" 7
		}
	fi
	local current
	current="$(field "$store" '.dispatch.brief // empty')"
	if [ "$status" = "done" ] && fresh_per_brief "$(field "$store" .sidekick.kind)" && [ -n "$current" ] && [ "$report" = "$(expected_report "$store" "$current")" ] && \
		[ "$(field "$store" '.dispatch.generation // 0')" = "$(field "$store" '.sidekick.generation // 0')" ]; then
		if [ "$(field "$store" '.sidekick.rotation_required // false')" != true ]; then
			json_update "$store" '.sidekick.rotation_required = true'
			event "$store" sidekick rotation-required "$report" "generation:$(field "$store" '.sidekick.generation // 0')"
		fi
	fi
	cmd_notify "$store" "$report"
	local late
	while IFS= read -r late; do
		[ -n "$late" ] || continue
		printf 'late steer: %s arrived after this report; record pair.sh progress %s "steer s%s late: reported" and the master folds it into the next brief\n' \
			"$late" "$store" "$(basename "$late" .md | sed -E 's/.*-s([0-9]+)$/\1/')"
	done < <(open_steers "$store")
	if [ "$status" = "done" ] && fresh_per_brief "$(field "$store" .sidekick.kind)"; then
		if [ "$(field "$store" '.sidekick.rotation_required // false')" = true ]; then
			printf 'rotation: required before the next task; leave the queue for the master to dispatch after pair.sh rotate %s\n' "$store"
		fi
		printf 'next: end the turn with the single line: %s REPORT %s\n' "$PAIR_SKILL" "$report"
		return 0
	fi
	if [ "$status" = done ] && ! paused_reason "$store" >/dev/null && brief="$(take_queued "$store")"; then
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

# The stop-like reports (or advice) of role $2 on disk, as "path:mtime" lines.
stop_candidates() {
	local dir f
	case "$2" in consultant) dir=advice ;; *) dir=reports ;; esac
	for f in "$1/$dir"/[0-9][0-9][0-9]-*.md; do
		[ -f "$f" ] || continue
		case "$(basename "$f")" in
		[0-9][0-9][0-9]-stop.md) ;;
		*) grep -q 'STOP' <<<"$(head -1 "$f")" || grep -qi stop <<<"$(header_field "$f" status)" || continue ;;
		esac
		printf '%s:%s\n' "$f" "$(file_mtime "$f")"
	done
}

# True when role $2 wrote a stop report or advice since the snapshot $3 that
# stop_candidates took before the send. The role docs name it NNN-stop.md,
# but Devin also writes NNN-<slug>-stop.md or NNN-<slug>-partial1.md, so any
# report counts when its heading says STOP in capitals ("partial (STOP)") or
# its status mentions a stop ("stopped-partial"); a slug that merely contains
# "stop" ("bus-stop") does not. Comparing against the snapshot, not the send
# time, keeps a report from the same second and drops an older one.
stop_written() {
	local line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		grep -qxF "$line" <<<"$3" || return 0
	done < <(stop_candidates "$1" "$2")
	return 1
}

# Delivers a prompt already typed into a working Devin's input. Devin needs
# two Enters: one submits the text to its queue, the next sends the queue now,
# cancelling the running command. A fixed sleep before one Enter could land
# before Devin took the text, leaving STOP unsubmitted for over an hour, so
# the pane is watched instead: Enter while the text sits in the input box,
# then Enter once it shows in the queue with the "send now" hint, which an
# older queued message alone does not satisfy. The watch ends early once the
# stop report exists, and after 20 seconds or the caller's deadline, whichever
# comes first. When the pane never showed the text, one Enter goes as a
# fallback. $1 store, $2 role, $3 agent name, $4 prompt text, $5 snapshot
# from stop_candidates, $6 deadline (epoch). Returns 1 with a reason on stderr
# when delivery could not be confirmed.
devin_send_now() {
	local store="$1" role="$2" name="$3" text="$4" before="$5" deadline="$6" end screen seen=0
	end=$(( $(date +%s) + 20 ))
	[ "$end" -le "$deadline" ] || end="$deadline"
	while [ "$(date +%s)" -lt "$end" ]; do
		stop_written "$store" "$role" "$before" && return 0
		screen="$(pane_text "$name")"
		if grep -qF "❭ $text" <<<"$screen"; then
			seen=1
			herdr agent send-keys "$name" enter >/dev/null 2>&1 || true
		elif grep -qF "○ $text" <<<"$screen" && grep -qiE 'send queued messages now|↵ send now' <<<"$screen"; then
			herdr agent send-keys "$name" enter >/dev/null 2>&1 || true
			return 0
		fi
		sleep 1
	done
	stop_written "$store" "$role" "$before" && return 0
	if grep -qF "❭ $text" <<<"$(pane_text "$name")"; then
		printf '%s: STOP is still typed in the input box; read it: herdr agent read %s --source visible\n' "$role" "$name" >&2
		return 1
	fi
	if [ "$seen" -eq 0 ]; then
		herdr agent send-keys "$name" enter >/dev/null 2>&1 || true
		printf '%s: STOP never showed in the pane; sent one Enter as a fallback\n' "$role" >&2
		return 1
	fi
	return 0
}

# STOP for one role; sets code, out, and err in the caller, which declares
# them. An idle agent gets it with a wait. A working one may settle its
# current turn before it reads STOP, so the wait ends on its stop report or
# advice written after the send, not on a settle. A working Devin parks a
# mid-turn message as queued until Enter is pressed, so Enter follows.
stop_role() {
	local store="$1" role="$2" timeout="$3" name errfile epoch deadline before
	name="$(field "$store" ".$role.name")"
	code=0 out="" err=""
	errfile="$(mktemp)"
	event "$store" master send-stop - "$role"
	if [ "$(agent_status "$name")" = working ]; then
		epoch="$(date +%s)"
		before="$(stop_candidates "$store" "$role")"
		if ! herdr agent prompt "$name" "$PAIR_SKILL STOP $store" >/dev/null 2>"$errfile"; then
			code=2
			err="$(cat "$errfile")"
			rm -f "$errfile"
			return 0
		fi
		deadline=$(( epoch + timeout / 1000 ))
		if [ "$(field "$store" ".$role.kind")" = devin ]; then
			devin_send_now "$store" "$role" "$name" "$PAIR_SKILL STOP" "$before" "$deadline" || true
		fi
		until stop_written "$store" "$role" "$before"; do
			if [ "$(date +%s)" -ge "$deadline" ]; then
				code=1
				printf '{"error":{"code":"timeout"}}\n' >"$errfile"
				break
			fi
			sleep 5
		done
		out="$(herdr agent get "$name" 2>/dev/null || true)"
	else
		out="$(herdr agent prompt "$name" "$PAIR_SKILL STOP $store" --wait --timeout "$timeout" 2>"$errfile")" || code=$?
	fi
	err="$(cat "$errfile")"
	rm -f "$errfile"
}

cmd_stop() {
	in_herdr
	[ $# -ge 1 ] || die "usage: pair.sh stop <store> [--timeout MS]"
	local store="$1" timeout=300000 rest
	shift
	wait_opts "$@"
	no_extra_opts
	local name status out err code=0
	name="$(field "$store" .sidekick.name)"
	status="$(agent_status "$name")"
	case "$status" in
	absent) die "sidekick $name is not live" 2 ;;
	blocked) die "sidekick $name is blocked; inspect it before stopping" 3 ;;
	esac
	rm -f "$store/queue"
	json_update "$store" '.pending = []'
	stop_role "$store" sidekick "$timeout"
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
	pause_notice "$store"
	steer_notice "$store"
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
		event "$store" master send-steer "$steer" working
		if [ "$(field "$store" .sidekick.kind)" = devin ] && [ "$interrupt" -eq 0 ]; then
			# Devin parks a mid-turn message as queued, and the Enter that would
			# deliver it cancels the running command. The steer stays in the
			# store; the sidekick's next step, notes, or progress prints it.
			json_update "$store" --arg s "$steer" '.notice_steers = ((.notice_steers // []) + [$s] | unique)'
			printf 'steer %s left for %s: it lands at the sidekick'"'"'s next pair.sh step, notes, or progress, between tool calls; the ack lands in the progress log. Use --interrupt only to cancel the running command.\n' "$steer" "$name"
		else
			herdr agent prompt "$name" "$PAIR_SKILL STEER $steer" >/dev/null || die "herdr prompt failed for $name" 2
			printf 'steered %s with %s; its harness hands it over between tool calls and the ack lands in the progress log\n' "$name" "$steer"
		fi
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
		json_update "$store" --argjson epoch "$(date +%s)" '.sent.epoch = $epoch | del(.sent.seen)'
		prompt_sidekick "$name" "$PAIR_SKILL STEER $steer"
		local ready
		wait_for_reply "$store" "$name" "$timeout"
		finish_wait "$store" "$code" "$out" "$err" "$(reply_mode)" "$ready"
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
		if [ -f "$store/paused" ]; then
			printf 'paused: %s\n' "$(paused_reason "$store")"
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
	# The worktree lives inside the repo's git directory: an agent started
	# there inherits the folder trust the human gave the repo (Claude and Codex
	# check the directory's ancestors), and the main tree's status never sees
	# it. The store keeps a link at scratch/<id>; an older store's real
	# directory there is still removed.
	local link="$store/scratch/$id"
	path="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)/pstack-scratch/$(basename "$(dirname "$store")")-$(basename "$store")/$id"
	[ -L "$link" ] || [ ! -d "$link" ] || path="$link"
	if [ "$remove" -eq 1 ]; then
		if [ -d "$cwd/.jj" ]; then
			jj -R "$cwd" workspace forget "scratch-$id" >/dev/null 2>&1 || true
			rm -rf "$path"
		else
			git -C "$cwd" worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path"
			git -C "$cwd" worktree prune >/dev/null 2>&1 || true
		fi
		[ ! -L "$link" ] || rm -f "$link"
		rmdir "$(dirname "$path")" 2>/dev/null || true
		json_update "$store" --arg id "$id" '.scratch = ((.scratch // []) - [$id])'
		printf 'removed %s\n' "$path"
		return 0
	fi
	if [ -d "$path" ]; then
		printf '%s\n' "$path"
		return 0
	fi
	mkdir -p "$store/scratch" "$(dirname "$path")"
	ln -sfn "$path" "$link"
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
		else if (ev == "failover") { nfail++; fails = fails ", " d }
		else if (ev == "step") { nsteps++; split(d, sk, ":"); st[u, sk[1]] = t }
		else if (ev == "note") {
			# A note reviews every step of its unit since the last note.
			nnotes++; split(d, nk, ":"); if (nk[2] == "blocking") nblock++
			for (i = noted[u] + 1; i <= nk[1]; i++) if ((u, i) in st) { nsl++; sl[nsl] = t - st[u, i] }
			noted[u] = nk[1]
		}
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
		if (nfail) printf "failovers: %d (%s)\n", nfail, substr(fails, 3)
		if (nsteps) printf "steps: %d committed, %d notes (%d blocking); step to note median %s\n", nsteps, nnotes, nblock, m(median(sl, nsl))
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
