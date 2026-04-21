#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# /ship Pipeline Gate Enforcement
#
# Prevents Claude from skipping pipeline steps.
# Called by Claude Code hooks on PreToolUse and PostToolUse.
#
# Usage (via hooks — not called directly):
#   echo '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' | ship-gate.sh pre
#   echo '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' | ship-gate.sh post
#
# State file: .ship-pipeline-state in the current working directory
# Created by the /ship command at pipeline start.
# If the state file doesn't exist, all calls are allowed (not in pipeline).
# ─────────────────────────────────────────────────────────────
set -euo pipefail

MODE="${1:-}"
STATE_FILE=".ship-pipeline-state"
BASELINE_FILE=".ship-baseline-tests.json"

# Read JSON from stdin
INPUT=$(cat)

# ── Enforce baseline-before-state (runs BEFORE the "no state file" early return) ──
# The baseline captures pre-change test pass/fail so Phase 4A can distinguish
# regressions from pre-existing failures. It MUST exist before .ship-pipeline-state
# is created, otherwise the whole diff-based gate has no reference point.
if [[ "$MODE" == "pre" && ! -f "$STATE_FILE" ]]; then
  _TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
  _CREATING_STATE=false
  if [[ "$_TOOL" == "Bash" ]]; then
    _CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # Matches: `> .ship-pipeline-state`, `touch .ship-pipeline-state`, `tee ... .ship-pipeline-state`
    if echo "$_CMD" | grep -qE "(>[[:space:]]*\.ship-pipeline-state|touch[[:space:]]+\.ship-pipeline-state|tee[[:space:]]+.*\.ship-pipeline-state)"; then
      _CREATING_STATE=true
    fi
  fi
  if [[ "$_TOOL" == "Write" || "$_TOOL" == "Edit" ]]; then
    _FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null || true)
    if [[ "$_FP" == *".ship-pipeline-state"* ]]; then
      _CREATING_STATE=true
    fi
  fi

  if $_CREATING_STATE; then
    if [[ ! -f "$BASELINE_FILE" ]]; then
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SHIP PIPELINE GATE: Cannot create .ship-pipeline-state without a baseline.\\n\\n.ship-baseline-tests.json does not exist. Pipeline Init Step A (baseline test capture) MUST run BEFORE Step B (state file creation) — otherwise Phase 4A has no reference for the regression diff.\\n\\nRun the project's test suite now and write .ship-baseline-tests.json with this schema:\\n  {\\n    \\\"captured_at\\\": \\\"<ISO-8601>\\\",\\n    \\\"test_command\\\": \\\"<exact command>\\\",\\n    \\\"failed_tests\\\": [<test ids>],\\n    \\\"total\\\": N, \\\"passed\\\": N, \\\"failed\\\": N\\n  }\\n\\nThen re-attempt state file creation."
  }
}
EOF
      exit 0
    fi
    # Schema validation — required fields
    if ! jq -e 'has("test_command") and has("failed_tests") and (.failed_tests | type == "array")' "$BASELINE_FILE" >/dev/null 2>&1; then
      MISSING=$(jq -r '
        [
          (if has("test_command") then empty else "test_command" end),
          (if has("failed_tests") then empty else "failed_tests" end),
          (if (.failed_tests // null) | type == "array" then empty else "failed_tests (must be array)" end)
        ] | join(", ")
      ' "$BASELINE_FILE" 2>/dev/null || echo "unparseable JSON")
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SHIP PIPELINE GATE: .ship-baseline-tests.json is malformed.\\n\\nMissing or invalid fields: ${MISSING}\\n\\nRequired schema: { test_command: string, failed_tests: array, ... }. Fix the baseline file before creating .ship-pipeline-state."
  }
}
EOF
      exit 0
    fi
  fi
fi

# ── If no state file, pipeline isn't active — allow everything ──
if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

# ── Extract tool info from hook JSON ──
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
SKILL_NAME=""
AGENT_TYPE=""
AGENT_PROMPT=""

if [[ "$TOOL_NAME" == "Skill" ]]; then
  SKILL_NAME=$(echo "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null || true)
fi

if [[ "$TOOL_NAME" == "Agent" ]]; then
  AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)
  AGENT_PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null || true)
