#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# /ship Pipeline — Prerequisites Setup
#
# Installs and validates everything needed to run /ship:
#   1. Claude Code CLI
#   2. Everything Claude Code (ECC) plugin
#   3. Codex plugin + authentication
#   4. /ship skill files
#
# Usage:
#   bash setup.sh              # Full setup
#   bash setup.sh --check      # Validate only, don't install
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND_SRC="${SCRIPT_DIR}/skills/ship/SKILL.md"
COMMAND_DST="${HOME}/.claude/commands/ship.md"
CHECK_ONLY=false

if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
header() { echo -e "\n${CYAN}[$1]${NC}"; }

ERRORS=0

# ─────────────────────────────────────────────────────────────
# Check 1: Claude Code CLI
# ─────────────────────────────────────────────────────────────
header "1/7 Claude Code CLI"

if command -v claude &>/dev/null; then
  CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
  pass "Claude Code CLI found (${CLAUDE_VERSION})"
else
  fail "Claude Code CLI not found"
  info "Install: https://docs.anthropic.com/en/docs/claude-code/overview"
  info "  npm install -g @anthropic-ai/claude-code"
  ERRORS=$((ERRORS + 1))
fi

# ─────────────────────────────────────────────────────────────
# Check 2: Everything Claude Code (ECC) plugin
# ─────────────────────────────────────────────────────────────
header "2/7 Everything Claude Code (ECC) plugin"

ECC_INSTALLED=false

# Check marketplace + cache locations
if [ -d "${HOME}/.claude/plugins/marketplaces/everything-claude-code" ] || \
   [ -d "${HOME}/.claude/plugins/cache/everything-claude-code" ]; then
  ECC_INSTALLED=true
fi

if $ECC_INSTALLED; then
  pass "ECC plugin installed"
else
  if $CHECK_ONLY; then
    fail "ECC plugin not installed"
    info "Install with: claude /plugin marketplace add affaan-m/everything-claude-code"
    info "Then: claude /plugin install everything-claude-code@everything-claude-code"
    ERRORS=$((ERRORS + 1))
  else
    warn "ECC plugin not found — installing..."
    info "Adding marketplace..."
    claude /plugin marketplace add affaan-m/everything-claude-code 2>/dev/null || true
    info "Installing plugin..."
    claude /plugin install everything-claude-code@everything-claude-code 2>/dev/null || true

    # Verify
    if [ -d "${HOME}/.claude/plugins/marketplaces/everything-claude-code" ] || \
       [ -d "${HOME}/.claude/plugins/cache/everything-claude-code" ]; then
      pass "ECC plugin installed successfully"
    else
      fail "ECC plugin installation failed"
      info "Try manually: claude /plugin marketplace add affaan-m/everything-claude-code"
      ERRORS=$((ERRORS + 1))
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
# Check 3: Codex plugin
# ─────────────────────────────────────────────────────────────
header "3/7 Codex plugin"

CODEX_PLUGIN_INSTALLED=false

if [ -d "${HOME}/.claude/plugins/marketplaces/openai-codex" ] || \
   [ -d "${HOME}/.claude/plugins/cache/openai-codex" ]; then
  CODEX_PLUGIN_INSTALLED=true
fi

if $CODEX_PLUGIN_INSTALLED; then
  pass "Codex plugin installed"
else
  if $CHECK_ONLY; then
    fail "Codex plugin not installed"
    info "Install with: claude /plugin marketplace add openai/codex-plugin-cc"
    info "Then: claude /plugin install codex@openai-codex"
    ERRORS=$((ERRORS + 1))
  else
    warn "Codex plugin not found — installing..."
    info "Adding marketplace..."
    claude /plugin marketplace add openai/codex-plugin-cc 2>/dev/null || true
    info "Installing plugin..."
    claude /plugin install codex@openai-codex 2>/dev/null || true

    # Verify
    if [ -d "${HOME}/.claude/plugins/marketplaces/openai-codex" ] || \
       [ -d "${HOME}/.claude/plugins/cache/openai-codex" ]; then
      pass "Codex plugin installed successfully"
    else
      fail "Codex plugin installation failed"
      info "Try manually: claude /plugin marketplace add openai/codex-plugin-cc"
      ERRORS=$((ERRORS + 1))
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
# Check 4: Codex CLI authentication
# ─────────────────────────────────────────────────────────────
header "4/7 Codex CLI authentication"

