#!/bin/bash
set -euo pipefail

SSH_OPTS="-q -T -o StrictHostKeyChecking=no -o LogLevel=ERROR"

ssh ${SSH_OPTS} "${SSH_USER}@${TARGET_SERVER}" \
  TARGET_SERVER="${TARGET_SERVER}" \
  RUN_SERVICES_AS_MON_CI="${RUN_SERVICES_AS_MON_CI:-true}" \
  DEPLOY_USER="${DEPLOY_USER:-}" \
  MON_SYS_USER="${MON_SYS_USER:-}" \
  PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}" \
  GRAFANA_PORT="${GRAFANA_PORT:-3300}" \
  /bin/bash -s 2>/dev/null <<'ENDSSH'
set -euo pipefail

HARVEST_UNIX_PORT=12995
HARVEST_NETAPP_PORT=12996
NODE_EXPORTER_PORT=9100

if [[ "${RUN_SERVICES_AS_MON_CI}" == "true" ]]; then
  RUNTIME_USER="${DEPLOY_USER}"
else
  RUNTIME_USER="${MON_SYS_USER}"
fi

RUNTIME_UID="$(id -u "${RUNTIME_USER}" 2>/dev/null || true)"
SERVER_DOMAIN="$(hostname -f 2>/dev/null || hostname)"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="${TARGET_SERVER}"
fi

if [[ -n "${RUNTIME_UID}" ]]; then
  echo "[VERIFY] ${TARGET_SERVER}: user=${RUNTIME_USER}, uid=${RUNTIME_UID}"
else
  echo "[VERIFY] ${TARGET_SERVER}: не удалось определить uid runtime-user=${RUNTIME_USER}"
fi

get_http_code() {
  local url="$1"
  curl -k -sS -o /dev/null -w "%{http_code}" --max-time 8 "$url" 2>/dev/null || echo "000"
}

status_text() {
  local code="$1"
  [[ "$code" =~ ^2[0-9][0-9]$ ]] && echo "ok" || echo "fail"
}

prom_code="$(get_http_code "https://127.0.0.1:${PROMETHEUS_PORT}/-/ready")"
graf_code="$(get_http_code "https://127.0.0.1:${GRAFANA_PORT}/api/health")"
harv_n_code="$(get_http_code "https://127.0.0.1:${HARVEST_NETAPP_PORT}/metrics")"
harv_u_code="$(get_http_code "http://127.0.0.1:${HARVEST_UNIX_PORT}/metrics")"

prom_ver="$(rpm -q --qf '%{VERSION}-%{RELEASE}' prometheus 2>/dev/null || echo 'N/A')"
graf_ver="$(rpm -q --qf '%{VERSION}-%{RELEASE}' grafana 2>/dev/null || echo 'N/A')"
harv_ver="$(rpm -q --qf '%{VERSION}-%{RELEASE}' harvest 2>/dev/null || echo 'N/A')"
node_ver="$($HOME/bin/node_exporter --version 2>/dev/null | head -1 | sed 's/^node_exporter, version[[:space:]]*//' || true)"
if [[ -z "${node_ver}" ]]; then
  node_ver="N/A"
fi

json="$(jq -nc \
  --arg server "${TARGET_SERVER}" \
  --arg server_ip "${SERVER_IP}" \
  --arg server_domain "${SERVER_DOMAIN}" \
  --arg runtime_user "${RUNTIME_USER}" \
  --arg prom_ver "${prom_ver}" \
  --arg graf_ver "${graf_ver}" \
  --arg harv_ver "${harv_ver}" \
  --arg node_ver "${node_ver}" \
  --arg prom_code "${prom_code}" \
  --arg graf_code "${graf_code}" \
  --arg harv_n_code "${harv_n_code}" \
  --arg harv_u_code "${harv_u_code}" \
  --arg prom_port "${PROMETHEUS_PORT}" \
  --arg graf_port "${GRAFANA_PORT}" \
  --arg harv_n_port "${HARVEST_NETAPP_PORT}" \
  --arg harv_u_port "${HARVEST_UNIX_PORT}" \
  '{
    server: $server,
    server_ip: $server_ip,
    server_domain: $server_domain,
    runtime_user: $runtime_user,
    versions: {
      grafana: $graf_ver,
      prometheus: $prom_ver,
      harvest: $harv_ver,
      node_exporter: $node_ver
    },
    services: {
      prometheus: {
        url: ("https://" + $server_domain + ":" + $prom_port),
        code: $prom_code,
        status: (if ($prom_code|test("^2[0-9][0-9]$")) then "ok" else "fail" end)
      },
      grafana: {
        url: ("https://" + $server_domain + ":" + $graf_port),
        code: $graf_code,
        status: (if ($graf_code|test("^2[0-9][0-9]$")) then "ok" else "fail" end)
      },
      harvest_netapp: {
        url: ("https://" + $server_domain + ":" + $harv_n_port + "/metrics"),
        code: $harv_n_code,
        status: (if ($harv_n_code|test("^2[0-9][0-9]$")) then "ok" else "fail" end)
      },
      harvest_unix: {
        url: ("http://localhost:" + $harv_u_port + "/metrics"),
        code: $harv_u_code,
        status: (if ($harv_u_code|test("^2[0-9][0-9]$")) then "ok" else "fail" end)
      }
    }
  }')"

echo "__VERIFY_JSON__${json}"
ENDSSH
