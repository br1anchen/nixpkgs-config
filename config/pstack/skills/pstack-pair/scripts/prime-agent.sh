# shellcheck shell=bash
# Prime's TUI attaches to a daemon session. Its Herdr session reference, rather
# than a name or the newest log in a directory, identifies the session we own.
record_prime_session() {
	local store="$1" role="$2" info session
	info="$(herdr agent get "$(field "$store" ".$role.name")" 2>/dev/null)" || return 1
	session="$(jq -ce --arg pane "$(field "$store" ".$role.pane_id")" '
		.result.agent | select(.agent == "prime-agent" and .pane_id == $pane)
		| .agent_session | select((.kind == "path" or .kind == "id") and (.value | type == "string" and length > 0))
		| {kind, value}' <<<"$info")" || return 1
	json_update "$store" --arg role "$role" --argjson session "$session" '.[$role].session = $session'
}

# Management commands must use the same daemon socket as the launched client.
prime_command() {
	local store="$1" role="$2" arg socket="" next=0
	shift 2
	while IFS= read -r arg; do
		if [ "$next" -eq 1 ]; then socket="$arg"; next=0; continue; fi
		case "$arg" in
		--daemon-socket) next=1 ;;
		--daemon-socket=*) socket="${arg#*=}" ;;
		esac
	done < <(jq -r --arg role "$role" '.[$role].start_args[]?' "$store/pair.json")
	case "$socket" in
	"" | /*) ;;
	*) socket="$(field "$store" ".$role.launch_cwd // .cwd")/$socket" ;;
	esac
	local -a socket_args=()
	[ -z "$socket" ] || socket_args=(--socket "$socket")
	with_timeout "${PAIR_PRIME_COMMAND_TIMEOUT:-30}" prime-agent "$@" "${socket_args[@]}"
}

prime_sessions() {
	local out
	out="$(prime_command "$1" "$2" list --json)" || return 1
	jq -ce '.sessions | select(type == "array")' <<<"$out"
}

# Exact path/id matching yields the live daemon id. No prefix or name matching:
# another kitchen or the human may have a similar session name.
prime_active_session() {
	local store="$1" role="$2" session matches
	session="$(field "$store" ".$role.session // empty")"
	[ -n "$session" ] || { printf 'no recorded Prime session for %s; inspect its pane before cleanup\n' "$role" >&2; return 1; }
	matches="$(prime_sessions "$store" "$role" | jq -c --argjson session "$session" '[.[]
		| select(.activeSessionId? | type == "string" and length > 0)
		| select(if $session.kind == "path" then .sessionFile == $session.value
		         else .sessionId == $session.value or .activeSessionId == $session.value end)
		| .activeSessionId] | unique')" || return 1
	case "$(jq length <<<"$matches")" in
	0) prime_active_id="" ;;
	1) prime_active_id="$(jq -r '.[0]' <<<"$matches")" ;;
	*) printf 'multiple live Prime sessions match %s; none was stopped\n' "$session" >&2; return 1 ;;
	esac
}

stop_prime_role() {
	local store="$1" role="$2" name status id remaining pane info
	name="$(field "$store" ".$role.name")"
	status="$(agent_status "$name")"
	if [ "$status" != absent ]; then
		record_prime_session "$store" "$role" || return 1
	fi
	prime_active_session "$store" "$role" || return 1
	id="$prime_active_id"
	if [ "$status" != absent ] && [ -z "$id" ]; then
		printf 'no live daemon session matches %s in its recorded socket; inspect the client before cleanup\n' "$name" >&2
		return 1
	fi
	# Detach while the client is still an active Herdr target. A blocked client
	# cannot take /quit through agent.prompt; Ctrl+D exits its empty editor.
	# Stopping the worker alone leaves the TUI displaying a session-closed error.
	if [ "$status" = idle ] || [ "$status" = "done" ]; then
		herdr agent prompt "$name" /quit >/dev/null 2>&1 || true
	elif [ "$status" = blocked ]; then
		herdr agent send-keys "$name" ctrl+d >/dev/null 2>&1 || true
	fi
	if [ -n "$id" ]; then
		prime_command "$store" "$role" stop "$id" --json >/dev/null || return 1
		remaining="$(prime_sessions "$store" "$role" | jq --arg id "$id" '[.[] | select(.activeSessionId == $id)] | length')" || return 1
		[ "$remaining" -eq 0 ] || { printf 'Prime session %s is still active; its pane and scratch stay\n' "$id" >&2; return 1; }
	fi
	# The reporter releases on stop. Wait for the actual shell as well: killing
	# a worker does not by itself prove the TUI has exited or released its PTY.
	pane="$(field "$store" ".$role.pane_id")"
	local deadline=$(( $(date +%s) + 15 ))
	while :; do
		info="$(herdr pane process-info --pane "$pane" 2>/dev/null)" || return 1
		if [ "$(agent_status "$pane")" = absent ] && jq -e '
			.result.process_info | (.shell_pid | type == "number")
			and .foreground_process_group_id == .shell_pid' <<<"$info" >/dev/null; then
			break
		fi
		[ "$(date +%s)" -lt "$deadline" ] || { printf 'Prime client has not exited in %s; inspect it before cleanup\n' "$pane" >&2; return 1; }
		sleep 1
	done
	json_update "$store" --arg role "$role" '.[$role].session_stopped = true'
}

prime_steer() {
	local store="$1" text="$2" receipt
	record_prime_session "$store" sidekick || return 1
	prime_active_session "$store" sidekick || return 1
	[ -n "$prime_active_id" ] || return 1
	# Prime 0.10.0 advertises --steer but its Rust CLI rejects that flag.
	# Plain send defaults to steering; require a receipt confirming that lane.
	receipt="$(prime_command "$store" sidekick send --json "$prime_active_id" "$text")" || return 1
	jq -e --arg id "$prime_active_id" '.deliveryMode == "steer" and .target.activeSessionId == $id
		and (.deliveryStatus == "queued" or .deliveryStatus == "delivered")' <<<"$receipt" >/dev/null
}

preflight_prime() {
	local out attempt rc dir
	dir="$(mktemp -d)" || return 1
	for attempt in 1 2; do
		rc=0
		out="$(HERDR_ENV=0 with_timeout "${PAIR_PREFLIGHT_TIMEOUT:-90}" prime-agent "$@" --cwd "$dir" --no-session \
			--no-context-files --no-skills --no-prompt-templates --print --mode text \
			'Reply with exactly: OK. Do not use tools.' 2>&1)" || rc=$?
		if [ "$rc" -eq 0 ] && grep -qxE '[[:space:]]*OK[[:space:]]*' <<<"$out"; then
			rm -rf "$dir"
			return 0
		fi
		[ "$attempt" -eq 2 ] || sleep "${PAIR_PREFLIGHT_RETRY_S:-3}"
	done
	rm -rf "$dir"
	printf 'prime-agent %s at %s, twice: exit %s ' "$(prime-agent --version 2>/dev/null || printf '?')" "$(command -v prime-agent)" "$rc" >&2
	printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ' ' >&2
	printf '\n' >&2
	return 1
}

prime_role_error() {
	local store="$1" role="$2" session
	record_prime_session "$store" "$role" || true
	session="$(field "$store" ".$role.session | select(.kind == \"path\") | .value // empty")"
	[ -z "$session" ] || agent_session_error "$session"
}
