---
name: review-features
description: "Identify feature gaps, enhancement opportunities, and UX improvements. Produces .claude/product-review/FEATURES-REVIEW.md with P0-P3 severity suggestions across 7 dimensions."
origin: custom
tools: Read, Write, Edit, Bash, Grep, Glob, Agent
---

# /review-features -- Product Intelligence Reviewer

Analyze a repository's product capabilities across 7 dimensions. Produces a structured review document with severity-classified suggestions (P0-P3) for feature gaps, UX improvements, and enhancement opportunities.

## When to Activate

- User says `/review-features`
- User says `/review-features --full` or `/review-features --light`
- Called by the `/review-product` coordinator as part of a full product review
- User wants a product audit, feature gap analysis, UX review, or competitive parity check

## Arguments

| Argument | Effect |
|----------|--------|
| `--full` | **(default when standalone)** Full codebase scan across all 7 dimensions |
| `--light` | Diff-based review: only analyze files changed since `last_reviewed_commit` in state.json |

## Input

1. Read `.claude/product-review/CONTEXT.md` if it exists -- use it for repo type, architecture, and identity context.
2. If CONTEXT.md does not exist, fall back to inline detection (auto-detect repo type, language, framework from manifest files).
3. For `--light` mode: read `.claude/product-review/state.json` to get `last_reviewed_commit` as the baseline.

## Output

```
.claude/product-review/FEATURES-REVIEW.md
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

Scan the entire codebase across all 7 dimensions. Every file in the repo is in scope.

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

## Repo Type Applicability Matrix

**CRITICAL:** Not all dimensions apply to all repo types. Use this matrix to determine which dimensions to evaluate. Skip inapplicable dimensions and document the reason.

| Dimension | Applies to | Skip for |
|-----------|-----------|----------|
| Feature Completeness | web-app, api-backend, mobile-app, cli-tool | library, generic |
| Error Handling UX | web-app, mobile-app | api-backend, cli-tool, library, generic |
| Accessibility | web-app, mobile-app | api-backend, cli-tool, library, generic |
| API Design | api-backend, web-app (if has API routes) | cli-tool, library, generic |
| Observability | All | -- |
| User-Facing Gaps | web-app, api-backend, mobile-app | cli-tool, library, generic |
| Competitive Parity | web-app, api-backend, mobile-app | cli-tool, library, generic |

---

## 7 Evaluation Dimensions

Evaluate the codebase across all applicable dimensions below. For each dimension, run the specified commands, analyze the output, and produce findings with severity classifications.

---

### Dimension 1: Feature Completeness

**Purpose:** Detect incomplete features, stub implementations, and orphan entities that indicate unfinished product work.

**Applies to:** web-app, api-backend, mobile-app, cli-tool
**Skip for:** library, generic

#### 1A: Incomplete CRUD

Find entities that have some CRUD operations but not all (e.g., Create/Read but no Update/Delete):

```bash
# For API backends and web apps: find route files and check for CRUD verb coverage
# Express/Fastify/Koa style
grep -rn "router\.\(get\|post\|put\|patch\|delete\)" \
  --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | sed 's/.*router\.\(get\|post\|put\|patch\|delete\).*/\1/' | sort | uniq -c | sort -rn

# Next.js API routes: check for missing HTTP method handlers
find . -path "*/api/*" \( -name "*.ts" -o -name "*.js" \) ! -path '*/node_modules/*' 2>/dev/null | while read -r f; do
  methods=""
  grep -q "GET\|get" "$f" && methods="${methods}GET "
  grep -q "POST\|post" "$f" && methods="${methods}POST "
  grep -q "PUT\|put\|PATCH\|patch" "$f" && methods="${methods}UPDATE "
  grep -q "DELETE\|delete" "$f" && methods="${methods}DELETE "
  echo "$f: $methods"
done | head -20

# Django views: check viewsets for missing actions
grep -rn "class.*ViewSet\|class.*APIView\|class.*View" \
  --include="*.py" \
  . 2>/dev/null | grep -v test | grep -v migration | head -20

