---
name: review-product
description: "Orchestrate product review: contextualize repo, run tech + feature reviewers in parallel, merge findings, produce unified brief, sync to Linear. Supports --light (default) and --full modes."
origin: custom
tools: Read, Write, Edit, Bash, Grep, Glob, Agent, Skill
---

# /review-product -- Product Review Coordinator

Orchestrate all review agents, merge their outputs, produce a unified product review brief, and sync actionable findings to Linear.

This skill is the top-level coordinator for the ship-pipeline review system. It invokes three sub-skills in sequence:

1. `/contextualize` -- generate or refresh the repo context bible
2. `/review-tech` -- technical health analysis (6 dimensions)
3. `/review-features` -- product intelligence analysis (7 dimensions)

Then it merges, deduplicates, ranks, and formats all findings into a single brief with Linear integration.

## When to Activate

- User says `/review-product`
- User says `/review-product --full` or `/review-product --light`
- Scheduled cron trigger (daily light, weekly full)
- User wants a comprehensive product review combining tech and feature analysis

## Arguments

| Argument | Effect |
|----------|--------|
| `--light` | **(default)** Skip context if hash matches, run light reviewers, Linear read-only (update existing issues only) |
| `--full` | Force context regen, run full reviewers, full Linear permissions (create/update/close) |
| `--tech-only` | Only run `/review-tech`, skip `/review-features` |
| `--features-only` | Only run `/review-features`, skip `/review-tech` |

Flags are combinable. Examples:
- `--full --tech-only` -- force full context regen + full tech review only
- `--light --features-only` -- light features review only, no tech
- `--full` -- full context + full tech + full features (most thorough)
- *(no flags)* -- equivalent to `--light` (both reviewers, hash-gated context, Linear read-only)

---

## Prerequisites

**MANDATORY CHECK:** Before proceeding, verify that all three sub-skills exist:

```bash
MISSING=""
[[ ! -f "skills/contextualize/SKILL.md" ]] && MISSING="${MISSING} /contextualize"
[[ ! -f "skills/review-tech/SKILL.md" ]]    && MISSING="${MISSING} /review-tech"
[[ ! -f "skills/review-features/SKILL.md" ]] && MISSING="${MISSING} /review-features"

if [[ -n "$MISSING" ]]; then
  echo "HARD STOP: Missing required skills:${MISSING}"
  echo "Run: bash setup.sh to install the ship-pipeline plugin."
  exit 1
fi
```

If any skill is missing, HARD STOP and report which skills are absent.

---

## Initialization

**MANDATORY FIRST ACTION:** Set up the working directory and default config files.

```bash
mkdir -p .claude/product-review
```

### Create default `config.json` if missing:

```bash
if [[ ! -f ".claude/product-review/config.json" ]]; then
  cat > .claude/product-review/config.json << 'CONFIGEOF'
{
  "linear": {
    "team_id": "",
    "project_id": "",
    "auto_sync": false,
    "sync_threshold": "P1"
  },
  "schedule": {
    "light_cron": "0 9 * * 1-5",
    "full_cron": "0 9 * * 1"
  }
}
CONFIGEOF
fi
```

### Create empty `state.json` if missing:

```bash
if [[ ! -f ".claude/product-review/state.json" ]]; then
  cat > .claude/product-review/state.json << 'STATEEOF'
{
  "last_reviewed_commit": "",
  "last_full_run": "",
  "last_light_run": "",
  "repo_type": "",
  "findings": {}
}
STATEEOF
fi
```

---

## Pipeline

11 steps. Execute in order. Record the start time at the beginning for duration tracking.

```bash
PIPELINE_START=$(date -u +%s)
```

---

### Step 1: Parse Flags

Parse `$ARGUMENTS` to determine the run mode and scope.

```bash
MODE="light"        # default
RUN_TECH=true
RUN_FEATURES=true

for arg in $ARGUMENTS; do
  case "$arg" in
    --full)            MODE="full" ;;
    --light)           MODE="light" ;;
    --tech-only)       RUN_FEATURES=false ;;
    --features-only)   RUN_TECH=false ;;
  esac
done
```

If both `--tech-only` and `--features-only` are passed, that is contradictory. Default to running both and warn:

```
Warning: --tech-only and --features-only both specified. Running both reviewers.
```

Report the parsed configuration before proceeding:

