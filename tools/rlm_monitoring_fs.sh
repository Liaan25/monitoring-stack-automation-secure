#!/bin/bash
set -euo pipefail

emit_result() {
  local reason="${1:-unknown}"
  echo "[RLM-FS-RESULT] reason=${reason}"
}

server="${SERVER_FQDN:-<empty>}"
netapp="${TARGET_NETAPP:-unknown-netapp}"
mount_name_raw="${MOUNT_NAME:-monitoring}"
mount_name="${mount_name_raw#/}"
mount_point="/${mount_name}"
vg_name="${VG_NAME:-rootvg}"
lv_name="${LV_NAME:-$mount_name}"
size_gb="${SIZE_GB:-0}"
table_id="${TABLE_ID:-uvslinuxtemplatewithtestandpromandvirt}"
force_apply="${FORCE_FS_APPLY:-false}"
max_attempts="${RLM_MAX_ATTEMPTS:-120}"
sleep_sec="${RLM_SLEEP_SEC:-10}"
server_ip="${SERVER_IP:-}"

echo "┌────────────────────────────────────────────────────────────┐"
printf "│  🗄️  ПОДГОТОВКА FS: %-35s │\n" "${mount_point}"
printf "│  Server: %-48s │\n" "${server}"
printf "│  NetApp: %-48s │\n" "${netapp}"
printf "│  Size: %-50s │\n" "${size_gb} GB"
printf "│  Force apply: %-43s │\n" "${force_apply}"
echo "└────────────────────────────────────────────────────────────┘"

required_vars=(RLM_API_URL RLM_TOKEN NAMESPACE_CI SERVER_FQDN SIZE_GB TABLE_ID)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "[RLM-FS][ERROR] required var is empty: ${v}"
    emit_result "validation_missing_${v}"
    exit 2
  fi
done

if ! [[ "${size_gb}" =~ ^[0-9]+$ ]] || [[ "${size_gb}" -le 0 ]]; then
  echo "[RLM-FS][ERROR] SIZE_GB must be positive integer, got: ${size_gb}"
  emit_result "validation_bad_size"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[RLM-FS][ERROR] jq is required"
  emit_result "dependency_jq_missing"
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "[RLM-FS][ERROR] curl is required"
  emit_result "dependency_curl_missing"
  exit 2
fi

kae_server="$(echo "${NAMESPACE_CI}" | cut -d'_' -f2)"
mon_ci_user="${kae_server}-lnx-mon_ci"
mon_ci_group="${kae_server}-lnx-mon_ci"

echo "[RLM-FS] Derived KAE=${kae_server}"
echo "[RLM-FS] mon_ci_user=${mon_ci_user}"
echo "[RLM-FS] mon_ci_group=${mon_ci_group}"
echo "[RLM-FS] Poll settings: attempts=${max_attempts}, sleep=${sleep_sec}s"

if [[ -n "${SSH_USER:-}" && "${force_apply}" != "true" ]]; then
  if ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
      "${SSH_USER}@${server}" "findmnt '${mount_point}' >/dev/null 2>&1"; then
    current_df="$(ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
      "${SSH_USER}@${server}" "df -h '${mount_point}' 2>/dev/null | tail -1 || true" || true)"
    echo "🗄️ FS ${mount_point} │ server: ${server} │ netapp: ${netapp} │ Статус: already-exists ✅ │ reason: skip_without_force"
    [[ -n "${current_df}" ]] && echo "[RLM-FS] Текущий размер: ${current_df}"
    emit_result "skipped_existing_mount"
    exit 0
  fi
fi

