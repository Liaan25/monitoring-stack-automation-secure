#!/bin/bash
set -euo pipefail

emit_result() {
  local reason="${1:-unknown}"
  echo "[RLM-FS-RESULT] reason=${reason}"
}

RLM_TLS_CERT_FILE="${RLM_TLS_CERT_FILE:-}"
RLM_TLS_KEY_FILE="${RLM_TLS_KEY_FILE:-}"
RLM_TLS_CA_FILE="${RLM_TLS_CA_FILE:-}"
RLM_MTLS_TMP_DIR=""

cleanup_mtls_tmp_dir() {
  if [[ -n "${RLM_MTLS_TMP_DIR:-}" && -d "${RLM_MTLS_TMP_DIR}" ]]; then
    rm -rf "${RLM_MTLS_TMP_DIR}" >/dev/null 2>&1 || true
  fi
}

prepare_mtls_materials_if_needed() {
  if [[ -n "${RLM_TLS_CERT_FILE}" && -n "${RLM_TLS_KEY_FILE}" ]]; then
    [[ -r "${RLM_TLS_CERT_FILE}" ]] || { echo "[RLM-FS][ERROR] RLM_TLS_CERT_FILE unreadable: ${RLM_TLS_CERT_FILE}"; return 1; }
    [[ -r "${RLM_TLS_KEY_FILE}" ]] || { echo "[RLM-FS][ERROR] RLM_TLS_KEY_FILE unreadable: ${RLM_TLS_KEY_FILE}"; return 1; }
    if [[ -n "${RLM_TLS_CA_FILE}" ]]; then
      [[ -r "${RLM_TLS_CA_FILE}" ]] || { echo "[RLM-FS][ERROR] RLM_TLS_CA_FILE unreadable: ${RLM_TLS_CA_FILE}"; return 1; }
    fi
    echo "[RLM-FS] mTLS: using explicit cert/key paths"
    return 0
  fi

  local cred_json="${CRED_JSON_FILE:-${CRED_JSON_PATH:-}}"
  if [[ -z "${cred_json}" || ! -f "${cred_json}" ]]; then
    echo "[RLM-FS][ERROR] CRED_JSON_FILE is not set or file missing (mTLS required)"
    return 1
  fi

  command -v jq >/dev/null 2>&1 || { echo "[RLM-FS][ERROR] jq is required for mTLS extraction"; return 1; }
  command -v openssl >/dev/null 2>&1 || { echo "[RLM-FS][ERROR] openssl is required for mTLS extraction"; return 1; }

  local tmp_dir bundle_file cert_file key_file ca_file
  tmp_dir="$(mktemp -d /tmp/rlm-fs-mtls-XXXXXX)"
  chmod 700 "${tmp_dir}" || true

  bundle_file="${tmp_dir}/client_bundle.pem"
  cert_file="${tmp_dir}/client.crt"
  key_file="${tmp_dir}/client.key"
  ca_file="${tmp_dir}/ca_chain.crt"

  jq -r '.certificates.grafana_client_pem // .certificates.server_bundle_pem // empty' "${cred_json}" > "${bundle_file}" 2>/dev/null || true
  if [[ ! -s "${bundle_file}" ]]; then
    echo "[RLM-FS][ERROR] mTLS bundle is empty in ${cred_json}"
    rm -rf "${tmp_dir}" >/dev/null 2>&1 || true
    return 1
  fi

  openssl pkey -in "${bundle_file}" -out "${key_file}" >/dev/null 2>&1 || { echo "[RLM-FS][ERROR] failed to extract client private key"; rm -rf "${tmp_dir}" >/dev/null 2>&1 || true; return 1; }
  openssl crl2pkcs7 -nocrl -certfile "${bundle_file}" | openssl pkcs7 -print_certs -out "${cert_file}" >/dev/null 2>&1 || { echo "[RLM-FS][ERROR] failed to extract client certificate"; rm -rf "${tmp_dir}" >/dev/null 2>&1 || true; return 1; }

  jq -r '.certificates.ca_chain_crt // empty' "${cred_json}" > "${ca_file}" 2>/dev/null || true
  [[ -s "${ca_file}" ]] || rm -f "${ca_file}" >/dev/null 2>&1 || true

  chmod 600 "${bundle_file}" "${cert_file}" "${key_file}" >/dev/null 2>&1 || true
  [[ -f "${ca_file}" ]] && chmod 600 "${ca_file}" >/dev/null 2>&1 || true

  RLM_TLS_CERT_FILE="${cert_file}"
  RLM_TLS_KEY_FILE="${key_file}"
  RLM_TLS_CA_FILE="${ca_file}"
  RLM_MTLS_TMP_DIR="${tmp_dir}"
  echo "[RLM-FS] mTLS materials prepared from ${cred_json}"
  return 0
}