fi

# ── Normalize skill name: strip plugin prefix ──
normalize_skill() {
  local s="$1"
  s="${s#everything-claude-code:}"
  s="${s#codex:}"
  echo "$s"
}

# ── Map skill/agent to pipeline step ID ──
resolve_step() {
  # Check Skill tool invocations
  if [[ -n "$SKILL_NAME" ]]; then
    local skill
    skill=$(normalize_skill "$SKILL_NAME")
    case "$skill" in
      prp-plan)                    echo "STEP_1A"; return ;;
      adversarial-review)          echo "STEP_1B"; return ;;
      rescue)
        # codex:rescue used for adversarial review (check args)
        local args
        args=$(echo "$INPUT" | jq -r '.tool_input.args // empty' 2>/dev/null || true)
        local args_lower
        args_lower=$(echo "$args" | tr '[:upper:]' '[:lower:]')
        if echo "$args_lower" | grep -q "adversarial"; then
          echo "STEP_1B"; return
        elif echo "$args_lower" | grep -q "review"; then
          echo "STEP_3C"; return
        fi
        ;;
      tdd|tdd-workflow)            echo "STEP_2"; return ;;
      code-review)                 echo "STEP_3A"; return ;;
      security-review)             echo "STEP_3B"; return ;;
      review)                      echo "STEP_3C"; return ;;
      e2e|e2e-testing)             echo "STEP_4B"; return ;;
      verify|verification-loop)    echo "STEP_5A"; return ;;
      browser-qa)                  echo "STEP_5B"; return ;;
      flutter-test)                echo "STEP_5C"; return ;;
      eval|eval-harness)           echo "STEP_6"; return ;;
      prp-commit)                  echo "STEP_7A"; return ;;
      prp-pr)                      echo "STEP_7B"; return ;;
    esac
  fi

  # Check Bash tool for regression-test and native-simulator commands
  if [[ "$TOOL_NAME" == "Bash" ]]; then
    local cmd
    cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

    # Native simulator commands → STEP_5C (match first, before generic test matchers)
    if echo "$cmd" | grep -qE "(detox test|maestro test|xcrun simctl|emulator |flutter drive|flutter test.*integration)"; then
      echo "STEP_5C"; return
    fi

    # Regression-test runners → STEP_4A
    # Matches: npm/yarn/pnpm test, vitest, jest, pytest, go test, cargo test, mvn test, gradle test
    if echo "$cmd" | grep -qE "(^|[[:space:]]|;|&&|\|\|)(npm|yarn|pnpm)[[:space:]]+(run[[:space:]]+)?test([[:space:]]|$)|(^|[[:space:]]|;|&&|\|\|)(vitest|jest|pytest|mocha)([[:space:]]|$)|(^|[[:space:]]|;|&&|\|\|)go[[:space:]]+test([[:space:]]|$)|(^|[[:space:]]|;|&&|\|\|)cargo[[:space:]]+test([[:space:]]|$)|(^|[[:space:]]|;|&&|\|\|)(mvn|gradle|\./gradlew)[[:space:]]+(.*[[:space:]])?test([[:space:]]|$)"; then
      echo "STEP_4A"; return
    fi
  fi

  echo ""
}

# ── Check if project is a mobile app ──
is_mobile_app() {
  grep -q "^MOBILE_APP=true$" "$STATE_FILE" 2>/dev/null
}

# ── Check if a step is recorded as done (or user-approved skip) ──
step_done() {
  grep -qE "^$1=(done|skipped)$" "$STATE_FILE" 2>/dev/null
}

# ── Record step completion ──
record_step() {
  if ! step_done "$1"; then
    echo "$1=done" >> "$STATE_FILE"
  fi
}