if command -v codex &>/dev/null; then
  pass "Codex CLI found"

  # Check if codex is authenticated by attempting a dry-run
  # codex doesn't have a simple "am I logged in" command,
  # so we check for config/token files
  CODEX_CONFIG="${HOME}/.codex"
  CODEX_AUTH_EXISTS=false

  if [ -d "${CODEX_CONFIG}" ]; then
    # Look for auth tokens or config files
    if find "${CODEX_CONFIG}" -name "*.json" -o -name "auth" -o -name "credentials" 2>/dev/null | head -1 | grep -q .; then
      CODEX_AUTH_EXISTS=true
    fi
  fi

  # Also check environment variable
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    CODEX_AUTH_EXISTS=true
  fi

  if $CODEX_AUTH_EXISTS; then
    pass "Codex authentication configured"
  else
    warn "Codex may not be authenticated"
    info "Run: codex login"
    info "Or set OPENAI_API_KEY in your environment"
    if $CHECK_ONLY; then
      ERRORS=$((ERRORS + 1))
    else
      echo ""
      info "Please authenticate Codex now. Run this in your terminal:"
      echo -e "    ${YELLOW}codex login${NC}"
      echo ""
      info "After logging in, re-run this setup script with: bash setup.sh --check"
    fi
  fi
else
  warn "Codex CLI not found (optional — plugin uses built-in companion script)"
  info "Install if needed: npm install -g @openai/codex"
  info "The Codex plugin may work without the standalone CLI if OPENAI_API_KEY is set"

  if [ -n "${OPENAI_API_KEY:-}" ]; then
    pass "OPENAI_API_KEY is set — Codex plugin should work"
  else
    fail "Neither Codex CLI nor OPENAI_API_KEY found"
    info "Set OPENAI_API_KEY or run: codex login"
    ERRORS=$((ERRORS + 1))
  fi
fi

# ─────────────────────────────────────────────────────────────
# Check 5: /ship command installed
# ─────────────────────────────────────────────────────────────
header "5/7 /ship command"

if [ -f "${COMMAND_DST}" ]; then
  # Check if it's up to date by comparing the command file with the source SKILL.md
  # The command file has different frontmatter, so we compare content after frontmatter
  SHIP_INSTALLED=true

  # Simple size-based staleness check — if source changed, sizes likely differ
  SRC_SIZE=$(wc -c < "${COMMAND_SRC}" 2>/dev/null || echo "0")
  DST_SIZE=$(wc -c < "${COMMAND_DST}" 2>/dev/null || echo "0")

  if [ "$SRC_SIZE" != "$DST_SIZE" ]; then
    if $CHECK_ONLY; then
      warn "/ship command installed but may be outdated"
      info "Re-run setup.sh (without --check) to update"
    else
      info "Updating /ship command..."
      cp "${COMMAND_DST}" "${COMMAND_DST}.bak"
      # Regenerate from source — setup always installs the canonical version
      cp "${SCRIPT_DIR}/commands/ship.md" "${COMMAND_DST}" 2>/dev/null || \
        cp "${COMMAND_SRC}" "${COMMAND_DST}"
      pass "/ship command updated (backup at ${COMMAND_DST}.bak)"
    fi
  else
    pass "/ship command installed and up to date"
  fi
else
  if $CHECK_ONLY; then
    fail "/ship command not installed"
    info "Run setup.sh (without --check) to install"
    ERRORS=$((ERRORS + 1))
  else
    info "Installing /ship command..."
    mkdir -p "$(dirname "${COMMAND_DST}")"
    # Install from commands/ if available, else from skills/ship/SKILL.md
    if [ -f "${SCRIPT_DIR}/commands/ship.md" ]; then
      cp "${SCRIPT_DIR}/commands/ship.md" "${COMMAND_DST}"
    else
      cp "${COMMAND_SRC}" "${COMMAND_DST}"
    fi
    pass "/ship command installed to ${COMMAND_DST}"
  fi
fi

