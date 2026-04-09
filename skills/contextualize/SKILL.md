---
name: contextualize
description: "Generate a comprehensive AI context document (bible) for any repo. Produces .claude/product-review/CONTEXT.md with identity, architecture, capabilities, data model, integrations, tests, infra, team, open work, and docs state."
origin: custom
tools: Read, Write, Edit, Bash, Grep, Glob
---

# /contextualize — AI Context Bible Generator

Generate a comprehensive, structured context document for any repository. The output is a single markdown file at `.claude/product-review/CONTEXT.md` that gives any AI agent (or human) full situational awareness of the project.

## When to Activate

- User says `/contextualize`
- User says `/contextualize --full`
- User wants a "project bible", "context doc", or "repo overview" for AI consumption
- User wants to understand a new codebase quickly
- Before running `/review-product` or any product-level analysis that needs repo context

## Arguments

| Argument | Effect |
|----------|--------|
| *(none)* | Generate context doc, skipping sections that haven't changed since last run (staleness detection) |
| `--full` | Force full regeneration of all sections, ignoring cached hash |

## Output Path

```
.claude/product-review/CONTEXT.md
```

The hash file for staleness detection:

```
.claude/product-review/.context-hash
```

---

## Initialization

**MANDATORY FIRST ACTION:** Create the output directory if it doesn't exist:

```bash
mkdir -p .claude/product-review
```

---

## Staleness Detection

Before generating, check whether the repo has changed since the last run. Compute a SHA256 hash of the git HEAD and key manifest files:

```bash
CURRENT_HASH=$( (git rev-parse HEAD 2>/dev/null || echo "no-git"; for f in package.json Cargo.toml pyproject.toml pubspec.yaml go.mod pom.xml build.gradle composer.json Gemfile; do sha256sum "$f" 2>/dev/null || true; done) | sha256sum | cut -d' ' -f1 )
```

Compare against the stored hash:

```bash
STORED_HASH=""
if [[ -f ".claude/product-review/.context-hash" ]]; then
  STORED_HASH=$(cat .claude/product-review/.context-hash)
fi
```

**Decision:**
- If `$CURRENT_HASH == $STORED_HASH` and `--full` was NOT passed: report "Context is up to date. No changes since last generation." and stop.
- If `$CURRENT_HASH != $STORED_HASH` or `--full` was passed: proceed with full generation.

---

## Repo Type Auto-Detection

Detect the repo type to guide which sections are relevant and how to extract information. Run these checks in order — first match wins:

```bash
REPO_TYPE="generic"

# Mobile app detection
if [[ -f "pubspec.yaml" ]]; then
  REPO_TYPE="mobile-app"  # Flutter
elif [[ -f "react-native.config.js" ]]; then
  REPO_TYPE="mobile-app"  # React Native
elif [[ -f "app.json" ]] && grep -q '"expo"' app.json 2>/dev/null; then
  REPO_TYPE="mobile-app"  # Expo

# Web app detection (check package.json for framework deps)
elif [[ -f "package.json" ]]; then
  if grep -qE '"(next|nuxt|remix|gatsby|svelte|angular|vue|react-dom)"' package.json 2>/dev/null; then
    REPO_TYPE="web-app"
  elif grep -qE '"(express|fastify|hono|koa|nestjs|hapi)"' package.json 2>/dev/null; then
    REPO_TYPE="api-backend"
  elif grep -qE '"bin"' package.json 2>/dev/null; then
    REPO_TYPE="cli-tool"
  else
    REPO_TYPE="library"  # JS/TS library
  fi

# Python detection
elif [[ -f "pyproject.toml" ]]; then
  if grep -qE '(django|flask|fastapi|starlette|sanic|tornado)' pyproject.toml 2>/dev/null; then
    REPO_TYPE="api-backend"
  elif grep -qE '\[tool\.poetry\.scripts\]|\[project\.scripts\]' pyproject.toml 2>/dev/null; then
    REPO_TYPE="cli-tool"
  else
    REPO_TYPE="library"
  fi

# Go detection
elif [[ -f "go.mod" ]]; then
  if [[ -d "cmd" ]]; then
    REPO_TYPE="cli-tool"
  elif find . -maxdepth 2 -name "*.go" -exec grep -l 'net/http\|gin\|echo\|fiber\|chi' {} + 2>/dev/null | head -1 | grep -q .; then
    REPO_TYPE="api-backend"
  else
    REPO_TYPE="library"
  fi

# Rust detection
elif [[ -f "Cargo.toml" ]]; then
  if grep -q '\[\[bin\]\]' Cargo.toml 2>/dev/null; then
    REPO_TYPE="cli-tool"
  elif grep -qE '(actix|axum|rocket|warp|hyper)' Cargo.toml 2>/dev/null; then
    REPO_TYPE="api-backend"
  else
    REPO_TYPE="library"
  fi

# JVM detection
elif [[ -f "pom.xml" || -f "build.gradle" || -f "build.gradle.kts" ]]; then
  if grep -qE '(spring-boot|quarkus|micronaut|ktor)' pom.xml build.gradle build.gradle.kts 2>/dev/null; then
    REPO_TYPE="api-backend"
  else
    REPO_TYPE="library"
  fi
fi
```