# Flask/FastAPI routes
grep -rn "@app\.\(get\|post\|put\|patch\|delete\)\|@router\.\(get\|post\|put\|patch\|delete\)" \
  --include="*.py" \
  . 2>/dev/null | grep -v test | head -20
```

#### 1B: Stub Endpoints

Find endpoints that return 501, TODO, or "not implemented":

```bash
# Search for stub/placeholder responses
grep -rn "501\|not.implemented\|NotImplemented\|TODO\|FIXME\|stub\|placeholder" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  --include="*.java" --include="*.kt" \
  . 2>/dev/null | grep -v node_modules | grep -v '.git/' | grep -v test \
  | grep -iE "(route|controller|handler|endpoint|api|view)" | head -20

# Check for empty handler functions (function body with only a comment or return)
grep -rn -A3 "async.*handler\|async.*controller\|def.*view\|func.*Handler" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -E "pass$|return;$|return null|return undefined|\{\s*\}" | head -10
```

#### 1C: Orphan Data Models

Find model/entity definitions that have no corresponding API route or UI component:

```bash
# Find all model/entity names
grep -rn "model \|class.*Model\|class.*Entity\|type.*struct\|interface.*Entity" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  --include="*.java" --include="*.kt" --include="*.prisma" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v migration | head -30

# For Prisma schemas specifically
grep "^model " prisma/schema.prisma 2>/dev/null | sed 's/model \([^ ]*\).*/\1/' | while read -r model; do
  refs=$(grep -rn "$model" --include="*.ts" --include="*.js" . 2>/dev/null \
    | grep -v node_modules | grep -v prisma/schema | grep -v test | wc -l)
  if [[ $refs -lt 2 ]]; then
    echo "Orphan model (only $refs references): $model"
  fi
done
```

#### 1D: Missing Standard Flows

Check for common application flows that should exist but don't:

```bash
# Authentication flows
grep -rn "login\|signin\|sign.in\|authenticate\|register\|signup\|sign.up\|logout\|sign.out" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.py" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -10

# Settings/profile pages
grep -rn "settings\|profile\|account\|preferences" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.py" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -iE "(page|route|view|component|screen)" | head -10

# Password reset
grep -rn "password.reset\|forgot.password\|reset.password" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.py" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5
```

Incomplete CRUD for core entities is **P1**. Stub endpoints in production routes are **P1**. Orphan models are **P2**. Missing standard flows (auth, settings) depend on app maturity -- **P1** for apps with existing auth, **P2** otherwise.

---

### Dimension 2: Error Handling UX

**Purpose:** Detect missing error states, loading indicators, and empty states that create a poor user experience.

**Applies to:** web-app, mobile-app
**Skip for:** api-backend, cli-tool, library, generic

#### 2A: Missing Error UI

Find components that fetch data but have no error handling UI:

```bash
# React: components using fetch/axios/useSWR/useQuery without error state rendering
grep -rn -l "useQuery\|useSWR\|useFetch\|useEffect.*fetch\|axios\.\|fetch(" \
  --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | while read -r f; do
  has_error=$(grep -c "error\|Error\|isError\|err\b" "$f" 2>/dev/null)
  if [[ $has_error -lt 2 ]]; then
    echo "Missing error handling UI: $f"
  fi
done | head -15

# Flutter: FutureBuilder/StreamBuilder without error handling
grep -rn -A10 "FutureBuilder\|StreamBuilder" \
  --include="*.dart" \
  . 2>/dev/null | grep -v test | grep -v '.dart_tool' \
  | grep -B5 "snapshot" | grep -v "hasError\|error" | head -10
```

#### 2B: Missing Loading Indicators

Find async data-fetching components without loading/spinner states:

```bash
# React: data fetching without loading state
grep -rn -l "useQuery\|useSWR\|useFetch\|useState.*loading\|isLoading" \
  --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | while read -r f; do
  has_loading=$(grep -c "loading\|Loading\|isLoading\|spinner\|Spinner\|skeleton\|Skeleton" "$f" 2>/dev/null)
  if [[ $has_loading -lt 1 ]]; then
    echo "Missing loading indicator: $f"
  fi