# Install the skill at ~/.claude/skills/ship/SKILL.md too (user-level skill).
# This makes the SKILL.md invokable via the Skill tool in addition to the /ship slash command.
SKILL_DST="${HOME}/.claude/skills/ship/SKILL.md"
if [ -f "${COMMAND_SRC}" ]; then
  SRC_SKILL_SIZE=$(wc -c < "${COMMAND_SRC}" 2>/dev/null || echo "0")
  if [ -f "${SKILL_DST}" ]; then
    DST_SKILL_SIZE=$(wc -c < "${SKILL_DST}" 2>/dev/null || echo "0")
    if [ "$SRC_SKILL_SIZE" != "$DST_SKILL_SIZE" ]; then
      if $CHECK_ONLY; then
        warn "ship skill installed but may be outdated"
      else
        info "Updating ship skill at ${SKILL_DST}..."
        cp "${SKILL_DST}" "${SKILL_DST}.bak"
        cp "${COMMAND_SRC}" "${SKILL_DST}"
        pass "ship skill updated (backup at ${SKILL_DST}.bak)"
      fi
    else
      pass "ship skill installed and up to date"
    fi
  else
    if $CHECK_ONLY; then
      warn "ship skill not installed at ${SKILL_DST} (optional — command still works)"
    else
      info "Installing ship skill to ${SKILL_DST}..."
      mkdir -p "$(dirname "${SKILL_DST}")"
      cp "${COMMAND_SRC}" "${SKILL_DST}"
      pass "ship skill installed to ${SKILL_DST}"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
# Check 6: Pipeline enforcement hooks
# ─────────────────────────────────────────────────────────────
header "6/7 Pipeline enforcement hooks"

HOOK_SCRIPT="${SCRIPT_DIR}/hooks/ship-gate.sh"
SETTINGS_FILE="${HOME}/.claude/settings.json"

if [ ! -f "${HOOK_SCRIPT}" ]; then
  fail "Hook script not found at ${HOOK_SCRIPT}"
  ERRORS=$((ERRORS + 1))
else
  pass "Hook script exists"
  chmod +x "${HOOK_SCRIPT}"

  # Check if hooks are configured in settings.json
  HOOKS_CONFIGURED=false
  if [ -f "${SETTINGS_FILE}" ]; then
    if jq -e '.hooks.PreToolUse[]? | select(.matcher | contains("Skill")) | .hooks[]? | select(.command | contains("ship-gate.sh"))' "${SETTINGS_FILE}" >/dev/null 2>&1; then
      HOOKS_CONFIGURED=true
    fi
  fi

  if $HOOKS_CONFIGURED; then
    pass "Pipeline hooks configured in settings.json"
  else
    if $CHECK_ONLY; then
      fail "Pipeline hooks not configured in ~/.claude/settings.json"
      info "Re-run setup.sh (without --check) to install hooks"
      ERRORS=$((ERRORS + 1))
    else
      info "Installing pipeline enforcement hooks..."

      # Matcher covers Skill, Agent, Edit, Write, Bash — the full set ship-gate.sh acts on.
      # Wiring only Skill+Agent (as earlier versions did) silently disabled the source-edit
      # block and the state-file deletion guard.
      if [ ! -f "${SETTINGS_FILE}" ]; then
        # Create minimal settings with hooks
        cat > "${SETTINGS_FILE}" <<HOOKJSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Skill|Agent|Edit|Write|Bash",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} pre", "timeout": 5, "statusMessage": "Checking /ship pipeline gate..." }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Skill|Agent|Bash",
        "hooks": [{ "type": "command", "command": "${HOOK_SCRIPT} post", "timeout": 5, "statusMessage": "Recording /ship pipeline step..." }]
      }
    ]
  }
}
HOOKJSON
        pass "Created settings.json with pipeline hooks"
      else
        # Settings file exists — add hooks using jq
        # Backup first
        cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.bak"

        PRE_HOOK="{\"matcher\":\"Skill|Agent|Edit|Write|Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"${HOOK_SCRIPT} pre\",\"timeout\":5,\"statusMessage\":\"Checking /ship pipeline gate...\"}]}"
        POST_HOOK="{\"matcher\":\"Skill|Agent|Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"${HOOK_SCRIPT} post\",\"timeout\":5,\"statusMessage\":\"Recording /ship pipeline step...\"}]}"

        jq ".hooks.PreToolUse += [${PRE_HOOK}] | .hooks.PostToolUse += [${POST_HOOK}]" "${SETTINGS_FILE}" > "${SETTINGS_FILE}.tmp" && \
          mv "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"

        if jq -e '.hooks.PreToolUse[]? | select(.matcher | contains("Skill")) | .hooks[]? | select(.command | contains("ship-gate.sh"))' "${SETTINGS_FILE}" >/dev/null 2>&1; then
          pass "Pipeline hooks installed (backup at ${SETTINGS_FILE}.bak)"
        else
          fail "Failed to install hooks — restoring backup"
          mv "${SETTINGS_FILE}.bak" "${SETTINGS_FILE}"
          ERRORS=$((ERRORS + 1))
        fi
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
# Check 7: Pipe-test the hook
# ─────────────────────────────────────────────────────────────
header "7/7 Hook pipe-test"