```
Mode: <light|full>
Tech reviewer: <enabled|disabled>
Features reviewer: <enabled|disabled>
```

---

### Step 2: Context Refresh

Perform the same hash-based staleness check used by `/contextualize`.

**Compute current hash:**

```bash
CURRENT_HASH=$( (git rev-parse HEAD 2>/dev/null || echo "no-git"; for f in package.json Cargo.toml pyproject.toml pubspec.yaml go.mod pom.xml build.gradle composer.json Gemfile; do sha256sum "$f" 2>/dev/null || true; done) | sha256sum | cut -d' ' -f1 )
```

**Read stored hash:**

```bash
STORED_HASH=""
if [[ -f ".claude/product-review/.context-hash" ]]; then
  STORED_HASH=$(cat .claude/product-review/.context-hash)
fi
```

**Decision:**

| Condition | Action | Context Status |
|-----------|--------|----------------|
| Hash matches AND `--light` mode | Skip context generation | `cached` |
| Hash mismatch (any mode) | Invoke `/contextualize` skill | `refreshed` |
| `--full` mode (regardless of hash) | Invoke `/contextualize --full` skill | `refreshed` |

If context refresh is needed, use the Skill tool:

```
Invoke: /contextualize         (if hash mismatch, light mode)
Invoke: /contextualize --full  (if --full mode)
```

Record the context status (`cached` or `refreshed`) for the brief.

---

### Step 3: Run Reviewers

Dispatch the enabled reviewers. Pass the mode flag (`--light` or `--full`) to each.

**CRITICAL: Run in PARALLEL if both reviewers are enabled.** Use two Agent tool calls in a single message so they execute concurrently:

If both `RUN_TECH` and `RUN_FEATURES` are true, dispatch two Agent calls in the same message:

- **Agent 1:** "Run `/review-tech --<mode>` on this repository. Write output to `.claude/product-review/TECH-REVIEW.md`."
- **Agent 2:** "Run `/review-features --<mode>` on this repository. Write output to `.claude/product-review/FEATURES-REVIEW.md`."

If only one reviewer is enabled, dispatch a single Agent call for that reviewer.

Wait for all dispatched agents to complete before proceeding to Step 4.

---

### Step 4: Read and Merge Outputs

Read the output files produced by the reviewers:

```bash
# Read available review files
cat .claude/product-review/TECH-REVIEW.md 2>/dev/null
cat .claude/product-review/FEATURES-REVIEW.md 2>/dev/null
```

Parse all findings from each review file. Each finding has:
- **Source:** `tech` or `features`
- **Dimension:** the review dimension it came from (e.g., "Architecture", "Security", "Feature Gaps")
- **Title:** the finding title
- **Severity:** P0, P1, P2, or P3
- **Impact:** High, Medium, or Low
- **Effort:** Small, Medium, or Large
- **Details:** the full finding text
- **Recommendation:** the actionable recommendation

Collect all findings into a unified list.

---

### Step 5: Compute Fingerprints

For each finding, compute a stable fingerprint to enable deduplication and cross-run tracking:

```
fingerprint = SHA256(dimension + ":" + normalized_title)
```

**Normalization rules for title:**
1. Convert to lowercase
2. Collapse all consecutive whitespace to a single space
3. Strip version numbers (patterns like `v1.2.3`, `1.0.0`, `@4.2.1`)
4. Trim leading and trailing whitespace

**Example:**

```
Dimension: "Security"
Title: "SQL Injection in User Query v2.1.0"
Normalized: "sql injection in user query"
Input to hash: "Security:sql injection in user query"
Fingerprint: SHA256("Security:sql injection in user query")
```

```bash
# Example fingerprint computation
echo -n "Security:sql injection in user query" | sha256sum | cut -d' ' -f1
```

---

### Step 6: Deduplicate

Compare fingerprints across both reviewer outputs. If the same fingerprint appears from both `/review-tech` and `/review-features`:

1. **Keep the higher severity.** If tech says P1 and features says P2, the merged finding is P1.
2. **Merge details.** Combine the detail text from both sources, noting the source of each perspective.
3. **Use the more specific recommendation.** If one reviewer provides a more actionable recommendation, prefer it.
4. **Mark as `source: "both"`** to indicate cross-reviewer agreement (this is a signal of importance).

