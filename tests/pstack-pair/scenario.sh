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
export PAIR_SETTLE_HOLD=10 PAIR_BUSY_POLL=1 HOME="$T/home" FAKE="$T/fake" PATH="$H/bin:$PATH" HERDR_ENV=1 HERDR_PANE_ID=p0 HERDR_WORKSPACE_ID=w1 HERDR_TAB_ID=t1 XDG_STATE_HOME="$T/state"
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
"$prefix BRIEF "*|"$prefix ANSWER "*) if [ -f "\$FAKE/busy-on-brief" ]; then mkdir -p "\$FAKE/busy"; : >"\$FAKE/busy/\$name"
	elif [ -f "\$FAKE/brief-working" ]; then printf 'working devin\n' >"\$FAKE/agents/\$name"
	else b="\$(basename "\${text##* }")"; case "\$text" in *ANSWER*) b="\$(basename "\$b" | sed -E 's/-a[0-9]+//')" ;; esac; body report done >"\$store/reports/\$b"; fi ;;
"$prefix CONSULT "*) c="\${text#* CONSULT }"; a="\$(grep -m1 '^advice:' "\$c" | sed 's/^advice: //')"; body advice answered >"\$a" ;;
"$prefix STEER "*) st="\${text#* STEER }"; b="\$(basename "\$st" .md | sed -E 's/-s[0-9]+\$//')"
	# A paused sidekick answers a superseding steer by finishing the brief.
	[ "\$(cut -d' ' -f1 "\$FAKE/agents/\$name")" = idle ] && body report done >"\$store/reports/\$b.md" ;;
"$prefix STOP "*) body stop partial >"\$store/reports/\$(ls \$store/briefs | tail -1 | cut -c1-3)-stop.md" ;;
esac
exit 0
HOOK
chmod +x "$FAKE/hook"

norm() { sed -E -e "s#$T#<T>#g" -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/<TS>/g' -e 's#/tmp/tmp\.[A-Za-z0-9]+#<TMP>#g' \
	-e 's#/tmp/pair-spawn-err\.[0-9]+#<ERR>#g' -e 's/(^| )[0-9]{2}:[0-9]{2} /\1<HM> /' -e 's/elapsed [0-9]+m/elapsed <N>m/' -e 's/last [0-9]+m ago/last <N>m ago/' \
	-e 's/\b1[0-9]{9}\b/<EPOCH>/g' -e 's/[0-9a-f]{7,40}/<SHA>/g'; }
