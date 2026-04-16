# Ship Learnings Hook Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/ship` learning capture reliable by replacing advisory hooks with hard enforcement: auto-inject past learnings for RECALL, inject existing headings for dedup on CAPTURE, verify file content (not just marker), and lock tool use after each phase until capture completes.

**Architecture:** All changes are in `hooks/ship-gate.sh` plus supporting updates in `commands/ship.md`, `skills/ship/SKILL.md`, and `setup.sh`. The hook adds a `learnings_gate_met()` function that checks the state-file marker AND file content (new `###` heading since baseline OR a `**Seen:**` line updated today). Pipeline init snapshots heading counts as `<PHASE>_BASELINE_HEADINGS`. Phase-end POST-hook writes `UNCLAIMED_LEARNINGS=<phase>` which blocks every non-learning tool call in the next PRE-hook until both conditions clear.

**Tech Stack:** Bash, JSON via jq, Claude Code PreToolUse/PostToolUse hook API.

**Spec:** `docs/superpowers/specs/2026-04-17-ship-learnings-hook-enforcement-design.md`

---

## File Map

### Files to modify

| File | What changes |
|------|-------------|
| `hooks/ship-gate.sh` | Add `learnings_gate_met()`, `maybe_clear_unclaimed()`; rewrite RECALL block to inject file content; rewrite CAPTURE block to include headings; handle `UNCLAIMED_LEARNINGS` lock; expand to handle `Bash`/`Edit`/`Write` matchers |
| `commands/ship.md` | Update init block to write `*_BASELINE_HEADINGS` to state file |
| `skills/ship/SKILL.md` | Same init block update (mirrored) |
| `setup.sh` | Register `Bash`/`Edit`/`Write` PreToolUse matchers; add test cases T17-T24 |
| `~/.claude/commands/ship.md` | Synced automatically by setup.sh from `commands/ship.md` |

### No new files

All behavior lives in existing files.

---

## Decomposition

10 tasks, ordered so later tasks build on earlier ones. TDD where practical: test via the existing pipe-test harness in `setup.sh`. Commit after each task.

---

### Task 1: Add `learnings_gate_met()` helper and wire it into `step_done()`

**Files:**
- Modify: `hooks/ship-gate.sh:104-107` (existing `step_done()`)

**Context:** `step_done()` is called from `get_prereqs()` loop in the PRE-hook. When a prereq is `LEARNINGS_<PHASE>`, the current grep-for-marker check is toothless. We intercept `LEARNINGS_*` calls and route them through a content-verified check; everything else stays as-is.

- [ ] **Step 1: Add `learnings_gate_met()` function above `step_done()`**

Edit `hooks/ship-gate.sh`, inserting before line 104 (before the existing `step_done()`):

```bash
# ── Check if learning capture is complete for a phase ──
# Requires BOTH: marker in state file AND actual file content change
# (new heading since baseline OR an existing **Seen:** line updated today).
learnings_gate_met() {
  local phase="$1"  # PLAN, TDD, REVIEW, TEST, VERIFY, EVAL, DELIVER
  local phase_lower
  phase_lower=$(echo "$phase" | tr '[:upper:]' '[:lower:]')
  local file=".claude/ship-learnings/${phase_lower}.md"
  local today
  today=$(date +%Y-%m-%d)

  # Marker must exist in state
  grep -qE "^LEARNINGS_${phase}=(done|skipped)$" "$STATE_FILE" 2>/dev/null || return 1

  # Skipped counts as met (user-approved skip)
  grep -qE "^LEARNINGS_${phase}=skipped$" "$STATE_FILE" 2>/dev/null && return 0

  # Condition A: heading count grew since init
  local baseline
  baseline=$(grep "^${phase}_BASELINE_HEADINGS=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
  local current
  current=$(grep -c "^### " "$file" 2>/dev/null || echo 0)
  if [[ "$current" -gt "${baseline:-0}" ]]; then
    return 0
  fi

  # Condition B: an existing **Seen:** line contains today's date
  grep -qE "^\*\*Seen:\*\*.*${today}" "$file" 2>/dev/null && return 0

  return 1
}
```

- [ ] **Step 2: Update `step_done()` to delegate `LEARNINGS_*` checks**

Replace the existing `step_done()` block (lines 104-107) with:

```bash
# ── Check if a step is recorded as done (or user-approved skip) ──
step_done() {
  # LEARNINGS_* prereqs use content-verified gate
  if [[ "$1" == LEARNINGS_* ]]; then
    learnings_gate_met "${1#LEARNINGS_}"
    return $?
  fi
  grep -qE "^$1=(done|skipped)$" "$STATE_FILE" 2>/dev/null
}
```

- [ ] **Step 3: Smoke-test the hook still runs**

Run: `bash hooks/ship-gate.sh pre </dev/null`
Expected: exits 0 with no output (no state file present).

- [ ] **Step 4: Commit**

```bash
git add hooks/ship-gate.sh
git commit -m "refactor(ship-gate): add content-verified learnings_gate_met()

Replaces toothless marker-only check for LEARNINGS_* prereqs.
Gate passes only when the state marker exists AND either:
  - a new ### heading was added since pipeline init, or
  - an existing **Seen:** line carries today's date.

step_done() now delegates LEARNINGS_* lookups to the new helper
and leaves all other step checks unchanged."
```

---

### Task 2: Write baseline heading counts at pipeline init

**Files:**
- Modify: `commands/ship.md:31-40` (init block)
- Modify: `skills/ship/SKILL.md:36-45` (mirrored init block)

**Context:** The pipeline state file is created at the start of `/ship`. Each learning file's `###` heading count must be snapshotted here so `learnings_gate_met()` knows the baseline.

- [ ] **Step 1: Update `commands/ship.md` init block**

Find this block (lines 31-40):

```bash
# Initialize learnings directory
mkdir -p .claude/ship-learnings
for phase in plan tdd review test verify eval deliver; do
  if [[ ! -f ".claude/ship-learnings/${phase}.md" ]]; then
    echo "# /ship Learnings — ${phase} phase" > ".claude/ship-learnings/${phase}.md"
    echo "" >> ".claude/ship-learnings/${phase}.md"
    echo "Learnings are auto-captured after each /ship run. Read before starting the phase." >> ".claude/ship-learnings/${phase}.md"
    echo "" >> ".claude/ship-learnings/${phase}.md"
  fi
done
```

Replace with:

