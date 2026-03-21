#!/usr/bin/env bash
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$BACKEND_DIR/.." && pwd)"
COMPOSE=(docker compose -f "$PROJECT_ROOT/my-dashboard-docker/docker-compose.yml")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_env_file() {
  local env_file="$1"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

load_env_file "$SCRIPT_DIR/.env"
load_env_file "$SCRIPT_DIR/.env.dev"

BASE_URL="${BASE_URL:?BASE_URL must be set in helper-scripts/.env or environment}"
ADMIN_EMAIL="${ADMIN_EMAIL:?ADMIN_EMAIL must be set in helper-scripts/.env.dev or environment}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set in helper-scripts/.env.dev or environment}"
PERF_REQUESTS="${PERF_REQUESTS:-15}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd docker
need_cmd curl
need_cmd python3

echo "==> Ensuring services are up"
"${COMPOSE[@]}" up -d >/dev/null

echo "==> Ensuring admin user exists"
"${COMPOSE[@]}" exec -T auth-php php bin/console app:create-test-user \
  --email "$ADMIN_EMAIL" \
  --password "$ADMIN_PASSWORD" \
  --firstName Admin \
  --lastName Test \
  --role ROLE_ADMIN \
  --upsert >/dev/null

TMP_DIR="$(mktemp -d)"
TOKEN=""
TEST_USER_ID=""
TEST_USER_EMAIL="perf-user-$(date +%s)@example.com"
AUTH_PREFIX=""
EVENTS_PREFIX=""
NOTIFICATION_PREFIX=""

request() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local data="${4:-}"
  local auth_token="${5:-}"

  local args=(-s -o "$output_file" -w "%{http_code}" -X "$method" "$BASE_URL$path" -H "Content-Type: application/json")
  if [[ -n "$auth_token" ]]; then
    args+=(-H "Authorization: Bearer $auth_token")
  fi
  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi

  curl "${args[@]}"
}

resolve_path_prefix() {
  local output_file="$1"
  local method="$2"
  local auth_token="$3"
  local data="$4"
  shift 4

  local status=""
  local path=""

  for path in "$@"; do
    status=$(request "$method" "$path" "$output_file" "$data" "$auth_token")
    if [[ "$status" != "404" ]]; then
      echo "$path"
      return 0
    fi
  done

  return 1
}

cleanup() {
  local has_token="false"
  if [[ -n "$TOKEN" ]]; then
    has_token="true"
  fi

  if [[ "$has_token" == "true" ]]; then
    request DELETE "${NOTIFICATION_PREFIX}/inbox" "$TMP_DIR/cleanup_inbox.json" "" "$TOKEN" >/dev/null || true
  fi

  if [[ "$has_token" == "true" && -n "$TEST_USER_ID" ]]; then
    request DELETE "${AUTH_PREFIX}/users/$TEST_USER_ID" "$TMP_DIR/cleanup_user_soft.json" "" "$TOKEN" >/dev/null || true

    # Hard-delete test user to avoid polluting auth data between runs.
    "${COMPOSE[@]}" exec -T auth-php php bin/console doctrine:query:sql "DELETE FROM user WHERE id='${TEST_USER_ID}'" >/dev/null || true
  fi

  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

echo "==> Login"
LOGIN_PATH=$(resolve_path_prefix "$TMP_DIR/login_probe.json" POST "" "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" "/api/auth/login" "/auth/login")
if [[ -z "$LOGIN_PATH" ]]; then
  echo "Could not resolve auth login route"
  exit 1
fi

AUTH_PREFIX="${LOGIN_PATH%/login}"
EVENTS_PREFIX=$(resolve_path_prefix "$TMP_DIR/events_probe.json" GET "$TOKEN" "" "/api/routes" "/events/routes" || true)
NOTIFICATION_PROBE_PATH=$(resolve_path_prefix "$TMP_DIR/notification_probe.json" GET "$TOKEN" "" "/api/notifications/inbox" "/notification/inbox" || true)

if [[ -z "$NOTIFICATION_PROBE_PATH" ]]; then
  NOTIFICATION_PREFIX="/api/notifications"
else
  NOTIFICATION_PREFIX="${NOTIFICATION_PROBE_PATH%/inbox}"
fi

if [[ -z "$EVENTS_PREFIX" ]]; then
  EVENTS_PREFIX="/api/routes"
fi

LOGIN_STATUS=$(request POST "$LOGIN_PATH" "$TMP_DIR/login.json" "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
if [[ "$LOGIN_STATUS" != "200" ]]; then
  echo "Login failed with status $LOGIN_STATUS"
  cat "$TMP_DIR/login.json"
  echo
  exit 1
fi

TOKEN=$(python3 - <<PY
import json
with open("$TMP_DIR/login.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("token", ""))
PY
)

if [[ -z "$TOKEN" ]]; then
  echo "Login token is empty"
  exit 1
fi

echo "==> Creating temporary test user"
CREATE_USER_STATUS=$(request POST "${AUTH_PREFIX}/users" "$TMP_DIR/create_user.json" "{\"email\":\"$TEST_USER_EMAIL\",\"password\":\"PerfPass123!\",\"firstName\":\"Perf\",\"lastName\":\"Runner\",\"role\":\"ROLE_USER\"}" "$TOKEN")
if [[ "$CREATE_USER_STATUS" != "201" ]]; then
  echo "Create user failed with status $CREATE_USER_STATUS"
  cat "$TMP_DIR/create_user.json"
  echo
  exit 1
fi

TEST_USER_ID=$(python3 - <<PY
import json
with open("$TMP_DIR/create_user.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print((payload.get("user") or {}).get("id", ""))
PY
)

if [[ -z "$TEST_USER_ID" ]]; then
  echo "Temporary user id is empty"
  exit 1
fi

echo "==> Running performance checks (${PERF_REQUESTS} requests per endpoint)"
python3 - <<PY
import statistics
import subprocess
import sys

base_url = "$BASE_URL"
token = "$TOKEN"
loops = int("$PERF_REQUESTS")

endpoints = [
  ("auth-me", "$AUTH_PREFIX/me"),
  ("users-list", "$AUTH_PREFIX/users"),
  ("routes-list", "$EVENTS_PREFIX"),
  ("notifications-inbox", "$NOTIFICATION_PREFIX/inbox"),
]

failed = False
for name, path in endpoints:
    timings = []
    for _ in range(loops):
        cmd = [
            "curl",
            "-s",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code} %{time_total}",
            "-H",
            f"Authorization: Bearer {token}",
            "-H",
            "Content-Type: application/json",
            f"{base_url}{path}",
        ]
        out = subprocess.check_output(cmd, text=True).strip()
        parts = out.split()
        status = parts[0]
        elapsed = float(parts[1])
        if status != "200":
            print(f"[FAIL] {name}: expected 200, got {status}")
            failed = True
            break
        timings.append(elapsed)

    if not timings:
        continue

    avg = statistics.mean(timings)
    p95 = sorted(timings)[max(0, min(len(timings) - 1, int(len(timings) * 0.95) - 1))]
    mx = max(timings)
    print(f"[OK] {name}: avg={avg:.4f}s p95={p95:.4f}s max={mx:.4f}s")

if failed:
    sys.exit(1)
PY

echo "==> Performance test completed and temporary data cleanup scheduled"
