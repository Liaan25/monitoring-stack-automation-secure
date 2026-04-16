#!/bin/bash
set -euo pipefail

SSH_OPTS="-q -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes -o TCPKeepAlive=yes -o LogLevel=ERROR"

[ ! -f "${CRED_JSON_FILE}" ] && echo "[ERROR] ${CRED_JSON_FILE} не найден!" && exit 1

log_step() {
  echo "[COPY-DIAG] [$TARGET_SERVER] ===== $* ====="
}

run_cmd() {
  local title="$1"
  local cmd="$2"
  local output rc

  log_step "$title"
  echo "[COPY-DIAG] [$TARGET_SERVER] CMD: $cmd"

  set +e
  output="$(bash -o pipefail -c "$cmd" 2>&1)"
  rc=$?
  set -e

  if [[ -n "$output" ]]; then
    while IFS= read -r line; do
      echo "[COPY-DIAG] [$TARGET_SERVER] OUT: $line"
    done <<< "$output"
  else
    echo "[COPY-DIAG] [$TARGET_SERVER] OUT: <empty>"
  fi
  echo "[COPY-DIAG] [$TARGET_SERVER] RC: $rc"

  return "$rc"
}

echo "[INFO] [${TARGET_SERVER}] Тестируем SSH подключение..."
run_cmd "SSH connectivity check" \
  "ssh ${SSH_OPTS} \"${SSH_USER}@${TARGET_SERVER}\" \"echo '[OK] SSH подключение успешно'\""

run_cmd "Remote FS diagnostics before copy" \
  "ssh ${SSH_OPTS} \"${SSH_USER}@${TARGET_SERVER}\" \"bash -s\" <<'REMOTE_EOF'
set -u
echo \"[FS-DIAG] host=\$(hostname -f 2>/dev/null || hostname)\"
echo \"[FS-DIAG] user=\$(whoami)\"
echo \"[FS-DIAG] pwd=\$(pwd)\"
echo \"[FS-DIAG] deploy_path=${DEPLOY_PATH}\"
echo \"[FS-DIAG] monitoring_mount=/monitoring\"
echo \"[FS-DIAG] findmnt(/monitoring):\"
findmnt -T /monitoring -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true
echo \"[FS-DIAG] findmnt(deploy_path):\"
findmnt -T \"${DEPLOY_PATH}\" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true
echo \"[FS-DIAG] df -Th /monitoring and deploy path:\"
df -Th /monitoring \"${DEPLOY_PATH}\" 2>&1 || true
echo \"[FS-DIAG] permissions:\"
ls -ld /monitoring /monitoring/mon-harvest-prometheus-grafana \"${DEPLOY_PATH}\" 2>&1 || true
echo \"[FS-DIAG] write probe /monitoring:\"
if : > /monitoring/.copy_rw_probe_\$\$ 2>/dev/null; then
  rm -f /monitoring/.copy_rw_probe_\$\$ 2>/dev/null || true
  echo \"[FS-DIAG] /monitoring write probe: OK\"
else
  echo \"[FS-DIAG] /monitoring write probe: FAIL\"
fi
echo \"[FS-DIAG] write probe deploy path parent:\"
deploy_parent=\"\$(dirname \"${DEPLOY_PATH}\")\"
if : > \"\${deploy_parent}/.copy_rw_probe_\$\$\" 2>/dev/null; then
  rm -f \"\${deploy_parent}/.copy_rw_probe_\$\$\" 2>/dev/null || true
  echo \"[FS-DIAG] \${deploy_parent} write probe: OK\"
else
  echo \"[FS-DIAG] \${deploy_parent} write probe: FAIL\"
fi
REMOTE_EOF"

echo "[INFO] [${TARGET_SERVER}] Создаем рабочую директорию ${DEPLOY_PATH}..."
run_cmd "Ensure remote deploy directory exists" \
  "ssh ${SSH_OPTS} \"${SSH_USER}@${TARGET_SERVER}\" \"mkdir -p '${DEPLOY_PATH}'\""

echo "[INFO] [${TARGET_SERVER}] Копируем скрипт, wrappers и credentials..."
run_cmd "SCP install script" \
  "scp -o StrictHostKeyChecking=no -o LogLevel=ERROR install-monitoring-stack.sh \"${SSH_USER}@${TARGET_SERVER}:${DEPLOY_PATH}/install-monitoring-stack.sh\""
run_cmd "SCP wrappers directory" \
  "scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -r wrappers \"${SSH_USER}@${TARGET_SERVER}:${DEPLOY_PATH}/\""
if [ -d dashboards ]; then
  run_cmd "SCP dashboards directory" \
    "scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -r dashboards \"${SSH_USER}@${TARGET_SERVER}:${DEPLOY_PATH}/\""
fi
run_cmd "SCP credentials json" \
  "scp -o StrictHostKeyChecking=no -o LogLevel=ERROR \"${CRED_JSON_FILE}\" \"${SSH_USER}@${TARGET_SERVER}:${DEPLOY_PATH}/${CRED_JSON_FILE}\""

run_cmd "Remote post-copy verification" \
  "ssh ${SSH_OPTS} \"${SSH_USER}@${TARGET_SERVER}\" \"bash -s\" <<'REMOTE_EOF'
[ ! -f \"${DEPLOY_PATH}/install-monitoring-stack.sh\" ] && echo \"[ERROR] Скрипт не найден!\" && exit 1
[ ! -d \"${DEPLOY_PATH}/wrappers\" ] && echo \"[ERROR] Wrappers не найдены!\" && exit 1
[ ! -f \"${DEPLOY_PATH}/${CRED_JSON_FILE}\" ] && echo \"[ERROR] Credentials не найдены!\" && exit 1
echo \"[OK] Все файлы на месте\"
REMOTE_EOF"

echo "[SUCCESS] [${TARGET_SERVER}] Копирование завершено"
