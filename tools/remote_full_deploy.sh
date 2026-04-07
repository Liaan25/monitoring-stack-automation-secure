#!/bin/bash
set -euo pipefail

SSH_OPTS="-q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

ssh ${SSH_OPTS} "${SSH_USER}@${TARGET_SERVER}" \
  DEPLOY_PATH="${DEPLOY_PATH}" \
  CRED_JSON_FILE="${CRED_JSON_FILE}" \
  TARGET_NETAPP="${TARGET_NETAPP}" \
  LOG_LEVEL="${LOG_LEVEL:-normal}" \
  MONITORING_MOUNT_NAME="${MONITORING_MOUNT_NAME:-monitoring}" \
  MONITORING_STACK_DIR_NAME="${MONITORING_STACK_DIR_NAME:-mon-harvest-prometheus-grafana}" \
  SEC_MAN_ADDR="${SEC_MAN_ADDR}" \
  NAMESPACE_CI="${NAMESPACE_CI}" \
  RLM_API_URL="${RLM_API_URL}" \
  RLM_TOKEN="${RLM_TOKEN}" \
  GRAFANA_PORT="${GRAFANA_PORT}" \
  PROMETHEUS_PORT="${PROMETHEUS_PORT}" \
  RPM_URL_KV="${RPM_URL_KV}" \
  NETAPP_SSH_KV="${NETAPP_SSH_KV}" \
  GRAFANA_WEB_KV="${GRAFANA_WEB_KV}" \
  SBERCA_CERT_KV="${SBERCA_CERT_KV}" \
  ADMIN_EMAIL="${ADMIN_EMAIL}" \
  VICTORIA_METRICS_REMOTE_WRITE_URL="${VICTORIA_METRICS_REMOTE_WRITE_URL}" \
  RENEW_CERTIFICATES_ONLY="${RENEW_CERTIFICATES_ONLY}" \
  USE_SIMPLIFIED_CERT_FLOW="${USE_SIMPLIFIED_CERT_FLOW}" \
  EFFECTIVE_SKIP_RPM="${EFFECTIVE_SKIP_RPM}" \
  SKIP_IPTABLES="${SKIP_IPTABLES}" \
  RUN_SERVICES_AS_MON_CI="${RUN_SERVICES_AS_MON_CI}" \
  DEPLOY_VERSION="${DEPLOY_VERSION}" \
  DEPLOY_GIT_COMMIT="${DEPLOY_GIT_COMMIT}" \
  DEPLOY_BUILD_DATE="${DEPLOY_BUILD_DATE}" \
  /bin/bash -s <<'REMOTE_EOF'
set -e
DEPLOY_DIR="${DEPLOY_PATH}"
REMOTE_SCRIPT_PATH="${DEPLOY_DIR}/install-monitoring-stack.sh"

if [ ! -f "${REMOTE_SCRIPT_PATH}" ]; then
  echo "[ERROR] Скрипт ${REMOTE_SCRIPT_PATH} не найден" && exit 1
fi

cd "${DEPLOY_DIR}"
chmod +x "${REMOTE_SCRIPT_PATH}"
if command -v dos2unix >/dev/null 2>&1; then
  dos2unix "${REMOTE_SCRIPT_PATH}" || true
else
  sed -i 's/\r$//' "${REMOTE_SCRIPT_PATH}" || true
fi

RPM_GRAFANA=$(jq -r '.rpm_url.grafana // empty' "${DEPLOY_DIR}/${CRED_JSON_FILE}" 2>/dev/null || echo "")
RPM_PROMETHEUS=$(jq -r '.rpm_url.prometheus // empty' "${DEPLOY_DIR}/${CRED_JSON_FILE}" 2>/dev/null || echo "")
RPM_HARVEST=$(jq -r '.rpm_url.harvest // empty' "${DEPLOY_DIR}/${CRED_JSON_FILE}" 2>/dev/null || echo "")
RPM_NODE_EXPORTER=$(jq -r '.rpm_url.node_exporter // empty' "${DEPLOY_DIR}/${CRED_JSON_FILE}" 2>/dev/null || echo "")

if [[ -z "${RPM_GRAFANA}" || -z "${RPM_PROMETHEUS}" || -z "${RPM_HARVEST}" ]]; then
  echo "[ERROR] Один или несколько RPM URLs пусты для ${CRED_JSON_FILE}"
  exit 1
