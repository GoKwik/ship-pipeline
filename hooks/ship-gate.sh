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

# Read JSON from stdin
INPUT=$(cat)

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

  # Check Bash tool for native simulator commands (React Native / Expo)
  if [[ "$TOOL_NAME" == "Bash" ]]; then
    local cmd
    cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    if echo "$cmd" | grep -qE "(detox test|maestro test|xcrun simctl|emulator |flutter drive|flutter test.*integration)"; then
      echo "STEP_5C"; return
    fi
  fi

  echo ""
}

# ── Check if project is a mobile app ──
is_mobile_app() {
  grep -q "^MOBILE_APP=true$" "$STATE_FILE" 2>/dev/null
}

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
  baseline=$(grep "^${phase}_BASELINE_HEADINGS=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
  local current
  current=$(grep -c "^### " "$file" 2>/dev/null)
  current=${current:-0}
  if [[ "$current" -gt "${baseline:-0}" ]]; then
    return 0
  fi

  # Condition B: an existing **Seen:** line contains today's date
  grep -qE "^\*\*Seen:\*\*.*${today}" "$file" 2>/dev/null && return 0

  return 1
}

# ── Check if a step is recorded as done (or user-approved skip) ──
step_done() {
  # LEARNINGS_* prereqs use content-verified gate
  if [[ "$1" == LEARNINGS_* ]]; then
    learnings_gate_met "${1#LEARNINGS_}"
    return $?
  fi
  grep -qE "^$1=(done|skipped)$" "$STATE_FILE" 2>/dev/null
}

# ── Record step completion ──
record_step() {
  if ! step_done "$1"; then
    echo "$1=done" >> "$STATE_FILE"
  fi
}

# ── Prerequisite map ──
# Each step lists what must be done before it can start.
# LEARNINGS_* gates ensure learning capture before the next phase begins.
get_prereqs() {
  case "$1" in
    STEP_1A) echo "" ;;
    STEP_1B) echo "STEP_1A" ;;
    STEP_2)  echo "STEP_1A STEP_1B LEARNINGS_PLAN" ;;
    STEP_3A) echo "STEP_2 LEARNINGS_TDD" ;;
    STEP_3B) echo "STEP_2 LEARNINGS_TDD" ;;
    STEP_3C) echo "STEP_2 LEARNINGS_TDD" ;;
    STEP_4B) echo "STEP_3A STEP_3B LEARNINGS_REVIEW" ;;
    STEP_5A) echo "STEP_4B LEARNINGS_TEST" ;;
    STEP_5B) echo "STEP_5A" ;;
    STEP_5C) echo "STEP_5A" ;;
    STEP_6)  echo "STEP_5A STEP_5C LEARNINGS_VERIFY" ;;
    STEP_7A) echo "STEP_6 LEARNINGS_EVAL" ;;
    STEP_7B) echo "STEP_7A LEARNINGS_DELIVER" ;;
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
    STEP_4B) echo "Phase 4B: E2E Tests (/e2e)" ;;
    STEP_5A) echo "Phase 5A: Verification (/verify)" ;;
    STEP_5B) echo "Phase 5B: Browser QA (/browser-qa)" ;;
    STEP_5C) echo "Phase 5C: Native Simulator QA (/flutter-test)" ;;
    STEP_6)  echo "Phase 6: Eval (/eval)" ;;
    STEP_7A) echo "Phase 7A: Commit (/prp-commit)" ;;
    STEP_7B) echo "Phase 7B: PR (/prp-pr)" ;;
    LEARNINGS_PLAN)   echo "Capture learnings → .claude/ship-learnings/plan.md" ;;
    LEARNINGS_TDD)    echo "Capture learnings → .claude/ship-learnings/tdd.md" ;;
    LEARNINGS_REVIEW) echo "Capture learnings → .claude/ship-learnings/review.md" ;;
    LEARNINGS_TEST)   echo "Capture learnings → .claude/ship-learnings/test.md" ;;
    LEARNINGS_VERIFY) echo "Capture learnings → .claude/ship-learnings/verify.md" ;;
    LEARNINGS_EVAL)   echo "Capture learnings → .claude/ship-learnings/eval.md" ;;
    *)       echo "$1" ;;
  esac
}

# ── Read step summary (rich metadata) ──
step_summary() {
  grep "^${1}_SUMMARY=" "$STATE_FILE" 2>/dev/null | sed "s/^${1}_SUMMARY=//" | head -1
}

# ── Build progress header ──
build_progress() {
  local ALL_STEPS="STEP_1A STEP_1B STEP_2 STEP_3A STEP_3B STEP_3C STEP_4B STEP_5A STEP_5B STEP_5C STEP_6 STEP_7A STEP_7B"
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
      STEP_4B) name="4B E2E Tests" ;;
      STEP_5A) name="5A Verify" ;;
      STEP_5B) name="5B Browser QA" ;;
      STEP_5C) name="5C Native Simulator" ;;
      STEP_6)  name="6  Eval" ;;
      STEP_7A) name="7A Commit" ;;
      STEP_7B) name="7B PR" ;;
    esac

    local summary
    summary=$(step_summary "$step")

    if grep -q "^${step}=skipped$" "$STATE_FILE" 2>/dev/null; then
      header="${header}  [SKIP] ${name}  (user approved)\\n"
    elif step_done "$step"; then
      if [[ -n "$summary" ]]; then
        header="${header}  [DONE] ${name}  — ${summary}\\n"
      else
        header="${header}  [DONE] ${name}\\n"
      fi
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