Report the detected type at the top of CONTEXT.md.

---

## Sections to Generate

Generate ALL 10 sections below. Each section MUST follow this format:

```markdown
## Section Name

**Last updated:** <ISO 8601 timestamp>
**Sources:** <list of files/commands used to gather this info>

<structured content>
```

---

### Section 1: Identity

**Purpose:** Who is this project, at a glance?

**Gather from:** `package.json`, `Cargo.toml`, `pyproject.toml`, `pubspec.yaml`, `go.mod`, `pom.xml`, `build.gradle`, `composer.json`, `Gemfile`, `README.md` (first 50 lines), `LICENSE`

**Output structure:**

```markdown
## Identity

**Last updated:** <timestamp>
**Sources:** <manifest files read>

| Field | Value |
|-------|-------|
| Project name | <from manifest> |
| Description | <from manifest or README first line> |
| Tech stack | <language + framework> |
| Language | <primary language> |
| Framework | <primary framework, if any> |
| Package manager | <npm/yarn/pnpm/cargo/pip/poetry/go/maven/gradle/composer/bundler> |
| Version | <from manifest> |
| License | <from LICENSE file or manifest> |
| Repo type | <detected: web-app / api-backend / cli-tool / library / mobile-app / generic> |
```

---

### Section 2: Architecture

**Purpose:** How is the code organized?

**Gather from:** Directory tree, entry points, config files

**Commands:**

```bash
# Directory tree (depth 3, ignore node_modules, .git, build artifacts)
find . -maxdepth 3 -type d \
  ! -path '*/node_modules/*' \
  ! -path '*/.git/*' \
  ! -path '*/dist/*' \
  ! -path '*/build/*' \
  ! -path '*/.next/*' \
  ! -path '*/target/*' \
  ! -path '*/__pycache__/*' \
  ! -path '*/.dart_tool/*' \
  | head -80 \
  | sort
```

```bash
# Identify entry points
for f in src/index.ts src/index.js src/main.ts src/main.js src/app.ts src/app.js \
         main.go cmd/main.go src/main.rs src/lib.rs \
         manage.py app.py main.py wsgi.py asgi.py \
         lib/main.dart index.html; do
  [[ -f "$f" ]] && echo "Entry point: $f"
done
```

```bash
# Key config files
for f in tsconfig.json .eslintrc* .prettierrc* vite.config.* webpack.config.* \
         next.config.* nuxt.config.* svelte.config.* angular.json \
         Dockerfile docker-compose.yml .github/workflows/*.yml \
         Makefile CMakeLists.txt setup.cfg setup.py pyproject.toml \
         pubspec.yaml analysis_options.yaml build.yaml; do
  ls $f 2>/dev/null
done
```

**Output structure:**

```markdown
## Architecture

**Last updated:** <timestamp>
**Sources:** directory tree, entry points, config files

### Directory Tree (depth 3)

\`\`\`
<tree output>
\`\`\`

### Entry Points

- <list of entry point files with one-line description of what each does>

### Module Boundaries

- <describe top-level directories and what they contain>
- <note any monorepo/workspace structure>

### Key Config Files

- <list config files with purpose>
```

---

### Section 3: Product Capabilities

**Purpose:** What does this project actually DO from a user perspective?

**Gather from:** Route files, API endpoint definitions, CLI command definitions, screen/page components

**For web-app:**
```bash
# Find route definitions
grep -rn "path\|route\|Route\|router\." --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  src/app src/pages src/routes pages app routes 2>/dev/null | head -40
```

**For api-backend:**
```bash
# Find API endpoint definitions
grep -rn "app\.\(get\|post\|put\|patch\|delete\)\|@Get\|@Post\|@Put\|@Delete\|@RequestMapping\|@router\." \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.java" --include="*.go" --include="*.rs" \
  src app routes controllers api 2>/dev/null | head -40
```

**For cli-tool:**
```bash
# Find CLI commands/subcommands
grep -rn "command\|subcommand\|\.add_command\|@click\|#\[clap\|cobra\.\|\.Arg(" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  src cmd cli commands 2>/dev/null | head -40
```