done | head -15

# Check for Suspense boundaries
grep -rn "Suspense\|fallback=" \
  --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -10
```

#### 2C: Missing Empty States

Find list/collection components without empty state handling:

```bash
# React: components that map over arrays without checking for empty
grep -rn "\.map(" \
  --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | while read -r f; do
  line=$(grep -n "\.map(" "$f" | head -1 | cut -d: -f1)
  # Check if there's a length check or empty state within 10 lines
  has_empty=$(sed -n "$((line-5)),$((line+10))p" "$f" 2>/dev/null | grep -c "length.*0\|\.length\|empty\|Empty\|no.*found\|No.*found")
  if [[ $has_empty -lt 1 ]]; then
    echo "Possibly missing empty state: $f:$line"
  fi
done | head -15
```

#### 2D: Missing 404 Page

```bash
# Next.js: check for 404 page
ls -la pages/404.tsx pages/404.jsx pages/404.js app/not-found.tsx app/not-found.jsx \
  src/pages/404.tsx src/pages/404.jsx src/app/not-found.tsx 2>/dev/null || echo "No custom 404 page found"

# React Router: check for catch-all route
grep -rn "path=.\*\|NoMatch\|NotFound\|404" \
  --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -iE "(route|router|switch)" | head -5

# Flutter: check for unknown route handler
grep -rn "onUnknownRoute\|unknownRoute\|onGenerateRoute" \
  --include="*.dart" \
  . 2>/dev/null | grep -v test | head -5
```

Components fetching data without error UI are **P1**. Missing loading indicators for async operations are **P1**. Missing empty states are **P2**. Missing 404 page is **P2**.

---

### Dimension 3: Accessibility

**Purpose:** Detect accessibility violations that prevent users with disabilities from using the product.

**Applies to:** web-app, mobile-app
**Skip for:** api-backend, cli-tool, library, generic

#### 3A: Images Without Alt Text

```bash
grep -rn '<img ' --include="*.tsx" --include="*.jsx" --include="*.html" --include="*.vue" --include="*.svelte" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v 'alt=' | head -20
```

#### 3B: Interactive Elements Without ARIA Labels

```bash
# Buttons and links without accessible text
grep -rn '<button\|<a ' --include="*.tsx" --include="*.jsx" --include="*.html" --include="*.vue" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -v 'aria-label\|aria-labelledby\|aria-describedby\|title=' | head -20

# Icon-only buttons (buttons containing only an icon component, no text)
grep -rn '<button.*>\s*<.*Icon\|<IconButton' --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -v 'aria-label' | head -10
```

#### 3C: Missing Form Labels

```bash
# Input elements without associated labels
grep -rn '<input\|<select\|<textarea' --include="*.tsx" --include="*.jsx" --include="*.html" --include="*.vue" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -v 'aria-label\|aria-labelledby\|id=.*label\|Label\|label' | head -20

# Check for htmlFor/for attributes on labels
grep -rn '<label' --include="*.tsx" --include="*.jsx" --include="*.html" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -v 'htmlFor\|for=' | head -10
```

#### 3D: Click Without Keyboard

```bash
# onClick without onKeyDown/onKeyPress/onKeyUp (keyboard-inaccessible interactions)
grep -rn 'onClick' --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -v '<button\|<a \|<input\|<select\|<Link\|onKeyDown\|onKeyPress\|onKeyUp\|role=' | head -20

# Non-semantic elements with click handlers (div, span with onClick)
grep -rn '<div.*onClick\|<span.*onClick' --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -v 'role=\|tabIndex\|onKeyDown' | head -15
```

Images without alt text are **P1**. Missing form labels are **P1**. onClick without keyboard handling on non-semantic elements is **P2**. Missing ARIA labels on icon-only buttons are **P2**.

---

### Dimension 4: API Design

**Purpose:** Detect API design inconsistencies, missing best practices, and gaps that hurt developer experience.

**Applies to:** api-backend, web-app (if has API routes)
**Skip for:** cli-tool, library, generic

#### 4A: Inconsistent Naming

```bash
# Check for mixed camelCase and snake_case in API response fields
grep -rn "res\.json\|jsonify\|JSON\.stringify\|json\.dumps\|ResponseEntity" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -20

