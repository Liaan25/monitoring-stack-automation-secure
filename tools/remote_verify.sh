#!/bin/bash
set -euo pipefail

SSH_OPTS="-q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR"

ssh ${SSH_OPTS} "${SSH_USER}@${TARGET_SERVER}" 2>/dev/null <<'ENDSSH'
echo "================================================"
echo "СЕРВЕР: ${TARGET_SERVER}"
echo "ПРОВЕРКА СЕРВИСОВ (USER UNITS):"
echo "================================================"

if [ "${RUN_SERVICES_AS_MON_CI}" = "true" ]; then
    RUNTIME_USER="${DEPLOY_USER}"
else
    RUNTIME_USER="${MON_SYS_USER}"
fi
RUNTIME_UID=$(id -u "${RUNTIME_USER}" 2>/dev/null || echo "")

if [ -n "${RUNTIME_UID}" ]; then
    echo "[INFO] Проверка user-юнитов для ${RUNTIME_USER} (UID: ${RUNTIME_UID})..."
    sudo -u "${RUNTIME_USER}" env XDG_RUNTIME_DIR="/run/user/${RUNTIME_UID}" systemctl --user is-active monitoring-prometheus.service && echo "[OK] Prometheus активен" || echo "[FAIL] Prometheus не активен"
    sudo -u "${RUNTIME_USER}" env XDG_RUNTIME_DIR="/run/user/${RUNTIME_UID}" systemctl --user is-active monitoring-grafana.service && echo "[OK] Grafana активна" || echo "[FAIL] Grafana не активна"
    sudo -u "${RUNTIME_USER}" env XDG_RUNTIME_DIR="/run/user/${RUNTIME_UID}" systemctl --user is-active monitoring-harvest-unix.service && echo "[OK] Harvest Unix активен" || echo "[FAIL] Harvest Unix не активен"
    sudo -u "${RUNTIME_USER}" env XDG_RUNTIME_DIR="/run/user/${RUNTIME_UID}" systemctl --user is-active monitoring-harvest-netapp.service && echo "[OK] Harvest NetApp активен" || echo "[FAIL] Harvest NetApp не активен"
else
    echo "[ERROR] Не удалось определить UID для ${RUNTIME_USER}"
fi

echo ""
echo "================================================"
echo "ПРОВЕРКА ПОРТОВ:"
echo "================================================"
ss -tln | grep -q ":${PROMETHEUS_PORT} " && echo "[OK] Порт ${PROMETHEUS_PORT} (Prometheus) открыт" || echo "[FAIL] Порт ${PROMETHEUS_PORT} не открыт"
ss -tln | grep -q ":${GRAFANA_PORT} " && echo "[OK] Порт ${GRAFANA_PORT} (Grafana) открыт" || echo "[FAIL] Порт ${GRAFANA_PORT} не открыт"
ss -tln | grep -q ":12996 " && echo "[OK] Порт 12996 (Harvest-NetApp) открыт" || echo "[FAIL] Порт 12996 не открыт"
ss -tln | grep -q ":12995 " && echo "[OK] Порт 12995 (Harvest-Unix) открыт" || echo "[FAIL] Порт 12995 не открыт"
ENDSSH
