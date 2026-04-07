#!/bin/bash
set -euo pipefail

SSH_OPTS="-q -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes -o TCPKeepAlive=yes -o LogLevel=ERROR"

[ ! -f "${CRED_JSON_FILE}" ] && echo "[ERROR] ${CRED_JSON_FILE} не найден!" && exit 1

echo "[INFO] [${TARGET_SERVER}] Тестируем SSH подключение..."
ssh ${SSH_OPTS} "${SSH_USER}@${TARGET_SERVER}" "echo '[OK] SSH подключение успешно'" 2>/dev/null

echo "[INFO] [${TARGET_SERVER}] Создаем рабочую директорию ${DEPLOY_PATH}..."
ssh ${SSH_OPTS} "${SSH_USER}@${TARGET_SERVER}" "mkdir -p '${DEPLOY_PATH}'" 2>/dev/null

echo "[INFO] [${TARGET_SERVER}] Копируем скрипт, wrappers и credentials..."
scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  install-monitoring-stack.sh \
  "${SSH_USER}@${TARGET_SERVER}:${DEPLOY_PATH}/install-monitoring-stack.sh" 2>/dev/null
scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR -r \
  wrappers \
  "${SSH_USER}@${TARGET_SERVER}:${DEPLOY_PATH}/" 2>/dev/null
if [ -d dashboards ]; then
  scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR -r \
    dashboards \
    "${SSH_USER}@${TARGET_SERVER}:${DEPLOY_PATH}/" 2>/dev/null
fi
scp -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  "${CRED_JSON_FILE}" \
  "${SSH_USER}@${TARGET_SERVER}:${DEPLOY_PATH}/${CRED_JSON_FILE}" 2>/dev/null

ssh -q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  "${SSH_USER}@${TARGET_SERVER}" 2>/dev/null <<REMOTE_EOF
[ ! -f "${DEPLOY_PATH}/install-monitoring-stack.sh" ] && echo "[ERROR] Скрипт не найден!" && exit 1
[ ! -d "${DEPLOY_PATH}/wrappers" ] && echo "[ERROR] Wrappers не найдены!" && exit 1
[ ! -f "${DEPLOY_PATH}/${CRED_JSON_FILE}" ] && echo "[ERROR] Credentials не найдены!" && exit 1
echo "[OK] Все файлы на месте"
REMOTE_EOF

echo "[SUCCESS] [${TARGET_SERVER}] Копирование завершено"