# Check route naming patterns for inconsistency
grep -rn "router\.\|app\.\(get\|post\|put\|delete\)\|@app\.route\|@router\." \
  --include="*.ts" --include="*.js" --include="*.py" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -oE "['\"/][a-zA-Z_-]+['\"]" | sort -u | head -30
```

#### 4B: List Endpoints Without Pagination

```bash
# Find list/get-all endpoints that don't accept pagination params
grep -rn "\.find(\|\.findAll\|\.findMany\|\.all()\|\.list(\|\.filter(" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v migration \
  | while read -r line; do
  file=$(echo "$line" | cut -d: -f1)
  has_pagination=$(grep -c "limit\|offset\|page\|skip\|take\|cursor\|per_page\|pageSize" "$file" 2>/dev/null)
  if [[ $has_pagination -lt 1 ]]; then
    echo "No pagination found: $line"
  fi
done | head -15

# Check if any pagination utility/helper exists
grep -rn "paginate\|Pagination\|PaginatedResponse\|PageRequest\|Pageable" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5
```

#### 4C: No Rate Limiting

```bash
# Check for rate limiting middleware or configuration
grep -rn "rateLimit\|rate.limit\|rate_limit\|throttle\|RateLimit\|Throttle" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  --include="*.yaml" --include="*.yml" --include="*.toml" --include="*.json" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' | head -10

# Check for common rate limiting packages
grep -E "express-rate-limit|rate-limiter-flexible|bottleneck|p-limit|django-ratelimit|flask-limiter|throttling" \
  package.json pyproject.toml requirements.txt Gemfile go.mod Cargo.toml pom.xml build.gradle 2>/dev/null | head -5
```

#### 4D: No API Versioning

```bash
# Check routes for version prefixes
grep -rn "/v[0-9]\|/api/v[0-9]\|version.*header\|Api-Version\|Accept.*version" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  --include="*.yaml" --include="*.yml" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' | head -10

# Check if routes are organized under version directories
ls -d src/v[0-9]* src/api/v[0-9]* app/v[0-9]* api/v[0-9]* routes/v[0-9]* 2>/dev/null | head -5
```

#### 4E: Missing Request Validation

```bash
# Check for validation middleware or schema validation
grep -rn "validate\|validation\|zod\|yup\|joi\|ajv\|class-validator\|pydantic\|marshmallow\|cerberus" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' | head -10

# Check for validation library in dependencies
grep -E "zod|yup|joi|ajv|class-validator|express-validator|pydantic|marshmallow|validator" \
  package.json pyproject.toml requirements.txt Gemfile go.mod Cargo.toml pom.xml build.gradle 2>/dev/null | head -5

# Find route handlers that access req.body/request.data without validation
grep -rn "req\.body\|request\.data\|request\.json\|request\.form\|c\.Bind\|c\.ShouldBind" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -v "validate\|schema\|parse\|safeParse" | head -15
```

List endpoints without pagination are **P1**. No rate limiting is **P1** for public APIs, **P2** for internal. Inconsistent naming is **P2**. No API versioning is **P2**. Missing request validation is **P1**.

---

### Dimension 5: Observability

**Purpose:** Detect gaps in logging, monitoring, error tracking, and health checks that hinder production operations.

**Applies to:** All repo types

#### 5A: Logging Library Usage

```bash
# Check for structured logging
grep -rn "winston\|pino\|bunyan\|log4js\|morgan\|logging\.\|logger\.\|log\.\(info\|warn\|error\|debug\)" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' | head -10

# Check for logging library in dependencies
grep -E "winston|pino|bunyan|log4js|morgan|loguru|structlog|logback|log4j|zerolog|zap|slog" \
  package.json pyproject.toml requirements.txt Gemfile go.mod Cargo.toml pom.xml build.gradle 2>/dev/null | head -5