Findings with unique fingerprints pass through unchanged.

---

### Step 7: Rank

Sort the deduplicated findings using a two-level ranking:

**Primary sort: Severity (ascending priority number = higher urgency)**
```
P0 (critical) > P1 (high) > P2 (medium) > P3 (low)
```

**Secondary sort: Impact-Effort ratio**

Within the same severity level, rank by actionability:

| Impact | Effort | Priority within severity |
|--------|--------|--------------------------|
| High   | Small  | 1st (quick wins)         |
| High   | Medium | 2nd                      |
| Medium | Small  | 3rd                      |
| High   | Large  | 4th                      |
| Medium | Medium | 5th                      |
| Low    | Small  | 6th                      |
| Medium | Large  | 7th                      |
| Low    | Medium | 8th                      |
| Low    | Large  | 9th (deprioritize)       |

---

### Step 8: Generate BRIEF.md

Write the unified brief to `.claude/product-review/BRIEF.md` with the following structure:

```bash
PIPELINE_END=$(date -u +%s)
DURATION=$(( PIPELINE_END - PIPELINE_START ))
DURATION_FORMATTED="$(( DURATION / 60 ))m $(( DURATION % 60 ))s"
```

```markdown
# Product Review Brief -- <YYYY-MM-DD>

**Mode:** <light | full> | **Duration:** <elapsed time> | **Context:** <cached | refreshed>

---

## Critical (act now)

> P0 findings require immediate attention. Each includes a `/ship` command to begin fixing.

<For each P0 finding:>

### [P0] <finding title>

**Source:** <tech | features | both> | **Dimension:** <dimension> | **Impact:** <High/Med/Low> | **Effort:** <Small/Med/Large>

<finding details>

**Recommendation:** <actionable recommendation>

**Fix:** `/ship <concise task description derived from recommendation>`

---

## High Priority (this sprint)

> P1 findings should be addressed within the current sprint.

<For each P1 finding, same format as P0>

---

## Improvements (backlog)

> P2 findings are genuine improvements worth scheduling.

<For each P2 finding:>

### [P2] <finding title>

**Source:** <source> | **Dimension:** <dimension> | **Impact:** <impact> | **Effort:** <effort>

<finding details>

**Recommendation:** <recommendation>

---

## Low Priority

> P3 findings are minor or cosmetic. Address opportunistically.

<For each P3 finding:>

- **[P3] <finding title>** (<source>, <dimension>): <one-line summary>

---

## Health Dashboard

| Metric | Value | Trend |
|--------|-------|-------|
| P0 Findings | <count> | <+N/-N/unchanged vs last run> |
| P1 Findings | <count> | <+N/-N/unchanged vs last run> |
| P2 Findings | <count> | <+N/-N/unchanged vs last run> |
| P3 Findings | <count> | <+N/-N/unchanged vs last run> |
| Total Findings | <count> | <+N/-N/unchanged vs last run> |
| Tech Dimensions Scanned | <N>/6 | -- |
| Feature Dimensions Scanned | <N>/7 | -- |
| Cross-reviewer Duplicates | <count> | -- |
| Context Status | <cached/refreshed> | -- |

Trend values are computed by comparing current finding counts against the counts stored in `state.json` from the previous run. If no previous run exists, report "first run" instead of a trend.

---

## Changes Since Last Run

Read the previous findings from `state.json` and compare fingerprints:

- **NEW:** <findings with fingerprints not present in previous state>
- **RESOLVED:** <findings in previous state but not in current scan -- ONLY if --full mode>
- **WORSENED:** <findings whose severity increased (e.g., P2 -> P1) compared to previous state>
- **IMPROVED:** <findings whose severity decreased (e.g., P1 -> P2) compared to previous state>

> **Note:** In light mode, RESOLVED items are NOT reported. A light scan only examines changed files, so the absence of a finding does not confirm resolution -- the issue may still exist in unchanged files. Only a `--full` scan can confirm that a finding is truly resolved.

If no previous state exists, report:

```
First run -- no previous state to compare against. All findings are NEW.
```
```

Write this content to `.claude/product-review/BRIEF.md`.

---

### Step 9: Linear Sync

Read `.claude/product-review/config.json` to determine Linear sync behavior.

