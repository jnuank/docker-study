#!/usr/bin/env bash
# =============================================================
# Signal handling test: CMD shell vs CMD exec vs ENTRYPOINT
# Simulates k8s pod termination (SIGTERM) behavior
# =============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

WAIT_SECONDS=5       # seconds to let the container run before sending SIGTERM
SIGTERM_TIMEOUT=10   # seconds to wait for graceful shutdown

log() { echo -e "${BLUE}[TEST]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() {
  echo ""
  echo -e "${YELLOW}============================================================${NC}"
  echo -e "${YELLOW} $*${NC}"
  echo -e "${YELLOW}============================================================${NC}"
}

run_test() {
  local name="$1"
  local dockerfile="$2"
  local image="signal-test-${name}"
  local container="signal-test-${name}-run"

  section "Pattern: ${name}"
  log "Dockerfile: ${dockerfile}"

  # Build
  log "Building image..."
  docker build -f "${dockerfile}" -t "${image}" . --quiet
  log "Image built: ${image}"

  # Run in background
  log "Starting container (will run for ${WAIT_SECONDS}s before SIGTERM)..."
  docker rm -f "${container}" 2>/dev/null || true
  docker run --name "${container}" --rm -d "${image}" > /dev/null

  # Show container PID info
  sleep 1
  echo ""
  log "--- Container output so far ---"
  docker logs "${container}" 2>&1 | head -20
  echo ""

  # Check PID 1 inside container
  local pid1_cmd
  pid1_cmd=$(docker exec "${container}" cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "unknown")
  log "PID 1 inside container: ${pid1_cmd}"

  if echo "${pid1_cmd}" | grep -q "python"; then
    pass "Python is PID 1 → SIGTERM will reach the ADK process"
  elif echo "${pid1_cmd}" | grep -qE "sh|bash"; then
    warn "Shell is PID 1 → SIGTERM will NOT reliably reach Python ADK"
    local python_pid
    python_pid=$(docker exec "${container}" pgrep -f "python" 2>/dev/null || echo "N/A")
    log "Python process PID: ${python_pid}"
  fi

  # Wait then send SIGTERM (simulates k8s pod termination)
  log "Waiting ${WAIT_SECONDS}s then sending SIGTERM (simulating k8s pod termination)..."
  sleep "${WAIT_SECONDS}"

  log "Sending SIGTERM to container..."
  docker stop --time="${SIGTERM_TIMEOUT}" "${container}" 2>&1 || true

  echo ""
  log "--- Full container output ---"
  # Note: --rm removes container after stop, logs captured during run
  echo ""
}

run_test_with_logs() {
  local name="$1"
  local dockerfile="$2"
  local image="signal-test-${name}"
  local container="signal-test-${name}-run"
  local logfile="/tmp/docker-signal-test-${name}.log"

  section "Pattern: ${name}"
  log "Dockerfile: ${dockerfile}"

  # Build
  log "Building image..."
  docker build -f "${dockerfile}" -t "${image}" . --quiet
  log "Image built: ${image}"

  # Run in background without --rm so we can inspect logs after stop
  docker rm -f "${container}" 2>/dev/null || true
  log "Starting container..."
  docker run --name "${container}" -d "${image}" > /dev/null

  sleep 1

  # Check PID 1
  local pid1_cmd
  pid1_cmd=$(docker exec "${container}" cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "unknown")
  log "PID 1 inside container: [${pid1_cmd}]"

  if echo "${pid1_cmd}" | grep -q "python"; then
    pass "Python is PID 1 → SIGTERM WILL reach ADK"
    local pid1_result="PYTHON_IS_PID1"
  elif echo "${pid1_cmd}" | grep -qE "^sh |^/bin/sh"; then
    warn "Shell (/bin/sh) is PID 1 → SIGTERM will NOT reliably reach Python ADK"
    local pid1_result="SHELL_IS_PID1"
    local python_pid
    python_pid=$(docker exec "${container}" pgrep -f "python app.py" 2>/dev/null | head -1 || echo "N/A")
    log "Python ADK is running as PID: ${python_pid}"
  else
    log "PID 1 is: ${pid1_cmd}"
    local pid1_result="OTHER"
  fi

  # Show running output
  echo ""
  log "--- Container logs before SIGTERM ---"
  docker logs "${container}" 2>&1
  echo ""

  # Simulate k8s SIGTERM
  log ">>> Simulating k8s pod termination (docker stop = SIGTERM + wait ${SIGTERM_TIMEOUT}s + SIGKILL) <<<"
  sleep "${WAIT_SECONDS}"
  docker stop --time="${SIGTERM_TIMEOUT}" "${container}" 2>&1 || true

  # Capture full logs
  echo ""
  log "--- Full container logs after SIGTERM ---"
  docker logs "${container}" 2>&1 | tee "${logfile}"
  echo ""

  # Analyze result
  if grep -q "\[SIGNAL\] \*\*\* SIGTERM received" "${logfile}"; then
    pass "SIGTERM was received by Python ADK process!"
  else
    fail "SIGTERM was NOT received by Python ADK process."
    if [ "${pid1_result:-}" = "SHELL_IS_PID1" ]; then
      fail "Root cause: shell is PID 1, it absorbed SIGTERM without forwarding to Python"
    fi
  fi

  docker rm -f "${container}" 2>/dev/null || true
  echo ""
}

# Main
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE} Docker Signal Handling Test: CMD vs ENTRYPOINT${NC}"
echo -e "${BLUE} Verifying Python ADK receives k8s SIGTERM${NC}"
echo -e "${BLUE}============================================================${NC}"

run_test_with_logs "cmd-shell"    "Dockerfile.cmd-shell"
run_test_with_logs "cmd-exec"     "Dockerfile.cmd-exec"
run_test_with_logs "entrypoint"   "Dockerfile.entrypoint"

section "Summary"
echo ""
echo "Pattern             | PID 1       | SIGTERM reaches Python ADK?"
echo "--------------------|-------------|-----------------------------"
echo "CMD (shell form)    | /bin/sh     | NO  - shell absorbs signal"
echo "CMD (exec form)     | python      | YES - python receives signal"
echo "ENTRYPOINT (exec)   | python      | YES - python receives signal"
echo ""
echo "k8s termination flow:"
echo "  1. k8s sends SIGTERM to PID 1 of the container"
echo "  2. If PID 1 is shell → Python ADK does NOT get SIGTERM"
echo "  3. After terminationGracePeriodSeconds, k8s sends SIGKILL (force kill)"
echo "  4. This means no graceful shutdown for Python ADK with CMD shell form"
echo ""
log "Logs saved to /tmp/docker-signal-test-*.log"