# ── Prerequisite map ──
# Each step lists what must be done before it can start
get_prereqs() {
  case "$1" in
    STEP_1A) echo "" ;;
    STEP_1B) echo "STEP_1A" ;;
    STEP_2)  echo "STEP_1A STEP_1B" ;;
    STEP_3A) echo "STEP_2" ;;
    STEP_3B) echo "STEP_2" ;;
    STEP_3C) echo "STEP_2" ;;
    STEP_4A) echo "STEP_3A STEP_3B STEP_3C" ;;
    STEP_4B) echo "STEP_3A STEP_3B STEP_3C STEP_4A" ;;
    STEP_5A) echo "STEP_3A STEP_3B STEP_3C STEP_4A STEP_4B" ;;
    STEP_5B) echo "STEP_5A" ;;
    STEP_5C) echo "STEP_5A" ;;
    STEP_6)  echo "STEP_5A STEP_5C" ;;
    STEP_7A) echo "STEP_6" ;;
    STEP_7B) echo "STEP_7A" ;;
    *)       echo "" ;;
  esac
}

# ── Human-readable step names ──
step_name() {
  case "$1" in
    STEP_1A) echo "Phase 1A: Create Implementation Plan (/prp-plan)" ;;
    STEP_1B) echo "Phase 1B: Adversarial Review (/codex:adversarial-review)" ;;
    STEP_2)  echo "Phase 2: TDD (/tdd)" ;;
    STEP_3A) echo "Phase 3A: Code Review (/code-review)" ;;
    STEP_3B) echo "Phase 3B: Security Review (/security-review)" ;;
    STEP_3C) echo "Phase 3C: Codex Review (/codex:review)" ;;
    STEP_4A) echo "Phase 4A: Regression Tests (npm test / pytest / go test / etc.)" ;;
    STEP_4B) echo "Phase 4B: E2E Tests (/e2e)" ;;
    STEP_5A) echo "Phase 5A: Verification (/verify)" ;;
    STEP_5B) echo "Phase 5B: Browser QA (/browser-qa)" ;;
    STEP_5C) echo "Phase 5C: Native Simulator QA (/flutter-test)" ;;
    STEP_6)  echo "Phase 6: Eval (/eval)" ;;
    STEP_7A) echo "Phase 7A: Commit (/prp-commit)" ;;
    STEP_7B) echo "Phase 7B: PR (/prp-pr)" ;;
    *)       echo "$1" ;;
  esac
}

# ── Build progress header ──
build_progress() {
  local ALL_STEPS="STEP_1A STEP_1B STEP_2 STEP_3A STEP_3B STEP_3C STEP_4A STEP_4B STEP_5A STEP_5B STEP_5C STEP_6 STEP_7A STEP_7B"
  local header="\\n=== /ship Pipeline Progress ===\\n"

  for step in $ALL_STEPS; do
    local name
    case "$step" in
      STEP_1A) name="1A Plan" ;;
      STEP_1B) name="1B Adversarial" ;;
      STEP_2)  name="2  TDD" ;;
      STEP_3A) name="3A Code Review" ;;
      STEP_3B) name="3B Security" ;;
      STEP_3C) name="3C Codex Review" ;;
      STEP_4A) name="4A Regression Tests" ;;
      STEP_4B) name="4B E2E Tests" ;;
      STEP_5A) name="5A Verify" ;;
      STEP_5B) name="5B Browser QA" ;;
      STEP_5C) name="5C Native Simulator" ;;
      STEP_6)  name="6  Eval" ;;
      STEP_7A) name="7A Commit" ;;
      STEP_7B) name="7B PR" ;;
    esac

    if grep -q "^${step}=skipped$" "$STATE_FILE" 2>/dev/null; then
      header="${header}  [SKIP] ${name}  (user approved)\\n"
    elif step_done "$step"; then
      header="${header}  [DONE] ${name}\\n"
    elif [[ "$step" == "$1" ]]; then
      header="${header}  [ >> ] ${name}  <-- current\\n"
    else
      header="${header}  [    ] ${name}\\n"
    fi
  done

  header="${header}================================\\n"
  echo "$header"
}