**For mobile-app:**
```bash
# Find screens/pages
find . -type f \( -name "*screen*" -o -name "*page*" -o -name "*Screen*" -o -name "*Page*" \) \
  ! -path '*/node_modules/*' ! -path '*/.dart_tool/*' 2>/dev/null | head -30
```

**For library or generic:** Skip this section with the note:

```markdown
## Product Capabilities

**Last updated:** <timestamp>
**Sources:** N/A

> This is a **<library|generic>** project. Product capabilities are defined by the consuming application, not this repo. See the public API surface in the Architecture section instead.
```

**Output structure (when applicable):**

```markdown
## Product Capabilities

**Last updated:** <timestamp>
**Sources:** <route files, endpoint files, CLI definitions>

### Routes / Endpoints / Commands / Screens

| Path / Command | Method | Handler | Description |
|----------------|--------|---------|-------------|
| <path> | <GET/POST/...> | <handler file:line> | <inferred purpose> |
```

---

### Section 4: Data Model

**Purpose:** What data does this project manage?

**Gather from:** Database schemas, migrations, ORM models, type definitions

```bash
# Find schema/model/migration files
find . -type f \( \
  -name "*.prisma" -o -name "*.sql" -o -name "*migration*" -o -name "*schema*" \
  -o -name "*model*" -o -name "*entity*" -o -name "*models.py" -o -name "*schema.py" \
  -o -path "*/migrations/*.py" -o -path "*/models/*.ts" -o -path "*/entities/*.ts" \
  -o -path "*/models/*.go" -o -path "*/models/*.rs" -o -path "*/models/*.java" \
  \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' \
  2>/dev/null | head -30
```

```bash
# Detect storage tech
for indicator in "prisma" "typeorm" "sequelize" "mongoose" "knex" "drizzle" \
                 "sqlalchemy" "django.db" "peewee" "tortoise" \
                 "gorm" "sqlx" "diesel" "sea-orm" \
                 "hibernate" "jpa" "exposed" "jooq" \
                 "redis" "mongodb" "postgresql" "mysql" "sqlite"; do
  grep -rl "$indicator" --include="*.ts" --include="*.js" --include="*.py" --include="*.go" \
    --include="*.rs" --include="*.java" --include="*.toml" --include="*.json" \
    . 2>/dev/null | head -1 | grep -q . && echo "Storage: $indicator"
done
```

**Output structure:**

```markdown
## Data Model

**Last updated:** <timestamp>
**Sources:** <schema files, migration files, model files>

### Entities

| Entity | Fields (key) | Storage | Source File |
|--------|-------------|---------|-------------|
| <name> | <key fields> | <postgres/mongo/redis/...> | <file path> |

### Relationships

- <Entity A> has many <Entity B> (via <foreign key>)
- <Entity C> belongs to <Entity A>

### Storage Tech

- Primary: <database>
- Cache: <redis/memcached/none>
- File storage: <s3/local/none>
```

---

### Section 5: Integrations

**Purpose:** What external services does this project talk to?

**Gather from:** Environment variables, import statements, SDK usage

```bash
# Find .env files and extract variable names (not values!)
for f in .env .env.example .env.local .env.development .env.sample; do
  if [[ -f "$f" ]]; then
    echo "=== $f ==="
    grep -E '^[A-Z_]+=' "$f" | sed 's/=.*//' | sort
  fi
done
```

```bash
# Find SDK/client imports that suggest external integrations
grep -rn "import.*\(stripe\|twilio\|sendgrid\|aws-sdk\|@aws-sdk\|firebase\|supabase\|clerk\|auth0\|sentry\|datadog\|segment\|mixpanel\|posthog\|openai\|anthropic\|resend\|postmark\|slack\|discord\|github\|google\|azure\)" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" --include="*.java" \
  src lib app 2>/dev/null | head -30
```

```bash
# Find webhook handlers
grep -rn "webhook\|Webhook\|WEBHOOK" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  src lib app routes api 2>/dev/null | head -20
```

**Output structure:**

```markdown
## Integrations

**Last updated:** <timestamp>
**Sources:** <env files, import statements, webhook handlers>

### External APIs & SDKs

| Service | SDK/Client | Purpose | Env Vars |
|---------|-----------|---------|----------|
| <service> | <package name> | <inferred purpose> | <relevant env var names> |

### Webhooks

| Endpoint | Source | Purpose |
|----------|--------|---------|
| <path> | <service> | <what it handles> |

### Environment Variables (names only)

| Variable | Likely Purpose |
|----------|---------------|
| <VAR_NAME> | <inferred from name> |
```

