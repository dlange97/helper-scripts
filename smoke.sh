#!/usr/bin/env bash
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$BACKEND_DIR/.." && pwd)"
COMPOSE=(docker compose -f "$PROJECT_ROOT/my-dashboard-docker/docker-compose.yml")
BASE_URL="${BASE_URL:-http://localhost:8081}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin.test@micro.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Admin123!}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd docker
need_cmd curl
need_cmd python3

compose_exec() {
  local service="$1"
  shift

  "${COMPOSE[@]}" exec -T "$service" "$@"
}

dump_service_logs() {
  local service="$1"

  echo "---- logs: $service ----" >&2
  "${COMPOSE[@]}" logs --tail=120 "$service" >&2 || true
  echo "------------------------" >&2
}

get_service_container_id() {
  local service="$1"

  "${COMPOSE[@]}" ps -q "$service"
}

wait_for_health_status() {
  local service="$1"
  local expected_status="$2"
  local attempts="${3:-90}"
  local delay="${4:-2}"
  local attempt
  local container_id
  local current_status

  container_id="$(get_service_container_id "$service")"
  if [[ -z "$container_id" ]]; then
    echo "❌ Could not resolve container id for service: $service" >&2
    exit 1
  fi

  echo "==> Waiting for $service health: $expected_status"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    current_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || echo "unknown")"

    if [[ "$current_status" == "$expected_status" ]]; then
      echo "✅ $service health is $expected_status"
      return 0
    fi

    sleep "$delay"
  done

  echo "❌ $service did not reach health status: $expected_status" >&2
  dump_service_logs "$service"
  exit 1
}

wait_for_console_ready() {
  local service="$1"
  local description="$2"
  local attempts="${3:-80}"
  local delay="${4:-3}"
  local attempt

  echo "==> Waiting for $description"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if compose_exec "$service" sh -lc 'test -f vendor/autoload.php && php bin/console about >/dev/null 2>&1'; then
      echo "✅ $description is ready"
      return 0
    fi

    sleep "$delay"
  done

  echo "❌ $description did not become ready in time" >&2
  dump_service_logs "$service"
  exit 1
}

run_migration() {
  local service="$1"
  local description="$2"
  local attempts="${3:-10}"
  local delay="${4:-3}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if compose_exec "$service" php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration >/dev/null; then
      echo "✅ $description migrations finished"
      return 0
    fi

    if (( attempt < attempts )); then
      sleep "$delay"
    fi
  done

  echo "❌ $description migrations failed" >&2
  dump_service_logs "$service"
  exit 1
}

echo "==> Ensuring services are up"
"${COMPOSE[@]}" up -d mysql rabbitmq >/dev/null
wait_for_health_status mysql healthy

"${COMPOSE[@]}" up -d auth-php notification-php dashboard-php events-php nginx >/dev/null

wait_for_console_ready auth-php "auth service"
wait_for_console_ready notification-php "notification service"
wait_for_console_ready dashboard-php "dashboard service"
wait_for_console_ready events-php "events service"

echo "==> Running DB migrations"
run_migration auth-php "auth service"
run_migration notification-php "notification service"
run_migration dashboard-php "dashboard service"
run_migration events-php "events service"

echo "==> Starting async worker"
"${COMPOSE[@]}" up -d notification-worker >/dev/null
wait_for_console_ready notification-worker "notification worker"

echo "==> Ensuring smoke admin user exists"
compose_exec auth-php php bin/console app:create-test-user \
  --email "$ADMIN_EMAIL" \
  --password "$ADMIN_PASSWORD" \
  --firstName Admin \
  --lastName Test \
  --role ROLE_ADMIN \
  --upsert >/dev/null

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

assert_status() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  local body_file="$4"

  if [[ "$actual" != "$expected" ]]; then
    echo "❌ $name failed: expected $expected, got $actual"
    echo "Body:"
    cat "$body_file"
    echo
    exit 1
  fi

  echo "✅ $name: $actual"
}

echo "==> Login"
LOGIN_PATH=$(resolve_path_prefix "$TMP_DIR/login_probe.json" POST "" "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" "/api/auth/login" "/auth/login")
if [[ -z "$LOGIN_PATH" ]]; then
  echo "❌ login-path failed: could not resolve login route"
  exit 1
fi

AUTH_PREFIX="${LOGIN_PATH%/login}"

