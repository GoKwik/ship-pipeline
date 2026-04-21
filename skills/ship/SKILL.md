---
name: ship
description: "Full-cycle shipping pipeline v1.1.0: plan → TDD → review → test → verify → eval → deliver. One command with hard quality gates and fix-retry loops. Requires ECC + Codex plugins."
origin: custom
version: "1.1.0"
tools: Read, Write, Edit, Bash, Grep, Glob, Agent, Skill
---

# /ship — Full-Cycle Shipping Pipeline (v1.1.0)

One command to take a task from idea to merged PR with deterministic quality enforcement at every step.

## Version Banner (MANDATORY FIRST OUTPUT)

Before any other action — even before the Pipeline State Initialization bash block — print this banner verbatim to the user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SHIP PIPELINE  v1.1.0
 Updated: 2026-04-21 (coverage 95%, baseline diff, STEP_4A, verdict sanity)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

This tells the user exactly which pipeline version is running. If they expected a newer version, they will stop you here.

## When to Activate

- User says `/ship <task description>`
- User wants to implement a feature end-to-end with quality gates
- User wants a deterministic, no-compromise shipping workflow

## Pipeline State Initialization

**MANDATORY FIRST ACTION:** Complete these 2 steps IN ORDER before Phase 1.

### Step A: Capture test baseline (BEFORE creating state file)

Run the project's full test suite NOW, before anything else. This gives us a pre-change snapshot so Phase 4A can distinguish regressions (newly failing tests) from pre-existing failures (already broken before `/ship` started).

