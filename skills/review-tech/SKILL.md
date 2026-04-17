---
name: review-tech
description: "Analyze architecture, security, dependencies, and tech debt. Produces .claude/product-review/TECH-REVIEW.md with P0-P3 severity findings across 6 dimensions."
origin: custom
tools: Read, Write, Edit, Bash, Grep, Glob, Agent
---

# /review-tech -- Technical Health Reviewer

Analyze a repository's technical health across 6 dimensions. Produces a structured review document with severity-classified findings (P0-P3) and actionable recommendations.

## When to Activate

- User says `/review-tech`
- User says `/review-tech --full` or `/review-tech --light`
- Called by the `/review-product` coordinator as part of a full product review
- User wants a technical audit, architecture review, security scan, or tech debt assessment

## Arguments

| Argument | Effect |
|----------|--------|
| `--full` | **(default when standalone)** Full codebase scan across all 6 dimensions |
| `--light` | Diff-based review: only analyze files changed since `last_reviewed_commit` in state.json |

## Input

1. Read `.claude/product-review/CONTEXT.md` if it exists -- use it for repo type, architecture, and identity context.
2. If CONTEXT.md does not exist, fall back to inline detection (auto-detect repo type, language, framework from manifest files).
3. For `--light` mode: read `.claude/product-review/state.json` to get `last_reviewed_commit` as the baseline.

## Output

```
.claude/product-review/TECH-REVIEW.md
```

---

## Initialization

**MANDATORY FIRST ACTION:** Create the output directory if it doesn't exist:

```bash
mkdir -p .claude/product-review
```

---

## Mode Behavior

### Full Mode (default)

Scan the entire codebase across all 6 dimensions. Every file in the repo is in scope.

### Light Mode (`--light`)

1. Read `last_reviewed_commit` from `.claude/product-review/state.json`:
   ```bash
   BASELINE=$(cat .claude/product-review/state.json 2>/dev/null | grep -o '"last_reviewed_commit"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"last_reviewed_commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
   ```

2. If no baseline is found, fall back to full mode and report:
   ```
   No baseline commit found in state.json. Falling back to full scan.
   ```

3. If baseline exists, get changed files:
   ```bash
   git diff --name-only $BASELINE..HEAD
   ```

4. Only analyze the changed files and their immediate dependents. Skip dimensions that have zero intersection with changed files.

---

## Repo Type Detection

If CONTEXT.md is not available, detect the repo type inline:

```bash
REPO_TYPE="generic"

if [[ -f "pubspec.yaml" ]]; then
  REPO_TYPE="mobile-app"
elif [[ -f "react-native.config.js" ]]; then
  REPO_TYPE="mobile-app"
elif [[ -f "app.json" ]] && grep -q '"expo"' app.json 2>/dev/null; then
  REPO_TYPE="mobile-app"
elif [[ -f "package.json" ]]; then
  if grep -qE '"(next|nuxt|remix|gatsby|svelte|angular|vue|react-dom)"' package.json 2>/dev/null; then
    REPO_TYPE="web-app"
  elif grep -qE '"(express|fastify|hono|koa|nestjs|hapi)"' package.json 2>/dev/null; then
    REPO_TYPE="api-backend"
  elif grep -qE '"bin"' package.json 2>/dev/null; then
    REPO_TYPE="cli-tool"
  else
    REPO_TYPE="library"
  fi
elif [[ -f "pyproject.toml" ]]; then
  if grep -qE '(django|flask|fastapi|starlette|sanic|tornado)' pyproject.toml 2>/dev/null; then
    REPO_TYPE="api-backend"
  elif grep -qE '\[tool\.poetry\.scripts\]|\[project\.scripts\]' pyproject.toml 2>/dev/null; then
    REPO_TYPE="cli-tool"
  else
    REPO_TYPE="library"
  fi
elif [[ -f "go.mod" ]]; then
  if [[ -d "cmd" ]]; then
    REPO_TYPE="cli-tool"
  elif find . -maxdepth 2 -name "*.go" -exec grep -l 'net/http\|gin\|echo\|fiber\|chi' {} + 2>/dev/null | head -1 | grep -q .; then
    REPO_TYPE="api-backend"
  else
    REPO_TYPE="library"
  fi
elif [[ -f "Cargo.toml" ]]; then
  if grep -q '\[\[bin\]\]' Cargo.toml 2>/dev/null; then
    REPO_TYPE="cli-tool"
  elif grep -qE '(actix|axum|rocket|warp|hyper)' Cargo.toml 2>/dev/null; then
    REPO_TYPE="api-backend"
  else
    REPO_TYPE="library"
  fi
elif [[ -f "pom.xml" || -f "build.gradle" || -f "build.gradle.kts" ]]; then
  if grep -qE '(spring-boot|quarkus|micronaut|ktor)' pom.xml build.gradle build.gradle.kts 2>/dev/null; then
    REPO_TYPE="api-backend"
  else
    REPO_TYPE="library"
  fi
fi
```

