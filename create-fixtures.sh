#!/usr/bin/env bash
# create-fixtures.sh — bootstrap a dev instance and seed sample data
#
# Usage:
#   ./create-fixtures.sh                   # uses defaults
#   SEED_COUNT=50 ./create-fixtures.sh     # seed more records
#
# What it does:
#   1. Creates a "dev" instance in the DB (idempotent – skips if already exists)
#   2. Upserts admin user (admin@mydashboard.local / Admin123!) and assigns to dev instance
#   3. Creates a regular test user (user@mydashboard.local / User123!)
#   4. Seeds todos, events, shopping lists, and routes via API
#
# Credentials after running:
#   Admin : admin@mydashboard.local / Admin123!
#   User  : user@mydashboard.local  / User123!

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/my-dashboard-docker"

# ── Config ─────────────────────────────────────────────────────────────────
BASE_URL="${BASE_URL:-http://localhost}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@mydashboard.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Admin123!}"
USER_EMAIL="${USER_EMAIL:-user@mydashboard.local}"
USER_PASSWORD="${USER_PASSWORD:-User123!}"
SEED_COUNT="${SEED_COUNT:-20}"

# Fixed UUIDs so script is idempotent on re-runs
DEV_INSTANCE_ID="${DEV_INSTANCE_ID:-a1b2c3d4-0000-0000-0000-000000000001}"