if [ -x "${HOOK_SCRIPT}" ]; then
  TEST_DIR=$(mktemp -d)
  cd "${TEST_DIR}"
  TESTS_PASSED=0
  TESTS_TOTAL=0

  run_test() {
    local desc="$1" expected="$2" input="$3" mode="$4"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    RESULT=$(echo "$input" | "${HOOK_SCRIPT}" "$mode" 2>&1)
    EXIT_CODE=$?

    case "$expected" in
      allow)
        if [ $EXIT_CODE -eq 0 ] && [ -z "$RESULT" ]; then
          pass "$desc"
          TESTS_PASSED=$((TESTS_PASSED + 1))
        else
          fail "$desc (expected: allow, got output)"
          ERRORS=$((ERRORS + 1))
        fi
        ;;
      deny)
        if echo "$RESULT" | grep -q "permissionDecision.*deny"; then
          pass "$desc"
          TESTS_PASSED=$((TESTS_PASSED + 1))
        else
          fail "$desc (expected: deny, got allow)"
          ERRORS=$((ERRORS + 1))
        fi
        ;;
      record)
        if echo "$RESULT" | grep -q "COMPLETE"; then
          pass "$desc"
          TESTS_PASSED=$((TESTS_PASSED + 1))
        else
          fail "$desc (expected: record, got nothing)"
          ERRORS=$((ERRORS + 1))
        fi
        ;;
    esac
  }

  # ── No state file: everything allowed ──
  rm -f .ship-pipeline-state

  run_test "T1: No state file → Skill allowed" "allow" \
    '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' "pre"

  run_test "T2: No state file → Edit allowed" "allow" \
    '{"tool_name":"Edit","tool_input":{"file_path":"src/index.ts"}}' "pre"

  # ── State file exists, Phase 1 not done ──
  echo "# pipeline active" > .ship-pipeline-state

  run_test "T3: Pipeline active, no steps done → Edit source blocked" "deny" \
    '{"tool_name":"Edit","tool_input":{"file_path":"src/lib/foo.ts"}}' "pre"

  run_test "T4: Pipeline active, no steps done → Edit plan file allowed" "allow" \
    '{"tool_name":"Edit","tool_input":{"file_path":".claude/PRPs/plan.md"}}' "pre"

  run_test "T5: Pipeline active, no steps done → Skill tdd blocked (needs 1A+1B)" "deny" \
    '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' "pre"

  run_test "T6: Pipeline active, no steps done → Skill prp-plan allowed (no prereqs)" "allow" \
    '{"tool_name":"Skill","tool_input":{"skill":"prp-plan"}}' "pre"

  # ── Phase 1A done only ──
  echo "STEP_1A=done" > .ship-pipeline-state

  run_test "T7: 1A done → Edit source still blocked (1B missing)" "deny" \
    '{"tool_name":"Edit","tool_input":{"file_path":"src/lib/foo.ts"}}' "pre"

  run_test "T8: 1A done → Skill tdd blocked (1B missing)" "deny" \
    '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' "pre"

  # ── Phase 1A + 1B done ──
  echo "STEP_1B=done" >> .ship-pipeline-state

  run_test "T9: 1A+1B done → Edit source allowed (can code now)" "allow" \
    '{"tool_name":"Edit","tool_input":{"file_path":"src/lib/foo.ts"}}' "pre"

  run_test "T10: 1A+1B done → Skill tdd allowed" "allow" \
    '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' "pre"

  run_test "T11: 1A+1B done → Skill verify blocked (needs Phase 2+3)" "deny" \
    '{"tool_name":"Skill","tool_input":{"skill":"verify"}}' "pre"

  # ── Phase 2 done, review fix-retry ──
  echo "STEP_2=done" >> .ship-pipeline-state
  echo "STEP_3A=done" >> .ship-pipeline-state

  run_test "T12: Review fix-retry → Edit source allowed" "allow" \
    '{"tool_name":"Edit","tool_input":{"file_path":"src/lib/foo.ts"}}' "pre"

  run_test "T13: 3A done → Skill security-review allowed (parallel with 3A)" "allow" \
    '{"tool_name":"Skill","tool_input":{"skill":"security-review"}}' "pre"

  # ── Block state file deletion mid-pipeline ──
  run_test "T14: rm .ship-pipeline-state mid-pipeline → blocked" "deny" \
    '{"tool_name":"Bash","tool_input":{"command":"rm -f .ship-pipeline-state"}}' "pre"

  # ── Post: record step completion ──
  run_test "T15: PostToolUse records step" "record" \
    '{"tool_name":"Skill","tool_input":{"skill":"prp-plan"}}' "post"

  # ── STEP_4A (regression tests) via Bash matcher ──
  # State: Phase 1+2+3 done
  cat > .ship-pipeline-state <<'STATE'
