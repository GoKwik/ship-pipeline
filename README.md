# /ship — Full-Cycle Shipping Pipeline

**v1.1.0** · One command to take a task from idea to merged PR with deterministic, hook-enforced quality gates.

```
/ship Add webhook support for card expiry notifications
```

When you invoke `/ship`, the first line Claude prints is:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SHIP PIPELINE  v1.1.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

— so you always know which version is running.

## What It Does

Pipeline Init (captures a test baseline before anything else) → 7 phases, each with a fix-retry loop and a hard gate:

| Phase | What | Tools |
|-------|------|-------|
| Init | Capture test baseline + create state file | test runner + state init |
| 1. Plan | Design + adversarial challenge + user confirmation | ECC `/prp-plan` + Codex `/adversarial-review` |
| 2. TDD | Tests first, then implement — **coverage ≥ 95%** | ECC `/tdd` |
| 3. Review | 3 independent reviewers (all three required) | ECC `/code-review` + `/security-review` + Codex `/review` |
| 4. Test | Regression diff vs baseline + E2E | `npm test` + ECC `/e2e` |
| 5. Verify | Build + lint + types + UI + native simulator | ECC `/verify` + `/browser-qa` + `/flutter-test` |
| 6. Eval | Acceptance criteria validation | ECC `/eval` |
| 7. Deliver | Commit + PR | ECC `/prp-commit` + `/prp-pr` |

If any phase fails, it retries with a different fix (max 3 attempts). If it still fails, hard stop — no skipping.

## Hook-Enforced Gates (v1.1.0)

The `hooks/ship-gate.sh` bash hook runs on every tool call and blocks actions that would skip a gate. Not text guidance — actual `permissionDecision: "deny"` returned to Claude Code.

| # | Gate | How it's enforced |
|---|------|-------------------|
| 1 | Baseline captured before state file | Pre-hook blocks `.ship-pipeline-state` creation unless `.ship-baseline-tests.json` exists |
| 2 | Baseline schema valid | `jq` validates required fields (`test_command`, `failed_tests[]`) |
| 3 | Source edits blocked before plan approved | Pre-hook on Edit/Write denies until STEP_1A + STEP_1B done |
| 4 | Step ordering (1A → 1B → 2 → 3A/B/C → 4A → 4B → 5A → 5B/5C → 6 → 7A → 7B) | Pre-hook checks prerequisite set for each Skill/Agent/Bash invocation |
| 5 | Adversarial review verdict = PASS | Post-hook reads `.ship-1b-verdict`; STEP_1B not recorded otherwise |
| 6 | Coverage ≥ 95% | Post-hook parses `coverage/coverage-summary.json`; STEP_2 not recorded below threshold |
| 7 | Regression diff against baseline | Post-hook requires `.ship-4a-regression-check.json` with `verdict: PASS` |
| 8 | Verdict math sanity | Post-hook cross-checks `pre_existing_failures ⊆ baseline_failures` and `new_failures ∩ baseline_failures = ∅` — prevents mislabeling a regression as pre-existing |
| 9 | Codex review is a real prereq | STEP_3C required before 4B/5A (not bypassable) |
| 10 | State-file deletion until pipeline done | Pre-hook blocks `rm`, `unlink`, `shred`, `mv`, `>` redirect, `find -delete` against the state file before STEP_7B |

Everything else the skill text says (reviewer P0/P1 counts, eval pass rate, fix-loop attempt counts) is still guideline-only — the hook-enforced set is listed explicitly above.

## Regression vs Pre-Existing Failure

Phase 4A runs the full test suite and compares against the baseline captured at pipeline start:

```
new_failures            = current_failures  -  baseline_failures   ← blocks /ship
pre_existing_failures   = current_failures  ∩  baseline_failures   ← reported, not blocking
fixed_tests             = baseline_failures  -  current_failures   ← bonus
```

A test that was broken before `/ship` started stays in `pre_existing_failures` forever — surfaced in reporting but never gates progress. Only tests that went PASS → FAIL due to your change count as regressions.

