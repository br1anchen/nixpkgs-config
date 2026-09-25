#!/usr/bin/env bash
# Drive one variant's pair.sh through every command against fake herdr and
# print a normalized transcript: command, exit code, output, herdr calls, and
# the final store tree. Usage: scenario.sh <skills-dir> <pair|guided|trio>
set -u
skills="$(readlink -f "$1")" variant="$2"
H="$(cd "$(dirname "$0")" && pwd)"
case "$variant" in
pair) skill=pstack-pair prefix=pstack-pair ;;
guided) skill=pstack-pair-guided prefix=pstack-pair-guided ;;
trio) skill=pstack-trio prefix=pstack-trio ;;
esac
T="$(mktemp -d)"
export HOME="$T/home" FAKE="$T/fake" PATH="$H/bin:$PATH" HERDR_ENV=1 HERDR_PANE_ID=p0 HERDR_WORKSPACE_ID=w1 HERDR_TAB_ID=t1 XDG_STATE_HOME="$T/state"
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$FAKE" "$T/repo" "$T/home"
git -C "$T/repo" init -q -b main && git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'a\n' >"$T/repo/a.txt" && git -C "$T/repo" add a.txt && git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q -m a
cd "$T/repo"
P="$skills/$skill/scripts/pair.sh"
store="$T/state/pstack/$( [ $variant = pair ] && echo pair || { [ $variant = guided ] && echo pair-guided || echo trio; })/demo"

cat >"$FAKE/hook" <<HOOK
#!/usr/bin/env bash
name="\$1" text="\$2" store="$store"
role=sidekick; case "\$name" in *-consultant) role=consultant ;; *-master) role=master ;; esac
body() { printf '# %s\n\nstatus: %s\nhead: abc\n' "\$1" "\$2"; }
case "\$text" in
Load*) [ \$role = sidekick ] && body ready done >"\$store/reports/000-ready.md"; [ \$role = consultant ] && body ready answered >"\$store/advice/000-ready.md" ;;
"$prefix PLAN "*) p="\${text#* PLAN }"; b="\$(basename "\$p")"
	[ \$role = sidekick ] && body plan agree >"\$store/reports/\$b"
	[ \$role = consultant ] && body plan agree >"\$store/advice/\$b" ;;
"$prefix BRIEF "*|"$prefix ANSWER "*) if [ -f "\$FAKE/brief-working" ]; then printf 'working devin\n' >"\$FAKE/agents/\$name"
	else b="\$(basename "\${text##* }")"; case "\$text" in *ANSWER*) b="\$(basename "\$b" | sed -E 's/-a[0-9]+//')" ;; esac; body report done >"\$store/reports/\$b"; fi ;;
"$prefix CONSULT "*) c="\${text#* CONSULT }"; a="\$(grep -m1 '^advice:' "\$c" | sed 's/^advice: //')"; body advice answered >"\$a" ;;
"$prefix STOP "*) body stop partial >"\$store/reports/\$(ls \$store/briefs | tail -1 | cut -c1-3)-stop.md" ;;
esac
exit 0
HOOK
chmod +x "$FAKE/hook"

norm() { sed -E -e "s#$T#<T>#g" -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/<TS>/g' -e 's#/tmp/tmp\.[A-Za-z0-9]+#<TMP>#g' \
	-e 's#/tmp/pair-spawn-err\.[0-9]+#<ERR>#g' -e 's/(^| )[0-9]{2}:[0-9]{2} /\1<HM> /' -e 's/elapsed [0-9]+m/elapsed <N>m/' -e 's/last [0-9]+m ago/last <N>m ago/' \
	-e 's/[0-9a-f]{7,40}/<SHA>/g'; }
run() {
	printf '\n$ pair.sh %s\n' "$*" | norm
	local out code
	out="$("$P" "$@" 2>&1)"; code=$?
	printf '%s\n[exit %s]\n' "$out" "$code" | norm
	if [ -s "$FAKE/calls.log" ]; then sed 's/^/  herdr /' "$FAKE/calls.log" | norm; : >"$FAKE/calls.log"; fi
}
fill() { perl -0pi -e 's/\{\{.*?\}\}/x/gs' "$1"; }
set_hdr() { sed -i -E "s#^$2:.*#$2: $3#" "$1"; }
status() { printf '%s %s\n' "$2" "$3" >"$FAKE/agents/$1"; }