```bash
AUTO_SYNC=$(cat .claude/product-review/config.json 2>/dev/null | grep -o '"auto_sync"[[:space:]]*:[[:space:]]*[a-z]*' | head -1 | grep -o '[a-z]*$')
TEAM_ID=$(cat .claude/product-review/config.json 2>/dev/null | grep -o '"team_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
SYNC_THRESHOLD=$(cat .claude/product-review/config.json 2>/dev/null | grep -o '"sync_threshold"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
```

**Skip conditions (report and continue):**

If `auto_sync` is `false` or `team_id` is empty:

```
Linear sync: SKIPPED
Reason: auto_sync is disabled or team_id is not configured.
To enable: edit .claude/product-review/config.json and set "auto_sync": true and provide a "team_id".
```

Skip to Step 10.

**If sync is enabled, apply MODE-SAFE permissions:**

> **P0 CONSTRAINT -- MODE-SAFE LINEAR SYNC**
>
> This is the single most critical safety invariant in the coordinator. Light mode runs on partial data (only changed files). It MUST NOT make destructive or additive decisions based on incomplete information.

| Action | `--full` mode | `--light` mode |
|--------|---------------|----------------|
| **Create new Linear issues** | YES -- for findings at or above `sync_threshold` severity | **NO -- NEVER** |
| **Update existing Linear issues** | YES -- full data refresh | YES -- data updates only (severity, details) |
| **Close resolved Linear issues** | YES -- after revalidation protocol | **NO -- NEVER** |

#### Create new issues (full mode only)

For each finding at or above the `sync_threshold` (e.g., if threshold is "P1", create issues for P0 and P1 findings):

1. Check if an issue with this fingerprint already exists in Linear (search by fingerprint tag/label).
2. If not found, create a new issue:
   - Title: `[<severity>] <finding title>`
   - Description: finding details + recommendation
   - Team: `team_id`
   - Project: `project_id` (if set)
   - Labels: `product-review`, `<severity>`, `<dimension>`
   - Metadata: fingerprint in a comment or custom field for future matching

#### Update existing issues (both modes)

For each finding whose fingerprint matches an existing Linear issue:

1. Update the issue description with latest details.
2. Update severity label if changed.
3. Add a comment: "Updated by /review-product (<mode> mode) on <date>."

#### Close resolved issues -- full mode only, with revalidation

**Close protocol (CRITICAL -- prevents false closures):**

For each finding in `state.json` with `status: "open"` that is NOT present in the current full scan:

1. **Re-check the original file/pattern.** Read the file path and line range from the stored finding. Verify the concern genuinely no longer exists.
2. **If the file was moved or renamed:** Search for the file by name/pattern elsewhere in the repo. If found, verify the concern doesn't exist in the new location.
3. **If the file was deleted:** Check whether the functionality was removed entirely or moved elsewhere.
4. **Only if truly resolved:** Close the Linear issue with comment: "Resolved -- no longer detected in full scan on <date>."
5. **If uncertain:** Do NOT close. Add a comment: "Not detected in full scan on <date>, but could not confirm resolution. Manual review recommended."

**Light mode MUST NOT close issues.** A finding absent from a light scan may simply be in an unchanged file that was not scanned. Closing it would be a false positive resolution.

---

### Step 10: Update state.json

After all processing is complete, update `.claude/product-review/state.json`:

```json
{
  "last_reviewed_commit": "<output of git rev-parse HEAD>",
  "last_full_run": "<ISO 8601 timestamp -- update only if MODE=full>",
  "last_light_run": "<ISO 8601 timestamp -- update only if MODE=light>",
  "repo_type": "<detected repo type from CONTEXT.md or inline detection>",
  "findings": {
    "<fingerprint>": {
      "title": "<finding title>",
      "severity": "<P0|P1|P2|P3>",
      "dimension": "<dimension>",
      "source": "<tech|features|both>",
      "status": "<open|resolved>",
      "first_seen": "<ISO 8601 timestamp of first detection>",
      "last_seen": "<ISO 8601 timestamp of this run>",
      "linear_issue_id": "<Linear issue ID, if synced, else empty string>",
      "file_path": "<primary file associated with finding, if applicable>",
      "severity_history": ["<previous severity values for trend tracking>"]
    }
  }
}
```

**Upsert logic for findings:**