---

### Section 6: Test Coverage

**Purpose:** How well tested is this project?

**Gather from:** Test files, test config, coverage reports

```bash
# Count test files
find . -type f \( -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" -o -name "test_*" \
  -o -path "*/tests/*" -o -path "*/__tests__/*" -o -path "*/test/*" \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/target/*' \
  2>/dev/null | wc -l
```

```bash
# Detect test framework
for indicator in "jest" "vitest" "mocha" "pytest" "unittest" "go test" "cargo test" \
                 "junit" "kotest" "rspec" "phpunit" "flutter_test" "detox" "cypress" "playwright"; do
  grep -rl "$indicator" --include="*.json" --include="*.toml" --include="*.yaml" --include="*.yml" \
    --include="*.cfg" --include="*.ts" --include="*.js" \
    . 2>/dev/null | head -1 | grep -q . && echo "Framework: $indicator"
done
```

```bash
# Check for coverage config or reports
ls coverage/ htmlcov/ .nyc_output/ .coverage lcov.info coverage.xml 2>/dev/null
```

**Output structure:**

```markdown
## Test Coverage

**Last updated:** <timestamp>
**Sources:** <test files, config files, coverage reports>

| Metric | Value |
|--------|-------|
| Test framework | <framework> |
| Test file count | <count> |
| Coverage % | <from report, or "no coverage report found"> |
| E2E framework | <playwright/cypress/detox/maestro/none> |

### What's Tested

- <list of key areas with test coverage>

### What's NOT Tested

- <list of areas missing test coverage, inferred from comparing test files to source files>
```

---

### Section 7: Infrastructure

**Purpose:** How is this project built, deployed, and run?

**Gather from:** Docker files, CI/CD configs, IaC files

```bash
# Docker
ls Dockerfile docker-compose.yml docker-compose.yaml .dockerignore 2>/dev/null

# CI/CD
ls .github/workflows/*.yml .gitlab-ci.yml .circleci/config.yml Jenkinsfile \
   .travis.yml bitbucket-pipelines.yml 2>/dev/null

# IaC
ls terraform/ pulumi/ cdk/ serverless.yml serverless.ts \
   cloudformation/ sam-template.yaml fly.toml render.yaml \
   vercel.json netlify.toml railway.json Procfile 2>/dev/null
```

**Output structure:**

```markdown
## Infrastructure

**Last updated:** <timestamp>
**Sources:** <Dockerfiles, CI configs, IaC files>

### Containerization

- <Docker setup description, or "No Docker configuration found">

### CI/CD

| Pipeline | File | Triggers | Steps |
|----------|------|----------|-------|
| <name> | <file path> | <on push/PR/etc> | <key steps> |

### Deploy Targets

- <where this deploys: Vercel, AWS, GCP, fly.io, etc.>
- <or "No deploy configuration found">

### Infrastructure as Code

- <Terraform, Pulumi, CDK, etc., or "None detected">
```

---

### Section 8: Team & Velocity

**Purpose:** Who works on this and how fast is it moving?

**Gather from:** Git history

```bash
# Top contributors (last 90 days)
git shortlog -sne --since="90 days ago" 2>/dev/null | head -10
```

```bash
# Commit frequency (last 30 days)
git log --oneline --since="30 days ago" 2>/dev/null | wc -l
```

```bash
# Hot files (most frequently changed in last 90 days)
git log --since="90 days ago" --pretty=format: --name-only 2>/dev/null | sort | uniq -c | sort -rn | head -15
```

```bash
# God files (largest source files by line count)
find . -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" -o -name "*.kt" \
  -o -name "*.dart" -o -name "*.swift" -o -name "*.rb" -o -name "*.php" \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/dist/*' ! -path '*/build/*' ! -path '*/target/*' \
  -exec wc -l {} + 2>/dev/null | sort -rn | head -15
```

**Output structure:**

```markdown
## Team & Velocity

**Last updated:** <timestamp>
**Sources:** git log, file stats

### Top Contributors (last 90 days)

| Commits | Author |
|---------|--------|
| <count> | <name> <email> |

### Velocity

- Commits in last 30 days: <count>
- Average: <count/30> commits/day

### Hot Files (most changed, last 90 days)

| Changes | File |
|---------|------|
| <count> | <file path> |

### God Files (largest source files)

| Lines | File |
|-------|------|
| <count> | <file path> |

> God files (>500 lines) are candidates for refactoring.
```

---

### Section 9: Open Work

**Purpose:** What's in progress or waiting for attention?

