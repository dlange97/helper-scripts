#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${BACKEND_DIR}/.." && pwd)"
FRONTEND_DIR="${PROJECT_ROOT}/my-dashboard-frontend"
VERIFY_ENDPOINTS_SCRIPT="${SCRIPT_DIR}/verify-missing-endpoints.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Missing required command: python3"
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "Missing required command: npm"
  exit 1
fi

if ! command -v bash >/dev/null 2>&1; then
  echo "Missing required command: bash"
  exit 1
fi

LOG_DIR="${PROJECT_ROOT}/test-output/all-checks-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${LOG_DIR}"

NAMES=()
CMDS=()
STATUS=()
DURATION=()
LOGS=()

add_check() {
  NAMES+=("$1")
  CMDS+=("$2")
}

add_check "Backend endpoint verifier" "python3 \"${VERIFY_ENDPOINTS_SCRIPT}\""
add_check "Backend smoke tests" "bash \"${SCRIPT_DIR}/smoke.sh\""
add_check "Backend quality gates" "bash \"${SCRIPT_DIR}/quality.sh\""
add_check "Backend performance checks" "bash \"${SCRIPT_DIR}/performance.sh\""
add_check "Frontend unit tests" "npm --prefix \"${FRONTEND_DIR}\" run test"
add_check "Frontend coverage" "npm --prefix \"${FRONTEND_DIR}\" run test:coverage"
add_check "Frontend production build" "npm --prefix \"${FRONTEND_DIR}\" run build"

run_one() {
  local idx="$1"
  local name="${NAMES[$idx]}"
  local cmd="${CMDS[$idx]}"
  local log_file="${LOG_DIR}/check-$((idx + 1)).log"

  echo ""
  echo "============================================================"
  echo "[$((idx + 1))/${#NAMES[@]}] ${name}"
  echo "Command: ${cmd}"
  echo "Log: ${log_file}"
  echo "============================================================"

  local start_ts
  start_ts=$(date +%s)

  if bash -lc "${cmd}" >"${log_file}" 2>&1; then
    STATUS+=("PASS")
  else
    STATUS+=("FAIL")
  fi

  local end_ts
  end_ts=$(date +%s)
  DURATION+=("$((end_ts - start_ts))")
  LOGS+=("${log_file}")

  if [[ "${STATUS[$idx]}" == "PASS" ]]; then
    echo "Result: PASS (${DURATION[$idx]}s)"
  else
    echo "Result: FAIL (${DURATION[$idx]}s)"
    echo "---- Last 30 lines of log ----"
    tail -n 30 "${log_file}" || true
    echo "------------------------------"
  fi
}

for i in "${!NAMES[@]}"; do
  run_one "$i"
done

echo ""
echo "==================== SUMMARY ===================="
printf "%-3s | %-34s | %-6s | %-8s | %s\n" "#" "Check" "Status" "Time" "Log"
printf '%s\n' "-----------------------------------------------------------------------------------------------"

failed_count=0
for i in "${!NAMES[@]}"; do
  printf "%-3s | %-34s | %-6s | %-8s | %s\n" \
    "$((i + 1))" \
    "${NAMES[$i]}" \
    "${STATUS[$i]}" \
    "${DURATION[$i]}s" \
    "${LOGS[$i]}"

  if [[ "${STATUS[$i]}" != "PASS" ]]; then
    failed_count=$((failed_count + 1))
  fi
done

echo "---------------------------------------------------------------"
if [[ "${failed_count}" -eq 0 ]]; then
  echo "All checks passed."
  exit 0
fi

echo "Failed checks: ${failed_count}"
exit 1