# ── Load docker .env for DB credentials ────────────────────────────────────
if [[ -f "$DOCKER_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$DOCKER_DIR/.env"
  set +a
fi

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
  echo "❌ MYSQL_ROOT_PASSWORD not set — ensure $DOCKER_DIR/.env exists" >&2
  exit 1
fi

COMPOSE=(docker compose -f "$DOCKER_DIR/docker-compose.yml" --project-directory "$DOCKER_DIR")

# ── Helpers ────────────────────────────────────────────────────────────────
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need_cmd curl
need_cmd python3
need_cmd docker

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INSTANCE_ID=""   # populated after login

request() {
  local method="$1"
  local path="$2"
  local out_file="$3"
  local body="${4:-}"
  local token="${5:-}"

  local -a args=(
    -sS -o "$out_file" -w "%{http_code}"
    -X "$method"
    "${BASE_URL}${path}"
    -H "Accept: application/json"
  )
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
    if [[ -n "${INSTANCE_ID:-}" ]]; then
      args+=(-H "X-Instance-Id: $INSTANCE_ID")
    fi
  fi
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  curl "${args[@]}"
}

assert_status() {
  local label="$1" status="$2" expected="$3" body_file="$4"
  if [[ "$status" != "$expected" ]]; then
    echo "❌ ${label}: expected ${expected}, got ${status}" >&2
    cat "$body_file" >&2 || true
    echo >&2
    exit 1
  fi
}

mysql_exec() {
  "${COMPOSE[@]}" exec -T \
    -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" \
    mysql mysql -uroot "$@"
}

# ── Step 1: Create dev instance + assign admin ─────────────────────────────
echo "==> Bootstrapping dev instance (id=$DEV_INSTANCE_ID)"

mysql_exec -e "
INSERT IGNORE INTO auth.instance (id, name, subdomain, created_at, updated_at)
  VALUES ('$DEV_INSTANCE_ID', 'My Dashboard Dev', 'dev', NOW(), NOW());
" >/dev/null

INSTANCE_EXISTS=$("${COMPOSE[@]}" exec -T \
  -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" \
  mysql mysql -sN -uroot \
  -e "SELECT COUNT(*) FROM auth.instance WHERE id='$DEV_INSTANCE_ID';" 2>/dev/null || echo 0)
echo "✅ Dev instance ready (rows: $INSTANCE_EXISTS)"

# ── Step 2: Upsert admin user ───────────────────────────────────────────────
echo "==> Upserting admin user ($ADMIN_EMAIL)"
"${COMPOSE[@]}" exec -T auth-php \
  php bin/console app:create-test-user \
  --email="$ADMIN_EMAIL" \
  --password="$ADMIN_PASSWORD" \
  --firstName="Admin" --lastName="User" \
  --role="ROLE_ADMIN" --upsert \
  >/dev/null
echo "✅ Admin user upserted"

# Assign admin to dev instance
ADMIN_ID=$("${COMPOSE[@]}" exec -T \
  -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" \
  mysql mysql -sN -uroot \
  -e "SELECT id FROM auth.user WHERE email='$ADMIN_EMAIL';" 2>/dev/null || true)

if [[ -z "$ADMIN_ID" ]]; then
  echo "❌ Could not find admin user in DB" >&2
  exit 1
fi

mysql_exec -e "
UPDATE auth.user SET instance_id='$DEV_INSTANCE_ID' WHERE id='$ADMIN_ID';
INSERT IGNORE INTO auth.user_instance (user_id, instance_id) VALUES ('$ADMIN_ID', '$DEV_INSTANCE_ID');
" >/dev/null
echo "✅ Admin assigned to dev instance"

# ── Step 3: Create regular test user ───────────────────────────────────────
echo "==> Upserting regular user ($USER_EMAIL)"
"${COMPOSE[@]}" exec -T auth-php \
  php bin/console app:create-test-user \
  --email="$USER_EMAIL" \
  --password="$USER_PASSWORD" \
  --firstName="Test" --lastName="User" \
  --role="ROLE_USER" --upsert \
  >/dev/null

USER_ID=$("${COMPOSE[@]}" exec -T \
  -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" \
  mysql mysql -sN -uroot \
  -e "SELECT id FROM auth.user WHERE email='$USER_EMAIL';" 2>/dev/null || true)

if [[ -n "$USER_ID" ]]; then
  mysql_exec -e "
  UPDATE auth.user SET instance_id='$DEV_INSTANCE_ID' WHERE id='$USER_ID';
  INSERT IGNORE INTO auth.user_instance (user_id, instance_id) VALUES ('$USER_ID', '$DEV_INSTANCE_ID');
  " >/dev/null
  echo "✅ Regular user assigned to dev instance"
fi

# ── Step 4: Login and extract token + instanceId ───────────────────────────
echo "==> Logging in as $ADMIN_EMAIL"
STATUS=$(request POST "/auth/login" "$TMP_DIR/login.json" \
  "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
assert_status "login" "$STATUS" "200" "$TMP_DIR/login.json"

TOKEN=$(python3 - <<PY
import json
with open("$TMP_DIR/login.json", "r", encoding="utf-8") as f:
    print(json.load(f).get("token", ""))
PY
)
if [[ -z "$TOKEN" ]]; then
  echo "❌ login failed: token is empty" >&2; exit 1
fi

INSTANCE_ID=$(python3 - <<PY
import json, base64, sys
with open("$TMP_DIR/login.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
token = payload.get("token", "")
parts = token.split(".")
if len(parts) < 2: sys.exit(0)
p = parts[1]; p += "=" * (-len(p) % 4)
try:
    data = json.loads(base64.b64decode(p))
    print(data.get("instanceId") or "")
except Exception:
    sys.exit(0)
PY
)
if [[ -z "$INSTANCE_ID" ]]; then
  echo "❌ instanceId missing from JWT after login" >&2; exit 1
fi
echo "✅ Logged in — instance: $INSTANCE_ID"

# ── Step 5: Resolve API paths ──────────────────────────────────────────────
resolve_path() {
  local out="$1" method="$2" token="$3"; shift 3
  for path in "$@"; do
    local s; s=$(request "$method" "$path" "$out" "" "$token")
    [[ "$s" != "404" && "$s" != "000" ]] && { echo "$path"; return 0; }
  done
  return 1
}

TODOS_PATH=$(resolve_path    "$TMP_DIR/p1.json" GET "$TOKEN" "/dashboard/todos" "/api/todos")
EVENTS_PATH=$(resolve_path   "$TMP_DIR/p2.json" GET "$TOKEN" "/events/events"   "/api/events")
SHOPPING_PATH=$(resolve_path "$TMP_DIR/p3.json" GET "$TOKEN" "/dashboard/shopping-lists" "/api/shopping-lists")
ROUTES_PATH=$(resolve_path   "$TMP_DIR/p4.json" GET "$TOKEN" "/events/routes"   "/api/routes")

echo "✅ API paths resolved"

seed_tag="fix$(date +%Y%m%d%H%M%S)"
declare -a EVENT_IDS=()

# ── Step 6: Seed todos ─────────────────────────────────────────────────────
echo "==> Seeding $SEED_COUNT todos"
for ((i=1; i<=SEED_COUNT; i++)); do
  payload=$(python3 -c "import json; print(json.dumps({'text': '${seed_tag} todo item $i'}))")
  s=$(request POST "$TODOS_PATH" "$TMP_DIR/t${i}.json" "$payload" "$TOKEN")
  assert_status "todo-$i" "$s" "201" "$TMP_DIR/t${i}.json"
done
echo "✅ $SEED_COUNT todos created"

# ── Step 7: Seed events ────────────────────────────────────────────────────
echo "==> Seeding $SEED_COUNT events"
for ((i=1; i<=SEED_COUNT; i++)); do
  payload=$(python3 - <<PY
import json
from datetime import datetime, timedelta, timezone
i = $i
start = datetime(2031, 1, 1, 9, 0, tzinfo=timezone.utc) + timedelta(days=i)
end   = start + timedelta(hours=2)
print(json.dumps({
  "title": "${seed_tag} event $i",
  "description": "Fixture event $i",
  "startAt": start.isoformat().replace('+00:00','Z'),
  "endAt":   end.isoformat().replace('+00:00','Z'),
  "location": {"display_name": "Krakow $i", "lat": 50.061 + i*0.001, "lon": 19.937 + i*0.001}
}))
PY
)
  s=$(request POST "$EVENTS_PATH" "$TMP_DIR/e${i}.json" "$payload" "$TOKEN")
  assert_status "event-$i" "$s" "201" "$TMP_DIR/e${i}.json"
  eid=$(python3 -c "import json; print(json.load(open('$TMP_DIR/e${i}.json')).get('id',''))")
  [[ -n "$eid" ]] && EVENT_IDS+=("$eid")
done
echo "✅ $SEED_COUNT events created"

# ── Step 8: Seed shopping lists ────────────────────────────────────────────
echo "==> Seeding $SEED_COUNT shopping lists"
for ((i=1; i<=SEED_COUNT; i++)); do
  payload=$(python3 - <<PY
import json
print(json.dumps({
  "name": "${seed_tag} list $i", "status": "active",
  "products": [
    {"name": "Mleko",   "qty": 2, "weight": "l",   "category": "dairy"},
    {"name": "Jablka",  "qty": 1, "weight": "kg",  "category": "fruits"},
    {"name": "Woda",    "qty": 6, "weight": "szt", "category": "beverages"},
  ]
}))
PY
)
  s=$(request POST "$SHOPPING_PATH" "$TMP_DIR/s${i}.json" "$payload" "$TOKEN")
  assert_status "shopping-$i" "$s" "201" "$TMP_DIR/s${i}.json"
done
echo "✅ $SEED_COUNT shopping lists created"

# ── Step 9: Seed routes ────────────────────────────────────────────────────
echo "==> Seeding $SEED_COUNT routes"
for ((i=1; i<=SEED_COUNT; i++)); do
  eid="${EVENT_IDS[$(( (i-1) % ${#EVENT_IDS[@]} ))]}"
  payload=$(python3 - <<PY
import json
i   = $i
lon = 19.90 + i * 0.01
lat = 50.00 + i * 0.01
eid = "$eid"
print(json.dumps({
  "name": "${seed_tag} route $i", "description": "Fixture route $i",
  "geoJson": {"type":"FeatureCollection","features":[{"type":"Feature",
    "geometry":{"type":"LineString","coordinates":[[lon,lat],[lon+.01,lat+.005],[lon+.02,lat+.01]]},
    "properties":{"name":"line $i"}}]},
  "distanceMeters": 1000 + i*25, "durationMinutes": 10 + i,
  "waypoints": [[lat,lon],[lat+.005,lon+.01],[lat+.01,lon+.02]],
  "eventId": int(eid) if eid.isdigit() else eid
}))
PY
)
  s=$(request POST "$ROUTES_PATH" "$TMP_DIR/r${i}.json" "$payload" "$TOKEN")
  assert_status "route-$i" "$s" "201" "$TMP_DIR/r${i}.json"
done
echo "✅ $SEED_COUNT routes created"

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo "🎉 Fixtures ready!"
echo ""
echo "  Instance : dev  ($DEV_INSTANCE_ID)"
echo "  Admin    : $ADMIN_EMAIL  /  $ADMIN_PASSWORD  (ROLE_ADMIN)"
echo "  User     : $USER_EMAIL  /  $USER_PASSWORD  (ROLE_USER)"
echo ""
echo "  Seeded per user (admin):"
echo "    todos          : $SEED_COUNT"
echo "    events         : $SEED_COUNT"
echo "    shopping lists : $SEED_COUNT"
echo "    routes         : $SEED_COUNT"
echo ""
echo "  App: http://localhost"