LOGIN_STATUS=""
for attempt in {1..20}; do
  LOGIN_STATUS=$(request POST "$LOGIN_PATH" "$TMP_DIR/login.json" "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
  if [[ "$LOGIN_STATUS" == "200" ]]; then
    break
  fi

  if [[ "$LOGIN_STATUS" == "502" || "$LOGIN_STATUS" == "503" || "$LOGIN_STATUS" == "504" || "$LOGIN_STATUS" == "000" ]]; then
    sleep 2
    continue
  fi

  break
done
assert_status "login" "$LOGIN_STATUS" "200" "$TMP_DIR/login.json"

TOKEN=$(python3 - <<PY
import json
with open("$TMP_DIR/login.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("token", ""))
PY
)

if [[ -z "$TOKEN" ]]; then
  echo "❌ login failed: token is empty"
  cat "$TMP_DIR/login.json"
  echo
  exit 1
fi

INBOX_PATH=$(resolve_path_prefix "$TMP_DIR/notification_probe.json" GET "$TOKEN" "" "/api/notifications/inbox" "/notification/inbox")
if [[ -z "$INBOX_PATH" ]]; then
  echo "❌ notification-path failed: could not resolve inbox route"
  exit 1
fi

NOTIFICATION_PREFIX="${INBOX_PATH%/inbox}"

ROUTES_COLLECTION_PATH=$(resolve_path_prefix "$TMP_DIR/routes_probe.json" GET "$TOKEN" "" "/api/routes" "/events/routes")
if [[ -z "$ROUTES_COLLECTION_PATH" ]]; then
  echo "❌ routes-path failed: could not resolve routes collection route"
  exit 1
fi

TODOS_COLLECTION_PATH=$(resolve_path_prefix "$TMP_DIR/todos_probe.json" GET "$TOKEN" "" "/api/todos" "/dashboard/todos")
if [[ -z "$TODOS_COLLECTION_PATH" ]]; then
  echo "❌ todos-path failed: could not resolve todos collection route"
  exit 1
fi

SHOPPING_COLLECTION_PATH=$(resolve_path_prefix "$TMP_DIR/shopping_probe.json" GET "$TOKEN" "" "/api/shopping-lists" "/dashboard/shopping-lists")
if [[ -z "$SHOPPING_COLLECTION_PATH" ]]; then
  echo "❌ shopping-path failed: could not resolve shopping collection route"
  exit 1
fi

EVENTS_COLLECTION_PATH=$(resolve_path_prefix "$TMP_DIR/events_probe.json" GET "$TOKEN" "" "/api/events" "/events")
if [[ -z "$EVENTS_COLLECTION_PATH" ]]; then
  echo "❌ events-path failed: could not resolve events collection route"
  exit 1
fi

echo "==> Auth me"
ME_STATUS=$(request GET "${AUTH_PREFIX}/me" "$TMP_DIR/me.json" "" "$TOKEN")
assert_status "auth-me" "$ME_STATUS" "200" "$TMP_DIR/me.json"

echo "==> Request access (public)"
REQ_STATUS=""
for attempt in {1..20}; do
  REQ_STATUS=$(request POST "${AUTH_PREFIX}/request-access" "$TMP_DIR/request_access.json" '{"email":"cleanup-smoke@example.com","firstName":"Smoke","lastName":"Test","message":"final cleanup smoke"}')
  if [[ "$REQ_STATUS" == "202" ]]; then
    break
  fi

  if [[ "$REQ_STATUS" == "502" || "$REQ_STATUS" == "503" || "$REQ_STATUS" == "504" || "$REQ_STATUS" == "000" ]]; then
    sleep 2
    continue
  fi

  break
done
assert_status "request-access" "$REQ_STATUS" "202" "$TMP_DIR/request_access.json"

echo "==> Inbox"
INBOX_STATUS=$(request GET "${NOTIFICATION_PREFIX}/inbox" "$TMP_DIR/inbox.json" "" "$TOKEN")
assert_status "inbox" "$INBOX_STATUS" "200" "$TMP_DIR/inbox.json"

echo "==> Notification template GET"
TPL_GET_STATUS=$(request GET "${NOTIFICATION_PREFIX}/settings/template/request-access" "$TMP_DIR/template_get.json" "" "$TOKEN")
assert_status "template-get" "$TPL_GET_STATUS" "200" "$TMP_DIR/template_get.json"

echo "==> Notification template PUT"
TPL_PUT_STATUS=$(request PUT "${NOTIFICATION_PREFIX}/settings/template/request-access" "$TMP_DIR/template_put.json" '{"channels":{"inbox":{"enabled":true,"title":"Access request from {{email}}","body":"Requester: {{email}}"},"email":{"enabled":false,"title":"Email req","body":"Email body"},"push":{"enabled":false,"title":"Push req","body":"Push body"}}}' "$TOKEN")
assert_status "template-put" "$TPL_PUT_STATUS" "200" "$TMP_DIR/template_put.json"

echo "==> Todo create"
TODO_CREATE_STATUS=$(request POST "$TODOS_COLLECTION_PATH" "$TMP_DIR/todo_create.json" '{"text":"Smoke todo item"}' "$TOKEN")
assert_status "todo-create" "$TODO_CREATE_STATUS" "201" "$TMP_DIR/todo_create.json"

TODO_ID=$(python3 - <<PY
import json
with open("$TMP_DIR/todo_create.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("id", ""))
PY
)

if [[ -z "$TODO_ID" ]]; then
  echo "❌ todo-create failed: todo id is empty"
  cat "$TMP_DIR/todo_create.json"
  echo
  exit 1
fi

echo "==> Todo toggle"
TODO_TOGGLE_STATUS=$(request PATCH "${TODOS_COLLECTION_PATH}/$TODO_ID/toggle" "$TMP_DIR/todo_toggle.json" '{}' "$TOKEN")
assert_status "todo-toggle" "$TODO_TOGGLE_STATUS" "200" "$TMP_DIR/todo_toggle.json"

echo "==> Todo update"
TODO_UPDATE_STATUS=$(request PATCH "${TODOS_COLLECTION_PATH}/$TODO_ID" "$TMP_DIR/todo_update.json" '{"text":"Smoke todo updated","done":false}' "$TOKEN")
assert_status "todo-update" "$TODO_UPDATE_STATUS" "200" "$TMP_DIR/todo_update.json"

echo "==> Todo delete"
TODO_DELETE_STATUS=$(request DELETE "${TODOS_COLLECTION_PATH}/$TODO_ID" "$TMP_DIR/todo_delete.json" "" "$TOKEN")
assert_status "todo-delete" "$TODO_DELETE_STATUS" "204" "$TMP_DIR/todo_delete.json"

echo "==> Event create"
EVENT_CREATE_STATUS=$(request POST "$EVENTS_COLLECTION_PATH" "$TMP_DIR/event_create.json" '{"title":"Smoke Event","description":"Event smoke test","startAt":"2030-01-10T12:00:00+00:00","endAt":"2030-01-10T14:00:00+00:00","location":{"display_name":"Kraków","lat":50.06143,"lon":19.93658}}' "$TOKEN")
assert_status "event-create" "$EVENT_CREATE_STATUS" "201" "$TMP_DIR/event_create.json"

EVENT_ID=$(python3 - <<PY
import json
with open("$TMP_DIR/event_create.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("id", ""))
PY
)

if [[ -z "$EVENT_ID" ]]; then
  echo "❌ event-create failed: event id is empty"
  cat "$TMP_DIR/event_create.json"
  echo
  exit 1
fi

echo "==> Event upcoming"
EVENT_UPCOMING_STATUS=$(request GET "${EVENTS_COLLECTION_PATH}/upcoming" "$TMP_DIR/event_upcoming.json" "" "$TOKEN")
assert_status "event-upcoming" "$EVENT_UPCOMING_STATUS" "200" "$TMP_DIR/event_upcoming.json"

echo "==> Event update"
EVENT_UPDATE_STATUS=$(request PUT "${EVENTS_COLLECTION_PATH}/$EVENT_ID" "$TMP_DIR/event_update.json" '{"title":"Smoke Event Updated","description":"Updated event smoke test"}' "$TOKEN")
assert_status "event-update" "$EVENT_UPDATE_STATUS" "200" "$TMP_DIR/event_update.json"

echo "==> Shopping list create"
SHOP_CREATE_STATUS=$(request POST "$SHOPPING_COLLECTION_PATH" "$TMP_DIR/shop_create.json" '{"name":"Smoke Shopping List","products":[{"name":"Milk","qty":2,"weight":"1L"},{"name":"Bread","qty":1}]}' "$TOKEN")
assert_status "shopping-create" "$SHOP_CREATE_STATUS" "201" "$TMP_DIR/shop_create.json"

SHOP_LIST_ID=$(python3 - <<PY
import json
with open("$TMP_DIR/shop_create.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("id", ""))
PY
)

if [[ -z "$SHOP_LIST_ID" ]]; then
  echo "❌ shopping-create failed: list id is empty"
  cat "$TMP_DIR/shop_create.json"
  echo
  exit 1
fi

echo "==> Shopping list update"
SHOP_UPDATE_STATUS=$(request PUT "${SHOPPING_COLLECTION_PATH}/$SHOP_LIST_ID" "$TMP_DIR/shop_update.json" '{"name":"Smoke Shopping List Updated","status":"active","products":[{"name":"Milk","qty":3,"weight":"1L","bought":true,"position":0},{"name":"Bread","qty":2,"bought":false,"position":1}]}' "$TOKEN")
assert_status "shopping-update" "$SHOP_UPDATE_STATUS" "200" "$TMP_DIR/shop_update.json"

echo "==> Shopping list archive"
SHOP_ARCHIVE_STATUS=$(request PATCH "${SHOPPING_COLLECTION_PATH}/$SHOP_LIST_ID/status" "$TMP_DIR/shop_archive.json" '{"status":"archived"}' "$TOKEN")
assert_status "shopping-archive" "$SHOP_ARCHIVE_STATUS" "200" "$TMP_DIR/shop_archive.json"

echo "==> Shopping list restore"
SHOP_RESTORE_STATUS=$(request PATCH "${SHOPPING_COLLECTION_PATH}/$SHOP_LIST_ID/status" "$TMP_DIR/shop_restore.json" '{"status":"active"}' "$TOKEN")
assert_status "shopping-restore" "$SHOP_RESTORE_STATUS" "200" "$TMP_DIR/shop_restore.json"

echo "==> Shopping list delete"
SHOP_DELETE_STATUS=$(request DELETE "${SHOPPING_COLLECTION_PATH}/$SHOP_LIST_ID" "$TMP_DIR/shop_delete.json" "" "$TOKEN")
assert_status "shopping-delete" "$SHOP_DELETE_STATUS" "204" "$TMP_DIR/shop_delete.json"

echo "==> Route create"
ROUTE_CREATE_STATUS=$(request POST "$ROUTES_COLLECTION_PATH" "$TMP_DIR/route_create.json" '{"name":"Smoke Route","description":"Route smoke test","geoJson":{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"LineString","coordinates":[[19.94,50.06],[19.95,50.065],[19.96,50.07]]},"properties":{"name":"Smoke Route"}}]},"distanceMeters":1300,"durationMinutes":16,"waypoints":[[50.06,19.94],[50.065,19.95],[50.07,19.96]],"eventId":'"$EVENT_ID"'}' "$TOKEN")
assert_status "route-create" "$ROUTE_CREATE_STATUS" "201" "$TMP_DIR/route_create.json"

ROUTE_ID=$(python3 - <<PY
import json
with open("$TMP_DIR/route_create.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("id", ""))
PY
)

if [[ -z "$ROUTE_ID" ]]; then
  echo "❌ route-create failed: route id is empty"
  cat "$TMP_DIR/route_create.json"
  echo
  exit 1
fi

echo "==> Route list"
ROUTES_STATUS=$(request GET "$ROUTES_COLLECTION_PATH" "$TMP_DIR/routes_list.json" "" "$TOKEN")
assert_status "route-list" "$ROUTES_STATUS" "200" "$TMP_DIR/routes_list.json"

echo "==> Route update"
ROUTE_UPDATE_STATUS=$(request PUT "${ROUTES_COLLECTION_PATH}/$ROUTE_ID" "$TMP_DIR/route_update.json" '{"name":"Smoke Route Updated","durationMinutes":18}' "$TOKEN")
assert_status "route-update" "$ROUTE_UPDATE_STATUS" "200" "$TMP_DIR/route_update.json"

echo "==> Route by event"
ROUTES_BY_EVENT_STATUS=$(request GET "${ROUTES_COLLECTION_PATH}/event/$EVENT_ID" "$TMP_DIR/routes_by_event.json" "" "$TOKEN")
assert_status "route-by-event" "$ROUTES_BY_EVENT_STATUS" "200" "$TMP_DIR/routes_by_event.json"

echo "==> Route delete"
ROUTE_DELETE_STATUS=$(request DELETE "${ROUTES_COLLECTION_PATH}/$ROUTE_ID" "$TMP_DIR/route_delete.json" "" "$TOKEN")
assert_status "route-delete" "$ROUTE_DELETE_STATUS" "204" "$TMP_DIR/route_delete.json"

echo "==> Event delete"
EVENT_DELETE_STATUS=$(request DELETE "${EVENTS_COLLECTION_PATH}/$EVENT_ID" "$TMP_DIR/event_delete.json" "" "$TOKEN")
assert_status "event-delete" "$EVENT_DELETE_STATUS" "204" "$TMP_DIR/event_delete.json"

echo "==> Public register blocked"
REGISTER_STATUS=$(request POST "${AUTH_PREFIX}/register" "$TMP_DIR/register_public.json" '{"email":"public@example.com","password":"secret123","firstName":"Public","lastName":"User"}')
assert_status "register-public" "$REGISTER_STATUS" "401" "$TMP_DIR/register_public.json"

echo "==> Roles list (auth/roles)"
ROLES_LIST_STATUS=$(request GET "${AUTH_PREFIX}/roles" "$TMP_DIR/roles_list.json" "" "$TOKEN")
assert_status "roles-list" "$ROLES_LIST_STATUS" "200" "$TMP_DIR/roles_list.json"

echo "==> Role create (custom)"
ROLE_CREATE_STATUS=$(request POST "${AUTH_PREFIX}/roles" "$TMP_DIR/role_create.json" '{"name":"Smoke Viewer","slug":"ROLE_SMOKE_VIEWER","permissions":["dashboard.view","map.view"]}' "$TOKEN")
assert_status "role-create" "$ROLE_CREATE_STATUS" "201" "$TMP_DIR/role_create.json"

SMOKE_ROLE_ID=$(python3 - <<PY
import json
with open("$TMP_DIR/role_create.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("id", ""))
PY
)

echo "==> Role rename (PUT)"
ROLE_UPDATE_STATUS=$(request PUT "${AUTH_PREFIX}/roles/$SMOKE_ROLE_ID" "$TMP_DIR/role_update.json" '{"name":"Smoke Viewer Renamed"}' "$TOKEN")
assert_status "role-rename" "$ROLE_UPDATE_STATUS" "200" "$TMP_DIR/role_update.json"

echo "==> Role delete"
ROLE_DELETE_STATUS=$(request DELETE "${AUTH_PREFIX}/roles/$SMOKE_ROLE_ID" "$TMP_DIR/role_delete.json" "" "$TOKEN")
assert_status "role-delete" "$ROLE_DELETE_STATUS" "204" "$TMP_DIR/role_delete.json"

echo "==> Access settings has roleDefinitions"
ACCESS_SETTINGS_STATUS=$(request GET "${AUTH_PREFIX}/settings/access" "$TMP_DIR/access_settings.json" "" "$TOKEN")
assert_status "access-settings" "$ACCESS_SETTINGS_STATUS" "200" "$TMP_DIR/access_settings.json"

HAS_DEFS=$(python3 - <<PY
import json
with open("$TMP_DIR/access_settings.json", "r", encoding="utf-8") as f:
    payload = json.load(f)
defs = payload.get("roleDefinitions", [])
print("yes" if len(defs) >= 4 else f"no:{len(defs)}")
PY
)

if [[ "$HAS_DEFS" != "yes" ]]; then
  echo "❌ access-settings-defs failed: $HAS_DEFS"
  exit 1
fi
echo "✅ access-settings-defs: roleDefinitions present (>=4)"

printf "\n🎉 Smoke passed on clean stack\n"
echo "- login: 200"
echo "- auth-me: 200"
echo "- request-access: 202"
echo "- inbox: 200"
echo "- template GET/PUT: 200/200"
echo "- todos create/toggle/update/delete: 201/200/200/204"
echo "- events create/upcoming/update/delete: 201/200/200/204"
echo "- shopping create/update/archive/restore/delete: 201/200/200/200/204"
echo "- routes create/list/update/by-event/delete: 201/200/200/200/204"
echo "- roles list/create/rename/delete: 200/201/200/204"
echo "- access-settings roleDefinitions: present"
echo "- public register blocked: 401"