---

## 6 Evaluation Dimensions

Evaluate the codebase across all 6 dimensions below. For each dimension, run the specified commands, analyze the output, and produce findings with severity classifications.

---

### Dimension 1: Architecture Health

**Purpose:** Detect structural problems that make the codebase hard to maintain, extend, or reason about.

#### 1A: God Files (>500 lines)

Find source files that are excessively large and likely doing too much:

```bash
find . -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" -o -name "*.kt" \
  -o -name "*.dart" -o -name "*.swift" -o -name "*.rb" -o -name "*.php" \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/dist/*' ! -path '*/build/*' \
  ! -path '*/target/*' ! -path '*/__pycache__/*' ! -path '*/.dart_tool/*' \
  -exec wc -l {} + 2>/dev/null | sort -rn | head -20
```

Flag any file with >500 lines. Files with >1000 lines are P1.

#### 1B: Circular Dependencies

Analyze import chains for circular references:

```bash
# For TypeScript/JavaScript projects
npx madge --circular --extensions ts,tsx,js,jsx src/ 2>/dev/null || true

# Manual fallback: check for bidirectional imports between top-level modules
for dir in $(find src lib app -maxdepth 1 -type d 2>/dev/null); do
  dirname=$(basename "$dir")
  grep -rn "from ['\"].*/${dirname}" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    src/ lib/ app/ 2>/dev/null | grep -v "/${dirname}/" | head -5
done
```

#### 1C: Module Coupling

Identify files with excessive cross-module imports (>10 unique imports from different top-level directories):

```bash
# For each source file, count how many different top-level directories it imports from
find src lib app -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) \
  2>/dev/null | while read -r file; do
  count=$(grep -oE "from ['\"][@./]+" "$file" 2>/dev/null | sort -u | wc -l)
  if [[ $count -gt 10 ]]; then
    echo "$count imports: $file"
  fi
done | sort -rn | head -10
```

For Python:
```bash
find . -name "*.py" ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/__pycache__/*' \
  2>/dev/null | while read -r file; do
  count=$(grep -cE "^(from|import) " "$file" 2>/dev/null)
  if [[ $count -gt 15 ]]; then
    echo "$count imports: $file"
  fi
done | sort -rn | head -10
```

#### 1D: Layer Violations

Check for direct database access from UI/controller layers, or direct HTTP calls from data layers:

```bash
# UI files importing DB clients directly
grep -rn "import.*\(prisma\|typeorm\|sequelize\|mongoose\|knex\|drizzle\|sqlalchemy\|gorm\|diesel\)" \
  --include="*.tsx" --include="*.jsx" --include="*.vue" --include="*.svelte" \
  src/components src/pages src/views app/components pages components 2>/dev/null | head -10

# Data/model layer making HTTP calls
grep -rn "fetch(\|axios\.\|http\.\|request(\|urllib\|requests\.\|net/http\|reqwest" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  src/models src/entities models entities data dal 2>/dev/null | head -10
```

---

### Dimension 2: Security

**Purpose:** Detect vulnerabilities, secrets exposure, and dangerous code patterns.

#### 2A: Secrets in Code

Scan for hardcoded secrets, API keys, passwords, and tokens:

```bash
grep -rn -E "(password|secret|api_key|apikey|token|private_key)\s*[:=]\s*['\"][^'\"]{8,}" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  --include="*.py" --include="*.go" --include="*.rs" --include="*.java" --include="*.kt" \
  --include="*.dart" --include="*.rb" --include="*.php" --include="*.yaml" --include="*.yml" \
  --include="*.json" --include="*.toml" --include="*.env" \
  . 2>/dev/null \
  | grep -v node_modules | grep -v '.git/' | grep -v 'package-lock' | grep -v 'yarn.lock' \
  | grep -v '\.example' | grep -v 'test' | grep -v 'mock' | grep -v 'fixture' \
  | head -20
```

Any confirmed secret in source code is **P0**.

#### 2B: Known CVEs

Run the package manager's built-in audit tool:

```bash
# Node.js
npm audit --json 2>/dev/null | head -100 || true

# Python
pip audit --format json 2>/dev/null | head -100 || true

# Rust
cargo audit --json 2>/dev/null | head -100 || true

# Ruby
bundle audit check 2>/dev/null | head -50 || true

# Go
govulncheck ./... 2>/dev/null | head -50 || true
```

CVEs with known exploits are **P0**. CVEs with no known exploit but high severity are **P1**.

#### 2C: OWASP Patterns

Scan for common OWASP Top 10 vulnerability patterns:

```bash
# SQL injection: string concatenation in queries
grep -rn -E "(SELECT|INSERT|UPDATE|DELETE|DROP).*\+(.*\+|.*\$\{|.*\`)" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -10

# eval() usage
grep -rn "eval(" \
  --include="*.ts" --include="*.js" --include="*.py" \
  . 2>/dev/null | grep -v node_modules | grep -v '.git/' | grep -v test | head -10

# dangerouslySetInnerHTML (XSS risk)
grep -rn "dangerouslySetInnerHTML" \
  --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -v node_modules | head -10

# Unvalidated redirects
grep -rn "redirect\|window\.location\s*=" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -10

# Insecure deserialization (Python)
grep -rn "pickle\.load\|yaml\.load(" \
  --include="*.py" \
  . 2>/dev/null | grep -v test | head -10
```

SQL injection and eval() in production code are **P0**. dangerouslySetInnerHTML without sanitization is **P1**.

---

### Dimension 3: Tech Debt

**Purpose:** Quantify accumulated shortcuts, deferred work, and code quality erosion.

#### 3A: TODO/FIXME/HACK/XXX/WORKAROUND Count

```bash
grep -rn -E "(TODO|FIXME|HACK|XXX|WORKAROUND)" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  --include="*.py" --include="*.go" --include="*.rs" --include="*.java" --include="*.kt" \
  --include="*.dart" --include="*.swift" --include="*.rb" --include="*.php" \
  . 2>/dev/null | grep -v node_modules | grep -v '.git/' | wc -l

# Show top offenders by category
for keyword in TODO FIXME HACK XXX WORKAROUND; do
  count=$(grep -rn "$keyword" \
    --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    --include="*.py" --include="*.go" --include="*.rs" --include="*.java" --include="*.kt" \
    --include="*.dart" --include="*.swift" --include="*.rb" --include="*.php" \
    . 2>/dev/null | grep -v node_modules | grep -v '.git/' | wc -l)
  echo "$keyword: $count"
done
```

#### 3B: Skipped Tests

```bash
# JavaScript/TypeScript
grep -rn "it\.skip\|describe\.skip\|test\.skip\|xit(\|xdescribe(\|xtest(" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | head -20

# Python
grep -rn "@pytest\.mark\.skip\|@unittest\.skip\|pytest\.skip(" \
  --include="*.py" \
  . 2>/dev/null | head -20

# Rust
grep -rn '#\[ignore\]' \
  --include="*.rs" \
  . 2>/dev/null | head -20

# Go
grep -rn 't\.Skip(' \
  --include="*.go" \
  . 2>/dev/null | head -20

# Java/Kotlin
grep -rn "@Disabled\|@Ignore" \
  --include="*.java" --include="*.kt" \
  . 2>/dev/null | head -20
```

#### 3C: Suppressed Lints

