# my-dashboard-backend/helper-scripts

## Overview

Validation scripts for API behavior and key business flows.

## Contents

- `smoke.sh` — full E2E smoke suite (auth, roles, events, shopping, routes, notifications).
- `test-roles.sh` — focused role endpoints check.
- `test-routes.sh` — focused route endpoints check.
- `quality.sh` — backend quality gates for all services (PHPCS, PHPStan, coverage check).
- `performance.sh` — API performance regression checks with automatic cleanup of temporary users and test data.

## Run

From `my-dashboard-backend`:

```bash
bash ./helper-scripts/smoke.sh
bash ./helper-scripts/test-roles.sh
bash ./helper-scripts/test-routes.sh
bash ./helper-scripts/quality.sh
bash ./helper-scripts/performance.sh
```

Default `BASE_URL`: `http://localhost:8081`.

Coverage threshold is controlled with `MIN_COVERAGE` (default: `70`):

```bash
MIN_COVERAGE=70 bash ./helper-scripts/quality.sh
```

Performance loop count is controlled with `PERF_REQUESTS` (default: `15`):

```bash
PERF_REQUESTS=30 bash ./helper-scripts/performance.sh
```
