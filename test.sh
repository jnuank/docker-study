#!/usr/bin/env bash
# =============================================================
# シグナルハンドリングテスト: CMD シェル形式 vs CMD exec形式 vs ENTRYPOINT
# k8s の pod termination（SIGTERM）の動作を検証する
# =============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 色リセット

WAIT_SECONDS=5       # SIGTERM を送る前にコンテナを動かす秒数
SIGTERM_TIMEOUT=10   # グレースフルシャットダウンの待機秒数

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

run_test_with_logs() {
  local name="$1"
  local dockerfile="$2"
  local image="signal-test-${name}"
  local container="signal-test-${name}-run"
  local logfile="/tmp/docker-signal-test-${name}.log"

  section "パターン: ${name}"
  log "Dockerfile: ${dockerfile}"

  # イメージをビルド
  log "イメージをビルド中..."
  docker build -f "${dockerfile}" -t "${image}" . --quiet
  log "イメージビルド完了: ${image}"

  # --rm なしでバックグラウンド起動（停止後にログを確認できるようにする）
  docker rm -f "${container}" 2>/dev/null || true
  log "コンテナを起動中..."
  docker run --name "${container}" -d "${image}" > /dev/null

  sleep 1

  # PID 1 を確認
  local pid1_cmd
  pid1_cmd=$(docker exec "${container}" cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "不明")
  log "コンテナ内の PID 1: [${pid1_cmd}]"

  if echo "${pid1_cmd}" | grep -q "python"; then
    pass "Python が PID 1 → SIGTERM は ADK に届く"
    local pid1_result="PYTHON_IS_PID1"
  elif echo "${pid1_cmd}" | grep -qE "^sh |^/bin/sh"; then
    warn "シェル（/bin/sh）が PID 1 → SIGTERM は Python ADK に届かない"
    local pid1_result="SHELL_IS_PID1"
    local python_pid
    python_pid=$(docker exec "${container}" pgrep -f "python app.py" 2>/dev/null | head -1 || echo "N/A")
    log "Python ADK のプロセス PID: ${python_pid}"
  else
    log "PID 1 のプロセス: ${pid1_cmd}"
    local pid1_result="OTHER"
  fi

  # SIGTERM 前のログを表示
  echo ""
  log "--- SIGTERM 送信前のコンテナログ ---"
  docker logs "${container}" 2>&1
  echo ""

  # k8s の SIGTERM をシミュレート
  log ">>> k8s pod termination をシミュレート（docker stop = SIGTERM → ${SIGTERM_TIMEOUT}秒待機 → SIGKILL）<<<"
  sleep "${WAIT_SECONDS}"
  docker stop --time="${SIGTERM_TIMEOUT}" "${container}" 2>&1 || true

  # SIGTERM 後の全ログを取得
  echo ""
  log "--- SIGTERM 送信後の全コンテナログ ---"
  docker logs "${container}" 2>&1 | tee "${logfile}"
  echo ""

  # 結果を判定
  if grep -q "\[SIGNAL\] \*\*\* SIGTERM を受信" "${logfile}"; then
    pass "Python ADK プロセスが SIGTERM を受信した！"
  else
    fail "Python ADK プロセスは SIGTERM を受信しなかった。"
    if [ "${pid1_result:-}" = "SHELL_IS_PID1" ]; then
      fail "原因: シェルが PID 1 のため、SIGTERM を吸収して Python に転送しなかった"
    fi
  fi

  docker rm -f "${container}" 2>/dev/null || true
  echo ""
}

# メイン処理
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE} Docker シグナルハンドリングテスト: CMD vs ENTRYPOINT${NC}"
echo -e "${BLUE} Python ADK が k8s の SIGTERM を受信できるか検証${NC}"
echo -e "${BLUE}============================================================${NC}"

run_test_with_logs "cmd-shell"    "Dockerfile.cmd-shell"
run_test_with_logs "cmd-exec"     "Dockerfile.cmd-exec"
run_test_with_logs "entrypoint"   "Dockerfile.entrypoint"

section "結果サマリー"
echo ""
echo "パターン              | PID 1       | Python ADK に SIGTERM が届くか"
echo "----------------------|-------------|--------------------------------"
echo "CMD（シェル形式）     | /bin/sh     | 届かない - シェルがシグナルを吸収"
echo "CMD（exec形式）       | python      | 届く     - python が直接受信"
echo "ENTRYPOINT（exec形式）| python      | 届く     - python が直接受信"
echo ""
echo "k8s のシグナル送信フロー:"
echo "  1. k8s がコンテナの PID 1 に SIGTERM を送信"
echo "  2. PID 1 がシェルの場合 → Python ADK に SIGTERM は届かない"
echo "  3. terminationGracePeriodSeconds 後に SIGKILL（強制終了）"
echo "  4. つまり CMD シェル形式では Python ADK のグレースフルシャットダウンができない"
echo ""
log "ログの保存先: /tmp/docker-signal-test-*.log"