build_tls_args() {
  local -n out_arr=$1
  out_arr=()
  if ! prepare_mtls_materials_if_needed; then
    return 1
  fi

  [[ -n "${RLM_TLS_CERT_FILE}" && -n "${RLM_TLS_KEY_FILE}" ]] || return 1
  [[ -r "${RLM_TLS_CERT_FILE}" ]] || return 1
  [[ -r "${RLM_TLS_KEY_FILE}" ]] || return 1

  out_arr+=(--tlsv1.2 --cert "${RLM_TLS_CERT_FILE}" --key "${RLM_TLS_KEY_FILE}")
  if [[ -n "${RLM_TLS_CA_FILE}" && -r "${RLM_TLS_CA_FILE}" ]]; then
    out_arr+=(--cacert "${RLM_TLS_CA_FILE}")
  fi
}

verify_remote_mount_writable() {
  local mount_point="$1"
  local server="$2"
  local ssh_user="$3"
  local probe_name
  probe_name=".rlm_fs_write_probe_$$"

  echo "[RLM-FS] Writable probe for ${mount_point} on ${server}"
  if ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
      "${ssh_user}@${server}" \
      "set -e;
       echo '[RLM-FS][REMOTE] findmnt:';
       findmnt -T '${mount_point}' -o TARGET,SOURCE,FSTYPE,OPTIONS || true;
       echo '[RLM-FS][REMOTE] df:';
       df -h '${mount_point}' || true;
       echo '[RLM-FS][REMOTE] perms:';
       ls -ld '${mount_point}' || true;
       echo '[RLM-FS][REMOTE] write probe start';
       : > '${mount_point}/${probe_name}';
       rm -f '${mount_point}/${probe_name}';
       echo '[RLM-FS][REMOTE] write probe: OK'"; then
    return 0
  fi

  echo "[RLM-FS][ERROR] Writable probe failed for ${mount_point} on ${server}"
  collect_remote_ro_diagnostics "${mount_point}" "${server}" "${ssh_user}"
  return 1
}

