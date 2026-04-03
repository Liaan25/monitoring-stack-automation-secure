#!/bin/bash
set -euo pipefail

echo "[RLM-FS] =================================================="
echo "[RLM-FS] START UVS_LINUX_EXTEND_FS2"
echo "[RLM-FS] target_fqdn=${SERVER_FQDN:-<empty>}"
echo "[RLM-FS] target_ip=${SERVER_IP:-<empty>}"
echo "[RLM-FS] mount=${MOUNT_POINT:-<empty>} vg=${VG_NAME:-<empty>} lv=${LV_NAME:-<empty>} size_gb=${SIZE_GB:-<empty>}"
echo "[RLM-FS] table_id=${TABLE_ID:-<empty>}"
echo "[RLM-FS] =================================================="

required_vars=(RLM_API_URL RLM_TOKEN NAMESPACE_CI SERVER_FQDN SERVER_IP MOUNT_POINT VG_NAME LV_NAME SIZE_GB TABLE_ID)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "[RLM-FS][ERROR] required var is empty: ${v}"
    exit 2
  fi
done

if ! [[ "${SIZE_GB}" =~ ^[0-9]+$ ]] || [[ "${SIZE_GB}" -le 0 ]]; then
  echo "[RLM-FS][ERROR] SIZE_GB must be positive integer, got: ${SIZE_GB}"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[RLM-FS][ERROR] jq is required"
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "[RLM-FS][ERROR] curl is required"
  exit 2
fi

max_attempts="${RLM_MAX_ATTEMPTS:-120}"
sleep_sec="${RLM_SLEEP_SEC:-10}"
kae_server="$(echo "${NAMESPACE_CI}" | cut -d'_' -f2)"
mon_ci_user="${kae_server}-lnx-mon_ci"
mon_ci_group="${kae_server}-lnx-mon_ci"

echo "[RLM-FS] Derived KAE=${kae_server}"
echo "[RLM-FS] mon_ci_user=${mon_ci_user}"
echo "[RLM-FS] mon_ci_group=${mon_ci_group}"
echo "[RLM-FS] Poll settings: attempts=${max_attempts}, sleep=${sleep_sec}s"

if [[ ! "${SERVER_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "[RLM-FS] SERVER_IP is not IPv4 literal, trying to resolve from SERVER_FQDN=${SERVER_FQDN}"
  resolved_ip="$(getent ahostsv4 "${SERVER_FQDN}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [[ -z "${resolved_ip}" ]]; then
    resolved_ip="$(nslookup "${SERVER_FQDN}" 2>/dev/null | awk '/^Address: /{print $2; exit}' || true)"
  fi
  if [[ -n "${resolved_ip}" ]]; then
    SERVER_IP="${resolved_ip}"
    echo "[RLM-FS] Resolved SERVER_IP=${SERVER_IP}"
  else
    echo "[RLM-FS][ERROR] Failed to resolve IPv4 for SERVER_FQDN=${SERVER_FQDN}"
    exit 2
  fi
fi

payload="$(
  jq -n \
    --arg vg "${VG_NAME}" \
    --arg lv "${LV_NAME}" \
    --arg mp "${MOUNT_POINT}" \
    --arg usr "${mon_ci_user}" \
    --arg grp "${mon_ci_group}" \
    --arg ip "${SERVER_IP}" \
    --arg table_id "${TABLE_ID}" \
    --argjson size "${SIZE_GB}" \
    '{
      params: {
        skip_sm_conflicts: true,
        VAR_FS: [
          {
            vg: $vg,
            lv: $lv,
            size: $size,
            mount_point: $mp,
            group: $grp,
            user: $usr
          }
        ]
      },
      start_at: "now",
      service: "UVS_LINUX_EXTEND_FS2",
      skip_check_collisions: true,
      items: [
        {
          table_id: $table_id,
          invsvm_ip: $ip
        }
      ]
    }'
)"

echo "[RLM-FS] Payload:"
echo "${payload}" | jq .

create_resp="$(curl -k -sS -X POST "${RLM_API_URL}/api/tasks.json" \
  -H "Accept: application/json" \
  -H "Authorization: Token ${RLM_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${payload}")"

echo "[RLM-FS] Create response:"
echo "${create_resp}" | jq . || true

task_id="$(echo "${create_resp}" | jq -r '.id // empty')"
if [[ -z "${task_id}" ]]; then
  echo "[RLM-FS][ERROR] Task id not found in response"
  exit 3
fi

echo "[RLM-FS] Created task_id=${task_id}"

final_status="unknown"
last_resp=""
for i in $(seq 1 "${max_attempts}"); do
  status_resp="$(curl -k -sS -X GET "${RLM_API_URL}/api/tasks/${task_id}/" \
    -H "Accept: application/json" \
    -H "Authorization: Token ${RLM_TOKEN}" \
    -H "Content-Type: application/json")"

  status="$(echo "${status_resp}" | jq -r '.status // "unknown"')"
  final_status="${status}"
  last_resp="${status_resp}"

  echo "[RLM-FS] poll attempt=${i}/${max_attempts} status=${status}"
  if [[ "${status}" == "success" || "${status}" == "failed" || "${status}" == "error" ]]; then
    break
  fi
  sleep "${sleep_sec}"
done

echo "[RLM-FS] Final status=${final_status}"
echo "[RLM-FS] Final task response:"
echo "${last_resp}" | jq . || true

if [[ "${final_status}" != "success" ]]; then
  echo "[RLM-FS][ERROR] Task finished with status=${final_status}"
  exit 4
fi

if [[ -n "${SSH_USER:-}" ]]; then
  echo "[RLM-FS] Verifying mount point over SSH..."
  ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "${SSH_USER}@${SERVER_FQDN}" \
    "set -e;
     echo '[RLM-FS][REMOTE] findmnt:';
     findmnt '${MOUNT_POINT}' || true;
     echo '[RLM-FS][REMOTE] df:';
     df -h '${MOUNT_POINT}' || true;
     echo '[RLM-FS][REMOTE] perms:';
     stat -c '%U:%G %a %n' '${MOUNT_POINT}' || true;"
fi

echo "[RLM-FS] SUCCESS"