The hook cross-checks the verdict against the actual baseline, so you can't get past the gate by mislabeling a regression as "pre-existing."

## Install

Clone the repo and run the setup script:

```bash
git clone git@github.com:GoKwik/ship-pipeline.git
cd ship-pipeline
bash setup.sh
```

`setup.sh` validates prerequisites, installs the `/ship` command + skill to `~/.claude/`, wires the enforcement hooks into `~/.claude/settings.json`, and runs 35 self-tests (all must pass).

Then in any Claude Code session:

```
/ship Add webhook support for card expiry notifications
```

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview)
- [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) plugin
- [Codex plugin](https://github.com/openai/codex-plugin-cc) + authentication

### Updating

```bash
cd ship-pipeline
git pull
bash setup.sh
```

Run `bash setup.sh --check` at any time to re-validate your install without modifying anything.

## Configuration

| Env var | Default | Effect |
|---------|---------|--------|
| `SHIP_COVERAGE_THRESHOLD` | `95` | Minimum line coverage % for Phase 2 |
| `SHIP_SKIP_COVERAGE_CHECK` | `0` | Set to `1` for projects without coverage tooling (skips the Phase 2 gate) |

## Artifacts Written During a Run

| File | Created at | Purpose |
|------|-----------|---------|
| `.ship-baseline-tests.json` | Init Step A | Pre-change test pass/fail snapshot |
| `.ship-pipeline-state` | Init Step B | Tracks completed steps; hooks read this |
| `.ship-1b-verdict` | End of Phase 1B | `PASS` when adversarial review converges |
| `.ship-4a-regression-check.json` | Phase 4A | Verdict + regression/pre-existing/fixed sets |
| `.claude/ship-learnings/*.md` | After each phase | Deduplicated learnings, fed back into future runs |
| `.claude/ship-logs/YYYY-MM-DD.log` | Per step | Timestamped audit trail |

`.ship-pipeline-state` is removed at Phase 7B (PR created). Others persist for inspection.

## Auto-Learning

Every `/ship` run appends to `.claude/ship-learnings/<phase>.md` — but with a dedup protocol:

- Read the file first before writing
- Same root cause already present → update its `Seen:` count, don't duplicate
- Clean pass with no issues → write nothing
- File exceeds ~20 entries → consolidate related learnings into broader rules

Subsequent runs read the file before starting each phase (RECALL) so past lessons inform current behavior.

## File Structure

```
ship-pipeline/
├── .claude-plugin/
│   ├── plugin.json            ← Plugin manifest (declares skills, commands, hooks)
│   └── marketplace.json       ← Marketplace descriptor
├── skills/ship/
│   └── SKILL.md               ← Source of truth — full pipeline spec, mirrors commands/ship.md
├── commands/
│   └── ship.md                ← /ship slash command entry point
├── hooks/
│   ├── hooks.json             ← Hook wiring for plugin auto-install
│   └── ship-gate.sh           ← Hook enforcement (gates, verdicts, state file protection)
├── setup.sh                   ← Manual installer + validator (35 self-tests)
└── README.md                  ← You are here
```

## Version

**1.1.0** (2026-04-21)

### Changelog

**v1.1.0**
- Coverage gate raised 80 → 95% with post-hook parser for `coverage-summary.json`
- Baseline capture at init + Phase 4A regression diff against baseline
- Hook-enforced baseline presence + schema validity
- Hook-enforced Phase 4A verdict math sanity (anti-cheat)
- STEP_4A added as distinct regression-test step
- STEP_3C (Codex review) now a required prereq of 4B/5A
- State-file deletion guard broadened (rm/unlink/shred/mv/redirect/find)
- Plugin auto-install wires hooks (previously only `setup.sh` did)
- `setup.sh` matcher widened to `Skill|Agent|Edit|Write|Bash` (Edit/Write/Bash logic was dead code before)
- Adversarial Review Summary required before Phase 1 confirmation
- Version banner printed on every `/ship` invocation
- Self-tests: 16 → 35

**v1.0.0**
- Initial Claude Code installable plugin — 7 phases, hook-enforced step ordering, auto-learning
