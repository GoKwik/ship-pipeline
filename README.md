# /ship — Full-Cycle Shipping Pipeline

One command to take a task from idea to merged PR with deterministic quality enforcement.

```
/ship Add webhook support for card expiry notifications
```

## What It Does

7 phases, each with fix-retry loops and hard quality gates:

| Phase | What | Tools |
|-------|------|-------|
| 1. Plan | Design + adversarial challenge | ECC `/prp-plan` + Codex `/adversarial-review` |
| 2. TDD | Tests first, then implement | ECC `/tdd` |
| 3. Review | 3 independent reviewers | ECC `/code-review` + `/security-review` + Codex `/review` |
| 4. Test | Full regression + E2E | `npm test` + ECC `/e2e` |
| 5. Verify | Build + lint + types + UI + native simulator | ECC `/verify` + `/browser-qa` + `/flutter-test` |
| 6. Eval | Acceptance criteria validation | ECC `/eval` |
| 7. Deliver | Commit + PR | ECC `/prp-commit` + `/prp-pr` |

If any phase fails, it retries with a different fix (max 3 attempts). If it still fails, hard stop — no skipping.

### Key Features

- **Hook-enforced gates** — a bash hook prevents skipping phases or editing code before the plan is approved
- **Native simulator testing** (Phase 5C) — always attempted; auto-detects Flutter, React Native, Expo, Capacitor projects. Asks user to approve skip if simulator isn't available.
- **Auto-learning** — captures learnings after each phase, deduplicates, and feeds them back into future runs. Learnings stored in `.claude/ship-learnings/`.

## Setup

```bash
# Clone this repo
git clone <repo-url> ship-pipeline
cd ship-pipeline

# Run setup (installs plugins + /ship command + hooks)
bash setup.sh

# Validate without installing
bash setup.sh --check
```

### Prerequisites (installed by setup.sh)

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview)
- [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) plugin
- [Codex plugin](https://github.com/openai/codex-plugin-cc) + authentication

## Team Onboarding

New team member? One command:

```bash
bash /path/to/ship-pipeline/setup.sh
```

Then in any Claude Code session:

```
/ship <describe what you want to build>
```

## Updating

When the skill is updated, team members re-run setup:

```bash
cd ship-pipeline && git pull && bash setup.sh
```

## File Structure

```
ship-pipeline/
├── README.md                  ← You are here
├── setup.sh                   ← One-command installer + validator (16 tests)
├── skills/ship/
│   ├── SKILL.md               ← Source of truth — full pipeline spec
│   └── .provenance.json       ← Metadata
├── commands/
│   └── ship.md                ← Command entry point (installed to ~/.claude/commands/)
└── hooks/
    └── ship-gate.sh           ← Hook enforcement (prereqs, edit blocks, learning reminders)
```
