#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8081}"

LOGIN_RESP=$(curl -s -X POST "$BASE_URL/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin.test@micro.com","password":"Admin123!"}')

TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))")

if [ -z "$TOKEN" ]; then
  echo "Login failed: $LOGIN_RESP"
  exit 1
fi
echo "Logged in successfully"

# Test GET /routes
echo "---GET /routes---"
curl -s "$BASE_URL/api/routes" -H "Authorization: Bearer $TOKEN"
echo

# Test POST /routes
echo "---POST /routes---"
curl -s -X POST "$BASE_URL/api/routes" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "name":"Test Route",
    "geoJson":{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"LineString","coordinates":[[19.0,52.0],[19.1,52.1]]},"properties":{"name":"Test"}}]},
    "distanceMeters":14000,
    "durationMinutes":10,
    "waypoints":[[52.0,19.0],[52.1,19.1]]
  }'
echo
