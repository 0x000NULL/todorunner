# Run-Todos.ps1

An autonomous todo-runner for [Claude Code](https://claude.com/code). Drop a
`todo.md` in a project, invoke the script, and Claude works through every
unchecked item using a **plan → execute** split with fresh sessions per phase.
Built for overnight-style runs where you want to come back to real progress
instead of a dumpster fire.

Targets **pwsh 7+** on Windows, Linux, and macOS. On Windows the binary may
resolve as `claude.cmd`; `Get-Command claude` handles both.

## Quick start

```powershell
cd my-project
# must be a git repo — rollback depends on it
git init; git add -A; git commit -m "baseline"

@"
- [ ] Add a health check endpoint at /healthz that returns 200 OK
- [ ] Bump the Node version in package.json to 22
- [ ] Add a CONTRIBUTING.md with setup instructions
"@ | Set-Content ./todo.md

pwsh -File ../Run-Todos.ps1
```

## todo.md format

Top-level markdown checkboxes, one item per line. The dash must be at
column 0:

```markdown
- [ ] Unchecked item (the runner will work on this)
- [x] Checked item (skipped)
- [ ] Multi-step task with sub-bullets
  - [ ] First sub-step (passed as spec context to the parent's plan)
  - [ ] Second sub-step (parent ticks; sub-bullets stay [ ])
```

The parser is strict: only `- [ ]` / `- [x]` lines starting at column 0
become tasks. Indented `- [ ]` checkboxes are **collected** and passed to
the planner as a "this item bundles N descriptive sub-steps" block, so
the agent treats them as one cohesive plan rather than splitting them
into separate items (which would multiply cost and produce the same
"is this part of one function or many?" planning blocker for each
sub-step). When the parent passes verify and gets ticked, the sub-bullet
checkboxes intentionally stay `[ ]` — they're documentation, not
separately verifiable units. The item text is slugged (lowercase,
non-alphanum → `-`, truncated to 60 chars at the nearest word boundary)
to produce a stable plan filename.

## Why two phases

Each todo item runs through two **separate `claude -p` invocations** with no
shared context:

1. **Phase 1 — PLAN** (`--permission-mode default` + only `Read,Glob,Grep`
   allowed — effectively read-only). Claude researches the codebase, produces
   a structured plan as its text reply, which the runner saves to
   `.claude/plans/<slug>.md` with goal, steps, files, risks, verify commands,
   assumptions, and blockers. Cannot edit files or run Bash.

   *Note:* we deliberately don't use `--permission-mode plan`. In headless
   that triggers Claude's `ExitPlanMode` tool, which writes the plan to a
   different location and leaves only a summary in the JSON `result`. By
   sticking to `default` mode with read-only allowed tools, the plan ends
   up in `result` where the runner can capture it.

2. **Phase 2 — EXECUTE** (`--permission-mode auto`, edit tools). Fresh
   session, no memory of phase 1 except the plan text injected into the
   prompt. Claude executes the plan, leaving changes staged. **Does not
   commit.** The runner commits after independently re-running the verify
   commands.

**Why split the context:** in a single long session, Claude's mental model
drifts. It discovers something mid-implementation, rethinks the plan, and by
the time it finishes item 3 it has forgotten what it decided for item 1. By
forcing a plan first (cheap, stable, reviewable) and then executing with a
clean context, the plan acts as a contract the execute phase must follow.

**Why the plans live on disk:** `.claude/plans/<slug>.md` is human-readable
and gets tracked in git. If a run goes wrong you can diff what Claude
*thought* it would do against what actually happened.

## Why `auto` mode, not `bypassPermissions`

Claude Code's `auto` mode uses a safety classifier to auto-approve routine
actions and prompt (or, in headless, abort) on risky ones. In headless `-p`,
the classifier aborts the session after **3 consecutive or 20 total
denials** — a safety net. `bypassPermissions` has no such brake and will
happily `rm -rf` on a misread.

The four failure modes below all depend on this classifier being active.

## Smart-runner safeguards

Beyond the four classifier-driven failure modes below, the runner has five
guardrails that prevent specific cost-burning loops we hit on real runs:

1. **Container/leaf parsing.** A parent `- [ ]` with indented `- [ ]`
   sub-bullets is treated as one item; the sub-bullets ride along as
   plan-prompt spec context. Avoids each sub-step asking "is this part of
   one function or seven?" as a planning blocker.
2. **Verify-fail circuit breaker.** Same-fingerprint verify failures across
   N consecutive items (default 3) or M total times (default 5) write
   `HALT.md` and exit code 5. Stops indefinite retries on the same compile
   error.
3. **Constrained verify grammar.** The plan prompt forbids verify
   commands that grep `TODO.md`/`needs-review.md`/`HALT.md`/`.claude/*` (runner
   bookkeeping that drifts), invoke `cargo run`/`npm start`/etc., or nest
   `pwsh -Command`. A plan with a forbidden verify is rejected before
   phase 2; the runner re-plans on next pass.
4. **Plan-staleness check before `-SkipPlan` reuse.** Before reusing a
   cached plan, the runner runs its verify gate. If it already passes, the
   item auto-ticks (work landed externally between runs). If it fails on a
   forbidden-grep pattern, the plan is discarded and regenerated.
5. **Pre-flight system-dep probe.** Scans `Cargo.toml` at startup for
   crates that need C-library system deps (`tesseract`, `openssl-sys`,
   `rdkafka-sys`); on miss, writes `HALT.md` with install instructions
   and exits 6 before any item runs. Bypass with `-SkipDepProbe`.

## The four failure modes

| Mode | What it looks like | Action |
|---|---|---|
| **(a) auto-mode blocked** | Classifier aborted the session mid-work. `is_error: true` + denial keywords in `result` + low `num_turns`. | Item routed to `needs-review.md` with reason "auto-mode blocked". Rollback runs. Three in a row halts the runner. |
| **(b) needs clarification** | Model stopped early asking a question (headless can't actually ask). `is_error: false` + `num_turns < 3` + "I need to know…" patterns. | Routed with reason "needs clarification" + the captured question. |
| **(c) verify failed** | Runner's independent run of the plan's Verify commands fails, regardless of what Claude claimed. | Rollback runs; routed with reason "verify failed" + the verify command output. |
| **(d) cost ceiling** | `plan_cost + execute_cost ≥ CostCeilingPerItem`. | Rollback if phase 2 ran; routed with reason "cost ceiling". |

In all four cases the item stays unchecked in `todo.md` so it's still visible,
and it's appended to `needs-review.md` as a triage block. The runner does
**not** halt on a single failure — only on infra errors, foundational
blockers, three consecutive case-(a) failures, or MaxIterations.

## Blocker workflow

Phase 1 emits a `Blockers` section (possibly `Blockers: none`). Each blocker
has a **severity**:

- **local** — only affects this item. Routed to needs-review, continue.
- **cross-item** — other pending items probably touch the same area. Routed
  to needs-review AND keywords added to `.claude/todo-runner/blockers.json`.
  Future items whose text matches any registered keyword are skipped too
  ("blocked by pending question on `<slug>`"). When the blocking item
  resolves and completes, its registry entry is removed.
- **foundational** — affects the whole codebase. Runner writes `HALT.md`
  and exits with code 2.

Claude is required to supply a `default_assumption` for every blocker. That
feeds the `-ProceedOnBlockers` escape hatch.

### Resolving blockers

Edit `needs-review.md`, find the `- Resolution:` line under each blocker,
and fill in the answer:

```markdown
### Blocker: db-choice
- severity: cross-item
- affects: database, db, orm
- question: Which ORM should we use?
- default_assumption: Prisma
- Resolution: Use Drizzle — we decided this yesterday
```

Re-run the script. Items where **every** blocker has a non-empty Resolution
line get re-queued, and the resolutions are injected into a fresh phase-1
prompt as "Previously blocked, now resolved". Items with any unresolved
blocker are still skipped — unless you also pass `-SkipPlan` to force a
retry.

### `-ProceedOnBlockers` (escape hatch)

If you want to just barrel through and let Claude use its default
assumptions for local + cross-item blockers, pass `-ProceedOnBlockers`. The
forced assumptions are:

- Logged loudly to `runs.jsonl` with the tag `ASSUMPTION_FORCED`.
- Spliced into the commit message as `ASSUMED: <question> → <default>` so
  they're grep-able in `git log`.

Foundational blockers still halt — no escape for those.

## `-PlanAllFirst` (recommended for ≥20 items)

Runs phase 1 on *every* eligible item before running phase 2 on any of
them. You get one aggregated `needs-review.md` upfront — answer all the
questions in one sitting, then re-run. Much better than discovering
blockers one at a time on an overnight run.

```powershell
pwsh -File ./Run-Todos.ps1 -PlanAllFirst
# answer questions in needs-review.md…
pwsh -File ./Run-Todos.ps1 -PlanAllFirst  # phase 2 now runs
```

Combine with `-DryRunPlan` to plan-only without execution.

## All parameters

| Param | Default | Purpose |
|---|---|---|
| `-CostCeilingPerItem` | `3.00` | USD ceiling for plan + execute combined |
| `-MaxIterations` | `50` | Max phase-1 invocations in this run |
| `-TodoFile` | `./todo.md` | Input |
| `-NeedsReviewFile` | `./needs-review.md` | Triage output |
| `-DryRunPlan` | off | Run only phase 1, skip execute |
| `-SkipPlan` | off | Reuse existing plan files; also forces retry of items in needs-review |
| `-ProceedOnBlockers` | off | Proceed using `default_assumption` for local/cross-item blockers |
| `-PlanAllFirst` | off | Plan every item before executing any |
| `-RollbackStrategy` | `stash` | `stash` or `reset` (for verify-fail and cost-ceiling rollbacks) |
| `-MaxTurns` | `30` | Per-`claude -p` invocation turn limit |
| `-SkipDepProbe` | off | Skip the startup system-dep probe (use for non-default toolchains like MinGW/MSYS2 with custom prefixes) |
| `-VerifyFingerprintConsecLimit` | `3` | Halt after this many consecutive same-error verify fails |
| `-VerifyFingerprintTotalLimit` | `5` | Halt after this many total occurrences of any one verify-fail fingerprint |

## Running detached

**Windows:**

```powershell
Start-Process pwsh -ArgumentList '-File','./Run-Todos.ps1' -WindowStyle Hidden -RedirectStandardOutput run.log -RedirectStandardError run.err
```

**Linux/macOS:**

```bash
nohup pwsh ./Run-Todos.ps1 > log.txt 2>&1 &
```

Tail `.claude/todo-runner/runs.jsonl` for progress during the run.

## Recovery

1. Re-runs pick up where `todo.md` left off (anything `[x]` is skipped).
2. Items in `needs-review.md` with unresolved blockers are skipped.
3. Add `Resolution:` lines, re-run — resolved items get re-queued with the
   resolutions injected into a fresh phase-1 prompt.
4. To retry a failed item that had no blockers (e.g., verify failed,
   cost ceiling), delete its `## <slug>` section from `needs-review.md`
   and re-run, or pass `-SkipPlan` to force retry.
5. Rolled-back changes sit in `git stash list` (one stash per failed item,
   named `todo-runner rollback <slug>`). Inspect with `git stash show -p`.

## Git hygiene

**Strong recommendation:** run in a worktree, not in your main working copy.

```bash
git worktree add ../feature-run main
cd ../feature-run
pwsh ./Run-Todos.ps1
```

That way the runner's commits, stashes, and staged changes don't collide
with your uncommitted work in the main tree. When the run is done:

```bash
cd ../main
git merge feature-run     # or cherry-pick the good commits
git worktree remove ../feature-run
```

The runner warns if the working tree is dirty at startup for this reason.

## Observability

### Runs log (`.claude/todo-runner/runs.jsonl`)

One JSON line per `claude -p` invocation, plus lines for forced-assumption
events. Fields:

```json
{"ts_utc":"2026-04-24T18:30:12.5Z","phase":"plan","slug":"add-healthz",
 "exit_code":0,"total_cost_usd":0.41,"num_turns":6,"is_error":false,
 "subtype":"success","stop_reason":"end_turn","session_id":"…"}
```

Tail it live during a detached run:

```powershell
Get-Content .claude/todo-runner/runs.jsonl -Wait
```

### Per-item summary line

```
[3/27] add-healthz: plan $0.42 / execute $1.18 / verified / committed abc1234
```

### needs-review.md schema

Per item:

```markdown
## <slug>
- Item: <verbatim todo text>
- Reason: <classifier reason>
- Timestamp: <ISO UTC>

### Detail
```
<raw output from Claude or verify command>
```

### Blocker: <name>
- severity: …
- affects: …
- question: …
- default_assumption: …
- Resolution: <-- you fill this in

---
```

### HALT.md

Only written when a foundational blocker is found (or in `-PlanAllFirst`,
any foundational blocker across all items). Lists the questions you need
to answer before the runner can continue.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Clean finish |
| 1 | Infra error (claude missing, not a git repo, todo unreadable) |
| 2 | Foundational blocker |
| 3 | Three consecutive classifier terminations |
| 4 | MaxIterations reached |
| 5 | Verify-fail circuit breaker tripped (same error repeated past `-VerifyFingerprintConsecLimit` / `-VerifyFingerprintTotalLimit`) |
| 6 | Pre-flight system-dep probe found a missing C library (see HALT.md for install instructions; or pass `-SkipDepProbe`) |

## Layout after a run

```
./todo.md                         # some items now [x]
./needs-review.md                 # created if any triage needed
./HALT.md                         # only on foundational blocker
./.claude/
  plans/
    add-healthz.md                # one per item
    bump-node-version.md
  todo-runner/
    runs.jsonl                    # append-only log
    blockers.json                 # cross-item blocker registry
```

## Known limits

- Headless Claude cannot actually ask questions. Detection of "needs
  clarification" relies on pattern-matching the model's text reply; some
  phrasings may slip through and look like successful completions.
- The classifier-terminated heuristic (`is_error: true` + denial keywords
  + low `num_turns`) is an approximation. The JSON output schema does not
  yet include a dedicated subtype for classifier denials.
- Verify commands run in `pwsh 7+`. Shell builtins specific to bash/zsh
  will not work — use cross-platform tooling (`npm test`, `pytest`,
  `go test`, `cargo test`, `Test-Path`).
- Per-item `max-turns` is hard-coded at 30. Enough for most items;
  unusually large items may hit it and surface as a non-classifier error.
- Phase 2's auto mode requires Max/Team/Enterprise plan with Sonnet 4.6 /
  Opus 4.6 / Opus 4.7. On other plans, change Phase 2's mode to
  `acceptEdits` (in `Run-Todos.ps1`, `Invoke-Phase2`) — but you lose the
  classifier safety net.