```bash
# JavaScript/TypeScript
grep -rn "eslint-disable\|@ts-ignore\|@ts-expect-error\|@ts-nocheck\|tslint:disable\|noinspection" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | wc -l

# Show individual suppressions
grep -rn "eslint-disable\|@ts-ignore\|@ts-expect-error\|@ts-nocheck" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | head -20

# Python
grep -rn "# noqa\|# type: ignore\|# pylint: disable\|# pragma: no cover" \
  --include="*.py" \
  . 2>/dev/null | wc -l

# Rust
grep -rn '#\[allow(' \
  --include="*.rs" \
  . 2>/dev/null | wc -l

# Go
grep -rn '//nolint\|// nolint' \
  --include="*.go" \
  . 2>/dev/null | wc -l
```

#### 3D: Dead Code Indicators

```bash
# Unused exports (TypeScript/JavaScript) -- look for exported symbols not imported elsewhere
# This is heuristic: find exports that appear only once in the entire codebase
grep -rn "export " --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  src/ lib/ app/ 2>/dev/null | grep -v node_modules | grep -v '.test\.' | grep -v '.spec\.' | head -30

# Commented-out code blocks (>3 consecutive commented lines)
grep -rn -E "^[[:space:]]*(//|#|/\*)" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  . 2>/dev/null | grep -v node_modules | grep -v '.git/' | wc -l
```

High HACK/XXX/WORKAROUND density or >10 skipped tests is **P1**. Scattered TODOs and lint suppressions are **P2**.

---

### Dimension 4: Dependency Health

**Purpose:** Detect outdated, unmaintained, or risky dependencies.

#### 4A: Outdated Packages

```bash
# Node.js
npm outdated --json 2>/dev/null | head -80 || true

# Python
pip list --outdated --format json 2>/dev/null | head -80 || true

# Rust
cargo outdated --format json 2>/dev/null || cargo outdated 2>/dev/null | head -40 || true

# Go
go list -u -m all 2>/dev/null | grep '\[' | head -40 || true

# Ruby
bundle outdated 2>/dev/null | head -40 || true
```

#### 4B: Unmaintained Dependencies

Check for packages whose last release was >2 years ago. This is a heuristic check:

```bash
# For Node.js: check top dependencies
if [[ -f "package.json" ]]; then
  for pkg in $(cat package.json | grep -oE '"[^"]+"\s*:\s*"[~^]?[0-9]' | head -20 | sed 's/"\([^"]*\)".*/\1/'); do
    npm view "$pkg" time --json 2>/dev/null | grep -oE '"modified":"[^"]*"' | head -1
  done 2>/dev/null | head -20
fi
```

Dependencies with no release in >2 years are **P2**. Dependencies with known security issues and no maintenance are **P1**.

#### 4C: License Risks

Scan for restrictive licenses (GPL, AGPL) in non-GPL projects:

```bash
# Check project license
PROJECT_LICENSE=""
if [[ -f "LICENSE" ]]; then
  PROJECT_LICENSE=$(head -5 LICENSE | grep -oiE "(MIT|Apache|BSD|GPL|AGPL|ISC|MPL|LGPL|Unlicense)" | head -1)
fi
echo "Project license: ${PROJECT_LICENSE:-unknown}"

# For Node.js: check dependency licenses
npx license-checker --summary 2>/dev/null | head -30 || true

# Fallback: search for GPL in dependency licenses
find node_modules -name "LICENSE*" -exec grep -l "GPL" {} + 2>/dev/null | head -10 || true
find . -path '*/site-packages/*/LICENSE*' -exec grep -l "GPL" {} + 2>/dev/null | head -10 || true
```

GPL/AGPL dependency in a non-GPL project is **P1**.

---

### Dimension 5: Performance Risks

**Purpose:** Detect patterns that cause performance degradation at scale.

#### 5A: N+1 Query Patterns

Look for database calls inside loops:

```bash
# JavaScript/TypeScript: DB calls in loops
grep -rn -B2 -A2 "for\s*(\|\.forEach\|\.map(\|while\s*(" \
  --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -A3 "prisma\.\|\.findOne\|\.findMany\|\.query\|\.execute\|\.find(\|\.aggregate(" \
  | grep -v node_modules | head -20

# Python: DB calls in loops
grep -rn -B2 -A2 "for .* in .*:" \
  --include="*.py" \
  . 2>/dev/null | grep -A3 "\.filter(\|\.get(\|\.all()\|\.execute(\|session\.\|cursor\." \
  | grep -v test | head -20

# Look for ORM queries inside loop bodies
grep -rn "\.find\|\.findOne\|\.query\|\.get(\|\.filter(" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -20
```