# ── Block state file deletion ──
if [[ "$MODE" == "pre" && "$TOOL_NAME" == "Bash" ]]; then
  BASH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
  if echo "$BASH_CMD" | grep -q "rm.*\.ship-pipeline-state"; then
    # Only allow deletion if all steps are done
    if ! step_done "STEP_7B"; then
      PROGRESS=$(build_progress "")
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SHIP PIPELINE GATE VIOLATION: Cannot delete .ship-pipeline-state before all phases are complete.\\n\\nPhase 7B (PR) must be done before the state file can be removed.\\n\\nThis is enforced by the /ship pipeline hooks. No exceptions.\\n${PROGRESS}"
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
    LEARNING_HEADINGS=$(grep -c "^### " ".claude/ship-learnings/${RECALL_FILE}.md" 2>/dev/null || true)
    LEARNING_HEADINGS=${LEARNING_HEADINGS:-0}
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
    STEP_4B)         LEARNING_FILE="test" ;;
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
  LEARNING_GATE=""
  if [[ "$IS_PHASE_END" == "true" && -n "$LEARNING_FILE" ]]; then
    # Map learning file to gate name
    GATE_NAME=$(echo "$LEARNING_FILE" | tr '[:lower:]' '[:upper:]')
    LEARNING_GATE="LEARNINGS_${GATE_NAME}"

    CAPTURE_MSG="\\n\\n[AUTO-LEARN] HARD GATE: You MUST capture learnings before the next phase can start.\\n  The next phase is BLOCKED until you record LEARNINGS_${GATE_NAME}=done in the state file.\\n\\n  Steps:\\n  1. Read .claude/ship-learnings/${LEARNING_FILE}.md FIRST (check existing entries)\\n  2. If same root cause exists: UPDATE its Seen count + date. Do NOT duplicate.\\n  3. If new learning: append new entry with takeaway as heading.\\n  4. If clean pass with no issues: write a clean-pass entry noting what went right (e.g., approach that worked, pattern that avoided issues). Every phase produces a learning — even success is worth recording so future runs can repeat what worked.\\n  5. If file exceeds ~20 entries: consolidate related learnings into broader rules.\\n  6. MANDATORY (only after writing to the learnings file): echo 'LEARNINGS_${GATE_NAME}=done' >> .ship-pipeline-state"
  fi

  # Build summary prompt based on step type
  SUMMARY_PROMPT=""
  case "$CURRENT_STEP" in
    STEP_1A)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_1A_SUMMARY=<N> tasks, <M> acceptance criteria' >> .ship-pipeline-state" ;;
    STEP_1B)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_1B_SUMMARY=<N> findings (<P0> P0, <P1> P1) | <N> iterations | <All resolved | N unresolved>' >> .ship-pipeline-state" ;;
    STEP_2)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_2_SUMMARY=<N> tests, <M>% coverage | <N> RED-GREEN-REFACTOR cycles' >> .ship-pipeline-state" ;;
    STEP_3A)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_3A_SUMMARY=<N> P0, <N> P1, <N> P2 findings | <key finding or clean>' >> .ship-pipeline-state" ;;
    STEP_3B)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_3B_SUMMARY=<N> P0, <N> P1, <N> P2 findings | <key finding or clean>' >> .ship-pipeline-state" ;;
    STEP_3C)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_3C_SUMMARY=<N> P0, <N> P1, <N> P2 findings | <key finding or clean>' >> .ship-pipeline-state" ;;
    STEP_4B)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_4B_SUMMARY=<N> E2E tests passed | coverage <N>% (was <N>% in TDD) | <N> flows covered' >> .ship-pipeline-state" ;;
    STEP_5A)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_5A_SUMMARY=build <ok|fail> | types <ok|N errors> | lint <ok|N errors>' >> .ship-pipeline-state" ;;
    STEP_5B)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_5B_SUMMARY=<N> breakpoints | <N> console errors | a11y <ok|N issues>' >> .ship-pipeline-state" ;;
    STEP_5C)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_5C_SUMMARY=<platform> | <N> tests passed | <key result>' >> .ship-pipeline-state" ;;
    STEP_6)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_6_SUMMARY=<N>/<M> acceptance criteria satisfied | <N> code graders, <N> model graders' >> .ship-pipeline-state" ;;
    STEP_7A)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_7A_SUMMARY=<commit hash short> | <N> files changed' >> .ship-pipeline-state" ;;
    STEP_7B)
      SUMMARY_PROMPT="\\n\\n[PROGRESS SUMMARY] Write a one-line summary to .ship-pipeline-state:\\n  echo 'STEP_7B_SUMMARY=<PR URL or PR #>' >> .ship-pipeline-state" ;;
  esac

  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[SHIP GATE] ${CURRENT_NAME} recorded as COMPLETE.\\n${PROGRESS}\\nDisplay the progress header above to the user.${CAPTURE_MSG}${SUMMARY_PROMPT}"
  }
}
EOF
  exit 0
fi

exit 0