**Important:** This runs while the enforcement hook is INACTIVE (state file doesn't exist yet, so `npm test`-like commands are not blocked by STEP_4A matching).

Detect the project's test runner (from `package.json` scripts, `pyproject.toml`, `go.mod`, `Cargo.toml`, `pom.xml`, `build.gradle`, etc.) and run it with structured output where possible:

| Runner | Command |
|--------|---------|
| vitest | `npx vitest run --reporter=json > /tmp/ship-baseline.json` |
| jest   | `npx jest --json --outputFile=/tmp/ship-baseline.json` |
| npm    | `npm test -- --json --outputFile=/tmp/ship-baseline.json` |
| pytest | `pytest --json-report --json-report-file=/tmp/ship-baseline.json` |
| go     | `go test -json ./... > /tmp/ship-baseline.json` |
| cargo  | `cargo test --message-format=json > /tmp/ship-baseline.json` |

Then write `.ship-baseline-tests.json` with this schema:

```json
{
  "captured_at": "<ISO-8601 timestamp>",
  "test_command": "<exact command used>",
  "runner": "vitest|jest|pytest|go|cargo|other",
  "total": <N>,
  "passed": <N>,
  "failed": <N>,
  "failed_tests": ["<stable test id>", ...]
}
```

Edge cases:
- **All tests pass:** write `failed_tests: []` — still capture the baseline.
- **No tests in repo:** write `{"total": 0, "failed_tests": [], "note": "no tests detected"}`.
- **Test runner not installed / setup error:** do NOT proceed. Ask the user to fix the test environment first.
- **Flaky tests:** run twice and record the stable fail set (tests that failed both runs). Document any flakes in the `note` field.

### Step B: Initialize pipeline state

```bash
echo "# /ship pipeline state — $(date -Iseconds)" > .ship-pipeline-state
echo "# Task: <task description>" >> .ship-pipeline-state

# Auto-detect mobile app project
IS_MOBILE=false
if [[ -d "ios" || -d "android" || -f "pubspec.yaml" || -f "react-native.config.js" \
   || -f "capacitor.config.ts" || -f "capacitor.config.json" ]]; then
  IS_MOBILE=true
fi
if [[ -f "app.json" ]] && grep -q '"expo"' app.json 2>/dev/null; then
  IS_MOBILE=true
fi
echo "MOBILE_APP=${IS_MOBILE}" >> .ship-pipeline-state

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

After this, verify `.ship-baseline-tests.json` exists. If missing, HARD STOP — do not proceed to Phase 1.

The `.ship-pipeline-state` file is used by enforcement hooks to prevent skipping steps. If this file does not exist, the pipeline gates are disabled.
The `MOBILE_APP` flag determines whether Phase 5C (Native Simulator QA) is mandatory.

## Prerequisites

Both plugins must be installed and configured:
- **Everything Claude Code (ECC)** — provides plan, tdd, review, verify, e2e, eval, browser-qa, commit, PR skills
- **Codex plugin** — provides adversarial-review and implementation review via GPT

If either is missing, stop immediately:
```
HARD STOP: Missing prerequisites.
Run the setup script: bash /path/to/ship-pipeline/setup.sh
```

---

## The Pipeline

7 phases. Each phase has a fix-retry loop. Hard gate between phases — no skipping, no exceptions.

```
Phase 1: PLAN          → design + adversarial challenge
Phase 2: TDD           → tests first, then implementation
Phase 3: REVIEW        → 3 independent reviewers (Claude + Codex + security)
Phase 4: TEST          → full regression + E2E
Phase 5: VERIFY        → build + lint + types + UI spot-check + native simulator
Phase 6: EVAL          → acceptance criteria validation
Phase 7: DELIVER       → commit + PR
```

---

## Fix-Retry Loop (applies to ALL phases)

Every phase follows this exact protocol when something fails:

```
attempt = 1
while attempt <= 3:
    run ALL phase checks
    if ALL PASS → advance to next phase
    if ANY FAIL:
        1. DIAGNOSE the root cause (not the symptom)
        2. APPLY a fix (must differ from any previous attempt)
        3. RE-RUN the FULL phase checks (not just the failing item)
        attempt += 1

if still failing after 3 attempts:
    HARD STOP
    Report:
      - What failed
      - What was tried in each attempt
      - Why each fix didn't hold
    Ask user for direction
```

### Fix-Loop Rules — Non-Negotiable

| Rule | Rationale |
|------|-----------|
| Diagnose before fixing | No blind retry of the same action |
| Each retry must try a DIFFERENT approach | Prevents loops doing the same broken fix 3x |
| Re-run the FULL phase check, not just the failing item | A fix in one place can break another |
| Max 3 fix attempts per phase | Bounded — doesn't spin forever |
| Hard stop means hard stop | No "skip with warning", no "move on and come back" |
| Fixes must pass the same bar as first-time code | No `@ts-ignore`, no skipped tests, no loosened assertions, no `eslint-disable` |
| No superficial patches | The fix must actually resolve the issue, not suppress it |

---

## Auto-Learning System

Every `/ship` run captures learnings and feeds them back into future runs. This is not optional — it's baked into every phase.

### Storage

```
.claude/ship-learnings/
├── plan.md          ← Phase 1 learnings
├── tdd.md           ← Phase 2 learnings
├── review.md        ← Phase 3 learnings
├── test.md          ← Phase 4 learnings
├── verify.md        ← Phase 5 learnings
├── eval.md          ← Phase 6 learnings
└── deliver.md       ← Phase 7 learnings
```

### Before Each Phase: RECALL

**MANDATORY** — Before starting any phase, read the corresponding learnings file:
```bash
cat .claude/ship-learnings/<phase>.md 2>/dev/null || true
```

If learnings exist, incorporate them into your approach for this phase. For example:
- **Plan phase** reads `plan.md` → avoids repeating past design mistakes
- **Review phase** reads `review.md` → checks for recurring review findings
- **Verify phase** reads `verify.md` → pre-fixes known build/lint patterns
- **TDD phase** reads `tdd.md` → writes better tests based on past failures

### After Each Phase: CAPTURE

**MANDATORY** — After every phase completes, update the learnings file. This is NOT a blind append — you must deduplicate and consolidate.

#### CAPTURE Protocol (follow exactly):

1. **Read** the existing `.claude/ship-learnings/<phase>.md` file first
2. **Compare** your current phase outcome against existing entries:
   - **Same root cause already exists?** → Update the existing entry: increment its `**Seen:**` count and add the new date. Do NOT add a duplicate entry.
   - **New learning?** → Append a new entry.
   - **Clean pass, no issues?** → Do NOT write anything. Only write when there's something to learn.
3. **Consolidate** if the file has grown past ~20 entries: merge related learnings into broader rules, remove entries that are now obvious or covered by a broader rule.

#### Entry Format (new learning):

```markdown
### <takeaway as a concise rule>

**Seen:** <count>x — <dates>
**Category:** <root-cause category: type-error | import | race-condition | security | config | test-flake | etc.>
**Example:** <most recent concrete example>
**Resolution pattern:** <what to do when you see this>
```

#### Dedup Example:

If `review.md` already contains:
```markdown
### Always use parameterized queries for database access

**Seen:** 1x — 2026-04-05
**Category:** security
**Example:** String interpolation in profile lookup → SQL injection flagged
**Resolution pattern:** Use $1/$2 placeholders, never template literals for SQL
```

And the same issue appears again on 2026-04-10, **update the existing entry**:
```markdown
### Always use parameterized queries for database access

**Seen:** 2x — 2026-04-05, 2026-04-10
**Category:** security
**Example:** Raw SQL in report generator → injection flagged (2026-04-10)
**Resolution pattern:** Use $1/$2 placeholders, never template literals for SQL
```

Do NOT add a second entry for the same root cause.

#### Consolidation Example:

If `verify.md` has 3 separate entries about missing type packages, merge into:
```markdown
### Verify type packages are in dependencies (not devDependencies) when imported in source

**Seen:** 3x — 2026-04-06, 2026-04-08, 2026-04-12
**Category:** type-error
**Example:** @types/chart.js, @types/lodash, @types/node all failed build when in devDeps
**Resolution pattern:** After `npm install <pkg>`, check if `@types/<pkg>` needs to be in dependencies
```

#### Rules:

| Rule | Why |
|------|-----|
| Never blindly append | Prevents duplicate dumping |
| Read before writing | You need existing entries to compare against |
| No "clean pass" entries | They add noise without learning value |
| Consolidate at ~20 entries | Keeps the file scannable and useful as context |
| Takeaway is the heading | Makes scanning fast — headings are the rules |
| Track seen count | High-count entries are the most important learnings |

### Initialization

On first `/ship` run, create the directory and empty learning files:
```bash
mkdir -p .claude/ship-learnings
for phase in plan tdd review test verify eval deliver; do
  if [[ ! -f ".claude/ship-learnings/${phase}.md" ]]; then
    echo "# /ship Learnings — ${phase^} Phase" > ".claude/ship-learnings/${phase}.md"
    echo "" >> ".claude/ship-learnings/${phase}.md"
    echo "Learnings are auto-captured after each /ship run. Read before starting the phase." >> ".claude/ship-learnings/${phase}.md"
    echo "" >> ".claude/ship-learnings/${phase}.md"
  fi
done
```

Add this to the Pipeline State Initialization block (runs once at pipeline start).

---

## Phase 1: PLAN

**Purpose:** Design the implementation and stress-test the approach before writing any code.

### RECALL: Read `.claude/ship-learnings/plan.md` before starting.

### Step 1A: Create Implementation Plan

Invoke: `/everything-claude-code:prp-plan <task description>`

This produces:
- Requirements restatement
- Files to change
- Step-by-step tasks
- Testing strategy
- Acceptance criteria (critical — used in Phase 6 EVAL)

### Step 1B: Adversarial Review of Plan

Invoke: `/codex:adversarial-review --wait --scope working-tree`

This challenges:
- Whether the approach is the right one
- What assumptions the design depends on
- Where the design could fail under real-world conditions
- Alternative approaches that were not considered

### Fix-Loop Trigger

If the adversarial review surfaces legitimate design flaws:
1. Revise the plan to address the flaws
2. Re-run adversarial review on the revised plan
3. Max 3 iterations

### Report Before Asking for Confirmation (MANDATORY)

Before asking the user to confirm the plan, you MUST print an "Adversarial Review Summary" block so the user can see what was challenged and how it was resolved. Do not ask for confirmation without it.

Format:

```
## Adversarial Review Summary

Codex raised N issue(s) across <iterations>/3 iteration(s):

1. **<short title>** — <one-line description of the concern>
   **Resolved by:** <what changed in the plan>

2. **<short title>** — ...
   **Resolved by:** ...

Final verdict: PASS (all findings addressed)
```

If codex raised zero findings, say so explicitly: "Codex adversarial review passed on first iteration — no design flaws found."

The user needs this summary to validate the review's quality. Silently rolling findings into the plan and asking for confirmation defeats the purpose of the adversarial step.

### Gate: Phase 1 Complete When

- [ ] Implementation plan exists with acceptance criteria
- [ ] Adversarial review has no unresolved design challenges
- [ ] Adversarial Review Summary printed to user (findings + resolutions, or "no findings")
- [ ] User explicitly confirms the plan (MANDATORY — do not skip)

**WAIT FOR USER CONFIRMATION BEFORE PROCEEDING TO PHASE 2.**

### CAPTURE: Append learnings to `.claude/ship-learnings/plan.md`.

---

## Phase 2: TDD

**Purpose:** Write tests first, then implement code to make them pass.

### RECALL: Read `.claude/ship-learnings/tdd.md` before starting.

### Execution

Invoke: `/everything-claude-code:tdd`

This enforces:
1. Write failing tests FIRST (RED)
2. Implement minimal code to make tests pass (GREEN)
3. Refactor while keeping tests green (REFACTOR)
4. Git checkpoint commits at each stage

### Fix-Loop Trigger

If tests fail after implementation:
1. Diagnose whether the bug is in implementation or test
2. Fix the root cause (usually the implementation, not the test)
3. Re-run all tests

### Gate: Phase 2 Complete When

- [ ] All tests pass (GREEN)
- [ ] Coverage >= 95%
- [ ] Tests cover edge cases and error scenarios from the plan
- [ ] Git checkpoint commits exist for RED → GREEN → REFACTOR

### CAPTURE: Append learnings to `.claude/ship-learnings/tdd.md`.

---

## Phase 3: REVIEW

**Purpose:** Three independent reviewers catch different classes of issues.

### RECALL: Read `.claude/ship-learnings/review.md` before starting. Apply past findings as a pre-check before invoking reviewers.

### Step 3A: Claude Code Review (local diff)

Invoke: `/everything-claude-code:code-review`

Reviews for: code quality, patterns, maintainability, DRY violations, naming.

### Step 3B: Security Review

Invoke: `/everything-claude-code:security-review`

Reviews for: injection, XSS, auth bypass, secrets exposure, OWASP Top 10.

### Step 3C: Codex Implementation Review

Invoke: `/codex:review --wait`

Reviews for: implementation correctness, edge cases, performance, idiomatic patterns.

**Run 3A, 3B, 3C in parallel where possible.**

### Fix-Loop Trigger

Merge findings from all 3 reviewers. For each finding:
1. Classify severity: P0 (blocker), P1 (must-fix), P2 (nice-to-have)
2. Fix all P0 and P1 findings
3. Re-run ALL THREE reviewers after fixes (a security fix can introduce a code quality issue)

### Gate: Phase 3 Complete When

- [ ] Zero P0 findings across all 3 reviewers
- [ ] Zero P1 findings across all 3 reviewers
- [ ] P2 findings documented but not blocking

### CAPTURE: Append learnings to `.claude/ship-learnings/review.md`. Include specific review findings and their categories.

---

## Phase 4: TEST

**Purpose:** Full regression suite + end-to-end tests confirm nothing is broken.

### RECALL: Read `.claude/ship-learnings/test.md` before starting. Watch for previously flaky tests or known timing issues.

### Step 4A: Regression Tests (diff against baseline)

Run the project's full test suite using the same command recorded in `.ship-baseline-tests.json.test_command`:
```bash
npm test
```

After running, **diff against the baseline** to tell regressions apart from pre-existing failures:

1. Load `.ship-baseline-tests.json` → `baseline_failures` set.
2. Run current suite → `current_failures` set.
3. Compute:
   - `new_failures = current_failures - baseline_failures` (tests that were PASSING before `/ship` started but are FAILING now — these are REGRESSIONS).
   - `pre_existing_failures = current_failures ∩ baseline_failures` (already broken before `/ship`; log but do not block).
   - `fixed_tests = baseline_failures - current_failures` (bonus — surfaced in the report but not required).
4. Verdict:
   - `new_failures` empty → verdict `PASS`.
   - `new_failures` non-empty → verdict `FAIL`. Each new failure must be fixed before STEP_4A is recorded.

Write the verdict to `.ship-4a-regression-check.json`:

```json
{
  "verdict": "PASS" | "FAIL",
  "ran_at": "<ISO-8601 timestamp>",
  "baseline_failures": ["<test id>", ...],
  "current_failures": ["<test id>", ...],
  "new_failures": ["<test id>", ...],
  "pre_existing_failures": ["<test id>", ...],
  "fixed_tests": ["<test id>", ...]
}
```

Report to the user:
- **Regressions (blocking):** `new_failures` list — fix before advancing.
- **Pre-existing failures (informational):** `pre_existing_failures` list — unchanged from baseline, not blocking.
- **Fixed:** `fixed_tests` (if any) — tests that were broken before and now pass.

### Step 4B: E2E Tests

Invoke: `/everything-claude-code:e2e`

Runs Playwright end-to-end tests against critical user flows.

### Fix-Loop Trigger

If STEP_4A verdict is FAIL (new_failures non-empty):
1. For each test in `new_failures`, identify the root cause (most often the new code from Phase 2).
2. Fix the root cause — do NOT silence the test.
3. Re-run the FULL test suite (not just the failing test).
4. Re-compute the diff and overwrite `.ship-4a-regression-check.json`.

Pre-existing failures are intentionally NOT a blocker — they were already broken when `/ship` started, so fixing them is out of scope for this change. The report lists them so they're visible.

If an E2E test fails (4B):
1. Identify which test failed and why.
2. Fix the root cause.
3. Re-run the full E2E suite.

### Gate: Phase 4 Complete When

- [ ] `.ship-4a-regression-check.json` exists with `verdict = "PASS"` (no new failures vs baseline)
- [ ] All E2E tests pass
- [ ] Pre-existing failures are reported but accepted as out of scope

### CAPTURE: Append learnings to `.claude/ship-learnings/test.md`. Note flaky tests, timing issues, and environment-specific failures.

---

## Phase 5: VERIFY

**Purpose:** Build, lint, types, and UI verification confirm the project is shippable.

### RECALL: Read `.claude/ship-learnings/verify.md` before starting. Pre-fix known build/lint/type patterns from past runs.

### Step 5A: Build + Lint + Types

Invoke: `/everything-claude-code:verify`

This runs:
1. Build verification (`npm run build`)
2. Type check (`npx tsc --noEmit`)
3. Lint check (`npm run lint`)
4. Security scan (secrets, console.log)
5. Diff review

### Step 5B: UI Spot-Check (if frontend changes)

Invoke: `/everything-claude-code:browser-qa`

This runs:
1. Smoke test (console errors, network errors, Core Web Vitals)
2. Interaction test (nav links, forms, auth flow)
3. Visual regression (screenshots at 3 breakpoints)
4. Accessibility (WCAG AA)

**Skip 5B if the change is backend-only with no UI impact.**

### Step 5C: Native Simulator QA

**Always mandatory to attempt.** The pipeline must always try to run native simulator verification. If it fails due to environment/setup issues (no simulator installed, no Xcode, no Android SDK, etc.), ask the user whether to skip. Do NOT silently skip.

#### Environment Check (run before tests)

```bash
# Check simulator availability
SIMULATOR_AVAILABLE=false
SKIP_REASON=""

# Flutter
if [[ -f "pubspec.yaml" ]]; then
  if command -v flutter &>/dev/null && flutter devices 2>/dev/null | grep -qE "(simulator|emulator)"; then
    SIMULATOR_AVAILABLE=true
  else
    SKIP_REASON="Flutter SDK not installed or no simulator/emulator running"
  fi
# React Native / Expo
elif [[ -f "react-native.config.js" || (-f "app.json" && grep -q '"expo"' app.json 2>/dev/null) ]]; then
  if command -v xcrun &>/dev/null && xcrun simctl list devices 2>/dev/null | grep -q "Booted"; then
    SIMULATOR_AVAILABLE=true
  elif command -v emulator &>/dev/null; then
    SIMULATOR_AVAILABLE=true
  else
    SKIP_REASON="No iOS Simulator booted and no Android Emulator available"
  fi
# Capacitor / native hybrid
elif [[ -f "capacitor.config.ts" || -f "capacitor.config.json" ]]; then
  if command -v xcrun &>/dev/null || command -v emulator &>/dev/null; then
    SIMULATOR_AVAILABLE=true
  else
    SKIP_REASON="No native toolchain (Xcode/Android SDK) found for Capacitor"
  fi
# iOS/Android dirs exist (generic native project)
elif [[ -d "ios" || -d "android" ]]; then
  if command -v xcrun &>/dev/null || command -v emulator &>/dev/null; then
    SIMULATOR_AVAILABLE=true
  else
    SKIP_REASON="ios/ or android/ directories exist but no simulator toolchain found"
  fi
# Web-only project — no native markers
else
  SKIP_REASON="No native mobile project markers detected (ios/, android/, pubspec.yaml, etc.)"
fi
```

#### If environment check fails:

```
⚠ PHASE 5C: Native Simulator QA cannot run.
Reason: <SKIP_REASON>

This step is mandatory. However, it can be skipped with your explicit approval.
Do you want to skip native simulator testing for this run? (yes/no)
```

- If user says **yes** → record `STEP_5C=skipped` in state file, continue to Phase 6
- If user says **no** → HARD STOP. User must fix their environment before continuing.

#### For Flutter projects:
Invoke: `/everything-claude-code:flutter-test`

This runs:
1. `flutter test` — unit + widget tests
2. `flutter drive` or integration_test on iOS Simulator / Android Emulator
3. Screenshot capture on both platforms
4. Golden file comparison (visual regression on device)

#### For React Native / Expo projects:
Run Detox or Maestro on simulator:
```bash
# iOS Simulator
npx detox test --configuration ios.sim.release
# or Maestro
maestro test .maestro/

# Android Emulator
npx detox test --configuration android.emu.release
```

#### For Capacitor / native hybrid:
Run Playwright E2E in a WebView context, then verify native plugin behavior on simulator.

**What this checks that browser-only testing misses:**
- Native navigation gestures (swipe back, pull-to-refresh)
- Push notification handling
- Deep link routing
- Platform-specific UI (status bar, safe area, notch)
- Native module bridges (camera, GPS, biometrics)
- App lifecycle (background → foreground, cold start)
- Actual device performance (jank, memory pressure)

### Fix-Loop Trigger

If build/lint/types fail:
1. Read the error message
2. Fix the source file
3. Re-run full verification

If browser-qa finds issues:
1. Fix the UI issue
2. Re-run browser-qa AND verification (UI fix might break types)

If native simulator tests fail:
1. Identify platform (iOS vs Android) and failure type
2. Fix the root cause (often platform-specific code paths)
3. Re-run simulator tests on BOTH platforms (a fix for one can break the other)

### Gate: Phase 5 Complete When

- [ ] Build succeeds with zero errors
- [ ] Zero type errors
- [ ] Zero lint errors
- [ ] No secrets or console.log in source
- [ ] Browser QA passes (if applicable)
- [ ] Native Simulator QA passes OR user explicitly approved skip (reason logged)

### CAPTURE: Append learnings to `.claude/ship-learnings/verify.md`. Include build errors, type issues, and simulator findings.

---

## Phase 6: EVAL

**Purpose:** Validate that the feature actually does what was asked — not just that code compiles and tests pass.

### RECALL: Read `.claude/ship-learnings/eval.md` before starting. Check for recurring gaps between acceptance criteria and implementation.

### Execution

Invoke: `/everything-claude-code:eval`

Using the **acceptance criteria from the Phase 1 plan**, construct evals:

#### Code-Based Graders (deterministic)
```bash
# Example: verify the new endpoint exists and returns expected shape
curl -s http://localhost:3000/api/new-endpoint | jq '.fieldName' && echo "PASS" || echo "FAIL"

# Example: verify the function handles edge case
npm test -- --testPathPattern="new-feature.edge" && echo "PASS" || echo "FAIL"
```

#### Model-Based Graders (for open-ended criteria)
```markdown
[MODEL GRADER]
Given the acceptance criteria: "<criteria from plan>"
And the implementation diff: "<git diff>"
Does the implementation satisfy the criteria?
Score: PASS / FAIL
Reasoning: [explanation]
```

### Fix-Loop Trigger

If any eval fails:
1. Map the failing eval back to its acceptance criterion
2. Identify what's missing or wrong in the implementation
3. Fix the implementation (not the eval, unless the eval is wrong)
4. Re-run ALL evals

### Gate: Phase 6 Complete When

- [ ] All code-based graders return PASS
- [ ] All model-based graders return PASS with reasoning
- [ ] Every acceptance criterion from Phase 1 is covered by at least one eval

### CAPTURE: Append learnings to `.claude/ship-learnings/eval.md`. Note gaps between what was planned and what was actually built.

---

## Phase 7: DELIVER

**Purpose:** Commit and create a PR with full traceability.

### RECALL: Read `.claude/ship-learnings/deliver.md` before starting. Check for past PR description issues or commit message patterns.

### Step 7A: Commit

Invoke: `/everything-claude-code:prp-commit`

Commit message should reference what was built and that it passed all quality gates.

### Step 7B: Create PR

Invoke: `/everything-claude-code:prp-pr`

PR description should include:
- Summary of what was built
- Link to implementation plan
- Phase-by-phase verification summary
- Any deviations from plan and why

### Step 7C: Clean Up Pipeline State

```bash
rm -f .ship-pipeline-state
```

### Gate: Phase 7 Complete When

- [ ] Changes committed to feature branch
- [ ] PR created with description
- [ ] PR URL returned to user
- [ ] Pipeline state file cleaned up

### CAPTURE: Append learnings to `.claude/ship-learnings/deliver.md`.

---

## Final Output

After all 7 phases pass, report:

```
## /ship Complete

Task: <original task description>
Branch: <branch name>
PR: <PR URL>

### Phase Summary
| Phase | Status | Attempts |
|-------|--------|----------|
| 1. Plan | PASS | 1 |
| 2. TDD | PASS | 1 |
| 3. Review | PASS | 2 (fixed: missing null check) |
| 4. Test | PASS | 1 |
| 5. Verify | PASS | 1 |
| 6. Eval | PASS | 1 |
| 7. Deliver | PASS | 1 |

### Quality Evidence
- Tests: X passed, 0 failed, Y% coverage
- Reviewers: Claude (0 P0/P1), Codex (0 P0/P1), Security (0 P0/P1)
- Build: clean
- Evals: X/X acceptance criteria satisfied
```

---

## Anti-Patterns — DO NOT

| Anti-Pattern | Why It's Wrong |
|-------------|---------------|
| Skip Phase 1 for "simple" changes | Simple changes have hidden complexity. The plan catches it. |
| Write implementation before tests (Phase 2) | TDD is non-negotiable. Tests first. |
| Fix a P1 review finding and skip re-review | The fix might introduce a new issue. Re-run all reviewers. |
| Mark a test as `.skip` to pass Phase 4 | That's not fixing, that's hiding. |
| Add `@ts-ignore` to pass Phase 5 | Fix the type error properly. |
| Loosen an eval assertion to pass Phase 6 | The eval reflects the requirement. Fix the code, not the eval. |
| Proceed after hard stop without user input | Hard stop means STOP. Ask the user. |
| Retry the same fix twice | Each attempt must try a different approach. |

---

## Related Skills

- `/everything-claude-code:prp-plan` — Phase 1 planning
- `/everything-claude-code:tdd` — Phase 2 test-driven development
- `/everything-claude-code:code-review` — Phase 3 code review
- `/everything-claude-code:security-review` — Phase 3 security review
- `/codex:adversarial-review` — Phase 1 design challenge
- `/codex:review` — Phase 3 implementation review
- `/everything-claude-code:e2e` — Phase 4 end-to-end tests
- `/everything-claude-code:verify` — Phase 5 verification
- `/everything-claude-code:browser-qa` — Phase 5 UI spot-check
- `/everything-claude-code:flutter-test` — Phase 5C Flutter simulator testing
- `/everything-claude-code:eval` — Phase 6 acceptance evaluation
- `/everything-claude-code:prp-commit` — Phase 7 commit
- `/everything-claude-code:prp-pr` — Phase 7 pull request