# ── Block code edits before Plan phase is complete ──
# After Plan is done, all edits are allowed (TDD, review fixes, verify fixes, etc.)
# The skill-level hooks enforce the phase ordering for skills themselves.
if [[ "$MODE" == "pre" && ("$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write") ]]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null || true)

  # Always allow: pipeline state files, plan files, config files
  if [[ "$FILE_PATH" == *".ship-pipeline-state"* || "$FILE_PATH" == *".claude/PRPs/"* || "$FILE_PATH" == *"TASK.md"* ]]; then
    exit 0
  fi

  # Block ALL source edits until Phase 1 (Plan + Adversarial Review) is complete
  if ! step_done "STEP_1A" || ! step_done "STEP_1B"; then
    PROGRESS=$(build_progress "STEP_1A")
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SHIP PIPELINE GATE: Cannot edit files before Phase 1 (PLAN) is complete.\\n\\nPhase 1A (Plan) and Phase 1B (Adversarial Review) must both pass before any code changes.\\n${PROGRESS}"
  }
}
EOF
    exit 0
  fi

  # Phase 1 done — allow all edits from here on.
  # TDD writes tests then implementation (both need Edit).
  # Review fix-retry needs Edit to fix findings.
  # Verify fix-retry needs Edit to fix build/lint errors.
  # The skill-level prereq checks (Skill/Agent matchers) still enforce phase ordering.
  exit 0
fi

# ── Block state file deletion / truncation / move ──
# Catches: rm, unlink, shred, find -delete, mv, cp (overwrite), and > redirection
if [[ "$MODE" == "pre" && "$TOOL_NAME" == "Bash" ]]; then
  BASH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
  TOUCHES_STATE=false
  if echo "$BASH_CMD" | grep -q "\.ship-pipeline-state"; then
    # Destructive ops targeting the state file
    if echo "$BASH_CMD" | grep -qE "(^|[[:space:]]|;|&&|\|\|)(rm|unlink|shred|mv)([[:space:]]|$)"; then
      TOUCHES_STATE=true
    fi
    # Truncate / clobber via redirection: `> .ship-pipeline-state` or `>> .ship-pipeline-state` with truncate semantics
    if echo "$BASH_CMD" | grep -qE ">[[:space:]]*\.ship-pipeline-state"; then
      TOUCHES_STATE=true
    fi
    # find ... -delete
    if echo "$BASH_CMD" | grep -qE "find[[:space:]].*-delete"; then
      TOUCHES_STATE=true
    fi
  fi

  if $TOUCHES_STATE; then
    # Only allow destructive ops if all steps are done
    if ! step_done "STEP_7B"; then
      PROGRESS=$(build_progress "")
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SHIP PIPELINE GATE VIOLATION: Cannot delete, move, or truncate .ship-pipeline-state before all phases are complete.\\n\\nPhase 7B (PR) must be done before the state file can be removed.\\n\\nThis is enforced by the /ship pipeline hooks. No exceptions.\\n${PROGRESS}"
  }
}
EOF
      exit 0
    fi
  fi
fi

# ── Resolve current step ──
CURRENT_STEP=$(resolve_step)

# Not a pipeline skill — allow without interference
if [[ -z "$CURRENT_STEP" ]]; then
  exit 0
fi