```bash
# Initialize learnings directory
mkdir -p .claude/ship-learnings
for phase in plan tdd review test verify eval deliver; do
  if [[ ! -f ".claude/ship-learnings/${phase}.md" ]]; then
    echo "# /ship Learnings — ${phase} phase" > ".claude/ship-learnings/${phase}.md"
    echo "" >> ".claude/ship-learnings/${phase}.md"
    echo "Learnings are auto-captured after each /ship run. Read before starting the phase." >> ".claude/ship-learnings/${phase}.md"
    echo "" >> ".claude/ship-learnings/${phase}.md"
  fi
  # Snapshot heading count so the hook can detect new learnings captured during this run.
  # Reset on every init: a re-run is a new pipeline instance expecting its own learning.
  headings=$(grep -c "^### " ".claude/ship-learnings/${phase}.md" 2>/dev/null || echo 0)
  # Remove any stale baseline line, then write the fresh one
  if [[ -f .ship-pipeline-state ]]; then
    sed -i.bak "/^$(echo "$phase" | tr '[:lower:]' '[:upper:]')_BASELINE_HEADINGS=/d" .ship-pipeline-state
    rm -f .ship-pipeline-state.bak
  fi
  echo "$(echo "$phase" | tr '[:lower:]' '[:upper:]')_BASELINE_HEADINGS=${headings}" >> .ship-pipeline-state
done
```

- [ ] **Step 2: Mirror the same change in `skills/ship/SKILL.md`**

Apply the identical substitution in `skills/ship/SKILL.md` (the block starts near line 36).

- [ ] **Step 3: Manually verify init produces the expected state file**

Run this sanity-check in a temp directory:

```bash
TMP=$(mktemp -d) && cd "$TMP"
mkdir -p .claude/ship-learnings
# Pre-seed a file with 2 headings to prove the counter works
cat > .claude/ship-learnings/plan.md <<'EOF'
# /ship Learnings — plan phase

### existing rule one

### existing rule two

EOF

# Simulate the init block (manually run the two lines that matter)
echo "# pipeline state" > .ship-pipeline-state
for phase in plan tdd review test verify eval deliver; do
  if [[ ! -f ".claude/ship-learnings/${phase}.md" ]]; then
    echo "# /ship Learnings — ${phase} phase" > ".claude/ship-learnings/${phase}.md"
    echo "" >> ".claude/ship-learnings/${phase}.md"
    echo "Learnings are auto-captured after each /ship run. Read before starting the phase." >> ".claude/ship-learnings/${phase}.md"
    echo "" >> ".claude/ship-learnings/${phase}.md"
  fi
  headings=$(grep -c "^### " ".claude/ship-learnings/${phase}.md" 2>/dev/null || echo 0)
  echo "$(echo "$phase" | tr '[:lower:]' '[:upper:]')_BASELINE_HEADINGS=${headings}" >> .ship-pipeline-state
done

cat .ship-pipeline-state
cd - && rm -rf "$TMP"
```

Expected output includes:
```
PLAN_BASELINE_HEADINGS=2
TDD_BASELINE_HEADINGS=0
REVIEW_BASELINE_HEADINGS=0
...
```

- [ ] **Step 4: Commit**

```bash
git add commands/ship.md skills/ship/SKILL.md
git commit -m "feat(ship): snapshot learning heading counts at pipeline init

Each learning file's ### heading count is written to state as
<PHASE>_BASELINE_HEADINGS=<N>. The hook compares current count to
the baseline to detect whether a new learning was captured during
this run. Baseline is reset on every init — a re-run is a new
pipeline instance that expects its own fresh learning."
```

---

### Task 3: RECALL — auto-inject learning file content into PRE-hook context

**Files:**
- Modify: `hooks/ship-gate.sh:309-336` (existing RECALL reminder block)

**Context:** Currently the PRE-hook emits a reminder like "Read `.claude/ship-learnings/plan.md`". Claude can skip the Read. Replace it with a hook that reads the file itself and embeds up to 200 lines of content directly in `additionalContext` — guaranteed delivery to Claude's context.

- [ ] **Step 1: Replace the RECALL block**

Find this block in `hooks/ship-gate.sh` (starts at line 309 with the `# ── PRE: RECALL reminder` comment; ends where `exit 0` closes the inner `if`, around line 337):

```bash
  # ── PRE: RECALL reminder — read learnings before starting phase ──
  # Only remind on the FIRST step of each phase
  RECALL_FILE=""
  case "$CURRENT_STEP" in
    STEP_1A) RECALL_FILE="plan" ;;
    STEP_2)  RECALL_FILE="tdd" ;;
    STEP_3A) RECALL_FILE="review" ;;
    STEP_4B) RECALL_FILE="test" ;;
    STEP_5A) RECALL_FILE="verify" ;;
    STEP_6)  RECALL_FILE="eval" ;;
    STEP_7A) RECALL_FILE="deliver" ;;
  esac

  if [[ -n "$RECALL_FILE" && -f ".claude/ship-learnings/${RECALL_FILE}.md" ]]; then
    LEARNING_LINES=$(wc -l < ".claude/ship-learnings/${RECALL_FILE}.md" 2>/dev/null || echo "0")
    if [[ "$LEARNING_LINES" -gt 4 ]]; then
      # File has content beyond the header — remind to read it
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "[AUTO-LEARN] RECALL: Read .claude/ship-learnings/${RECALL_FILE}.md before proceeding. It contains learnings from previous /ship runs that should inform this phase."
  }
}
EOF
      exit 0
    fi
  fi
fi
```

Replace with:

```bash
  # ── PRE: RECALL — inject learnings file content into Claude's context ──
  # Fires on the FIRST step of each phase. Content is embedded in additionalContext
  # so Claude cannot miss past lessons. 200-line cap prevents runaway growth.
  RECALL_FILE=""
  case "$CURRENT_STEP" in
    STEP_1A) RECALL_FILE="plan" ;;
    STEP_2)  RECALL_FILE="tdd" ;;
    STEP_3A) RECALL_FILE="review" ;;
    STEP_4B) RECALL_FILE="test" ;;
    STEP_5A) RECALL_FILE="verify" ;;
    STEP_6)  RECALL_FILE="eval" ;;
    STEP_7A) RECALL_FILE="deliver" ;;
  esac

  if [[ -n "$RECALL_FILE" && -f ".claude/ship-learnings/${RECALL_FILE}.md" ]]; then
    LEARNING_HEADINGS=$(grep -c "^### " ".claude/ship-learnings/${RECALL_FILE}.md" 2>/dev/null || echo 0)
    if [[ "$LEARNING_HEADINGS" -gt 0 ]]; then
      # Read up to 200 lines of the learning file
      LEARNING_CONTENT=$(head -200 ".claude/ship-learnings/${RECALL_FILE}.md")
      TOTAL_LINES=$(wc -l < ".claude/ship-learnings/${RECALL_FILE}.md" 2>/dev/null || echo 0)
      TRUNCATION_NOTE=""
      if [[ "$TOTAL_LINES" -gt 200 ]]; then
        TRUNCATION_NOTE="\\n\\n[... truncated at 200 lines, read full file .claude/ship-learnings/${RECALL_FILE}.md for remaining entries ...]"
      fi

      # JSON-escape the learning content (escape backslashes, double quotes, newlines, tabs, carriage returns)
      ESCAPED_CONTENT=$(printf '%s' "$LEARNING_CONTENT" | jq -Rs .)
      # Strip surrounding quotes jq adds; we're embedding into a larger JSON string below
      ESCAPED_CONTENT=${ESCAPED_CONTENT#\"}
      ESCAPED_CONTENT=${ESCAPED_CONTENT%\"}

      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "[AUTO-LEARN] RECALL for ${RECALL_FILE} phase — apply these past learnings, do NOT repeat the mistakes below:\\n\\n${ESCAPED_CONTENT}${TRUNCATION_NOTE}\\n\\n---\\nUse each entry's 'Resolution pattern' as a pre-check before proceeding."
  }
}
EOF
      exit 0
    fi
  fi
fi
```