#### 5B: Missing Indexes

Check for schema definitions or migrations without indexes on foreign keys or frequently queried fields:

```bash
# Prisma: models with relations but no @@index
grep -A20 "model " prisma/schema.prisma 2>/dev/null | grep -E "@relation|@@index" | head -20

# SQL migrations: CREATE TABLE without indexes
find . -path "*/migrations/*.sql" -exec grep -l "CREATE TABLE" {} + 2>/dev/null | while read -r f; do
  tables=$(grep -c "CREATE TABLE" "$f")
  indexes=$(grep -c "CREATE INDEX\|CREATE UNIQUE INDEX" "$f")
  echo "$f: $tables tables, $indexes indexes"
done | head -10

# Django: models without db_index=True or Meta.indexes
grep -rn "ForeignKey\|CharField\|IntegerField" --include="*.py" \
  . 2>/dev/null | grep -v "db_index\|index" | grep -v test | grep -v migration | head -10
```

#### 5C: Bundle Size

Check frontend bundle configuration for potential bloat:

```bash
# Check for barrel exports (index.ts re-exporting everything)
find src lib app -name "index.ts" -o -name "index.js" 2>/dev/null | while read -r f; do
  exports=$(grep -c "export" "$f" 2>/dev/null)
  if [[ $exports -gt 10 ]]; then
    echo "Barrel file ($exports exports): $f"
  fi
done | head -10

# Check for large dependencies that should be lazy-loaded or tree-shaken
grep -E "import .* from ['\"]moment['\"]|import .* from ['\"]lodash['\"](?!/)|import .* from ['\"]luxon['\"]" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  -rn . 2>/dev/null | grep -v node_modules | head -10

# Check build output size if available
ls -lh dist/ build/ .next/ out/ 2>/dev/null | head -10
du -sh dist/ build/ .next/ out/ 2>/dev/null | head -5
```

#### 5D: Large Images

Find oversized image assets (>500KB):

```bash
find . -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.gif" \
  -o -name "*.svg" -o -name "*.webp" -o -name "*.bmp" -o -name "*.ico" \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/dist/*' ! -path '*/build/*' \
  -size +500k 2>/dev/null | while read -r f; do
  size=$(du -h "$f" | cut -f1)
  echo "$size  $f"
done | sort -rh | head -15
```

N+1 patterns are **P1** in production paths. Large images and bundle bloat are **P2**.

---

### Dimension 6: CI/CD Health

**Purpose:** Verify that the project has proper continuous integration and deployment safeguards.

#### 6A: CI Config Exists

```bash
# Check for CI/CD configuration files
CI_FOUND=false
for f in .github/workflows/*.yml .github/workflows/*.yaml \
         .gitlab-ci.yml .circleci/config.yml Jenkinsfile \
         .travis.yml bitbucket-pipelines.yml \
         .buildkite/pipeline.yml azure-pipelines.yml; do
  if ls $f 2>/dev/null | head -1 | grep -q .; then
    echo "CI config: $f"
    CI_FOUND=true
  fi
done

if [[ "$CI_FOUND" == "false" ]]; then
  echo "NO CI CONFIGURATION FOUND"
fi
```

No CI config is **P1**.

#### 6B: Test Step in CI

Verify CI pipelines include a test execution step:

```bash
# Search CI configs for test commands
grep -rn "npm test\|yarn test\|pnpm test\|pytest\|go test\|cargo test\|flutter test\|bundle exec rspec\|mvn test\|gradle test" \
  .github/workflows/ .gitlab-ci.yml .circleci/ Jenkinsfile .travis.yml bitbucket-pipelines.yml \
  .buildkite/ azure-pipelines.yml 2>/dev/null | head -10
```

CI exists but has no test step is **P1**.

#### 6C: Lint Step in CI

Verify CI pipelines include linting:

```bash
grep -rn "lint\|eslint\|prettier\|flake8\|ruff\|black\|pylint\|golangci-lint\|clippy\|rubocop\|phpstan" \
  .github/workflows/ .gitlab-ci.yml .circleci/ Jenkinsfile .travis.yml bitbucket-pipelines.yml \
  .buildkite/ azure-pipelines.yml 2>/dev/null | head -10
```