fi

run_remote_deploy() {
  env \
    MONITORING_MOUNT_NAME="${MONITORING_MOUNT_NAME:-monitoring}" \
    MONITORING_STACK_DIR_NAME="${MONITORING_STACK_DIR_NAME:-mon-harvest-prometheus-grafana}" \
    SUPPRESS_LOCAL_FINAL_SUMMARY="true" \
    SEC_MAN_ADDR="${SEC_MAN_ADDR}" \
    NAMESPACE_CI="${NAMESPACE_CI}" \
    RLM_API_URL="${RLM_API_URL}" \
    RLM_TOKEN="${RLM_TOKEN}" \
    DEPLOY_TARGET_SERVER="${TARGET_SERVER}" \
    DEPLOY_TARGET_NETAPP="${TARGET_NETAPP}" \
    NETAPP_API_ADDR="${TARGET_NETAPP}" \
    GRAFANA_PORT="${GRAFANA_PORT}" \
    PROMETHEUS_PORT="${PROMETHEUS_PORT}" \
    RPM_URL_KV="${RPM_URL_KV}" \
    NETAPP_SSH_KV="${NETAPP_SSH_KV}" \
    GRAFANA_WEB_KV="${GRAFANA_WEB_KV}" \
    SBERCA_CERT_KV="${SBERCA_CERT_KV}" \
    ADMIN_EMAIL="${ADMIN_EMAIL}" \
    VICTORIA_METRICS_REMOTE_WRITE_URL="${VICTORIA_METRICS_REMOTE_WRITE_URL}" \
    RENEW_CERTIFICATES_ONLY="${RENEW_CERTIFICATES_ONLY}" \
    USE_SIMPLIFIED_CERT_FLOW="${USE_SIMPLIFIED_CERT_FLOW}" \
    SKIP_RPM_INSTALL="${EFFECTIVE_SKIP_RPM}" \
    SKIP_IPTABLES="${SKIP_IPTABLES}" \
    RUN_SERVICES_AS_MON_CI="${RUN_SERVICES_AS_MON_CI}" \
    GRAFANA_URL="${RPM_GRAFANA}" \
    PROMETHEUS_URL="${RPM_PROMETHEUS}" \
    HARVEST_URL="${RPM_HARVEST}" \
    NODE_EXPORTER_URL="${RPM_NODE_EXPORTER}" \
    DEPLOY_VERSION="${DEPLOY_VERSION}" \
    DEPLOY_GIT_COMMIT="${DEPLOY_GIT_COMMIT}" \
    DEPLOY_BUILD_DATE="${DEPLOY_BUILD_DATE}" \
    WRAPPERS_DIR="${DEPLOY_DIR}/wrappers" \
    CRED_JSON_PATH="${DEPLOY_DIR}/${CRED_JSON_FILE}" \
    /bin/bash "${REMOTE_SCRIPT_PATH}"
}

if [[ "${LOG_LEVEL:-normal}" == "debug" ]]; then
  run_remote_deploy
else
  run_remote_deploy 2>&1 | awk '
    /^DEBUG_/ { next }
    /^\[MAIN\]/ {
      if ($0 ~ /ERROR|FAIL|FAILED|WARNING|WARN|❌|⏰/) { print }
      next
    }
    /^\[SCRIPT\] Calling main with args:/ { next }
    /^\[SCRIPT\] main\(\) completed with exit code:/ { next }
    /^\[SCRIPT\] Script finished$/ { next }
    /^\[SCRIPT_START\]/ { next }
    /^\[SCRIPT\] Reached end of script definitions/ { next }
    /^\[SCRIPT\] DEBUG_LOG will be:/ { next }
    /^={20,}$/ { next }
    /^     MONITORING STACK AUTOMATION - DEPLOYMENT SCRIPT$/ { next }
    /^  Version:[[:space:]]/ { next }
    /^  Git Commit:[[:space:]]/ { next }
    /^  Build Date:[[:space:]]/ { next }
    /^  Script Start:[[:space:]]/ { next }
    /^OK - imported / { next }
    /^\[INFO\]   \[untar\] / { next }
    { print }
  '
  exit ${PIPESTATUS[0]}
fi
REMOTE_EOF