run() {
	printf '\n$ pair.sh %s\n' "$*" | norm
	local out code
	out="$("$P" "$@" 2>&1)"; code=$?
	printf '%s\n[exit %s]\n' "$out" "$code" | norm
	# A sliced wait polls herdr a timing-dependent number of times; fold repeats.
	# Slice lengths follow the clock, so they are masked before folding.
	if [ -s "$FAKE/calls.log" ]; then sed -E 's/^(agent wait .*--timeout )[0-9]+$/\1<MS>/' "$FAKE/calls.log" | uniq | sed 's/^/  herdr /' | norm; : >"$FAKE/calls.log"; fi
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
run dispatch "$store" "$brief" --timeout 1500
printf 'b\n' >>a.txt; printf 'c\n' >b.txt
run progress "$store" "step one done; next: two"
run wait "$store" --timeout 1500
run wait "$store" --timeout 1500
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
	# consults no longer wait for an idle sidekick
	run consult "$store" "$c1"
	run advice "$store"
	status "demo-sidekick" idle devin
	c2="$("$P" new-consult "$store" "$seq" --kind design)"; c3="$("$P" new-consult "$store" "$seq" --kind design)"
	run new-consult "$store" "$seq" --kind design
	run new-consult "$store" "$seq" --kind glance
	run new-consult "$store" "$seq" --kind glance
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
# queue and next: the master holds the next brief for a working sidekick,
# which takes it the moment its report is written. The report of the first
# brief lands, and the queued one is taken, before the master's wait, which
# must still surface that report.
q1="$("$P" new-brief "$store" qone)"; fill "$q1"; set_hdr "$q1" playbook investigation; set_hdr "$q1" plan none
q2="$("$P" new-brief "$store" qtwo)"; fill "$q2"; set_hdr "$q2" playbook investigation; set_hdr "$q2" plan none
status "demo-sidekick" idle devin
run queue "$store" "$q2"
: >"$FAKE/brief-working"
run dispatch "$store" "$q1" --timeout 1000
run queue "$store" "$q2"
run queue "$store" "$q1"
run dispatch "$store" "$q1"
run status "$store"
printf '# Report\n\nstatus: done\n' >"$store/reports/$(basename "$q1")"
# finish: the sidekick's one command after a report takes the queued brief
run finish "$store" "$store/reports/$(basename "$q1")"
run next "$store"
run wait "$store" --timeout 1500
q3="$("$P" new-brief "$store" qthree)"; fill "$q3"; set_hdr "$q3" playbook investigation; set_hdr "$q3" plan none
run queue "$store" "$q3"
# a partial report ends the turn and leaves the queued brief for the master
printf '# Report\n\nstatus: partial\n' >"$store/reports/$(basename "$q2")"
run finish "$store" "$store/reports/$(basename "$q2")"
rm -f "$FAKE/brief-working"; status "demo-sidekick" idle devin
run wait "$store" --timeout 1500
run status "$store"
# herdr reports a settle while the sidekick still works (a Devin sidekick
# flips done to idle as a prompt lands): dispatch keeps looking, and the
# report that lands on a later poll is what it returns.
: >"$FAKE/brief-working"
printf '1\n' >"$FAKE/lies"
printf '3 %s\n' "$store/reports/$(basename "$q3")" >"$FAKE/report-after"
run dispatch "$store" "$q3" --timeout 20000
# herdr reports done for a whole run while the pane shows Devin working, as
# in a narrow pane: queue accepts it as working, and dispatch waits for the
# report instead of returning missing after the settle hold.
q5="$("$P" new-brief "$store" qfive)"; fill "$q5"; set_hdr "$q5" playbook investigation; set_hdr "$q5" plan none
q6="$("$P" new-brief "$store" qsix)"; fill "$q6"; set_hdr "$q6" playbook investigation; set_hdr "$q6" plan none
: >"$FAKE/busy-on-brief"; status "demo-sidekick" done devin
printf '4 %s\n' "$store/reports/$(basename "$q5")" >"$FAKE/report-after"
"$P" queue "$store" --clear >/dev/null
run dispatch "$store" "$q5"
run queue "$store" "$q6"
rm -f "$FAKE/busy/demo-sidekick" "$FAKE/busy-on-brief"
run queue "$store" --clear
# a stop report written after the master re-dispatched the unit is not its
# reply: the wait shows a check-in, not the stop (walkthrough-808, brief 112)
q7="$("$P" new-brief "$store" qseven)"; fill "$q7"; set_hdr "$q7" playbook investigation; set_hdr "$q7" plan none
: >"$FAKE/brief-working"
run dispatch "$store" "$q7" --timeout 1000
printf '# Stop\n\nstatus: partial\n' >"$store/reports/$(basename "$q7" | cut -c1-3)-stop.md"
run wait "$store" --timeout 1500
# a brief the master read and reviewed without a wait does not come back as
# the reply to the next dispatch (kg-map, brief 003)
printf '# Report\n\nstatus: done\n' >"$store/reports/$(basename "$q7")"
printf '# Review\n\nverdict: accept\n' >"$store/reviews/$(basename "$q7")"
status "demo-sidekick" idle devin
q8="$("$P" new-brief "$store" qeight)"; fill "$q8"; set_hdr "$q8" playbook investigation; set_hdr "$q8" plan none
run dispatch "$store" "$q8" --timeout 1000
# a settle that holds with no report ends the wait at its interval
rm -f "$FAKE/brief-working"; status "demo-sidekick" idle devin
q4="$("$P" new-brief "$store" qfour)"; fill "$q4"; set_hdr "$q4" playbook investigation; set_hdr "$q4" plan none
"$P" dispatch "$store" "$q4" --timeout 1000 >/dev/null 2>&1; : >"$FAKE/calls.log"
rm -f "$store/reports/$(basename "$q4")"
run wait "$store" --timeout 3000
# a unit rechecked at its commit while the tree moves on
rid="$(basename "$q1" .md)-review"
run scratch "$store" "$rid" --at "$(git rev-parse HEAD)"
run scratch "$store" 099-bad-review --at deadbeef
run scratch "$store" "$rid" --remove
# draft-PR review: the sidekick commits each step and goes on; a wait
# returns the steps not yet reviewed; the master publishes a note; blocking
# notes reach the sidekick at its next step boundary, and finish refuses a
# done report while one is open. The final wait gives only the delta.
qs="$("$P" new-brief "$store" qsteps)"; fill "$qs"; set_hdr "$qs" playbook investigation; set_hdr "$qs" plan none
qn="$(basename "$qs" | cut -c1-3)"
status "demo-sidekick" idle devin; : >"$FAKE/brief-working"
"$P" dispatch "$store" "$qs" --timeout 1000 >/dev/null 2>&1; : >"$FAKE/calls.log"
commit() { git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; git rev-parse HEAD; }
s1="$(commit "step one")"
run step "$store" "$s1" "parser reads v2"
run wait "$store" --timeout 1500
# a range already shown does not wake the master again while it reviews
run wait "$store" --timeout 1500
# step two lands while the master reviews step one: the note covers only
# what the wait showed, and step two waits for the next note
s2="$(commit "step two")"
run step "$store" "$s2" "consumers switched"
run new-note "$store" "$qn"
n1="$store/notes/$(basename "$qs" .md)-n1.md.draft"
run note "$store" "$n1"
fill "$n1"; set_hdr "$n1" status blocking
run note "$store" "$n1"
run new-note "$store" "$qn"
run notes "$store"
printf '# Report\n\nstatus: done\n' >"$store/reports/$(basename "$qs")"
run finish "$store" "$store/reports/$(basename "$qs")"
rm -f "$store/reports/$(basename "$qs")"
run step "$store" "$(commit "stray")" "claims a note not published" --resolves n9
s3="$(commit "fix n1")"
run step "$store" "$s3" "fixup: board consumer" --resolves n1
run notes "$store"
run wait "$store" --timeout 1500
run new-note "$store" "$qn"
n3="$store/notes/$(basename "$qs" .md)-n3.md.draft"
fill "$n3"; set_hdr "$n3" status clear
run note "$store" "$n3"
printf '# Report\n\nstatus: done\n' >"$store/reports/$(basename "$qs")"
run finish "$store" "$store/reports/$(basename "$qs")"
rm -f "$FAKE/brief-working"; status "demo-sidekick" idle devin
run wait "$store" --timeout 1500
# a finished unit never holds a later wait on its steps
run wait "$store" --timeout 1500
# annotated may-write lines: paths with notes, comma lists, and a directory
qa="$("$P" new-brief "$store" qscope)"; fill "$qa"; set_hdr "$qa" playbook investigation; set_hdr "$qa" plan none
printf -- '\n## Scope\n\nmay write:\n- `b.txt` — the fixture (new file)\n- docs/, notes.md (only a link)\n\nmust not write:\n- x\n' >>"$qa"
status "demo-sidekick" idle devin; : >"$FAKE/brief-working"
run dispatch "$store" "$qa" --timeout 1000
rm -f "$FAKE/brief-working"; status "demo-sidekick" idle devin
# pause at a safe point: the master starts nothing new, the sidekick hears it
# at its next step or progress boundary, reports partial, and ends the turn
q9="$("$P" new-brief "$store" qnine)"; fill "$q9"; set_hdr "$q9" playbook investigation; set_hdr "$q9" plan none
status "demo-sidekick" idle devin; : >"$FAKE/brief-working"
"$P" dispatch "$store" "$q9" --timeout 1000 >/dev/null 2>&1; : >"$FAKE/calls.log"
run pause "$store" --reason "skill upgrade"
run queue "$store" "$q9"
run progress "$store" "half of step one"
run step "$store" "$(commit "step one of nine")" "step one of nine"
printf '# Report\n\nstatus: partial\n' >"$store/reports/$(basename "$q9")"
run finish "$store" "$store/reports/$(basename "$q9")"
rm -f "$FAKE/brief-working"; status "demo-sidekick" idle devin
run wait "$store" --timeout 1500
run status "$store"
run resume "$store"
# stop reaches a working Devin: Enter follows the prompt, since Devin parks a
# mid-turn message as queued (uxa's STOP sat unread that way), and the wait
# ends on the stop report, not on the running turn's settle
status "demo-sidekick" working devin
run stop "$store"
# a stop report named NNN-<slug>-stop.md, as Devin writes it, also ends the wait
cp "$FAKE/hook" "$FAKE/hook.orig"
sed -i 's#-stop.md"#-slugged-stop.md"#' "$FAKE/hook"
status "demo-sidekick" working devin
run stop "$store"
mv "$FAKE/hook.orig" "$FAKE/hook"
# a working Claude Code or Codex sidekick takes STOP between tool calls: no Enter
jq '.sidekick.kind = "claude"' "$store/pair.json" >"$store/pair.json.t" && mv "$store/pair.json.t" "$store/pair.json"
status "demo-sidekick" working claude
run stop "$store"
jq '.sidekick.kind = "devin"' "$store/pair.json" >"$store/pair.json.t" && mv "$store/pair.json.t" "$store/pair.json"
# herdr says done, and an 11-row pane shows only a queued-message block
status "demo-sidekick" done devin
mkdir -p "$FAKE/busy-queue"; : >"$FAKE/busy-queue/demo-sidekick"
run status "$store"
rm -f "$FAKE/busy-queue/demo-sidekick"
# herdr says done, and the pane shows only Devin's working placeholder
status "demo-sidekick" done devin
mkdir -p "$FAKE/busy-guide"; : >"$FAKE/busy-guide/demo-sidekick"
run status "$store"
rm -f "$FAKE/busy-guide/demo-sidekick"; status "demo-sidekick" idle devin
run stop "$store"
run bogus
# metrics over a known timeline: brief 002 runs 10m, the sidekick idles 4m,
# plan 003 answers in 2m (the consultant in 5m), brief 004 runs 20m with one
# check-in, and a 3m consult; reviews land 1m and 6m after their reports.
m="$T/metrics"; mkdir -p "$m"
e() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$m/events.tsv"; }
e ts epoch actor event unit detail
e t 1000 master init - x
e t 1000 master send-brief 002-a ""
e t 1600 sidekick report 002-a done
e t 1660 master log - "review: accept 002"
e t 1840 master send-plan 003-p sidekick
e t 1840 master send-plan 003-p consultant
e t 1960 master wake 003-p sidekick:agree
e t 2140 master wake 003-p consultant:object
e t 2200 master log - "plan: agreed 003"
e t 2200 master send-brief 004-b ""
e t 2740 master wake 004-b checkin
e t 2800 master send-consult 004-b-c1 finding
e t 2980 master wake 004-b-c1 advice:answered
e t 3400 master wake 004-b report:done
e t 3760 master log - "review: revise 004"
# 005 runs 10m after a 7m idle gap; 006, queued at 3900, starts the second
# 005's report lands, and the master's late wake on 005 must not end it. The
# review's verdict sits mid-sentence. A new brief at 5100 stops 006 after 12m,
# and 007 is still running 10m later, at the fixed now.
e t 3800 master send-brief 005-c ""
e t 3900 master queue 006-q ""
e t 4400 sidekick report 005-c done
e t 4400 sidekick send-brief 006-q queued
e t 4420 master wake 005-c report:done
e t 4600 master log - "review: unit 005 (c) accepted after a rerun"
e t 5100 master send-brief 007-r ""
PAIR_METRICS_NOW=5700 run metrics "$m"
run metrics "$T/nowhere"
printf '\n== store tree\n'
(cd "$store" && find . -type f ! -name '*.seen' | sort | while read -r f; do printf -- '--- %s\n' "$f"; norm <"$f" | grep -v '^generated:'; done)
printf '\n== git status\n'; git status --porcelain | norm
git worktree list | norm
rm -rf "$T"