#### 6D: Deploy Step

Check whether CI includes deployment:

```bash
grep -rn "deploy\|publish\|release\|push.*docker\|aws\|gcloud\|az\|fly deploy\|vercel\|netlify\|railway" \
  .github/workflows/ .gitlab-ci.yml .circleci/ Jenkinsfile .travis.yml bitbucket-pipelines.yml \
  .buildkite/ azure-pipelines.yml 2>/dev/null | head -10
```

#### 6E: Missing Checks

Identify common CI checks that are absent:

```bash
# Check for branch protection indicators
grep -rn "pull_request\|merge_request\|on:\s*push" \
  .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null | head -10

# Check for security scanning in CI
grep -rn "snyk\|dependabot\|renovate\|npm audit\|pip audit\|cargo audit\|trivy\|codeql\|sonar" \
  .github/workflows/ .github/ .gitlab-ci.yml 2>/dev/null | head -10

# Check for code coverage reporting
grep -rn "coverage\|codecov\|coveralls\|lcov" \
  .github/workflows/ .gitlab-ci.yml .circleci/ 2>/dev/null | head -10
```

Missing test or lint steps in CI is **P1**. Missing security scanning or coverage reporting is **P2**. Missing deploy step is **P3** (may be intentional for libraries).

---

## Severity Classification

Classify every finding into exactly one severity level:

| Severity | Meaning | Examples |
|----------|---------|----------|
| **P0** | Ship-blocker. Must fix before any release. | CVE with known exploit, secrets in source code, broken build, SQL injection |
| **P1** | Fix soon. Significant risk or quality issue. | Outdated deps with security advisories, architecture violations, missing critical tests, no CI, N+1 queries in hot paths, GPL license contamination |
| **P2** | Improvement. Measurable benefit but not urgent. | Tech debt accumulation, performance optimizations, bundle size, large images, missing coverage reporting |
| **P3** | Nice-to-have. Low impact, low effort. | Code style, minor refactors, documentation gaps, stale branches |

---

## Finding Format

Every finding MUST use this exact markdown template:

```markdown
### [P<N>] [<DIMENSION>] <title>

**Dimension:** <Architecture Health | Security | Tech Debt | Dependency Health | Performance Risks | CI/CD Health>
**Impact:** <High | Medium | Low> -- <why this matters>
**Effort:** <Small | Medium | Large> -- <scope of the fix>
**Details:**
- <bullet point with specific evidence>
- <file paths, line numbers, counts>
- <command output excerpts>
**Action:** `/ship <task description to fix this>`
```

---

## Output Structure

Write the complete review to `.claude/product-review/TECH-REVIEW.md` with this structure:

```markdown
# Technical Health Review -- <YYYY-MM-DD>

**Mode:** <light | full>
**Repo Type:** <detected repo type>
**Baseline:** <commit SHA for light mode, or "full scan">
**Files Analyzed:** <count>

## Summary

| Severity | Count |
|----------|-------|
| P0 | <n> |
| P1 | <n> |
| P2 | <n> |
| P3 | <n> |

## Findings

<all findings ordered P0 first, then P1, P2, P3>

## Dimensions Skipped

<list any dimensions that were skipped, with reasons>
<e.g., "Dimension 5 (Performance Risks): No database or frontend code detected.">
<e.g., "Dimension 4B (Unmaintained Deps): npm not available in this environment.">
<If no dimensions were skipped, write: "None -- all 6 dimensions evaluated.">
```

---

## After Review

After writing TECH-REVIEW.md, report a summary to the user:

```
## /review-tech Complete

Mode: <light | full>
Output: .claude/product-review/TECH-REVIEW.md
Files analyzed: <count>

### Finding Summary
| Severity | Count |
|----------|-------|
| P0 | <n> |
| P1 | <n> |
| P2 | <n> |
| P3 | <n> |

### Top Findings
- <P0/P1 findings listed here, one line each>

### Dimensions Covered
<list of 6 dimensions with checkmark or skip indicator>
```

If called by the `/review-product` coordinator, return the summary data for aggregation -- do not prompt the user.