- **New fingerprint:** Add entry with `first_seen` and `last_seen` set to now, `status: "open"`.
- **Existing fingerprint, still present:** Update `last_seen`, update `severity` (and append old severity to `severity_history` if changed), keep `first_seen` and `linear_issue_id` unchanged.
- **Existing fingerprint, not present in current scan (full mode only):** Set `status: "resolved"`, update `last_seen`.
- **Existing fingerprint, not present in current scan (light mode):** Do NOT change status. Light mode cannot confirm resolution.

**Timestamp updates:**

```bash
HEAD_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
RUN_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
```

- Always update `last_reviewed_commit` to `HEAD_COMMIT`.
- If `MODE=full`: update `last_full_run` to `RUN_TIMESTAMP`.
- If `MODE=light`: update `last_light_run` to `RUN_TIMESTAMP`.
- Do not overwrite the other timestamp (preserve the last full run timestamp when doing a light run, and vice versa).

---

### Step 11: Update HISTORY.md

Append a run entry to `.claude/product-review/HISTORY.md`. Create the file if it doesn't exist.

```bash
if [[ ! -f ".claude/product-review/HISTORY.md" ]]; then
  echo "# Product Review History" > .claude/product-review/HISTORY.md
  echo "" >> .claude/product-review/HISTORY.md
  echo "Run log for /review-product executions." >> .claude/product-review/HISTORY.md
  echo "" >> .claude/product-review/HISTORY.md
fi
```

Append this entry:

```markdown
---

## Run: <YYYY-MM-DD HH:MM UTC>

| Field | Value |
|-------|-------|
| Mode | <light \| full> |
| Duration | <elapsed time> |
| Context | <cached \| refreshed> |
| Tech Review | <enabled \| disabled> |
| Features Review | <enabled \| disabled> |
| P0 Findings | <count> |
| P1 Findings | <count> |
| P2 Findings | <count> |
| P3 Findings | <count> |
| Total Findings | <count> |
| New (vs previous) | <count> |
| Resolved (vs previous) | <count or "N/A (light mode)"> |
| Worsened | <count> |
| Improved | <count> |
| Linear Sync | <synced \| skipped \| N/A> |
| Linear Issues Created | <count or "N/A"> |
| Linear Issues Updated | <count or "N/A"> |
| Linear Issues Closed | <count or "N/A (light mode)"> |
| Commit | <HEAD commit hash> |
```

---

## After Pipeline

Once all 11 steps are complete, display the brief to the user and highlight the top 3 most actionable items.

**Final output format:**

```
## /review-product Complete

Mode: <light|full>
Duration: <elapsed>
Context: <cached|refreshed>
Reviewers: <tech + features | tech only | features only>

### Top 3 Actions

1. [<severity>] <finding title>
   `/ship <task description>`

2. [<severity>] <finding title>
   `/ship <task description>`

3. [<severity>] <finding title>
   `/ship <task description>`

### Summary

| Severity | Count | Trend |
|----------|-------|-------|
| P0       | <n>   | <trend> |
| P1       | <n>   | <trend> |
| P2       | <n>   | <trend> |
| P3       | <n>   | <trend> |

Full brief: .claude/product-review/BRIEF.md
History: .claude/product-review/HISTORY.md
```

Select the top 3 actions by choosing the highest-severity, highest-actionability (high impact + small effort) findings. Each action includes a `/ship` command that can be copy-pasted to begin fixing immediately.

---

## Output Files

| File | Purpose |
|------|---------|
| `.claude/product-review/BRIEF.md` | Unified review brief (regenerated each run) |
| `.claude/product-review/HISTORY.md` | Append-only run log |
| `.claude/product-review/state.json` | Persistent state for cross-run tracking |
| `.claude/product-review/config.json` | User configuration (Linear, schedule) |
| `.claude/product-review/TECH-REVIEW.md` | Raw tech review output (written by /review-tech) |
| `.claude/product-review/FEATURES-REVIEW.md` | Raw features review output (written by /review-features) |
| `.claude/product-review/CONTEXT.md` | Repo context bible (written by /contextualize) |

---

## Related Skills

- `/contextualize` -- generates the repo context bible (Step 2)
- `/review-tech` -- technical health reviewer (Step 3)
- `/review-features` -- product intelligence reviewer (Step 3)
- `/ship` -- full-cycle shipping pipeline (used in `/ship` commands within the brief)