STEP_1A=done
STEP_1B=done
STEP_2=done
STEP_3A=done
STEP_3B=done
STEP_3C=done
STATE

  # T17 needs a PASSING regression-check verdict (baseline diff gate is enforced for STEP_4A post)
  cat > .ship-4a-regression-check.json <<'VERDICT'
{"verdict":"PASS","new_failures":[]}
VERDICT

  run_test "T17: 3A+3B+3C done → 'npm test' Bash resolves to STEP_4A and runs" "record" \
    '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' "post"

  rm -f .ship-4a-regression-check.json

  # Reset to 3A+3B only (drop 3C) for T18
  cat > .ship-pipeline-state <<'STATE'
STEP_1A=done
STEP_1B=done
STEP_2=done
STEP_3A=done
STEP_3B=done
STATE

  run_test "T18: 3A+3B done only → 'npm test' blocked (STEP_3C missing)" "deny" \
    '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' "pre"

  # ── STEP_3C prereq for Phase 5A ──
  # State: Phase 1+2+3A+3B done but NOT 3C
  cat > .ship-pipeline-state <<'STATE'
STEP_1A=done
STEP_1B=done
STEP_2=done
STEP_3A=done
STEP_3B=done
STATE

  run_test "T19: 3A+3B done, 3C missing → Skill verify blocked (needs 3C now)" "deny" \
    '{"tool_name":"Skill","tool_input":{"skill":"verify"}}' "pre"

  # ── Coverage parser (STEP_2 post-hook) ──
  # State: Phase 1 done, running Phase 2 post-check
  cat > .ship-pipeline-state <<'STATE'
