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
    if jq -e '.hooks.PreToolUse[]? | select(.matcher == "Skill") | .hooks[]? | select(.command | contains("ship-gate.sh"))' "${SETTINGS_FILE}" >/dev/null 2>&1; then
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

      if [ ! -f "${SETTINGS_FILE}" ]; then
        # Create minimal settings with hooks
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

        SKILL_PRE_HOOK="{\"matcher\":\"Skill\",\"hooks\":[{\"type\":\"command\",\"command\":\"${HOOK_SCRIPT} pre\",\"timeout\":5,\"statusMessage\":\"Checking /ship pipeline gate...\"}]}"
        AGENT_PRE_HOOK="{\"matcher\":\"Agent\",\"hooks\":[{\"type\":\"command\",\"command\":\"${HOOK_SCRIPT} pre\",\"timeout\":5,\"statusMessage\":\"Checking /ship pipeline gate...\"}]}"
        SKILL_POST_HOOK="{\"matcher\":\"Skill\",\"hooks\":[{\"type\":\"command\",\"command\":\"${HOOK_SCRIPT} post\",\"timeout\":5,\"statusMessage\":\"Recording /ship pipeline step...\"}]}"
        AGENT_POST_HOOK="{\"matcher\":\"Agent\",\"hooks\":[{\"type\":\"command\",\"command\":\"${HOOK_SCRIPT} post\",\"timeout\":5,\"statusMessage\":\"Recording /ship pipeline step...\"}]}"

        jq ".hooks.PreToolUse += [${SKILL_PRE_HOOK}, ${AGENT_PRE_HOOK}] | .hooks.PostToolUse += [${SKILL_POST_HOOK}, ${AGENT_POST_HOOK}]" "${SETTINGS_FILE}" > "${SETTINGS_FILE}.tmp" && \
          mv "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"

        if jq -e '.hooks.PreToolUse[]? | select(.matcher == "Skill") | .hooks[]? | select(.command | contains("ship-gate.sh"))' "${SETTINGS_FILE}" >/dev/null 2>&1; then
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

  # ── All phases done, allow state file deletion ──
  for step in STEP_3B STEP_3C STEP_4B STEP_5A STEP_5B STEP_5C STEP_6 STEP_7A STEP_7B; do
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