- [ ] **Step 2: Add a pipe-test in `setup.sh` to verify injection works**

In `setup.sh`, inside the Check 7 test block, after the existing T16 test (around line 494) but before the `info "${TESTS_PASSED}/${TESTS_TOTAL} tests passed"` line, add:

```bash
  # ── T17: RECALL auto-injects learning content ──
  # Reset state, write a minimal state with 1A done, seed a learnings file with content
  rm -f .ship-pipeline-state
  echo "STEP_1A=done" > .ship-pipeline-state
  echo "STEP_1B=done" >> .ship-pipeline-state
  echo "LEARNINGS_PLAN=done" >> .ship-pipeline-state
  # Trivially pass the new content gate: set baseline=0 with 1 existing heading
  echo "PLAN_BASELINE_HEADINGS=0" >> .ship-pipeline-state
  echo "TDD_BASELINE_HEADINGS=0" >> .ship-pipeline-state
  mkdir -p .claude/ship-learnings
  cat > .claude/ship-learnings/tdd.md <<'TDDMD'
# /ship Learnings — tdd phase

### Avoid flaky setTimeout mocks in React tests

**Seen:** 1x — 2026-04-10
**Category:** test-flake
**Example:** jest.useFakeTimers broke because of React 18 batching
**Resolution pattern:** Use jest.advanceTimersByTimeAsync + await
TDDMD

  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  RESULT=$(echo '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' | "${HOOK_SCRIPT}" pre 2>&1)
  if echo "$RESULT" | grep -q "Avoid flaky setTimeout mocks"; then
    pass "T17: RECALL injects learning file content into additionalContext"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T17: RECALL did not inject learning file content (got: ${RESULT:0:200})"
    ERRORS=$((ERRORS + 1))
  fi
```

- [ ] **Step 3: Run setup.sh pipe-test to confirm T17 passes**

Run: `bash setup.sh --check 2>&1 | grep -E "T1[567]|tests passed"`
Expected: `T17: RECALL injects learning file content into additionalContext` appears as `✓`.

- [ ] **Step 4: Commit**

```bash
git add hooks/ship-gate.sh setup.sh
git commit -m "feat(ship-gate): auto-inject learnings content for RECALL

PRE-hook of each phase's first step now reads the corresponding
.claude/ship-learnings/<phase>.md and embeds up to 200 lines
directly into additionalContext. Past lessons enter Claude's
working context automatically — no separate Read step to skip.

Adds pipe-test T17 to verify content is injected."
```

---

### Task 4: CAPTURE — inject existing `###` headings into the phase-end prompt for dedup

**Files:**
- Modify: `hooks/ship-gate.sh:404-411` (existing CAPTURE_MSG block in POST-hook)

**Context:** Currently the capture prompt says "compare against existing entries" but doesn't show what exists. Extract the `###` headings from the learning file and include them verbatim so Claude sees what's already captured and updates `**Seen:**` counts instead of creating near-duplicates.

- [ ] **Step 1: Replace the CAPTURE_MSG construction**

Find this block in `hooks/ship-gate.sh` (lines ~404-411):

```bash
  CAPTURE_MSG=""
  LEARNING_GATE=""
  if [[ "$IS_PHASE_END" == "true" && -n "$LEARNING_FILE" ]]; then
    # Map learning file to gate name
    GATE_NAME=$(echo "$LEARNING_FILE" | tr '[:lower:]' '[:upper:]')
    LEARNING_GATE="LEARNINGS_${GATE_NAME}"

    CAPTURE_MSG="\\n\\n[AUTO-LEARN] HARD GATE: You MUST capture learnings before the next phase can start.\\n  The next phase is BLOCKED until you record LEARNINGS_${GATE_NAME}=done in the state file.\\n\\n  Steps:\\n  1. Read .claude/ship-learnings/${LEARNING_FILE}.md FIRST (check existing entries)\\n  2. If same root cause exists: UPDATE its Seen count + date. Do NOT duplicate.\\n  3. If new learning: append new entry with takeaway as heading.\\n  4. If clean pass with no issues: write a clean-pass entry noting what went right (e.g., approach that worked, pattern that avoided issues). Every phase produces a learning — even success is worth recording so future runs can repeat what worked.\\n  5. If file exceeds ~20 entries: consolidate related learnings into broader rules.\\n  6. MANDATORY (only after writing to the learnings file): echo 'LEARNINGS_${GATE_NAME}=done' >> .ship-pipeline-state"
  fi
```

Replace with:

```bash
  CAPTURE_MSG=""
  LEARNING_GATE=""
  if [[ "$IS_PHASE_END" == "true" && -n "$LEARNING_FILE" ]]; then
    GATE_NAME=$(echo "$LEARNING_FILE" | tr '[:lower:]' '[:upper:]')
    LEARNING_GATE="LEARNINGS_${GATE_NAME}"

    # Extract existing ### headings so Claude can dedup against them
    EXISTING_HEADINGS=""
    if [[ -f ".claude/ship-learnings/${LEARNING_FILE}.md" ]]; then
      # Build a bullet list of existing headings (empty string if none)
      EXISTING_HEADINGS=$(grep "^### " ".claude/ship-learnings/${LEARNING_FILE}.md" 2>/dev/null | sed 's|^### |    - |' || true)
    fi

    HEADINGS_SECTION=""
    if [[ -n "$EXISTING_HEADINGS" ]]; then
      # JSON-escape the headings block
      ESCAPED_HEADINGS=$(printf '%s' "$EXISTING_HEADINGS" | jq -Rs .)
      ESCAPED_HEADINGS=${ESCAPED_HEADINGS#\"}
      ESCAPED_HEADINGS=${ESCAPED_HEADINGS%\"}
      HEADINGS_SECTION="\\n\\n  Existing entry headings in .claude/ship-learnings/${LEARNING_FILE}.md:\\n${ESCAPED_HEADINGS}\\n\\n  If your learning matches one of the headings above: UPDATE that entry's **Seen:** count and add today's date ($(date +%Y-%m-%d)). Do NOT append a near-duplicate."
    else
      HEADINGS_SECTION="\\n\\n  .claude/ship-learnings/${LEARNING_FILE}.md currently has no entries — this capture will be the first."
    fi

    CAPTURE_MSG="\\n\\n[AUTO-LEARN] HARD GATE: Capture learnings before proceeding with ANY other tool call.${HEADINGS_SECTION}\\n\\n  Capture protocol:\\n  1. If genuinely new: append a new ### heading with the takeaway as a concise rule.\\n  2. If a near-duplicate of an existing heading: update that entry's **Seen:** count + today's date instead.\\n  3. If clean pass with no issues: write a brief entry noting what went right (approach that worked, pattern that avoided past issues) — success is a learning too.\\n  4. If file exceeds ~20 entries: consolidate related entries into broader rules.\\n  5. After writing: echo 'LEARNINGS_${GATE_NAME}=done' >> .ship-pipeline-state\\n\\n  Gate passes only when BOTH: (a) the marker above is written, AND (b) either a new ### heading exists OR an existing **Seen:** line carries today's date. Marker-only is insufficient."
  fi
```

- [ ] **Step 2: Add pipe-test T18 to verify headings appear in capture message**

In `setup.sh`, after T17:

```bash
  # ── T18: CAPTURE message includes existing headings for dedup ──
  rm -f .ship-pipeline-state
  echo "STEP_1A=done" > .ship-pipeline-state
  mkdir -p .claude/ship-learnings
  cat > .claude/ship-learnings/plan.md <<'PLANMD'
# /ship Learnings — plan phase

### Existing heading ALPHA for dedup test

**Seen:** 1x — 2026-04-10
PLANMD

  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  # Simulate STEP_1B post-hook by providing a passing verdict file
  echo "PASS" > .ship-1b-verdict
  RESULT=$(echo '{"tool_name":"Skill","tool_input":{"skill":"adversarial-review"}}' | "${HOOK_SCRIPT}" post 2>&1)
  rm -f .ship-1b-verdict
  if echo "$RESULT" | grep -q "Existing heading ALPHA for dedup test"; then
    pass "T18: CAPTURE message lists existing headings"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T18: CAPTURE did not include existing headings (got: ${RESULT:0:300})"
    ERRORS=$((ERRORS + 1))
  fi
```

- [ ] **Step 3: Run setup.sh to confirm T18 passes**

Run: `bash setup.sh --check 2>&1 | grep -E "T18"`
Expected: `T18: CAPTURE message lists existing headings` → `✓`.

- [ ] **Step 4: Commit**

```bash
git add hooks/ship-gate.sh setup.sh
git commit -m "feat(ship-gate): inject existing headings into capture prompt

POST-hook of phase-end steps now extracts every ### heading from
the learning file and includes them verbatim in the capture
message. Claude sees what is already captured and updates the
**Seen:** count on duplicates instead of appending near-duplicates.

Adds pipe-test T18 to verify headings appear in the capture output."
```

---

### Task 5: Write `UNCLAIMED_LEARNINGS=<phase>` marker after phase-end step

**Files:**
- Modify: `hooks/ship-gate.sh` (POST-hook, near the CAPTURE_MSG construction)

**Context:** To block abandonment, the POST-hook must flag that capture is owed. The flag is set when a phase-end step (STEP_1B/2/3C/4B/5C/6/7B) completes and `learnings_gate_met()` is not yet satisfied.

- [ ] **Step 1: Insert UNCLAIMED_LEARNINGS write after record_step**

In `hooks/ship-gate.sh`, inside the POST block, find where `IS_PHASE_END` is set (near line 394-402). After that case block but BEFORE the `CAPTURE_MSG=""` line, add:

```bash
  # Write UNCLAIMED_LEARNINGS marker so the next PRE-hook blocks
  # non-learning tool calls until capture is complete.
  if [[ "$IS_PHASE_END" == "true" && -n "$LEARNING_FILE" ]]; then
    GATE_PHASE=$(echo "$LEARNING_FILE" | tr '[:lower:]' '[:upper:]')
    if ! learnings_gate_met "$GATE_PHASE"; then
      # Remove any stale UNCLAIMED_LEARNINGS line first, then write fresh
      sed -i.bak "/^UNCLAIMED_LEARNINGS=/d" "$STATE_FILE" 2>/dev/null
      rm -f "${STATE_FILE}.bak"
      echo "UNCLAIMED_LEARNINGS=${LEARNING_FILE}" >> "$STATE_FILE"
    fi
  fi
```

- [ ] **Step 2: Add T19 to verify marker is written**

In `setup.sh`, after T18:

```bash
  # ── T19: Phase-end POST-hook writes UNCLAIMED_LEARNINGS=<phase> ──
  rm -f .ship-pipeline-state
  echo "STEP_1A=done" > .ship-pipeline-state
  echo "PLAN_BASELINE_HEADINGS=0" >> .ship-pipeline-state
  mkdir -p .claude/ship-learnings
  printf '# plan\n\n' > .claude/ship-learnings/plan.md  # 0 headings
  echo "PASS" > .ship-1b-verdict

  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  echo '{"tool_name":"Skill","tool_input":{"skill":"adversarial-review"}}' | "${HOOK_SCRIPT}" post >/dev/null 2>&1
  rm -f .ship-1b-verdict
  if grep -q "^UNCLAIMED_LEARNINGS=plan$" .ship-pipeline-state; then
    pass "T19: Phase-end POST-hook writes UNCLAIMED_LEARNINGS=plan"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T19: UNCLAIMED_LEARNINGS not written (state: $(cat .ship-pipeline-state))"
    ERRORS=$((ERRORS + 1))
  fi
```

- [ ] **Step 3: Run setup.sh to confirm T19 passes**

Run: `bash setup.sh --check 2>&1 | grep "T19"`
Expected: `T19` → `✓`.

- [ ] **Step 4: Commit**

