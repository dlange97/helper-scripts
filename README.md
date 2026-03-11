# my-dashboard-backend/helepr-scripts

## Overview

Validation scripts for API behavior and key business flows.

## Contents

- `smoke.sh` — full E2E smoke suite (auth, roles, events, shopping, routes, notifications).
- `test-roles.sh` — focused role endpoints check.
- `test-routes.sh` — focused route endpoints check.

## Run

From `my-dashboard-backend`:

```bash
bash ./helepr-scripts/smoke.sh
bash ./helepr-scripts/test-roles.sh
bash ./helepr-scripts/test-routes.sh
```

Default `BASE_URL`: `http://localhost:8081`.