if [[ ! "${server_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "[RLM-FS] SERVER_IP is not IPv4 literal, trying to resolve from SERVER_FQDN=${server}"
  resolved_ip="$(getent ahostsv4 "${server}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [[ -z "${resolved_ip}" ]]; then
    resolved_ip="$(nslookup "${server}" 2>/dev/null | awk '/^Address: /{print $2; exit}' || true)"
  fi
  if [[ -n "${resolved_ip}" ]]; then
    server_ip="${resolved_ip}"
    echo "[RLM-FS] Resolved SERVER_IP=${server_ip}"
  else
    echo "[RLM-FS][ERROR] Failed to resolve IPv4 for SERVER_FQDN=${server}"
    emit_result "validation_resolve_ip_failed"
    exit 2
  fi
fi

payload="$(
  jq -n \
    --arg vg "${vg_name}" \
    --arg lv "${lv_name}" \
    --arg mp "${mount_point}" \
    --arg usr "${mon_ci_user}" \
    --arg grp "${mon_ci_group}" \
    --arg ip "${server_ip}" \
    --arg table_id "${table_id}" \
    --argjson size "${size_gb}" \
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
  echo "[RLM-FS][ERROR] RLM API URL: ${RLM_API_URL}/api/tasks.json"
  emit_result "create_failed_no_task_id"
  exit 3
fi

echo "[SUCCESS] ✅ FS задача создана. ID: ${task_id}"
echo ""
echo "┌────────────────────────────────────────────────────────────┐"
printf "│  🗄️  UVS_LINUX_EXTEND_FS2: %-31s │\n" "${mount_point}"
printf "│  Task ID: %-47s │\n" "${task_id}"
printf "│  Max attempts: %-3d (интервал: %2dс)                      │\n" "${max_attempts}" "${sleep_sec}"
echo "└────────────────────────────────────────────────────────────┘"
echo ""

final_status="unknown"
last_resp=""
start_ts="$(date +%s)"

for i in $(seq 1 "${max_attempts}"); do
  status_resp="$(curl -k -sS -X GET "${RLM_API_URL}/api/tasks/${task_id}/" \
    -H "Accept: application/json" \
    -H "Authorization: Token ${RLM_TOKEN}" \
    -H "Content-Type: application/json")"

  status="$(echo "${status_resp}" | jq -r '.status // "unknown"')"
  final_status="${status}"
  last_resp="${status_resp}"

  now_ts="$(date +%s)"
  elapsed_sec=$(( now_ts - start_ts ))
  elapsed_min="$(awk -v s="${elapsed_sec}" 'BEGIN{printf "%.1f", s/60}')"

  status_icon="⏳"
  case "${status}" in
    success) status_icon="✅" ;;
    failed|error|canceled|aborted) status_icon="❌" ;;
    approved|performing|in_progress|pending|running) status_icon="⏳" ;;
  esac

  echo "🗄️ FS ${mount_point} │ server: ${server} │ netapp: ${netapp} │ Попытка ${i}/${max_attempts} │ Статус: ${status} ${status_icon} │ Время: ${elapsed_min}м (${elapsed_sec}с)"

  if [[ "${status}" == "success" || "${status}" == "failed" || "${status}" == "error" || "${status}" == "canceled" || "${status}" == "aborted" ]]; then
    break
  fi
  sleep "${sleep_sec}"
done

echo "[RLM-FS] Final status=${final_status}"
echo "[RLM-FS] Final task response:"
echo "${last_resp}" | jq . || true

if [[ "${final_status}" != "success" ]]; then
  echo "[RLM-FS][ERROR] Task finished with status=${final_status}"
  echo "[RLM-FS][ERROR] RLM status URL: ${RLM_API_URL}/api/tasks/${task_id}/"
  echo "[RLM-FS][ERROR] Parsed status: $(echo "${last_resp}" | jq -c '{status: .status, id: .id, state: .state, message: (.payload.mess // .message // .error // empty)}' 2>/dev/null || echo 'unparsed')"
  emit_result "failed_status_${final_status}"
  exit 4
fi

result_sts="$(echo "${last_resp}" | jq -r '.payload.sts // empty' 2>/dev/null || true)"
result_msg="$(echo "${last_resp}" | jq -r '.payload.mess // empty' 2>/dev/null || true)"
[[ -n "${result_sts}" ]] && echo "[RLM-FS] result.sts=${result_sts}"
[[ -n "${result_msg}" ]] && echo "[RLM-FS] result.mess=${result_msg}"

if [[ -n "${SSH_USER:-}" ]]; then
  echo "[RLM-FS] Verifying mount point over SSH..."
  ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "${SSH_USER}@${server}" \
    "set -e;
     echo '[RLM-FS][REMOTE] findmnt:';
     findmnt '${mount_point}' || true;
     echo '[RLM-FS][REMOTE] df:';
     df -h '${mount_point}' || true;
     echo '[RLM-FS][REMOTE] perms:';
     stat -c '%U:%G %a %n' '${mount_point}' || true;"
fi

echo "✅ FS ${mount_point} ГОТОВ на ${server}"
emit_result "applied_success"