```bash
git add hooks/ship-gate.sh setup.sh
git commit -m "feat(ship-gate): flag UNCLAIMED_LEARNINGS after phase-end step

When a phase-end step completes (STEP_1B/2/3C/4B/5C/6/7B) without
the learning gate being satisfied, POST-hook writes
UNCLAIMED_LEARNINGS=<phase> to state. This flag is the trigger for
the PRE-hook lock added in the next task.

Adds pipe-test T19 to verify the flag is written."
```

---

### Task 6: PRE-hook blocks all non-learning tools when `UNCLAIMED_LEARNINGS` is set

**Files:**
- Modify: `hooks/ship-gate.sh` (PRE-hook, at the top of the pre-mode block)

**Context:** With the flag in place, the PRE-hook must block every tool except learning-file reads/writes and state-file appends. This catches Claude even if the next phase is never invoked (the abandonment case).

- [ ] **Step 1: Insert UNCLAIMED_LEARNINGS lock at the top of PRE mode**

In `hooks/ship-gate.sh`, right after line 217 (the `if [[ "$MODE" == "pre" && ("$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write") ]]; then` block begins), we need a block that fires earlier. Actually it needs to fire for ALL tool names, so insert BEFORE that existing edit-block.

Find the line `# ── Block code edits before Plan phase is complete ──` (around line 214) and insert this BEFORE it:

```bash
# ── UNCLAIMED_LEARNINGS lock: block all non-learning tools until capture is done ──
# Fires on every PRE hook call. Cleared by POST-hook once learnings_gate_met returns true.
if [[ "$MODE" == "pre" ]]; then
  UNCLAIMED=$(grep "^UNCLAIMED_LEARNINGS=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 | head -1)
  if [[ -n "$UNCLAIMED" ]]; then
    ALLOWED=false

    # Allow Read/Edit/Write on any .claude/ship-learnings/*.md
    if [[ "$TOOL_NAME" == "Read" || "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" ]]; then
      FPATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null || true)
      if [[ "$FPATH" == *"/.claude/ship-learnings/"*".md" || "$FPATH" == ".claude/ship-learnings/"*".md" ]]; then
        ALLOWED=true
      fi
    fi

    # Allow Bash commands that only append to state file or write to learning files
    if [[ "$TOOL_NAME" == "Bash" ]]; then
      CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
      # Whitelist: appending LEARNINGS_* to state file
      if echo "$CMD" | grep -qE '^[[:space:]]*echo[[:space:]]+.*LEARNINGS_[A-Z]+=done.*>>[[:space:]]+\.ship-pipeline-state[[:space:]]*$'; then
        ALLOWED=true
      fi
      # Whitelist: appending/editing a ship-learnings file via cat/echo/tee
      if echo "$CMD" | grep -qE '\.claude/ship-learnings/[a-z]+\.md'; then
        # Only allow if it doesn't also touch a non-learning file
        if ! echo "$CMD" | grep -qE '(rm|mv|ln|chmod|chown).*\.claude/ship-learnings'; then
          ALLOWED=true
        fi
      fi
    fi

    if [[ "$ALLOWED" != "true" ]]; then
      UNCLAIMED_UPPER=$(echo "$UNCLAIMED" | tr '[:lower:]' '[:upper:]')
      PROGRESS=$(build_progress "")
      LOG_DIR=".claude/ship-logs"
      mkdir -p "$LOG_DIR"
      LOG_FILE="${LOG_DIR}/$(date +%Y-%m-%d).log"
      echo "- [$(date +%H:%M:%S)] BLOCKED: ${TOOL_NAME} (UNCLAIMED_LEARNINGS=${UNCLAIMED})" >> "$LOG_FILE"
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SHIP PIPELINE GATE: Cannot use ${TOOL_NAME} — learning capture owed for ${UNCLAIMED} phase.\\n\\nYou must first:\\n  1. Edit .claude/ship-learnings/${UNCLAIMED}.md (add a new ### entry OR update an existing **Seen:** line with today's date)\\n  2. Run: echo 'LEARNINGS_${UNCLAIMED_UPPER}=done' >> .ship-pipeline-state\\n\\nOnly these tools are allowed until both conditions are satisfied:\\n  - Read/Edit/Write on .claude/ship-learnings/*.md\\n  - Bash commands writing to the learning file or appending LEARNINGS_${UNCLAIMED_UPPER}=done to state\\n${PROGRESS}"
  }
}
EOF
      exit 0
    fi
  fi
fi
```

- [ ] **Step 2: Add T20–T22 to verify lock behavior**

In `setup.sh`, after T19:

```bash
  # ── T20: UNCLAIMED_LEARNINGS blocks unrelated Bash ──
  rm -f .ship-pipeline-state
  echo "STEP_1A=done" > .ship-pipeline-state
  echo "STEP_1B=done" >> .ship-pipeline-state
  echo "PLAN_BASELINE_HEADINGS=0" >> .ship-pipeline-state
  echo "UNCLAIMED_LEARNINGS=plan" >> .ship-pipeline-state

  run_test "T20: UNCLAIMED_LEARNINGS blocks unrelated Bash (ls)" "deny" \
    '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' "pre"

  # ── T21: UNCLAIMED_LEARNINGS allows Edit on learning file ──
  run_test "T21: UNCLAIMED_LEARNINGS allows Edit on learning file" "allow" \
    '{"tool_name":"Edit","tool_input":{"file_path":".claude/ship-learnings/plan.md"}}' "pre"

  # ── T22: UNCLAIMED_LEARNINGS allows Bash appending LEARNINGS_PLAN=done ──
  run_test "T22: UNCLAIMED_LEARNINGS allows marker-write Bash" "allow" \
    '{"tool_name":"Bash","tool_input":{"command":"echo LEARNINGS_PLAN=done >> .ship-pipeline-state"}}' "pre"
```

- [ ] **Step 3: Run setup.sh to confirm T20–T22 pass**

Run: `bash setup.sh --check 2>&1 | grep -E "T2[012]"`
Expected: all three pass.

- [ ] **Step 4: Commit**

```bash
git add hooks/ship-gate.sh setup.sh
git commit -m "feat(ship-gate): lock tool use while UNCLAIMED_LEARNINGS is set

PRE-hook now denies any tool call except Read/Edit/Write on
.claude/ship-learnings/*.md and Bash commands that append the
LEARNINGS_*=done marker or edit the learning file. Cleared by
POST-hook in the next task.

Fixes the abandonment scenario where a pipeline ending at Phase 1
without capture just leaves empty learning files forever.

Adds pipe-tests T20-T22."
```

---

### Task 7: POST-hook clears `UNCLAIMED_LEARNINGS` when gate is satisfied

