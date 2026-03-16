#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${BACKEND_DIR}/../my-dashboard-docker/docker-compose.yml"
MIN_COVERAGE="${MIN_COVERAGE:-70}"
DASHBOARD_MIN_COVERAGE="${DASHBOARD_MIN_COVERAGE:-25}"
EVENTS_MIN_COVERAGE="${EVENTS_MIN_COVERAGE:-35}"
NOTIFICATION_MIN_COVERAGE="${NOTIFICATION_MIN_COVERAGE:-0}"

run_in_service() {
  local service="$1"
  local command="$2"

  docker compose -f "${COMPOSE_FILE}" exec -T "${service}" sh -lc "${command}"
}

echo "==> Running auth-service quality checks (phpcs + phpstan)"
run_in_service "auth-php" "cd /app && composer run quality"

echo "==> Running dashboard-service quality checks with coverage"
run_in_service "dashboard-php" "cd /app && MIN_COVERAGE=${DASHBOARD_MIN_COVERAGE} composer run quality"

echo "==> Running events-service quality checks with coverage"
run_in_service "events-php" "cd /app && MIN_COVERAGE=${EVENTS_MIN_COVERAGE} composer run quality"

echo "==> Running notification-service quality checks with coverage"
run_in_service "notification-php" "cd /app && MIN_COVERAGE=${NOTIFICATION_MIN_COVERAGE} composer run quality"

echo "==> Quality checks completed successfully"
