# Maintainer

The maintainer is the session that looks after pstack on this host. Masters
file the gaps they hit in the kitchen itself, `kitchen.sh feedback` keeps
them in one inbox, and the maintainer turns them into fixes. Nothing here
needs a live maintainer: an unread report waits in the inbox.

`kitchen.sh` below means `~/.agents/skills/pstack-kitchen/scripts/kitchen.sh`.

## Registering

From the pane that will do this work, in Herdr:

```bash
kitchen.sh maintainer on      # records this pane's agent: name, pane, session
kitchen.sh maintainer status  # who, and whether that agent still checks live
kitchen.sh maintainer off     # when the session ends
```

A filed report goes to the registered agent as `pstack-kitchen FEEDBACK
<path>` only when that agent still exists, sits on the registered pane, is
the registered session, and is not blocked on a dialog. Anything else sends
the human a notification instead, and the report stays filed either way.

## On `pstack-kitchen FEEDBACK <path>`, or when asked

0. `kitchen.sh fleet` shows how the runs on this host are going, by build:
   wakes per verified unit, failovers and provider stops per run. Use it to
   compare the runs before and after a change, with the build rows' eligible
   run counts in mind; a `mixed` or `unknown` run belongs to no build.
1. `kitchen.sh feedback --inbox` lists the open reports, oldest first. Read
   the one named, or the oldest. The header says which run, repo and build it
   came from; the body says what happened, the workaround, and the evidence
   by path into the run's store (read-only, and only while it still exists).
2. For each gap, decide whether it is already fixed. A newer build alone does
   not prove it, and neither does a lower number in `fleet`: compare the cited
   behaviour with the code and the commits since the report's build (`build:`
   in the header, and `filed with:` when the filing command ran on another),
   and reproduce it when you can.
3. Propose the fixes to the human, with the gaps you would leave and why. A
   gap that is the repo's own habit (a lint, a profile command, a brief
   line) belongs to pstack-kitchen-setup's maintain path, not here.
4. Implement through the normal flow for this repo, one commit per fix.
5. `kitchen.sh feedback --close <id> <commit|none> "<note>"` for each report
   whose gaps are all fixed, declined or handed on, with the commit that
   fixed it or `none` and a one-line note. Closing twice is harmless.

Read `kitchen.sh retro` and the run store for context, not as the report: the
report is what the master chose to file.
