# /ship Learnings — Hook-Enforced RECALL + CAPTURE

**Date:** 2026-04-17
**Status:** Draft — awaiting implementation plan

## Problem

`.claude/ship-learnings/<phase>.md` files are not being reliably updated across `/ship` runs, so past mistakes get repeated and "clean-pass" success patterns are never captured.

Observed state in production:

| Pipeline | State | Learning files |
| --- | --- | --- |
| `/Users/prashant/sdk/` | `STEP_1A=done, STEP_1B=done` | All 7 files empty (template only) |
| `/Users/prashant/Code/ship-pipeline/` | (no active pipeline) | All 7 files empty |
| `/Users/prashant/conductor/.../milan-v1/` | `STEP_1A=done, STEP_1B=done` | Has content — but only from earlier runs that progressed past Phase 1 |

### Root-cause gaps in `hooks/ship-gate.sh`

1. **Capture is advisory, not blocking.** The `[AUTO-LEARN]` message is emitted as PostToolUse `additionalContext`. Claude can ignore it.
2. **Gate check is marker-only.** The PRE-hook greps for `LEARNINGS_<PHASE>=done` in the state file and nothing else. A bare `echo 'LEARNINGS_PLAN=done' >> .ship-pipeline-state` passes the gate without any content being written. Commit 096e691 ("require actual learning content before gate marker") updated instructional text but added **zero enforcement**.
3. **Pipeline-abandonment.** Phase 1 ends with "WAIT FOR USER CONFIRMATION BEFORE PROCEEDING TO PHASE 2". If the user doesn't proceed, Phase 2 never starts, so the PRE-gate never fires and learnings are lost. This is the most common real-world failure (both `sdk` and `milan-v1` stopped here).
4. **No dedup enforcement.** The SKILL.md protocol says "compare before writing, update Seen count on duplicates". The hook can't see whether Claude followed it.
5. **RECALL is advisory.** The PRE-hook only reminds Claude to read the file. If Claude skips the Read, it proceeds without past context.

## Goals

1. Claude **always sees** past learnings before starting a phase — repeat mistakes must become impossible.
2. Each phase **must capture** a learning entry before the next phase or any other work proceeds.
3. Duplicate learnings are prevented by structural checks, not by trusting Claude's self-discipline.
4. Gate cannot be bypassed by writing the marker without content.

## Non-goals