# Check for console.log usage (unstructured logging)
grep -rn "console\.log\|console\.error\|print(" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.py" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' | wc -l
```

#### 5B: Metrics Library Usage

```bash
# Check for metrics/monitoring libraries
grep -rn "prometheus\|datadog\|statsd\|newrelic\|metrics\|opentelemetry\|otel" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  --include="*.yaml" --include="*.yml" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' | head -10

# Check for metrics packages in dependencies
grep -E "prom-client|prometheus|datadog|statsd|newrelic|opentelemetry|@opentelemetry|dd-trace|apm" \
  package.json pyproject.toml requirements.txt Gemfile go.mod Cargo.toml pom.xml build.gradle 2>/dev/null | head -5
```

#### 5C: Error Tracking

```bash
# Check for error tracking services
grep -rn "Sentry\|sentry\|Bugsnag\|bugsnag\|Rollbar\|rollbar\|Honeybadger\|airbrake\|Raygun\|TrackJS" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  --include="*.yaml" --include="*.yml" --include="*.json" --include="*.toml" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' | grep -v 'lock' | head -10

# Check for error tracking packages in dependencies
grep -E "sentry|bugsnag|rollbar|honeybadger|airbrake|raygun|trackjs|@sentry" \
  package.json pyproject.toml requirements.txt Gemfile go.mod Cargo.toml pom.xml build.gradle 2>/dev/null | head -5
```

#### 5D: Health Check Endpoint

```bash
# Check for health/healthz/readiness/liveness endpoints
grep -rn "health\|healthz\|readiness\|liveness\|ready\|alive\|ping" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' \
  | grep -iE "(route|path|endpoint|app\.|router\.)" | head -10

# Check Docker or Kubernetes configs for health checks
grep -rn "healthcheck\|livenessProbe\|readinessProbe" \
  Dockerfile docker-compose.yml docker-compose.yaml \
  --include="*.yaml" --include="*.yml" \
  . 2>/dev/null | head -5
```

No structured logging (only console.log/print) is **P1**. No error tracking is **P1** for production apps. No health check endpoint is **P2** for backends. No metrics is **P2**.

---

### Dimension 6: User-Facing Gaps

**Purpose:** Detect data model entities and integrations that exist in code but have no user-facing surface (API endpoints, UI components, or CLI commands).

**Applies to:** web-app, api-backend, mobile-app
**Skip for:** cli-tool, library, generic

#### 6A: Data Models Without CRUD Endpoints

```bash
# Find all data model names
MODELS=$(grep -rn "model \|class.*Model\|@Entity\|@Table\|class.*Schema" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  --include="*.prisma" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v migration \
  | grep -oE "\b[A-Z][a-zA-Z]+\b" | sort -u | head -30)

