#!/usr/bin/env bash
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

BASE_URL="${BASE_URL:-http://localhost:8081}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin.test@micro.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Admin123!}"
SEED_COUNT="${SEED_COUNT:-20}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd python3

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

request() {
  local method="$1"
  local path="$2"
  local out_file="$3"
  local body="${4:-}"
  local token="${5:-}"

  local url="${BASE_URL}${path}"
  local -a curl_args=(
    -sS
    -o "$out_file"
    -w "%{http_code}"
    -X "$method"
    "$url"
    -H "Accept: application/json"
  )

  if [[ -n "$token" ]]; then
    curl_args+=( -H "Authorization: Bearer $token" )
  fi

  if [[ -n "$body" ]]; then
    curl_args+=( -H "Content-Type: application/json" --data "$body" )
  fi

  curl "${curl_args[@]}"
}

resolve_path_prefix() {
  local output_file="$1"
  local method="$2"
  local token="$3"
  local body="$4"
  shift 4

  local candidate
  local status
  for candidate in "$@"; do
    status=$(request "$method" "$candidate" "$output_file" "$body" "$token")
    if [[ "$status" == "200" || "$status" == "204" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

assert_status() {
  local label="$1"
  local status="$2"
  local expected="$3"
  local body_file="$4"

  if [[ "$status" != "$expected" ]]; then
    echo "❌ ${label}: expected ${expected}, got ${status}" >&2
    cat "$body_file" >&2 || true
    echo >&2
    exit 1
  fi
}

echo "==> Logging in as admin"
LOGIN_STATUS=$(request POST "/auth/login" "$TMP_DIR/login.json" "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
assert_status "login" "$LOGIN_STATUS" "200" "$TMP_DIR/login.json"

TOKEN=$(python3 - <<PY
import json
with open("$TMP_DIR/login.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("token", ""))
PY
)

if [[ -z "$TOKEN" ]]; then
  echo "❌ login failed: token is empty" >&2
  exit 1
fi

EVENTS_COLLECTION_PATH=$(resolve_path_prefix "$TMP_DIR/events_probe.json" GET "$TOKEN" "" "/api/events" "/events")
TODOS_COLLECTION_PATH=$(resolve_path_prefix "$TMP_DIR/todos_probe.json" GET "$TOKEN" "" "/api/todos" "/dashboard/todos")
SHOPPING_COLLECTION_PATH=$(resolve_path_prefix "$TMP_DIR/shopping_probe.json" GET "$TOKEN" "" "/api/shopping-lists" "/dashboard/shopping-lists")
ROUTES_COLLECTION_PATH=$(resolve_path_prefix "$TMP_DIR/routes_probe.json" GET "$TOKEN" "" "/api/routes" "/events/routes")

if [[ -z "$EVENTS_COLLECTION_PATH" || -z "$TODOS_COLLECTION_PATH" || -z "$SHOPPING_COLLECTION_PATH" || -z "$ROUTES_COLLECTION_PATH" ]]; then
  echo "❌ could not resolve one or more API collection paths" >&2
  exit 1
fi

seed_tag="seed$(date +%Y%m%d%H%M%S)"
declare -a EVENT_IDS=()

echo "==> Creating ${SEED_COUNT} to-do items"
for ((i=1; i<=SEED_COUNT; i++)); do
  payload=$(python3 - <<PY
import json
i = $i
tag = "$seed_tag"
print(json.dumps({"text": f"{tag} todo item {i}"}, ensure_ascii=False))
PY
)
  status=$(request POST "$TODOS_COLLECTION_PATH" "$TMP_DIR/todo_${i}.json" "$payload" "$TOKEN")
  assert_status "todo-create-$i" "$status" "201" "$TMP_DIR/todo_${i}.json"
done

echo "==> Creating ${SEED_COUNT} events"
for ((i=1; i<=SEED_COUNT; i++)); do
  payload=$(python3 - <<PY
import json
from datetime import datetime, timedelta, timezone
i = $i
tag = "$seed_tag"
start = datetime(2031, 1, 1, 9, 0, tzinfo=timezone.utc) + timedelta(days=i)
end = start + timedelta(hours=2)
obj = {
  "title": f"{tag} event {i}",
  "description": f"Sample event {i}",
  "startAt": start.isoformat().replace('+00:00', 'Z'),
  "endAt": end.isoformat().replace('+00:00', 'Z'),
  "location": {
    "display_name": f"Krakow sample {i}",
    "lat": 50.06143 + (i * 0.001),
    "lon": 19.93658 + (i * 0.001)
  }
}
print(json.dumps(obj, ensure_ascii=False))
PY
)
  status=$(request POST "$EVENTS_COLLECTION_PATH" "$TMP_DIR/event_${i}.json" "$payload" "$TOKEN")
  assert_status "event-create-$i" "$status" "201" "$TMP_DIR/event_${i}.json"

  event_id=$(python3 - <<PY
import json
with open("$TMP_DIR/event_${i}.json", "r", encoding="utf-8") as f:
    print(json.load(f).get("id", ""))
PY
)
  if [[ -z "$event_id" ]]; then
    echo "❌ event-create-$i returned empty id" >&2
    cat "$TMP_DIR/event_${i}.json" >&2
    exit 1
  fi
  EVENT_IDS+=("$event_id")
done

echo "==> Creating ${SEED_COUNT} shopping lists"
for ((i=1; i<=SEED_COUNT; i++)); do
  payload=$(python3 - <<PY
import json
i = $i
tag = "$seed_tag"
obj = {
  "name": f"{tag} shopping list {i}",
  "status": "active",
  "products": [
    {"name": "Mleko", "qty": 2, "weight": "l", "category": "dairy"},
    {"name": "Jablka", "qty": 1, "weight": "kg", "category": "fruits"},
    {"name": "Woda", "qty": 6, "weight": "szt", "category": "beverages"}
  ]
}
print(json.dumps(obj, ensure_ascii=False))
PY
)
  status=$(request POST "$SHOPPING_COLLECTION_PATH" "$TMP_DIR/shop_${i}.json" "$payload" "$TOKEN")
  assert_status "shopping-create-$i" "$status" "201" "$TMP_DIR/shop_${i}.json"
done

echo "==> Creating ${SEED_COUNT} routes with waypoints"
for ((i=1; i<=SEED_COUNT; i++)); do
  event_index=$(( (i - 1) % ${#EVENT_IDS[@]} ))
  event_id="${EVENT_IDS[$event_index]}"

  payload=$(python3 - <<PY
import json
i = $i
tag = "$seed_tag"
event_id = "$event_id"
lon = 19.90 + (i * 0.01)
lat = 50.00 + (i * 0.01)
obj = {
  "name": f"{tag} route {i}",
  "description": f"Sample route {i}",
  "geoJson": {
    "type": "FeatureCollection",
    "features": [
      {
        "type": "Feature",
        "geometry": {
          "type": "LineString",
          "coordinates": [
            [lon, lat],
            [lon + 0.01, lat + 0.005],
            [lon + 0.02, lat + 0.01]
          ]
        },
        "properties": {"name": f"{tag} route line {i}"}
      }
    ]
  },
  "distanceMeters": 1000 + i * 25,
  "durationMinutes": 10 + i,
  "waypoints": [
    [lat, lon],
    [lat + 0.005, lon + 0.01],
    [lat + 0.01, lon + 0.02]
  ],
  "eventId": int(event_id) if str(event_id).isdigit() else event_id
}
print(json.dumps(obj, ensure_ascii=False))
PY
)
  status=$(request POST "$ROUTES_COLLECTION_PATH" "$TMP_DIR/route_${i}.json" "$payload" "$TOKEN")
  assert_status "route-create-$i" "$status" "201" "$TMP_DIR/route_${i}.json"
done

echo ""
echo "✅ Sample data seeded successfully"
echo "- tag: $seed_tag"
echo "- todos created: $SEED_COUNT"
echo "- events created: $SEED_COUNT"
echo "- shopping lists created: $SEED_COUNT"
echo "- routes created: $SEED_COUNT"