# ── PRE: Enforce prerequisites before allowing the skill ──
if [[ "$MODE" == "pre" ]]; then
  PREREQS=$(get_prereqs "$CURRENT_STEP")
  MISSING=""

  for prereq in $PREREQS; do
    if ! step_done "$prereq"; then
      MISSING="${MISSING}  - $(step_name "$prereq")\n"
    fi
  done

  if [[ -n "$MISSING" ]]; then
    CURRENT_NAME=$(step_name "$CURRENT_STEP")
    PROGRESS=$(build_progress "$CURRENT_STEP")
    # Log the block
    LOG_DIR=".claude/ship-logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/$(date +%Y-%m-%d).log"
    echo "- [$(date +%H:%M:%S)] BLOCKED: ${CURRENT_NAME} (missing prereqs)" >> "$LOG_FILE"
    # Return JSON that blocks the tool call
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SHIP PIPELINE GATE VIOLATION: Cannot start ${CURRENT_NAME}.\\n\\nMissing prerequisites:\\n${MISSING}\\nYou MUST complete these steps first. No skipping, no exceptions.\\nThis is enforced by the /ship pipeline hooks.\\n${PROGRESS}"
  }
}
EOF
    exit 0
  fi

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

# ── POST: Record step completion ──
if [[ "$MODE" == "post" ]]; then

  # STEP_1B requires verdict file with "PASS" before recording completion.
  # The adversarial review is a convergence loop — the skill writes .ship-1b-verdict
  # after parsing the Codex output. Without "PASS", 1B stays incomplete and Phase 2 is blocked.
  if [[ "$CURRENT_STEP" == "STEP_1B" ]]; then
    VERDICT_FILE=".ship-1b-verdict"
    VERDICT=$(cat "$VERDICT_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if [[ "$VERDICT" != "PASS" ]]; then
      PROGRESS=$(build_progress "$CURRENT_STEP")
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[SHIP GATE] Phase 1B: Adversarial review invoked but verdict is NOT PASS (got: ${VERDICT:-<missing>}).\\n\\nThe adversarial review must converge (all flaws resolved) before 1B is recorded as complete.\\nWrite 'PASS' to .ship-1b-verdict after the review passes.\\n${PROGRESS}"
  }
}
EOF
      exit 0
    fi
  fi

  # STEP_4A requires .ship-4a-regression-check.json with verdict=PASS before recording.
  # This distinguishes regressions (newly failing tests) from pre-existing failures
  # by diffing current failures against the baseline captured at /ship start.
  if [[ "$CURRENT_STEP" == "STEP_4A" ]]; then
    VERDICT_FILE=".ship-4a-regression-check.json"
    if [[ ! -f "$VERDICT_FILE" ]]; then
      PROGRESS=$(build_progress "$CURRENT_STEP")
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[SHIP GATE] Phase 4A: regression check file missing (.ship-4a-regression-check.json).\\n\\nAfter running the test suite, diff current failures against .ship-baseline-tests.json and write a verdict file.\\nSTEP_4A will NOT be recorded until this file exists with verdict=PASS.\\nSee the Phase 4A section of the /ship skill for the file schema.\\n${PROGRESS}"
  }
}
EOF
      exit 0
    fi
    VERDICT=$(jq -r '.verdict // empty' "$VERDICT_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if [[ "$VERDICT" != "PASS" ]]; then
      NEW_FAILURES=$(jq -r '.new_failures // [] | join(", ")' "$VERDICT_FILE" 2>/dev/null || echo "<unable to parse>")
      PROGRESS=$(build_progress "$CURRENT_STEP")
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[SHIP GATE] Phase 4A: Regression detected. Verdict: ${VERDICT:-<missing>}.\\n\\nNew failures (tests that passed in baseline but fail now): ${NEW_FAILURES:-<none listed>}\\n\\nFix these regressions before STEP_4A can be recorded. Pre-existing failures are NOT blockers — only tests that went PASS → FAIL count.\\n${PROGRESS}"
  }
}
EOF
      exit 0
    fi

    # Verdict math sanity check — prevents mislabeling a regression as pre-existing.
    # Rules:
    #   1. pre_existing_failures ⊆ baseline_failures  (can't claim pre-existing if not in baseline)
    #   2. new_failures ∩ baseline_failures = ∅       (a test listed in baseline is not "new")
    if [[ -f "$BASELINE_FILE" ]]; then
      MATH_OK=$(jq --slurpfile baseline "$BASELINE_FILE" '
        ($baseline[0].failed_tests // []) as $base |
        (.pre_existing_failures // []) as $pre |
        (.new_failures // []) as $new |
        ($pre | all(. as $t | ($base | index($t)) != null)) as $pre_ok |
        ($new | all(. as $t | ($base | index($t)) == null)) as $new_ok |
        if $pre_ok and $new_ok then "OK"
        elif ($pre_ok | not) then "PRE_EXISTING_NOT_IN_BASELINE"
        else "NEW_FAILURE_ALREADY_IN_BASELINE"
        end
      ' "$VERDICT_FILE" 2>/dev/null | tr -d '"')

      if [[ "$MATH_OK" != "OK" ]]; then
        BAD_LIST=""
        if [[ "$MATH_OK" == "PRE_EXISTING_NOT_IN_BASELINE" ]]; then
          BAD_LIST=$(jq --slurpfile baseline "$BASELINE_FILE" -r '
            ($baseline[0].failed_tests // []) as $base |
            [(.pre_existing_failures // [])[] | select(. as $t | ($base | index($t)) == null)] | join(", ")
          ' "$VERDICT_FILE" 2>/dev/null)
          REASON="Tests claimed as pre_existing_failures but NOT in baseline.failed_tests: ${BAD_LIST}. A test can only be 'pre-existing' if it was actually failing in the baseline."
        else
          BAD_LIST=$(jq --slurpfile baseline "$BASELINE_FILE" -r '
            ($baseline[0].failed_tests // []) as $base |
            [(.new_failures // [])[] | select(. as $t | ($base | index($t)) != null)] | join(", ")
          ' "$VERDICT_FILE" 2>/dev/null)
          REASON="Tests claimed as new_failures but they were ALREADY in baseline.failed_tests: ${BAD_LIST}. These are pre-existing, not new — do not list them as new failures."
        fi
        PROGRESS=$(build_progress "$CURRENT_STEP")
        cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[SHIP GATE] Phase 4A: Verdict math is inconsistent with baseline.\\n\\n${REASON}\\n\\nFix .ship-4a-regression-check.json so: pre_existing_failures ⊆ baseline_failures AND new_failures ∩ baseline_failures = ∅.\\nSTEP_4A will NOT be recorded until the math is correct.\\n${PROGRESS}"
  }
}
EOF
        exit 0
      fi
    fi
  fi

  # STEP_2 requires coverage ≥ threshold (default 95%) before recording completion.
  # Parses Istanbul-format coverage-summary.json (vitest/jest/nyc default output).
  # Bypass: set SHIP_SKIP_COVERAGE_CHECK=1 (for projects without coverage tooling).
  if [[ "$CURRENT_STEP" == "STEP_2" && "${SHIP_SKIP_COVERAGE_CHECK:-0}" != "1" ]]; then
    THRESHOLD="${SHIP_COVERAGE_THRESHOLD:-95}"
    COV_PCT=""
    COV_SOURCE=""
    for path in coverage/coverage-summary.json coverage-summary.json coverage/lcov-report/coverage-summary.json; do
      if [[ -f "$path" ]]; then
        COV_PCT=$(jq -r '.total.lines.pct // empty' "$path" 2>/dev/null || true)
        if [[ -n "$COV_PCT" && "$COV_PCT" != "null" ]]; then
          COV_SOURCE="$path"
          break
        fi
      fi
    done

    if [[ -z "$COV_PCT" ]]; then
      PROGRESS=$(build_progress "$CURRENT_STEP")
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[SHIP GATE] Phase 2: Coverage report not found. Expected at coverage/coverage-summary.json.\\n\\nRun your test suite with coverage enabled (e.g., 'npm test -- --coverage', 'vitest run --coverage', 'pytest --cov=. --cov-report=json').\\nSTEP_2 will NOT be recorded until coverage >= ${THRESHOLD}% is verified.\\nBypass (projects without coverage tooling): export SHIP_SKIP_COVERAGE_CHECK=1\\n${PROGRESS}"
  }
}
EOF
      exit 0
    fi

    if awk "BEGIN {exit !($COV_PCT < $THRESHOLD)}"; then
      PROGRESS=$(build_progress "$CURRENT_STEP")
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[SHIP GATE] Phase 2: Coverage ${COV_PCT}% is BELOW threshold ${THRESHOLD}%.\\n\\nAdd more tests to reach ${THRESHOLD}% line coverage.\\nSTEP_2 will NOT be recorded until threshold is met.\\nCoverage source: ${COV_SOURCE}\\n${PROGRESS}"
  }
}
EOF
      exit 0
    fi
  fi

  record_step "$CURRENT_STEP"

  # Append to session log for learning/history
  LOG_DIR=".claude/ship-logs"
  mkdir -p "$LOG_DIR"
  LOG_DATE=$(date +%Y-%m-%d)
  LOG_FILE="${LOG_DIR}/${LOG_DATE}.log"
  TASK_LINE=$(grep "^# Task:" "$STATE_FILE" 2>/dev/null | head -1 | sed 's/^# Task: //' || true)
  # Create header on first entry
  if [[ ! -f "$LOG_FILE" ]] || ! grep -q "^## $(date +%H)" "$LOG_FILE" 2>/dev/null; then
    echo "" >> "$LOG_FILE"
    echo "## $(date +%H:%M) — ${TASK_LINE:-unknown task}" >> "$LOG_FILE"
  fi
  echo "- [$(date +%H:%M:%S)] $(step_name "$CURRENT_STEP") ✓" >> "$LOG_FILE"

  CURRENT_NAME=$(step_name "$CURRENT_STEP")
  PROGRESS=$(build_progress "$CURRENT_STEP")

  # Map step to learnings file for CAPTURE reminder
  LEARNING_FILE=""
  case "$CURRENT_STEP" in
    STEP_1A|STEP_1B) LEARNING_FILE="plan" ;;
    STEP_2)          LEARNING_FILE="tdd" ;;
    STEP_3A|STEP_3B|STEP_3C) LEARNING_FILE="review" ;;
    STEP_4A|STEP_4B) LEARNING_FILE="test" ;;
    STEP_5A|STEP_5B|STEP_5C) LEARNING_FILE="verify" ;;
    STEP_6)          LEARNING_FILE="eval" ;;
    STEP_7A|STEP_7B) LEARNING_FILE="deliver" ;;
  esac

  # Determine if this is the LAST step of its phase (trigger CAPTURE)
  IS_PHASE_END=false
  case "$CURRENT_STEP" in
    STEP_1B) IS_PHASE_END=true ;;   # Plan phase ends after adversarial
    STEP_2)  IS_PHASE_END=true ;;   # TDD is a single step
    STEP_3C) IS_PHASE_END=true ;;   # Review ends after Codex review
    STEP_4B) IS_PHASE_END=true ;;   # Test ends after E2E
    STEP_5C) IS_PHASE_END=true ;;   # Verify ends after native simulator
    STEP_6)  IS_PHASE_END=true ;;   # Eval is a single step
    STEP_7B) IS_PHASE_END=true ;;   # Deliver ends after PR
  esac

  CAPTURE_MSG=""
  if [[ "$IS_PHASE_END" == "true" && -n "$LEARNING_FILE" ]]; then
    CAPTURE_MSG="\\n\\n[AUTO-LEARN] Phase complete. CAPTURE learnings now:\\n  1. Read .claude/ship-learnings/${LEARNING_FILE}.md FIRST (check existing entries)\\n  2. If same root cause exists: UPDATE its Seen count + date. Do NOT duplicate.\\n  3. If new learning: append new entry with takeaway as heading.\\n  4. If clean pass with no issues: write NOTHING.\\n  5. If file exceeds ~20 entries: consolidate related learnings into broader rules."
  fi

  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[SHIP GATE] ${CURRENT_NAME} recorded as COMPLETE.\\n${PROGRESS}\\nDisplay the progress header above to the user.${CAPTURE_MSG}"
  }
}
EOF
  exit 0
fi

exit 0