collect_remote_ro_diagnostics() {
  local mount_point="$1"
  local server="$2"
  local ssh_user="$3"

  echo "[RLM-FS] Collecting extended readonly diagnostics for ${mount_point} on ${server}"
  ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    "${ssh_user}@${server}" \
    "set +e;
     echo '[RLM-FS][REMOTE-DIAG] ===== READONLY FORENSICS START =====';
     echo '[RLM-FS][REMOTE-DIAG] date:'; date;
     echo '[RLM-FS][REMOTE-DIAG] hostname:'; hostname -f 2>/dev/null || hostname;
     echo '[RLM-FS][REMOTE-DIAG] user:'; id;
     echo '[RLM-FS][REMOTE-DIAG] uname:'; uname -a;
     echo '[RLM-FS][REMOTE-DIAG] findmnt -T mount_point:'; findmnt -T '${mount_point}' -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true;
     echo '[RLM-FS][REMOTE-DIAG] /proc/mounts entry:'; awk '\$2==\"${mount_point}\" {print}' /proc/mounts 2>/dev/null || true;
     echo '[RLM-FS][REMOTE-DIAG] df -Th:'; df -Th '${mount_point}' 2>/dev/null || true;
     echo '[RLM-FS][REMOTE-DIAG] df -i:'; df -i '${mount_point}' 2>/dev/null || true;
     echo '[RLM-FS][REMOTE-DIAG] ls -ld mount and parent:'; ls -ld '${mount_point}' \"\$(dirname '${mount_point}')\" 2>/dev/null || true;
     echo '[RLM-FS][REMOTE-DIAG] lsblk -f:'; lsblk -f 2>/dev/null || true;
     echo '[RLM-FS][REMOTE-DIAG] fstab entry:'; awk '(\$1 !~ /^#/ && \$2==\"${mount_point}\") {print}' /etc/fstab 2>/dev/null || true;
     echo '[RLM-FS][REMOTE-DIAG] manual write probe in mount root:'; : > '${mount_point}/.rlm_fs_forensics_probe_$$' 2>/tmp/rlm_fs_forensics.err && rm -f '${mount_point}/.rlm_fs_forensics_probe_$$' || true;
     if [ -s /tmp/rlm_fs_forensics.err ]; then
       echo '[RLM-FS][REMOTE-DIAG] write probe stderr:'; cat /tmp/rlm_fs_forensics.err;
     fi;
     rm -f /tmp/rlm_fs_forensics.err 2>/dev/null || true;
     echo '[RLM-FS][REMOTE-DIAG] dmesg (tail 200):';
     (dmesg -T 2>/dev/null | egrep -i 'ext4|xfs|btrfs|I/O error|read-only|remount|buffer i/o' | tail -n 200) || echo '[RLM-FS][REMOTE-DIAG] dmesg unavailable (likely permission restricted)';
     echo '[RLM-FS][REMOTE-DIAG] journalctl -k (tail 200):';
     (journalctl -k --no-pager -n 200 2>/dev/null | egrep -i 'ext4|xfs|btrfs|I/O error|read-only|remount|buffer i/o') || echo '[RLM-FS][REMOTE-DIAG] journalctl unavailable or restricted';
     echo '[RLM-FS][REMOTE-DIAG] ===== READONLY FORENSICS END =====';" || true
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
trap cleanup_mtls_tmp_dir EXIT

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

if ! command -v openssl >/dev/null 2>&1; then
  echo "[RLM-FS][ERROR] openssl is required"
  emit_result "dependency_openssl_missing"
  exit 2
fi

kae_server="$(echo "${NAMESPACE_CI}" | cut -d'_' -f2)"
mon_ci_user="${kae_server}-lnx-mon_ci"
mon_ci_group="${kae_server}-lnx-mon_ci"

echo "[RLM-FS] Derived KAE=${kae_server}"
echo "[RLM-FS] mon_ci_user=${mon_ci_user}"
echo "[RLM-FS] mon_ci_group=${mon_ci_group}"
echo "[RLM-FS] Poll settings: attempts=${max_attempts}, sleep=${sleep_sec}s"

tls_args=()
if ! build_tls_args tls_args; then
  echo "[RLM-FS][ERROR] Unable to prepare mTLS materials for RLM API"
  emit_result "mtls_prepare_failed"
  exit 2
fi
echo "[RLM-FS] mTLS enabled for RLM API"

if [[ -n "${SSH_USER:-}" && "${force_apply}" != "true" ]]; then
  if ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
      "${SSH_USER}@${server}" "findmnt '${mount_point}' >/dev/null 2>&1"; then
    current_df="$(ssh -q -o StrictHostKeyChecking=no -o LogLevel=ERROR \
      "${SSH_USER}@${server}" "df -h '${mount_point}' 2>/dev/null | tail -1 || true" || true)"
    if verify_remote_mount_writable "${mount_point}" "${server}" "${SSH_USER}"; then
      echo "🗄️ FS ${mount_point} │ server: ${server} │ netapp: ${netapp} │ Статус: already-exists ✅ │ reason: skip_without_force"
      [[ -n "${current_df}" ]] && echo "[RLM-FS] Текущий размер: ${current_df}"
      emit_result "skipped_existing_mount"
      exit 0
    else
      echo "🗄️ FS ${mount_point} │ server: ${server} │ netapp: ${netapp} │ Статус: already-exists ❌ │ reason: existing_mount_not_writable"
      emit_result "existing_mount_not_writable"
      exit 5
    fi
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

set +e
create_resp="$(curl -sS -X POST "${RLM_API_URL}/api/tasks.json" \
  -H "Accept: application/json" \
  -H "Authorization: Token ${RLM_TOKEN}" \
  -H "Content-Type: application/json" \
  "${tls_args[@]}" \
  -d "${payload}" 2>&1)"
create_rc=$?
set -e
if [[ ${create_rc} -ne 0 ]]; then
  echo "[RLM-FS][ERROR] Create request failed (curl rc=${create_rc})"
  echo "[RLM-FS][ERROR] ${create_resp}"
  if [[ ${create_rc} -eq 56 ]]; then
    emit_result "curl_56_mtls_certificate_required"
  else
    emit_result "curl_create_rc_${create_rc}"
  fi
  exit 3
fi

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
  set +e
  status_resp="$(curl -sS -X GET "${RLM_API_URL}/api/tasks/${task_id}/" \
    -H "Accept: application/json" \
    -H "Authorization: Token ${RLM_TOKEN}" \
    -H "Content-Type: application/json" \
    "${tls_args[@]}" 2>&1)"
  status_rc=$?
  set -e
  if [[ ${status_rc} -ne 0 ]]; then
    echo "[RLM-FS][ERROR] Status request failed for task ${task_id} (curl rc=${status_rc})"
    echo "[RLM-FS][ERROR] ${status_resp}"
    emit_result "curl_status_rc_${status_rc}"
    exit 4
  fi

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

  if ! verify_remote_mount_writable "${mount_point}" "${server}" "${SSH_USER}"; then
    emit_result "applied_but_not_writable"
    exit 6
  fi
fi

echo "✅ FS ${mount_point} ГОТОВ на ${server}"
emit_result "applied_success"