STEP_1A=done
STEP_1B=done
STATE

  # T20: No coverage file → block STEP_2 recording
  rm -rf coverage coverage-summary.json
  RESULT=$(echo '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' | "${HOOK_SCRIPT}" post 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "Coverage report not found"; then
    pass "T20: No coverage file → STEP_2 completion blocked"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T20: No coverage file → expected block, got: $(echo "$RESULT" | head -c 200)"
    ERRORS=$((ERRORS + 1))
  fi

  # T21: Coverage below threshold → block
  mkdir -p coverage
  echo '{"total":{"lines":{"pct":80}}}' > coverage/coverage-summary.json
  RESULT=$(echo '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' | "${HOOK_SCRIPT}" post 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "BELOW threshold"; then
    pass "T21: Coverage 80% below 95% threshold → STEP_2 blocked"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T21: Coverage below threshold → expected block, got: $(echo "$RESULT" | head -c 200)"
    ERRORS=$((ERRORS + 1))
  fi

  # T22: Coverage at/above threshold → record
  echo '{"total":{"lines":{"pct":96}}}' > coverage/coverage-summary.json
  run_test "T22: Coverage 96% above 95% threshold → STEP_2 recorded" "record" \
    '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' "post"

  # T23: Bypass via SHIP_SKIP_COVERAGE_CHECK=1
  rm -rf coverage
  RESULT=$(echo '{"tool_name":"Skill","tool_input":{"skill":"tdd"}}' | SHIP_SKIP_COVERAGE_CHECK=1 "${HOOK_SCRIPT}" post 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "COMPLETE"; then
    pass "T23: SHIP_SKIP_COVERAGE_CHECK=1 bypasses coverage check"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T23: SHIP_SKIP_COVERAGE_CHECK=1 → expected record, got: $(echo "$RESULT" | head -c 200)"
    ERRORS=$((ERRORS + 1))
  fi

  # ── Baseline enforcement (pre-state-file) ──
  rm -f .ship-pipeline-state .ship-baseline-tests.json

  # T30: Missing baseline → block state file creation via Bash redirect
  RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo init > .ship-pipeline-state"}}' | "${HOOK_SCRIPT}" pre 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "Cannot create .ship-pipeline-state without a baseline"; then
    pass "T30: Missing baseline → state file creation blocked"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T30: Missing baseline → expected block, got: $(echo "$RESULT" | head -c 200)"
    ERRORS=$((ERRORS + 1))
  fi

  # T31: Malformed baseline (missing test_command) → block
  echo '{"failed_tests":[]}' > .ship-baseline-tests.json
  RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo init > .ship-pipeline-state"}}' | "${HOOK_SCRIPT}" pre 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "malformed" && echo "$RESULT" | grep -q "test_command"; then
    pass "T31: Malformed baseline (missing test_command) → state file creation blocked"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T31: Malformed baseline → expected block with field name, got: $(echo "$RESULT" | head -c 200)"
    ERRORS=$((ERRORS + 1))
  fi

  # T32: Valid baseline → state file creation allowed
  echo '{"test_command":"npm test","failed_tests":["already.broken"],"total":10,"passed":9,"failed":1}' > .ship-baseline-tests.json
  run_test "T32: Valid baseline → state file creation allowed" "allow" \
    '{"tool_name":"Bash","tool_input":{"command":"echo init > .ship-pipeline-state"}}' "pre"

  # Cleanup before the existing 4A verdict tests (they want fresh state)
  rm -f .ship-pipeline-state

  # ── Verdict math sanity check ──
  # State: Phase 1+2+3 done
  cat > .ship-pipeline-state <<'STATE'
STEP_1A=done
STEP_1B=done
STEP_2=done
STEP_3A=done
STEP_3B=done
STEP_3C=done
STATE
  # Baseline has two known failures
  echo '{"test_command":"npm test","failed_tests":["existing.test.ts > A","existing.test.ts > B"]}' > .ship-baseline-tests.json

  # T33: Verdict claims pre_existing that's NOT in baseline → block
  cat > .ship-4a-regression-check.json <<'VERDICT'
{"verdict":"PASS","new_failures":[],"pre_existing_failures":["existing.test.ts > A","lying.about.this.one"]}
VERDICT
  RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' | "${HOOK_SCRIPT}" post 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "pre_existing_failures but NOT in baseline" && echo "$RESULT" | grep -q "lying.about.this.one"; then
    pass "T33: Verdict math — pre_existing not in baseline → STEP_4A blocked, liar identified"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T33: Verdict math → expected block for pre_existing-not-in-baseline, got: $(echo "$RESULT" | head -c 250)"
    ERRORS=$((ERRORS + 1))
  fi

  # T34: Verdict claims new_failure that IS in baseline (mislabeling pre-existing as new) → block
  cat > .ship-4a-regression-check.json <<'VERDICT'
{"verdict":"PASS","new_failures":["existing.test.ts > A"],"pre_existing_failures":[]}
VERDICT
  RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' | "${HOOK_SCRIPT}" post 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "new_failures but they were ALREADY in baseline" && echo "$RESULT" | grep -q "existing.test.ts > A"; then
    pass "T34: Verdict math — new_failure already in baseline → STEP_4A blocked"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T34: Verdict math → expected block for new-in-baseline, got: $(echo "$RESULT" | head -c 250)"
    ERRORS=$((ERRORS + 1))
  fi

  # T35: Correct verdict math → STEP_4A recorded
  cat > .ship-4a-regression-check.json <<'VERDICT'
{"verdict":"PASS","new_failures":[],"pre_existing_failures":["existing.test.ts > A","existing.test.ts > B"]}
VERDICT
  run_test "T35: Correct verdict math (pre⊆baseline, new∩baseline=∅) → STEP_4A recorded" "record" \
    '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' "post"

  # Cleanup
  rm -f .ship-4a-regression-check.json .ship-baseline-tests.json

  # ── STEP_4A regression-check verdict ──
  # State: Phase 1+2+3 done, running Phase 4A post-check
  cat > .ship-pipeline-state <<'STATE'
STEP_1A=done
STEP_1B=done
STEP_2=done
STEP_3A=done
STEP_3B=done
STEP_3C=done
STATE

  # T27: Missing .ship-4a-regression-check.json → block
  rm -f .ship-4a-regression-check.json
  RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' | "${HOOK_SCRIPT}" post 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "regression check file missing"; then
    pass "T27: No regression-check verdict → STEP_4A blocked"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T27: No verdict file → expected block, got: $(echo "$RESULT" | head -c 200)"
    ERRORS=$((ERRORS + 1))
  fi

  # T28: Verdict=FAIL with new_failures → block
  cat > .ship-4a-regression-check.json <<'VERDICT'
{"verdict":"FAIL","new_failures":["foo.test.ts > should bar","baz.test.ts > should qux"],"pre_existing_failures":[]}
VERDICT
  RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' | "${HOOK_SCRIPT}" post 2>&1)
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if echo "$RESULT" | grep -q "Regression detected" && echo "$RESULT" | grep -q "foo.test.ts"; then
    pass "T28: Verdict=FAIL with new_failures → STEP_4A blocked, failures listed"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    fail "T28: Verdict=FAIL → expected block with failure list, got: $(echo "$RESULT" | head -c 200)"
    ERRORS=$((ERRORS + 1))
  fi

  # T29: Verdict=PASS → record
  cat > .ship-4a-regression-check.json <<'VERDICT'
{"verdict":"PASS","new_failures":[],"pre_existing_failures":["already.broken.test"]}
VERDICT
  run_test "T29: Verdict=PASS → STEP_4A recorded (pre-existing failures ignored)" "record" \
    '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' "post"

  # Cleanup baseline artifacts before subsequent tests
  rm -f .ship-4a-regression-check.json

  # ── Broadened state-file deletion guard ──
  echo "STEP_1A=done" > .ship-pipeline-state

  run_test "T24: mv .ship-pipeline-state mid-pipeline → blocked" "deny" \
    '{"tool_name":"Bash","tool_input":{"command":"mv .ship-pipeline-state /tmp/"}}' "pre"

  run_test "T25: > redirect to clobber .ship-pipeline-state → blocked" "deny" \
    '{"tool_name":"Bash","tool_input":{"command":"echo hi > .ship-pipeline-state"}}' "pre"

  run_test "T26: unlink .ship-pipeline-state → blocked" "deny" \
    '{"tool_name":"Bash","tool_input":{"command":"unlink .ship-pipeline-state"}}' "pre"

  # ── All phases done, allow state file deletion ──
  for step in STEP_1B STEP_2 STEP_3A STEP_3B STEP_3C STEP_4A STEP_4B STEP_5A STEP_5B STEP_5C STEP_6 STEP_7A STEP_7B; do
    echo "${step}=done" >> .ship-pipeline-state
  done

  run_test "T16: All phases done → rm .ship-pipeline-state allowed" "allow" \
    '{"tool_name":"Bash","tool_input":{"command":"rm -f .ship-pipeline-state"}}' "pre"

  info "${TESTS_PASSED}/${TESTS_TOTAL} tests passed"

  # Cleanup
  rm -rf "${TEST_DIR}"
  cd "${SCRIPT_DIR}"
else
  warn "Hook script not executable — skipping pipe-test"
fi

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"

if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}All prerequisites satisfied.${NC}"
  echo ""
  echo "  Reload plugins in Claude Code:"
  echo -e "    ${CYAN}/reload-plugins${NC}"
  echo ""
  echo "  Then start shipping:"
  echo -e "    ${CYAN}/ship Add webhook support for card expiry notifications${NC}"
else
  echo -e "${RED}${ERRORS} prerequisite(s) failed.${NC}"
  echo ""
  echo "  Fix the issues above and re-run:"
  echo -e "    ${CYAN}bash ${SCRIPT_DIR}/setup.sh${NC}"
  echo ""
  echo "  Or validate without installing:"
  echo -e "    ${CYAN}bash ${SCRIPT_DIR}/setup.sh --check${NC}"
  exit 1
fi
