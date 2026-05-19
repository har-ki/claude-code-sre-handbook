# allowedTools Notes

Pre-publish empirical findings for the watcher's `--allowedTools` configuration.
Tested on Claude Code 2.1.84, claude-sonnet-4-6, 2026-05-17.

## 1. Precise vs prefix match

`Bash(gh pr edit*)` prefix-matches: allows `gh pr edit --body "..."`,
`gh pr edit --add-label`, etc. Confirmed in Phase 1 live run — Claude
executed `gh pr edit 11 --repo ... --body "..."` successfully against
the allowedTools string that only includes `Bash(gh pr edit*)`.

**Important:** `--allowedTools` only restricts the `Bash` tool's command
prefixes. Non-Bash tools (Read, Write, Glob, Grep, Skill, Agent, etc.)
are allowed or denied based on whether they appear in the list by name.
However, tools like `Skill` and `Agent` that are not listed still executed
in our Phase 1 test — Claude Code v2.1.84 does not block non-Bash tools
that are omitted from `--allowedTools`. This means `--allowedTools` is
primarily a Bash command filter, not a full tool blocklist.

## 2. Disallowed-call behavior

Not directly tested (Claude did not attempt any blocked Bash commands
during the live run). The model stayed within the allowed prefixes
throughout both phases without attempting disallowed commands.

Observation: `Skill` and `Agent` tool calls are not blocked by
`--allowedTools` even when not listed. Claude loaded the `clickhouse`,
`k8s`, and `gh` skills via `Skill` tool during Phase 1 despite Skill
not being in the allowedTools string. This consumed extra turns.

## 3. Minimum allowedTools string for Phase 1

Tested Phase 1 string (successful, 11 turns, $0.22):
```
Bash(clickhouse client*),Bash(kubectl get*),Bash(kubectl describe*),Bash(kubectl logs*),Bash(gh pr edit*),Bash(gh pr comment*),Read,Write,Glob,Grep
```

All Bash prefixes were exercised:
- `clickhouse client --query "..."` — 8 queries for error rates, exceptions, traces, timeline
- `kubectl get pods` — pod health check
- `kubectl describe pod` — resource/restart details
- `gh pr edit` — wrote investigation findings to PR body

`Bash(kubectl logs*)` was available but not used — the model found
sufficient signal from ClickHouse logs and didn't need raw pod logs.

`Read` and `Glob` were essential — Phase 1 read `inventory.js` and
`checkout.js` to identify the TOCTOU race condition in source code.

## Phase 2 observations

Phase 2 string (partial success, 11 turns, $0.20):
```
Bash(git*),Bash(gh pr edit*),Bash(gh pr comment*),Edit,Write,Read,Glob,Grep
```

- `Edit` was used to fix `inventory.js` (removed the async sleep between
  check and write, eliminating the race condition)
- `Bash(git pull --rebase ...)` executed successfully
- Hit max-turns before completing commit + push + incident report
- Recommendation: increase `--max-turns` to 15 for Phase 2

---

*Updated 2026-05-17 after first live run against otel-demo stack.*