**Files:**
- Modify: `hooks/ship-gate.sh` (POST-hook)

**Context:** After Claude writes to the learning file and appends the marker, the next PostToolUse invocation should detect that the gate is met and remove the UNCLAIMED flag so normal work can resume.

- [ ] **Step 1: Add a `maybe_clear_unclaimed()` helper near the other helpers**

Insert after `learnings_gate_met()` (added in Task 1), before `step_done()`:

```bash
# ── If UNCLAIMED_LEARNINGS is set and its gate is now met, remove the flag ──
maybe_clear_unclaimed() {
  [[ -f "$STATE_FILE" ]] || return 0
  local unclaimed
  unclaimed=$(grep "^UNCLAIMED_LEARNINGS=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 | head -1)
  [[ -z "$unclaimed" ]] && return 0
  local phase
  phase=$(echo "$unclaimed" | tr '[:lower:]' '[:upper:]')
  if learnings_gate_met "$phase"; then
    sed -i.bak "/^UNCLAIMED_LEARNINGS=/d" "$STATE_FILE"
    rm -f "${STATE_FILE}.bak"
  fi
}
```

- [ ] **Step 2: Call `maybe_clear_unclaimed` near the top of POST-mode**

In `hooks/ship-gate.sh`, find the line `if [[ "$MODE" == "post" ]]; then` (around line 340) and insert a call on the next line:

```bash
if [[ "$MODE" == "post" ]]; then
  # Clear UNCLAIMED_LEARNINGS flag if the gate is now satisfied.
  # Runs on every post-hook invocation — cheap and idempotent.
  maybe_clear_unclaimed
```

- [ ] **Step 3: Add T23–T25 to verify clearing logic**

In `setup.sh`, after T22:

```bash
  # ── T23: After writing a new ### heading AND marker, post-hook clears UNCLAIMED ──
  rm -f .ship-pipeline-state
  echo "STEP_1A=done" > .ship-pipeline-state
  echo "STEP_1B=done" >> .ship-pipeline-state
  echo "PLAN_BASELINE_HEADINGS=0" >> .ship-pipeline-state
  echo "LEARNINGS_PLAN=done" >> .ship-pipeline-state
  echo "UNCLAIMED_LEARNINGS=plan" >> .ship-pipeline-state
  mkdir -p .claude/ship-learnings
  cat > .claude/ship-learnings/plan.md <<'PLANMD'
# /ship Learnings — plan phase

### A new entry written during this run
PLANMD

  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  # Any post-hook call should trigger the check
  echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | "${HOOK_SCRIPT}" post >/dev/null 2>&1
  if ! grep -q "^UNCLAIMED_LEARNINGS=" .ship-pipeline-state; then
    pass "T23: POST-hook clears UNCLAIMED_LEARNINGS when gate met (new heading)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T23: UNCLAIMED_LEARNINGS NOT cleared (state: $(cat .ship-pipeline-state))"
    ERRORS=$((ERRORS + 1))
  fi

  # ── T24: Seen-date update also clears UNCLAIMED (Condition B) ──
  rm -f .ship-pipeline-state
  echo "STEP_1A=done" > .ship-pipeline-state
  echo "STEP_1B=done" >> .ship-pipeline-state
  # Baseline=1: file starts with 1 heading, no new heading will be added, only Seen date updated
  echo "PLAN_BASELINE_HEADINGS=1" >> .ship-pipeline-state
  echo "LEARNINGS_PLAN=done" >> .ship-pipeline-state
  echo "UNCLAIMED_LEARNINGS=plan" >> .ship-pipeline-state
  TODAY=$(date +%Y-%m-%d)
  cat > .claude/ship-learnings/plan.md <<PLANMD
# /ship Learnings — plan phase

### Existing entry

**Seen:** 2x — 2026-04-10, ${TODAY}
PLANMD

  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | "${HOOK_SCRIPT}" post >/dev/null 2>&1
  if ! grep -q "^UNCLAIMED_LEARNINGS=" .ship-pipeline-state; then
    pass "T24: POST-hook clears UNCLAIMED_LEARNINGS when Seen line updated today"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T24: UNCLAIMED_LEARNINGS NOT cleared via Seen-date (state: $(cat .ship-pipeline-state))"
    ERRORS=$((ERRORS + 1))
  fi

  # ── T25: Marker without content does NOT clear UNCLAIMED (loophole closed) ──
  rm -f .ship-pipeline-state
  echo "STEP_1A=done" > .ship-pipeline-state
  echo "STEP_1B=done" >> .ship-pipeline-state
  echo "PLAN_BASELINE_HEADINGS=1" >> .ship-pipeline-state
  echo "LEARNINGS_PLAN=done" >> .ship-pipeline-state
  echo "UNCLAIMED_LEARNINGS=plan" >> .ship-pipeline-state
  # Learning file still has only the baseline single heading, no Seen-date update
  cat > .claude/ship-learnings/plan.md <<'PLANMD'
# /ship Learnings — plan phase

### Existing entry from a previous run

**Seen:** 1x — 2026-04-10
PLANMD

  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | "${HOOK_SCRIPT}" post >/dev/null 2>&1
  if grep -q "^UNCLAIMED_LEARNINGS=plan$" .ship-pipeline-state; then
    pass "T25: Marker-without-content leaves UNCLAIMED set (loophole closed)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T25: UNCLAIMED was cleared despite no content change (loophole still open)"
    ERRORS=$((ERRORS + 1))
  fi
```

- [ ] **Step 4: Run setup.sh to confirm T23–T25 pass**

Run: `bash setup.sh --check 2>&1 | grep -E "T2[345]"`
Expected: all three pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/ship-gate.sh setup.sh
git commit -m "feat(ship-gate): clear UNCLAIMED_LEARNINGS when gate is met

POST-hook now runs maybe_clear_unclaimed on every invocation.
When the learning-content gate is satisfied (new heading OR Seen
date updated today, AND marker written), the flag is removed and
normal work resumes.

