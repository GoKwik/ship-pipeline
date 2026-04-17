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

## Product Review Commands

In addition to `/ship`, this plugin provides a product intelligence system:

| Command | What | Output |
|---------|------|--------|
| `/contextualize` | Generate AI context bible for the repo | `.claude/product-review/CONTEXT.md` |
| `/review-tech` | Analyze architecture, security, deps, tech debt | `.claude/product-review/TECH-REVIEW.md` |
| `/review-features` | Identify feature gaps, UX improvements | `.claude/product-review/FEATURES-REVIEW.md` |
| `/review-product` | Run all above + merge + rank + Linear sync | `.claude/product-review/BRIEF.md` |

Each command works standalone or as part of the `/review-product` coordinator.

### Modes

- `--light` (default) — Incremental scan since last run. Fast. Linear read-only.
- `--full` — Deep scan of entire codebase. Creates/closes Linear issues.

### Linear Integration (optional)

Set `LINEAR_API_KEY` in your environment. Configure `.claude/product-review/config.json` with your team and project IDs.

### Scheduled Runs

```
/schedule create --name "product-review-light" --cron "0 9 * * 1-5" --prompt "/review-product --light"
/schedule create --name "product-review-full" --cron "0 9 * * 1" --prompt "/review-product --full"
```

## Install

Two commands — no cloning, no setup scripts:

```bash
claude /plugin marketplace add GoKwik/ship-pipeline
claude /plugin install ship@ship-pipeline
```

Then in any Claude Code session:

```
/ship Add webhook support for card expiry notifications
```

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview)
- [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) plugin
- [Codex plugin](https://github.com/openai/codex-plugin-cc) + authentication

### Team Onboarding

New team member? Same two commands:

```bash
claude /plugin marketplace add GoKwik/ship-pipeline
claude /plugin install ship@ship-pipeline
```

### Updating

```bash
claude /plugin update ship@ship-pipeline
```

### Manual Setup (alternative)

If you prefer cloning the repo directly:

```bash
git clone git@github.com:GoKwik/ship-pipeline.git
cd ship-pipeline
bash setup.sh
```

## File Structure

```
ship-pipeline/
├── .claude-plugin/
│   ├── plugin.json                ← Plugin manifest
│   └── marketplace.json           ← Marketplace descriptor
├── skills/
│   ├── ship/                      ← /ship pipeline skill
│   │   ├── SKILL.md
│   │   └── .provenance.json
│   ├── contextualize/             ← /contextualize AI bible skill
│   │   ├── SKILL.md
│   │   └── .provenance.json
│   ├── review-tech/               ← /review-tech technical health skill
│   │   ├── SKILL.md
│   │   └── .provenance.json
│   ├── review-features/           ← /review-features product intelligence skill
│   │   ├── SKILL.md
│   │   └── .provenance.json
│   └── review-product/            ← /review-product coordinator skill
│       ├── SKILL.md
│       └── .provenance.json
├── commands/
│   ├── ship.md                    ← /ship command entry
│   ├── contextualize.md           ← /contextualize command entry
│   ├── review-tech.md             ← /review-tech command entry
│   ├── review-features.md         ← /review-features command entry
│   └── review-product.md          ← /review-product command entry
├── hooks/
│   └── ship-gate.sh               ← Hook enforcement for /ship pipeline
├── setup.sh                       ← Installer + validator (11 checks)
└── README.md
```