- Semantic evaluation of learning quality (a hook can't judge whether a learning is "good").
- Reading learnings from external sources (Linear tickets, Slack threads, etc.).
- Changing phase order or the 7-phase structure of `/ship`.

## Design

### 1. RECALL — auto-inject learning content

**Where:** PRE-hook, first step of each phase (`STEP_1A`, `STEP_2`, `STEP_3A`, `STEP_4B`, `STEP_5A`, `STEP_6`, `STEP_7A`).

**Behavior:** Hook reads `.claude/ship-learnings/<phase>.md` and embeds the full file content into `additionalContext`. Claude sees past learnings as context without performing a separate Read.

**additionalContext format:**

```
[AUTO-LEARN] RECALL: Past learnings for this phase (apply them — do not repeat these mistakes):

<full content of .claude/ship-learnings/<phase>.md>

---
Apply the "Resolution pattern" from each entry before proceeding.
```

**Size management:** If a learning file exceeds 200 lines, the hook truncates and appends `[... truncated, read full file for details ...]`. The SKILL.md's 20-entry consolidation rule is the primary defense against size growth.

### 2. Dedup — inject existing headings at capture time

**Where:** POST-hook of phase-end steps (`STEP_1B`, `STEP_2`, `STEP_3C`, `STEP_4B`, `STEP_5C`, `STEP_6`, `STEP_7B`).

**Behavior:** Hook extracts every line matching `^### ` from the learning file and includes them verbatim in the `[AUTO-LEARN] HARD GATE` capture message.

**Capture message format:**

```
[AUTO-LEARN] HARD GATE: Capture learnings before proceeding.

Existing entry headings in .claude/ship-learnings/<phase>.md:
  - <heading 1>
  - <heading 2>
  - ...

Dedup rules:
  - If your learning matches one of the headings above: update that entry's **Seen:** count and add today's date. Do NOT append a new entry.
  - If genuinely new: append with a new `###` heading.
  - If clean pass: write a brief "what went right" entry (approach that worked, pattern that avoided past issues).

After writing, run: echo 'LEARNINGS_<PHASE>=done' >> .ship-pipeline-state

The next phase AND all other tool calls are BLOCKED until:
  (a) the learning file grows beyond its baseline, AND
  (b) the LEARNINGS_<PHASE>=done marker exists.
```

### 3. Content-verified gate — heading-count / Seen-date check

**Pipeline init:** When `/ship` initializes the state file, it snapshots each learning file's `###` heading count:

```bash
for phase in plan tdd review test verify eval deliver; do
  file=".claude/ship-learnings/${phase}.md"
  headings=$(grep -c "^### " "$file" 2>/dev/null || echo 0)
  echo "${phase^^}_BASELINE_HEADINGS=${headings}" >> .ship-pipeline-state
done
```

Heading count is chosen over line count because it's robust against consolidation: if Claude merges 5 entries into 1 broader rule, the line count may drop but a new canonical heading still exists.

**Gate check:** Replace the current `step_done()` check for `LEARNINGS_<PHASE>` with a two-condition wrapper. Either condition satisfies the gate:

```bash
learnings_gate_met() {
  local phase="$1"  # PLAN, TDD, REVIEW, ...
  local phase_lower
  phase_lower=$(echo "$phase" | tr '[:upper:]' '[:lower:]')
  local file=".claude/ship-learnings/${phase_lower}.md"
  local today
  today=$(date +%Y-%m-%d)

  # Marker must exist in state
  grep -qE "^LEARNINGS_${phase}=(done|skipped)$" "$STATE_FILE" 2>/dev/null || return 1

  # Condition A: new heading added since init
  local baseline
  baseline=$(grep "^${phase}_BASELINE_HEADINGS=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
  local current
  current=$(grep -c "^### " "$file" 2>/dev/null || echo 0)
  [[ "$current" -gt "${baseline:-0}" ]] && return 0

  # Condition B: an existing entry's **Seen:** line contains today's date
  grep -qE "^\*\*Seen:\*\*.*${today}" "$file" && return 0

  return 1
}
```

Block messages specify which condition failed:
- `"Marker missing"` → gate marker not written
- `"Marker exists, but no new entry and no **Seen:** line updated today"` → content check failed

### 4. Abandonment blocker — post-phase lock

**Where:** POST-hook of phase-end steps, and global PRE-hook for all tool types.

**Behavior:**

- After recording a phase-end step, POST-hook writes `UNCLAIMED_LEARNINGS=<phase_lower>` to the state file.
- Global PRE-hook (expanded matcher: `Skill`, `Agent`, `Bash`, `Edit`, `Write`, `Read`) checks for `UNCLAIMED_LEARNINGS`.
  - If set, block the tool call with a capture-required message, **except** the following allowed operations:
    - `Read` on any `.claude/ship-learnings/*.md` file
    - `Edit` / `Write` targeting `.claude/ship-learnings/<that phase>.md`
    - `Bash` commands that only append to `.ship-pipeline-state` or only write to the learning file (pattern-matched)
  - Text replies to the user (no tool use) remain unblocked.
- Clearing the lock: after POST-hook detects both conditions met (`LEARNINGS_<PHASE>=done` AND file grew), it removes the `UNCLAIMED_LEARNINGS` line from state.

Because clearing happens in a POST-hook, the mechanism is:
- After Claude writes to the learning file, the next Bash call that writes `LEARNINGS_<PHASE>=done` to state triggers POST-hook → hook verifies both conditions → removes `UNCLAIMED_LEARNINGS`.

### 5. Phase-start reminder when learnings exist

When `additionalContext` is injected (RECALL), also append a one-line reminder that learnings were just loaded, so Claude doesn't re-read the file unnecessarily.

## State file schema changes

Adds these keys (all written at pipeline init or by hooks):

```
PLAN_BASELINE_HEADINGS=<int>
TDD_BASELINE_HEADINGS=<int>
REVIEW_BASELINE_HEADINGS=<int>
TEST_BASELINE_HEADINGS=<int>
VERIFY_BASELINE_HEADINGS=<int>
EVAL_BASELINE_HEADINGS=<int>
DELIVER_BASELINE_HEADINGS=<int>
UNCLAIMED_LEARNINGS=<phase_lower>   # present when capture owed; absent when cleared
```

Existing keys (`STEP_*`, `STEP_*_SUMMARY`, `LEARNINGS_*`, `MOBILE_APP`, `# Task:`) are unchanged.

## Hook settings changes

In `~/.claude/settings.json`, the PostToolUse and PreToolUse matcher set must expand to cover the abandonment-lock mechanism:

- Current PreToolUse matchers: `Skill` → `ship-gate.sh pre`.
- Required: also match `Agent`, `Bash`, `Edit`, `Write` so the `UNCLAIMED_LEARNINGS` check fires on any tool call.

The `setup.sh` script (which installs hook registrations) must be updated to register all needed matchers.

## Affected files

| File | Change |
| --- | --- |
| `hooks/ship-gate.sh` | RECALL auto-inject, heading extraction, content-verified gate, lock logic |
| `commands/ship.md` | State file init block writes `<PHASE>_BASELINE_LINES` |
| `skills/ship/SKILL.md` | Same init block; update "gate rule" table to describe content check |
| `setup.sh` | Register expanded PreToolUse matchers; idempotent updates |
| `~/.claude/commands/ship.md` | Synced copy — same ship.md change |

## Edge cases

1. **Learning file deleted mid-pipeline.** Gate fails because `current=0 < baseline`. Correct behavior — capture required before proceeding.
2. **Learning file edited by human outside the pipeline.** Baseline reflects the state at pipeline start, so any growth counts. Human edits before pipeline start are folded into the baseline. Acceptable.
3. **Phase skipped by user approval** (`STEP_<X>=skipped`). Current logic already treats skipped as done for prereqs. Keep that — learnings apply to completed phases, and if a phase was skipped, there's no capture duty.
4. **Pipeline re-runs without removing state file.** Init block only writes baseline lines if they're not already present, so baselines carry forward across re-runs. Alternative: reset baselines at init every time, so each run's capture is enforced fresh. **Decision: reset on init** (re-run is a new pipeline instance — new learnings expected).
5. **Consolidation reduces heading count.** If Claude consolidates entries into fewer broader rules, current heading count could match or dip below baseline. Condition B (today's date in a `**Seen:**` line) covers this: any edit that updates Seen on an existing entry — including the merged survivor — passes the gate.

## Test plan

Add to `hooks/ship-gate.test.sh` (the existing test harness referenced in commit 0890b92):

- **T11**: Pipeline init writes `<PHASE>_BASELINE_HEADINGS=N` for each of 7 phases.
- **T12**: PRE-hook for `STEP_2` (TDD) injects plan.md content when the file has non-template content.
- **T13**: POST-hook for `STEP_1B` sets `UNCLAIMED_LEARNINGS=plan` after recording.
- **T14**: When `UNCLAIMED_LEARNINGS=plan` is set, PRE-hook for Bash command unrelated to learnings is blocked.
- **T15**: When `UNCLAIMED_LEARNINGS=plan` is set, PRE-hook for Edit of `.claude/ship-learnings/plan.md` is allowed.
- **T16**: After writing a new `### ` entry to plan.md AND `LEARNINGS_PLAN=done` to state, POST-hook clears `UNCLAIMED_LEARNINGS`.
- **T17**: After writing ONLY `LEARNINGS_PLAN=done` without new headings, gate remains unmet (closes the marker-only loophole).
- **T18**: After updating an existing entry's `**Seen:**` line with today's date, gate becomes met (Condition B).
- **T19**: PRE-hook capture message for `STEP_2` includes the existing `###` headings from tdd.md.

All 17 existing tests must continue to pass.

## Rollout

1. Implement + tests.
2. Run against the `ship-pipeline` repo itself (meta-test — this repo uses `/ship` on itself).
3. Update the "stale copies" referenced in commit 1af63f0 (`~/.claude/commands/ship.md`, `~/.claude/commands/ship-it.md`) with the same logic.
4. Document the change in README + a CHANGELOG entry.