Adds pipe-tests T23-T25 including negative test for the
marker-without-content loophole."
```

---

### Task 8: Register `Bash`/`Edit`/`Write` PreToolUse matchers in setup.sh

**Files:**
- Modify: `setup.sh:296-334` (hook installation block)

**Context:** Currently only `Skill` and `Agent` matchers trigger the ship-gate PRE-hook. For the UNCLAIMED_LEARNINGS lock to catch `ls`, `git status`, or arbitrary Edits, we need matchers for `Bash`, `Edit`, `Write`, and `Read`. These matchers become idempotent — re-running setup.sh must not duplicate entries.

- [ ] **Step 1: Update the new-settings branch (lines 296-321)**

In `setup.sh`, find the `cat > "${SETTINGS_FILE}" <<HOOKJSON` block that creates settings from scratch. Replace the `PreToolUse` array with this expanded set:

```bash
        cat > "${SETTINGS_FILE}" <<HOOKJSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Skill",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} pre", "timeout": 5, "statusMessage": "Checking /ship pipeline gate..." }]
      },
      {
        "matcher": "Agent",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} pre", "timeout": 5, "statusMessage": "Checking /ship pipeline gate..." }]
      },
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} pre", "timeout": 5, "statusMessage": "Checking /ship pipeline gate..." }]
      },
      {
        "matcher": "Edit",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} pre", "timeout": 5, "statusMessage": "Checking /ship pipeline gate..." }]
      },
      {
        "matcher": "Write",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} pre", "timeout": 5, "statusMessage": "Checking /ship pipeline gate..." }]
      },
      {
        "matcher": "Read",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} pre", "timeout": 5, "statusMessage": "Checking /ship pipeline gate..." }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Skill",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} post", "timeout": 5, "statusMessage": "Recording /ship pipeline step..." }]
      },
      {
        "matcher": "Agent",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} post", "timeout": 5, "statusMessage": "Recording /ship pipeline step..." }]
      },
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} post", "timeout": 5, "statusMessage": "Recording /ship pipeline step..." }]
      },
      {
        "matcher": "Edit",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} post", "timeout": 5, "statusMessage": "Recording /ship pipeline step..." }]
      },
      {
        "matcher": "Write",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} post", "timeout": 5, "statusMessage": "Recording /ship pipeline step..." }]
      }
    ]
  }
}
HOOKJSON
```

- [ ] **Step 2: Update the merge-into-existing-settings branch (the `jq` pipeline)**

Find the existing-file branch in `setup.sh` (around line 327-334). Replace the `jq` invocation that adds only Skill/Agent hooks with a version that adds all six matchers idempotently (removes stale ship-gate entries first, then appends):

```bash
        # Remove any existing ship-gate entries (idempotent), then re-append all matchers
        jq '
          .hooks.PreToolUse |= [.[] | select((.hooks // []) | all(.command | contains("ship-gate.sh") | not))]
          | .hooks.PostToolUse |= [.[] | select((.hooks // []) | all(.command | contains("ship-gate.sh") | not))]
        ' "${SETTINGS_FILE}" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"

        for matcher in Skill Agent Bash Edit Write Read; do
          PRE_HOOK="{\"matcher\":\"${matcher}\",\"hooks\":[{\"type\":\"command\",\"command\":\"${HOOK_SCRIPT} pre\",\"timeout\":5,\"statusMessage\":\"Checking /ship pipeline gate...\"}]}"
          jq ".hooks.PreToolUse += [${PRE_HOOK}]" "${SETTINGS_FILE}" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"
        done
        for matcher in Skill Agent Bash Edit Write; do
          POST_HOOK="{\"matcher\":\"${matcher}\",\"hooks\":[{\"type\":\"command\",\"command\":\"${HOOK_SCRIPT} post\",\"timeout\":5,\"statusMessage\":\"Recording /ship pipeline step...\"}]}"
          jq ".hooks.PostToolUse += [${POST_HOOK}]" "${SETTINGS_FILE}" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"
        done

        if jq -e '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.command | contains("ship-gate.sh"))' "${SETTINGS_FILE}" >/dev/null 2>&1; then
          pass "Pipeline hooks installed for Skill/Agent/Bash/Edit/Write/Read (backup at ${SETTINGS_FILE}.bak)"
        else
          fail "Failed to install hooks — restoring backup"
          mv "${SETTINGS_FILE}.bak" "${SETTINGS_FILE}"
          ERRORS=$((ERRORS + 1))
        fi
```

- [ ] **Step 3: Update the config-is-configured detection (line 279)**

Change the detection grep to look for the Bash matcher (which guarantees the new expansion was installed):

```bash
    if jq -e '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.command | contains("ship-gate.sh"))' "${SETTINGS_FILE}" >/dev/null 2>&1; then
      HOOKS_CONFIGURED=true
    fi
```

This forces a setup.sh re-run to upgrade any existing installation.

- [ ] **Step 4: Test idempotence**

Back up the user's real settings before testing:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.pre-task8-backup
bash setup.sh --check
bash setup.sh    # first install
bash setup.sh    # second run — must not duplicate
jq '.hooks.PreToolUse | map(select(.hooks[0].command | contains("ship-gate.sh"))) | length' ~/.claude/settings.json
```

Expected: the jq result is `6` (one per matcher), NOT 12 or higher.

If correct: `rm ~/.claude/settings.json.pre-task8-backup`.
If something broke: `cp ~/.claude/settings.json.pre-task8-backup ~/.claude/settings.json` to restore.

- [ ] **Step 5: Commit**

```bash
git add setup.sh
git commit -m "feat(setup): register PreToolUse hooks for Bash/Edit/Write/Read

The UNCLAIMED_LEARNINGS lock needs to fire on any tool call,
not just Skill/Agent. Adds matchers for Bash, Edit, Write, and
Read to PreToolUse. Also adds Bash/Edit/Write to PostToolUse so
the clear-UNCLAIMED helper runs after state edits.

Idempotent: removes stale ship-gate entries before re-adding, so
re-running setup.sh never duplicates."
```

---

### Task 9: End-to-end flow test

**Files:**
- Modify: `setup.sh` (add T26 in pipe-test block)

**Context:** Integration test simulating the full capture cycle in one pass: phase-end → UNCLAIMED set → blocked → write learning + marker → UNCLAIMED cleared → next phase allowed.

- [ ] **Step 1: Append T26 after T25 in setup.sh**

```bash
  # ── T26: Full capture cycle (integration) ──
  rm -f .ship-pipeline-state
  echo "STEP_1A=done" > .ship-pipeline-state
  echo "PLAN_BASELINE_HEADINGS=0" >> .ship-pipeline-state
  mkdir -p .claude/ship-learnings
  printf '# /ship Learnings — plan phase\n\n' > .claude/ship-learnings/plan.md

  TESTS_TOTAL=$((TESTS_TOTAL + 1))

  # Step A: Phase 1B completes with PASS verdict → UNCLAIMED_LEARNINGS written
  echo "PASS" > .ship-1b-verdict
  echo '{"tool_name":"Skill","tool_input":{"skill":"adversarial-review"}}' | "${HOOK_SCRIPT}" post >/dev/null 2>&1
  rm -f .ship-1b-verdict

  STATE_HAS_UNCLAIMED=$(grep -q "^UNCLAIMED_LEARNINGS=plan$" .ship-pipeline-state && echo 1 || echo 0)

  # Step B: With UNCLAIMED set, unrelated Bash is blocked
  BLOCK_RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "${HOOK_SCRIPT}" pre 2>&1)
  BASH_BLOCKED=$(echo "$BLOCK_RESULT" | grep -q '"permissionDecision":"deny"' && echo 1 || echo 0)

  # Step C: Claude writes a new entry + marker
  cat >> .claude/ship-learnings/plan.md <<'PLANMD'

### A learning captured during T26

**Seen:** 1x — today
PLANMD
  echo "LEARNINGS_PLAN=done" >> .ship-pipeline-state

  # Step D: Next post-hook call clears UNCLAIMED
  echo '{"tool_name":"Bash","tool_input":{"command":"echo LEARNINGS_PLAN=done"}}' | "${HOOK_SCRIPT}" post >/dev/null 2>&1
  UNCLAIMED_CLEARED=$(grep -q "^UNCLAIMED_LEARNINGS=" .ship-pipeline-state && echo 0 || echo 1)

  # Step E: Unrelated Bash now allowed
  echo "STEP_1B=done" >> .ship-pipeline-state
  ALLOW_RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "${HOOK_SCRIPT}" pre 2>&1)
  ALLOW_EXIT=$?
  BASH_ALLOWED=$(if [[ $ALLOW_EXIT -eq 0 && -z "$ALLOW_RESULT" ]]; then echo 1; else echo 0; fi)

  if [[ "$STATE_HAS_UNCLAIMED" == 1 && "$BASH_BLOCKED" == 1 && "$UNCLAIMED_CLEARED" == 1 && "$BASH_ALLOWED" == 1 ]]; then
    pass "T26: Full capture cycle — UNCLAIMED set, blocks, clears, unblocks"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T26: Full cycle broken (UNCLAIMED=$STATE_HAS_UNCLAIMED blocked=$BASH_BLOCKED cleared=$UNCLAIMED_CLEARED allowed=$BASH_ALLOWED)"
    ERRORS=$((ERRORS + 1))
  fi
```

- [ ] **Step 2: Run the full pipe-test and confirm all tests pass**

Run: `bash setup.sh --check 2>&1 | grep -E "T[0-9]+:|tests passed"`
Expected: all T1-T26 pass, summary shows `26/26 tests passed`.

- [ ] **Step 3: Commit**

```bash
git add setup.sh
git commit -m "test(setup): add T26 full capture-cycle integration test

Covers: phase-end → UNCLAIMED set → non-learning Bash blocked →
learning entry + marker written → POST clears UNCLAIMED →
non-learning Bash allowed. Proves the whole chain works end-to-end."
```

---

### Task 10: Update README and sync the user-installed command copy

**Files:**
- Modify: `README.md` (add a short section on the new enforcement)
- Auto-synced: `~/.claude/commands/ship.md` via setup.sh (already handled in existing setup logic)

**Context:** Users installing or re-running setup.sh get the updated `ship.md` automatically. README should reflect the new behavior so anyone reading the docs knows about the hard gate.

- [ ] **Step 1: Add a section to README.md**

Find the existing `/ship` section or the "how it works" area in `README.md`. Append (or insert after):

```markdown
### Learning enforcement (v2, 2026-04-17)

Every `/ship` phase must capture a learning before the next phase — and before any other tool call — can proceed. This is enforced by `hooks/ship-gate.sh`:

- **RECALL** — at the start of each phase, the hook reads `.claude/ship-learnings/<phase>.md` and embeds up to 200 lines of content into Claude's context. Past lessons are guaranteed to be seen.
- **CAPTURE** — when a phase ends, the hook lists every existing `###` heading in the capture prompt. Claude updates the `**Seen:**` count on a duplicate instead of appending a near-identical entry.
- **Gate** — a learning counts as captured only when (a) `LEARNINGS_<PHASE>=done` is in `.ship-pipeline-state` AND (b) the learning file either has a new `###` heading compared to pipeline init OR has a `**Seen:**` line updated with today's date.
- **Abandonment lock** — after each phase-end step, `UNCLAIMED_LEARNINGS=<phase>` is set. Only `Read`/`Edit`/`Write` on the learning file and `Bash` appending `LEARNINGS_<PHASE>=done` are allowed until the gate clears. This catches pipelines that stop mid-run.
```

- [ ] **Step 2: Re-run setup.sh to install the updated `ship.md` copy**

Run: `bash setup.sh`
Expected: output includes `Updated ship.md` or `/ship command installed and up to date`.

- [ ] **Step 3: Sanity-check the installed copy contains the new init block**

Run: `grep -c "BASELINE_HEADINGS" ~/.claude/commands/ship.md`
Expected: output is `1` or higher (meaning the new init snippet is present in the installed copy).

- [ ] **Step 4: Commit README update**

```bash
git add README.md
git commit -m "docs: document the hard learning gate in /ship

Explains RECALL auto-injection, CAPTURE heading injection,
content-verified gate, and the UNCLAIMED_LEARNINGS abandonment
lock so users understand the new enforcement behavior."
```

---

## Self-Review Checklist

After all 10 tasks are complete, run:

- [ ] `bash setup.sh --check 2>&1 | grep "tests passed"` — shows `26/26 tests passed`
- [ ] `jq '.hooks.PreToolUse | map(select(.hooks[0].command | contains("ship-gate.sh"))) | length' ~/.claude/settings.json` — returns `6`
- [ ] `jq '.hooks.PostToolUse | map(select(.hooks[0].command | contains("ship-gate.sh"))) | length' ~/.claude/settings.json` — returns `5`
- [ ] In a throwaway dir, run the pipeline-init snippet; verify `.ship-pipeline-state` contains all seven `<PHASE>_BASELINE_HEADINGS=` lines
- [ ] Simulate phase 1 end with the pipe-test harness; verify `UNCLAIMED_LEARNINGS=plan` appears, Bash is blocked, and after writing a new `###` + marker the flag is cleared

If any check fails, fix inline and re-run.

---

## Operational Notes

- **Rollback**: `git revert` any task commit. Hook logic is isolated to `hooks/ship-gate.sh` and is hot-reloaded by Claude Code on each tool call — no restart required.
- **Debugging a block**: tail `.claude/ship-logs/<date>.log` for `BLOCKED: ...` lines. Each block records the tool name and the reason.
- **Bypass for edge cases**: a user-approved skip is still honored — writing `LEARNINGS_<PHASE>=skipped` to state passes the gate without content check. Use sparingly.