**Gather from:** GitHub issues/PRs, local branches

```bash
# Open GitHub issues (requires gh CLI)
gh issue list --limit 20 --state open 2>/dev/null || echo "gh CLI not available or not in a GitHub repo"
```

```bash
# Open GitHub PRs
gh pr list --limit 10 --state open 2>/dev/null || echo "gh CLI not available or not in a GitHub repo"
```

```bash
# Local branches
git branch -a 2>/dev/null
```

```bash
# Stale branches (no commits in 30+ days)
for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null); do
  last_commit=$(git log -1 --format='%ci' "$branch" 2>/dev/null)
  echo "$last_commit $branch"
done | sort | head -20
```

**Output structure:**

```markdown
## Open Work

**Last updated:** <timestamp>
**Sources:** gh issue list, gh pr list, git branch

### Open Issues (top 20)

| # | Title | Labels | Assignee |
|---|-------|--------|----------|
| <number> | <title> | <labels> | <assignee> |

> Or: "gh CLI not available — skipped GitHub issues."

### Open Pull Requests

| # | Title | Author | Status |
|---|-------|--------|--------|
| <number> | <title> | <author> | <draft/review/approved> |

> Or: "gh CLI not available — skipped GitHub PRs."

### Local Branches

- <branch name> (last commit: <date>)

### Stale Branches (no commits in 30+ days)

- <branch name> — last commit <date>
```

---

### Section 10: Docs State

**Purpose:** How healthy is the project's documentation?

**Gather from:** README, docs directory, CHANGELOG, API docs

```bash
# Check documentation files
for f in README.md README.rst README.txt CHANGELOG.md CHANGELOG.rst CHANGES.md \
         CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md API.md; do
  if [[ -f "$f" ]]; then
    lines=$(wc -l < "$f")
    echo "$f: $lines lines"
  fi
done
```

```bash
# Check for docs directory
if [[ -d "docs" ]]; then
  echo "docs/ directory:"
  find docs -type f | head -20
  echo "Total files: $(find docs -type f | wc -l)"
else
  echo "No docs/ directory"
fi
```

```bash
# Check for API documentation
ls swagger.json openapi.json openapi.yaml docs/api* docs/swagger* 2>/dev/null
# Check for generated docs
ls docs/.vitepress docs/.docusaurus .storybook typedoc.json jsdoc.json 2>/dev/null
```

**Output structure:**

```markdown
## Docs State

**Last updated:** <timestamp>
**Sources:** documentation files, docs/ directory

### Documentation Files

| File | Lines | Health |
|------|-------|--------|
| README.md | <lines> | <good if >50 lines, sparse if <50, missing if absent> |
| CHANGELOG.md | <lines> | <good/sparse/missing> |
| CONTRIBUTING.md | <lines> | <good/sparse/missing> |

### Docs Directory

- <description of docs/ contents, or "No docs/ directory found">
- Total doc files: <count>

### API Documentation

- <OpenAPI/Swagger, Storybook, TypeDoc, etc., or "No API documentation found">

### Docs Health Summary

- <overall assessment: well-documented / adequate / needs attention / undocumented>
```

---

## After Generation

Once all 10 sections are generated:

### 1. Write CONTEXT.md

Write the complete document to `.claude/product-review/CONTEXT.md` with this header:

```markdown
# Project Context — AI Bible

> Auto-generated by `/contextualize` on <ISO 8601 timestamp>
> Repo type: **<detected repo type>**
> Hash: `<current hash>`

---

<all 10 sections>
```

### 2. Save Hash

```bash
echo "<CURRENT_HASH>" > .claude/product-review/.context-hash
```

### 3. Report Summary

After writing the file, report:

```
## /contextualize Complete

Output: .claude/product-review/CONTEXT.md
Repo type: <detected type>
Sections: 10/10
Hash: <current hash>

### Section Summary
| # | Section | Key Findings |
|---|---------|-------------|
| 1 | Identity | <project name>, <language>, <framework> |
| 2 | Architecture | <entry point count> entry points, <top-level dir count> top-level dirs |
| 3 | Product Capabilities | <route/endpoint/command count> capabilities found |
| 4 | Data Model | <entity count> entities, <storage tech> |
| 5 | Integrations | <integration count> external services |
| 6 | Test Coverage | <test file count> test files, <coverage %> |
| 7 | Infrastructure | <CI/CD>, <deploy target> |
| 8 | Team & Velocity | <contributor count> contributors, <commit count> commits (30d) |
| 9 | Open Work | <issue count> issues, <PR count> PRs |
| 10 | Docs State | <health assessment> |
```
