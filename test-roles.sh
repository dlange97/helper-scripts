#!/usr/bin/env bash
set -euo pipefail

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

LOGIN_RESP=$(curl -s -X POST "$BASE_URL/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")

TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))")

if [ -z "$TOKEN" ]; then
  echo "Login failed: $LOGIN_RESP"
  exit 1
fi
echo "Logged in successfully"

echo "---GET /auth/roles---"
ROLES=$(curl -s "$BASE_URL/api/auth/roles" -H "Authorization: Bearer $TOKEN")
echo "$ROLES" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Got {len(d)} roles:')
for r in d:
    print(f'  {r[\"name\"]} ({r[\"slug\"]}) isSystem={r[\"isSystem\"]}')
"
echo

echo "---POST /auth/roles (create custom)---"
NEW_ROLE=$(curl -s -X POST "$BASE_URL/api/auth/roles" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name":"Test Viewer","slug":"ROLE_TEST_VIEWER","permissions":["dashboard.view","map.view"]}')
echo "$NEW_ROLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Created: id={d.get(\"id\")} slug={d.get(\"slug\")}')"
NEW_ID=$(echo "$NEW_ROLE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")

echo

echo "---PUT /auth/roles/$NEW_ID (rename)---"
curl -s -X PUT "$BASE_URL/api/auth/roles/$NEW_ID" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name":"Renamed Viewer"}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Updated: name={d.get(\"name\")}')"
echo

echo "---DELETE /auth/roles/$NEW_ID---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE_URL/api/auth/roles/$NEW_ID" \
  -H "Authorization: Bearer $TOKEN")
echo "Delete status: $STATUS"
echo

echo "---GET /auth/settings/access (check roleDefinitions field)---"
curl -s "$BASE_URL/api/auth/settings/access" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
defs = d.get('roleDefinitions', [])
print(f'roleDefinitions count: {len(defs)}')
print(f'legacy roles count: {len(d.get(\"roles\",[]))}')
"
