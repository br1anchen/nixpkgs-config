# Kitchen feedback

Write this after `kitchen.sh retro`, then file it with
`kitchen.sh feedback <store> <this file>`. Only gaps in the kitchen itself
belong here: a command, a message, a default, or a document of
pstack-kitchen that cost the run time or a master wake. A class that repeats
in the repo (a lint, a profile command, a brief habit) goes to
pstack-kitchen-setup's maintain path instead.

`feedback` writes the header (run, repo, master, build, the retro's summary
line, the time filed). Start the file at `## Gaps`.

```markdown
## Gaps

### 1. <what the kitchen got wrong, in a few words>

What happened: <the sequence, with the command and its output where short>
Workaround: <what you did instead, or "none">
Suggestion: <the change you would make, or "none">
Evidence: <paths into the run store, or commits, one per line>

### 2. <title>

...

## What worked

- <what the kitchen got right and should keep>
```

One `### ` heading per gap; `feedback` refuses a file with none. Keep each
gap to what a maintainer needs to judge whether it is already fixed: the
command you ran, what it printed, what you expected.