run help
run init BadSlug
run init demo
run init demo
run permission
if [ $variant = trio ]; then run spawn "$store" --sidekick devin --consultant codex; run spawn "$store" --sidekick claude --consultant claude
else run spawn "$store" --kind devin; fi
run spawn "$store" --kind devin
plan="$("$P" new-plan "$store" design)"; printf '\nnew-plan -> %s\n' "$plan" | norm
run discuss "$store" "$plan"
fill "$plan"; [ $variant = guided ] && set_hdr "$plan" scale small
brief0="$("$P" new-brief "$store" early)"; fill "$brief0"; set_hdr "$brief0" playbook feature; set_hdr "$brief0" plan "$plan"
run dispatch "$store" "$brief0"
run discuss "$store" "$plan"
review="$store/reviews/$(basename "$plan")"
printf '# Review\n\nverdict: agreed\napproval: not-required\n' >"$review"
run dispatch "$store" "$brief0"
brief="$("$P" new-brief "$store" build)"; fill "$brief"; set_hdr "$brief" playbook feature; set_hdr "$brief" plan "$plan"; set_hdr "$brief" timebox 30
printf -- '\n## Scope\n\nmay write:\n- a.txt\n\nmust not write:\n- x\n' >>"$brief"
: >"$FAKE/brief-working"
run dispatch "$store" "$brief"
printf 'b\n' >>a.txt; printf 'c\n' >b.txt
run progress "$store" "step one done; next: two"
run wait "$store" --every 1
run wait "$store"
seq="$(basename "$brief" | cut -c1-3)"
s1="$("$P" new-steer "$store" "$seq")"; fill "$s1"; set_hdr "$s1" kind redirect; set_hdr "$s1" "scope effect" none; set_hdr "$s1" supersedes none
run steer "$store" "$s1"
run steer "$store" "$s1" --interrupt
s2="$("$P" new-steer "$store" "$seq")"; fill "$s2"; set_hdr "$s2" kind narrow; set_hdr "$s2" "scope effect" none; set_hdr "$s2" supersedes none
run new-steer "$store" "$seq"
rm -f "$FAKE/brief-working"; status "demo-sidekick" idle devin
printf '# Objection\n\nstatus: object\n' >"$store/reports/$(basename "$brief" .md)-s1.md"
run new-steer "$store" "$seq" --supersedes "$s1"
s3="$(ls -t "$store"/steers/*.md | head -1)"; fill "$s3"; set_hdr "$s3" kind redirect; set_hdr "$s3" "scope effect" none
run steer "$store" "$s3"
run report "$store"
run report "$store" 001
run notify "$store" "$store/reports/000-ready.md"
status "demo-master" working claude
run notify "$store" "$store/reports/000-ready.md"
status "demo-master" idle claude
run log "$store" review "accept $seq" "diff clean" "reviews/$seq" "next"
run status "$store"
if [ $variant = trio ]; then
	run new-consult "$store" "$seq" --kind bogus
	c1="$("$P" new-consult "$store" "$seq" --kind finding)"; fill "$c1"; set_hdr "$c1" kind finding
	status "demo-sidekick" working devin
	run consult "$store" "$c1"
	run consult "$store" "$c1" --force
	run advice "$store"
	status "demo-sidekick" idle devin
	c2="$("$P" new-consult "$store" "$seq" --kind design)"; c3="$("$P" new-consult "$store" "$seq" --kind design)"
	run new-consult "$store" "$seq" --kind design
	id="$(basename "$c1" .md)"
	run scratch "$store" "$id"
	run status "$store"
	run scratch "$store" "$id" --remove
fi
if [ $variant = guided ]; then
	run new-direction "$store" "$plan"
	run new-answer "$store" "$seq"
	printf '# Ask\n\nstatus: asking\n' >"$store/reports/$(basename "$brief" .md)-q1.md"
	run status "$store"
	a="$("$P" new-answer "$store" "$seq")"; fill "$a"; set_hdr "$a" "decided by" master
	run answer "$store" "$a"
	# medium plan without approval is refused
	set_hdr "$plan" scale medium
	b3="$("$P" new-brief "$store" gated)"; fill "$b3"; set_hdr "$b3" playbook feature; set_hdr "$b3" plan "$plan"
	run dispatch "$store" "$b3"
fi
run stop "$store"
run bogus
printf '\n== store tree\n'
(cd "$store" && find . -type f ! -name '*.seen' | sort | while read -r f; do printf -- '--- %s\n' "$f"; norm <"$f" | grep -v '^generated:'; done)
printf '\n== git status\n'; git status --porcelain | norm
git worktree list | norm
rm -rf "$T"