# For each model, check if there are corresponding API routes
for model in $MODELS; do
  route_refs=$(grep -rn -i "$model" \
    --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" \
    . 2>/dev/null | grep -v node_modules | grep -v test | grep -v migration \
    | grep -iE "(route|controller|handler|view|api|endpoint)" | wc -l)
  if [[ $route_refs -lt 1 ]]; then
    echo "No API routes found for model: $model"
  fi
done | head -15
```

#### 6B: API Endpoints Without UI

```bash
# Find all API endpoint paths
grep -rn "router\.\|app\.\(get\|post\|put\|delete\)\|@app\.route\|@router\.\|@RequestMapping\|@GetMapping\|@PostMapping" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.kt" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -oE "['\"][/][a-zA-Z0-9/_-]+['\"]" | sort -u | head -30

# For web apps: compare API routes against frontend fetch calls
grep -rn "fetch(\|axios\.\|useSWR\|useQuery" \
  --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -oE "['\"][/][a-zA-Z0-9/_-]+['\"]" | sort -u | head -30
```

#### 6C: Configured Integrations Not Used in Features

```bash
# Find environment variables for third-party services
grep -rn "process\.env\.\|os\.environ\|os\.Getenv\|env::" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' \
  | grep -iE "(stripe|sendgrid|twilio|slack|aws|gcp|azure|redis|elastic|algolia|pusher|firebase)" | head -15

# Check .env.example for configured services
cat .env.example .env.sample .env.template 2>/dev/null \
  | grep -iE "(stripe|sendgrid|twilio|slack|aws|gcp|azure|redis|elastic|algolia|pusher|firebase|mailgun|segment)" \
  | head -15

# Cross-reference: are these integrations used in actual feature code?
for service in stripe sendgrid twilio slack redis elastic algolia pusher firebase mailgun segment; do
  env_refs=$(grep -rn -i "$service" .env.example .env.sample .env.template 2>/dev/null | wc -l)
  code_refs=$(grep -rn -i "$service" \
    --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" \
    . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.env' | grep -v '.git/' | wc -l)
  if [[ $env_refs -gt 0 && $code_refs -lt 2 ]]; then
    echo "Configured but barely used: $service (env: $env_refs, code: $code_refs)"
  fi
done
```

Data models with no API surface are **P2**. API endpoints with no UI (in web apps) are **P2**. Configured but unused integrations are **P2**.

---

### Dimension 7: Competitive Parity

**Purpose:** Check for standard features expected by users of this product type, based on competitive norms.

**Applies to:** web-app, api-backend, mobile-app
**Skip for:** cli-tool, library, generic

Check the applicable feature set based on repo type:

#### 7A: Web App Standard Features

```bash
# Search functionality
grep -rn "search\|Search" \
  --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -iE "(component|page|route|input|bar|form)" | head -5

# Filtering and sorting
grep -rn "filter\|sort\|Filter\|Sort" \
  --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -iE "(component|hook|util|param|query)" | head -5

# Data export (CSV, PDF, Excel)
grep -rn "export\|download\|csv\|xlsx\|pdf" \
  --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -v node_modules | grep -v test | grep -v '.git/' \
  | grep -iE "(component|handler|util|button|function)" | head -5

# Notifications
grep -rn "notification\|Notification\|toast\|Toast\|alert\|snackbar" \
  --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# User settings/preferences
grep -rn "settings\|preferences\|Settings\|Preferences" \
  --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -iE "(page|component|route|screen)" | head -5

# Responsive design (media queries or responsive utilities)
grep -rn "@media\|useMediaQuery\|responsive\|breakpoint\|sm:\|md:\|lg:" \
  --include="*.tsx" --include="*.jsx" --include="*.css" --include="*.scss" --include="*.ts" \
  . 2>/dev/null | grep -v node_modules | grep -v test | wc -l
```

#### 7B: API Standard Features

```bash
# Pagination
grep -rn "paginate\|pagination\|page.*size\|limit.*offset\|cursor\|per_page" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Filtering and sorting
grep -rn "filter\|sort\|order_by\|orderBy\|sortBy\|where" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test \
  | grep -iE "(route|controller|handler|query|param)" | head -5

# Bulk operations
grep -rn "bulk\|batch\|many\|createMany\|updateMany\|deleteMany\|insertMany" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Webhooks
grep -rn "webhook\|Webhook" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Rate limiting (covered in Dimension 4C, cross-reference)

# API documentation (Swagger/OpenAPI)
grep -rn "swagger\|openapi\|OpenAPI\|@ApiProperty\|@ApiOperation\|@ApiResponse" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.java" --include="*.yaml" --include="*.yml" --include="*.json" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

ls swagger.json openapi.json openapi.yaml docs/api* 2>/dev/null | head -5
```

#### 7C: CLI Standard Features

```bash
# Help text
grep -rn "help\|--help\|-h\|usage\|Usage" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Version flag
grep -rn "version\|--version\|-v\|-V" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Config file support
grep -rn "config\|\.rc\|\.config\|configFile\|config_file" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Verbose/quiet mode
grep -rn "verbose\|quiet\|--verbose\|--quiet\|-v\|--silent" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Color output handling
grep -rn "chalk\|kleur\|ansi\|color\|NO_COLOR\|FORCE_COLOR\|colorama\|termcolor" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5
```

#### 7D: Mobile App Standard Features

```bash
# Push notifications
grep -rn "push.notification\|FCM\|APNS\|firebase.messaging\|notification" \
  --include="*.dart" --include="*.swift" --include="*.kt" --include="*.java" --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Offline support
grep -rn "offline\|cache\|persistence\|localStorage\|AsyncStorage\|sqflite\|realm\|CoreData" \
  --include="*.dart" --include="*.swift" --include="*.kt" --include="*.java" --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Deep linking
grep -rn "deep.link\|universal.link\|app.link\|scheme\|deeplink\|DeepLink" \
  --include="*.dart" --include="*.swift" --include="*.kt" --include="*.java" --include="*.tsx" --include="*.jsx" \
  --include="*.yaml" --include="*.yml" --include="*.plist" --include="*.xml" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Biometric auth
grep -rn "biometric\|fingerprint\|faceId\|Face.ID\|Touch.ID\|BiometricPrompt\|local_auth" \
  --include="*.dart" --include="*.swift" --include="*.kt" --include="*.java" --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5

# Pull to refresh
grep -rn "RefreshControl\|pull.to.refresh\|RefreshIndicator\|SwipeRefresh\|onRefresh" \
  --include="*.dart" --include="*.swift" --include="*.kt" --include="*.java" --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | grep -v node_modules | grep -v test | head -5
```

Missing standard features for the repo type are **P1** if they are table-stakes (e.g., search for web apps, pagination for APIs). Missing nice-to-have features are **P2** (e.g., data export, webhooks). Missing advanced features are **P3** (e.g., biometric auth, deep linking).

---

## Severity Classification

Classify every finding into exactly one severity level:

| Severity | Meaning | Examples |
|----------|---------|----------|
| **P0** | Critical gap. Ship-blocker or data-loss risk. | Missing auth on public endpoints, data loss risk, broken core feature, exposed PII |
| **P1** | High impact. Missing standard features or significant UX gaps. | Incomplete CRUD for core entities, no error handling UI, missing pagination, no rate limiting on public API, no accessibility on primary flows |
| **P2** | Improvement. Convenience features and polish. | Missing empty states, orphan models, missing data export, no API versioning, cosmetic accessibility |
| **P3** | Nice-to-have. Minor UX or advanced features. | Missing advanced competitive features, minor a11y, nice-to-have integrations |

---

## Finding Format

Every finding MUST use this exact markdown template (compatible with review-tech for merge):

```markdown
### [P<N>] [<DIMENSION>] <title>

**Dimension:** <Feature Completeness | Error Handling UX | Accessibility | API Design | Observability | User-Facing Gaps | Competitive Parity>
**Impact:** <High | Medium | Low> -- <user impact>
**Effort:** <Small | Medium | Large> -- <scope>
**Evidence:**
- <bullet point with specific evidence>
- <file paths, line numbers, counts>
- <command output excerpts>
**Action:** `/ship <task description to fix this>`
```

**Note:** review-features uses **Evidence** instead of **Details** (because findings are about gaps/suggestions, not existing problems). This is the one difference from review-tech format.

---

## Output Structure

Write the complete review to `.claude/product-review/FEATURES-REVIEW.md` with this structure:

```markdown
# Product Intelligence Review -- <YYYY-MM-DD>

**Mode:** <light | full>
**Repo Type:** <detected repo type>
**Baseline:** <commit SHA for light mode, or "full scan">

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

<list any dimensions that were skipped with reasons>
<e.g., "Accessibility: repo type is api-backend -- no frontend to audit">
<e.g., "Error Handling UX: repo type is cli-tool -- no UI components to evaluate">
<If no dimensions were skipped, write: "None -- all 7 dimensions evaluated.">
```

---

## After Review

After writing FEATURES-REVIEW.md, report a summary to the user:

```
## /review-features Complete

Mode: <light | full>
Output: .claude/product-review/FEATURES-REVIEW.md

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
<list of 7 dimensions with checkmark or skip indicator>
```

If called by the `/review-product` coordinator, return the summary data for aggregation -- do not prompt the user.
