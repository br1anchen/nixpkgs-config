# Verdict NNN: <slug>

status: clean | reject | inconclusive
units: <the unit numbers from the packet, space-separated>
range: <base>..<head> from the packet
verifier: <your agent kind and model>
verifier-agent: <copy the verifier-agent: line from the packet>

## Findings

<For reject: one numbered finding per broken Acceptance line or regression,
each naming the acceptance line or behaviour, what happened instead, and the
Evidence block that shows it. For clean: "none". For inconclusive: what you
could not reach and why (a missing prerequisite, a harness gap), and the
route you tried.>

## Evidence

<One block per claim: the command or the drive, then its output verbatim or
the relevant excerpt with the omitted line count. Screenshots and logs by
path. A claim without a block here does not count; kitchen.sh rejects a
verdict with no command output.>

```
$ <command>
<output>
```

## Not covered

<Acceptance lines or surfaces you did not exercise, and why, or "none".>
